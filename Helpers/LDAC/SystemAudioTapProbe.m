#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

#ifndef ACOUPLET_AUDIO_HELPER_BUNDLE_ID
#define ACOUPLET_AUDIO_HELPER_BUNDLE_ID "dev.baglayan.Acouplet.research.system-audio-tap"
#endif
#ifndef ACOUPLET_AUDIO_HELPER_STREAM_ONLY
#define ACOUPLET_AUDIO_HELPER_STREAM_ONLY 0
#endif

enum { CaptureStartWaitSeconds = 45, LiveRateChangeBufferSeconds = 18, LiveRateCaptureBufferSeconds = LiveRateChangeBufferSeconds + 2 };

static volatile sig_atomic_t interrupted = 0;
static _Atomic(const char *) permissionDeniedOperation = NULL;

static dispatch_source_t WatchParent(pid_t parent) {
    if (parent <= 1) return NULL;
    dispatch_source_t watcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent,
        DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!watcher) return NULL;
    dispatch_source_set_event_handler(watcher, ^{
        kill(getpid(), SIGTERM);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            kill(getpid(), SIGKILL);
        });
    });
    dispatch_resume(watcher);
    if (getppid() != parent) kill(getpid(), SIGTERM);
    return watcher;
}


typedef struct {
    AudioStreamBasicDescription format;
    float *pcm;
    UInt32 capacity;
    UInt32 callbackFrameBound;
    uint64_t frames;
    uint64_t pipeBytes;
    uint64_t callbacks;
    uint64_t nonzeroFrames;
    double squares[2];
    double peak[2];
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
    AudioTimeStamp firstTime;
    AudioTimeStamp lastTime;
#endif
    atomic_int failed;
    BOOL streaming;
    BOOL checkingPermission;
    atomic_uint_fast64_t produced;
    atomic_uint_fast64_t consumed;
    atomic_uint_fast64_t streamCallbacks;
    atomic_uint highWater;
    atomic_uint largestCallback;
    atomic_uint rejectedFrames;
    AudioConverterRef converter;
    float converterInput[2048];
    uint64_t converterLimit;
} Capture;

static void Interrupt(int value) {
    interrupted = value;
}

static double MonotonicTime(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static BOOL Status(OSStatus status, const char *operation) {
    printf("%s status=%d\n", operation, (int)status);
    if (status == kAudioDevicePermissionsError) atomic_store(&permissionDeniedOperation, operation);
    return status == noErr;
}

static BOOL StartCaptureIO(AudioDeviceID aggregate, AudioDeviceIOProcID io) {
    printf("BEFORE_START_AUDIO monotonic=%.9f\n", MonotonicTime());
    return Status(AudioDeviceStart(aggregate, io), "START_AUDIO");
}

static BOOL ReadFormat(AudioObjectID object, AudioObjectPropertySelector selector,
                       AudioObjectPropertyScope scope, double deadline, AudioStreamBasicDescription *format) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size;
    OSStatus status;
    do {
        size = sizeof(*format);
        status = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, format);
        if (status != kAudioHardwareUnknownPropertyError || interrupted || MonotonicTime() >= deadline) break;
        [NSThread sleepForTimeInterval:0.01];
    } while (!interrupted && MonotonicTime() < deadline);
    if (!Status(status, "READ_FORMAT")) return NO;
    printf("FORMAT object=%u rate=%.9g id=%08X flags=%08X channels=%u bits=%u bytesPerFrame=%u bytesPerPacket=%u framesPerPacket=%u\n",
           object, format->mSampleRate, format->mFormatID, format->mFormatFlags,
           format->mChannelsPerFrame, format->mBitsPerChannel, format->mBytesPerFrame,
           format->mBytesPerPacket, format->mFramesPerPacket);
    return size == sizeof(*format);
}

static UInt32 ReadCallbackFrameBound(AudioObjectID object) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyBufferFrameSizeRange,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioValueRange range;
    UInt32 size = sizeof(range);
    UInt32 bound = 0;
    if (AudioObjectHasProperty(object, &address) &&
        AudioObjectGetPropertyData(object, &address, 0, NULL, &size, &range) == noErr &&
        size == sizeof(range) && range.mMaximum >= 1 && range.mMaximum <= UINT32_MAX)
        bound = (UInt32)ceil(range.mMaximum);
    address.mSelector = kAudioDevicePropertyUsesVariableBufferFrameSizes;
    UInt32 variableBound;
    size = sizeof(variableBound);
    if (AudioObjectHasProperty(object, &address) &&
        AudioObjectGetPropertyData(object, &address, 0, NULL, &size, &variableBound) == noErr &&
        size == sizeof(variableBound))
        bound = MAX(bound, variableBound);
    return bound;
}

static BOOL RingWrite(Capture *capture, const float *samples, UInt32 frames) {
    if (!frames) return YES;
    if (frames > atomic_load_explicit(&capture->largestCallback, memory_order_relaxed))
        atomic_store_explicit(&capture->largestCallback, frames, memory_order_relaxed);
    uint64_t produced = atomic_load_explicit(&capture->produced, memory_order_relaxed);
    uint64_t consumed = atomic_load_explicit(&capture->consumed, memory_order_acquire);
    if (frames > capture->capacity - (produced - consumed)) {
        atomic_store_explicit(&capture->rejectedFrames, frames, memory_order_relaxed);
        atomic_store(&capture->failed, 3);
        return NO;
    }
    UInt32 offset = produced % capture->capacity;
    UInt32 first = MIN(frames, capture->capacity - offset);
    memcpy(capture->pcm + offset * 2, samples, first * 8);
    if (frames > first) memcpy(capture->pcm, samples + first * 2, (frames - first) * 8);
    UInt32 buffered = produced + frames - consumed;
    if (buffered > atomic_load_explicit(&capture->highWater, memory_order_relaxed))
        atomic_store_explicit(&capture->highWater, buffered, memory_order_relaxed);
    atomic_store_explicit(&capture->produced, produced + frames, memory_order_release);
    return YES;
}

static int CheckStreamRing(void) {
    Capture capture = {.capacity = 8};
    atomic_init(&capture.failed, 0);
    atomic_init(&capture.produced, 0);
    atomic_init(&capture.consumed, 0);
    atomic_init(&capture.highWater, 0);
    capture.pcm = calloc(16, sizeof(float));
    assert(capture.pcm);
    float samples[16];
    for (UInt32 frame = 0; frame < 8; frame++) {
        samples[frame * 2] = frame;
        samples[frame * 2 + 1] = -((float)frame);
    }
    assert(RingWrite(&capture, samples, 6));
    atomic_store_explicit(&capture.consumed, 5, memory_order_release);
    for (UInt32 frame = 0; frame < 7; frame++) {
        samples[frame * 2] = frame + 6;
        samples[frame * 2 + 1] = -((float)frame + 6);
    }
    assert(RingWrite(&capture, samples, 7));
    assert(atomic_load(&capture.produced) == 13 && atomic_load(&capture.highWater) == 8);
    assert(!RingWrite(&capture, samples, 1) && atomic_load(&capture.failed) == 3 &&
        atomic_load(&capture.rejectedFrames) == 1);
    assert(atomic_load(&capture.produced) == 13);
    for (uint64_t frame = 5; frame < 13; frame++) {
        assert(capture.pcm[(frame % 8) * 2] == frame);
        assert(capture.pcm[(frame % 8) * 2 + 1] == -((float)frame));
    }
    atomic_store_explicit(&capture.consumed, 13, memory_order_release);
    atomic_store(&capture.failed, 0);
    assert(RingWrite(&capture, samples, 8));
    assert(atomic_load(&capture.produced) == 21 && !atomic_load(&capture.failed));
    for (UInt32 frame = 0; frame < 8; frame++) {
        assert(capture.pcm[((13 + frame) % 8) * 2] == samples[frame * 2]);
        assert(capture.pcm[((13 + frame) % 8) * 2 + 1] == samples[frame * 2 + 1]);
    }
    free(capture.pcm);
    puts("STREAM_RING_CHECK passed: wrap, full, no overwrite, ordered stereo frames, reuse; no audio or Bluetooth.");
    return 0;
}

static BOOL SupportedSampleRate(Float64 rate) {
    return rate == 44100 || rate == 48000 || rate == 88200 || rate == 96000;
}

static OSStatus ConverterInput(AudioConverterRef converter, UInt32 *packets,
                               AudioBufferList *data, AudioStreamPacketDescription **descriptions,
                               void *context) {
    Capture *capture = context;
    uint64_t consumed = atomic_load_explicit(&capture->consumed, memory_order_relaxed);
    uint64_t produced = atomic_load_explicit(&capture->produced, memory_order_acquire);
    produced = MIN(produced, capture->converterLimit);
    UInt32 frames = (UInt32)MIN(produced - consumed, MIN(*packets, 1024));
    *packets = frames;
    data->mNumberBuffers = 1;
    data->mBuffers[0] = (AudioBuffer){2, frames * 8, capture->converterInput};
    if (!frames) return consumed == capture->converterLimit ? noErr : 'ndta';
    for (UInt32 frame = 0; frame < frames; ++frame) {
        UInt32 index = (consumed + frame) % capture->capacity;
        capture->converterInput[frame * 2] = capture->pcm[index * 2];
        capture->converterInput[frame * 2 + 1] = capture->pcm[index * 2 + 1];
        if (!isfinite(capture->converterInput[frame * 2]) || !isfinite(capture->converterInput[frame * 2 + 1])) {
            *packets = 0;
            atomic_store(&capture->failed, 2);
            return kAudio_ParamError;
        }
    }
    atomic_store_explicit(&capture->consumed, consumed + frames, memory_order_release);
    return noErr;
}

static BOOL CreateConverter(Capture *capture, Float64 rate) {
    capture->converterLimit = UINT64_MAX;
    if (capture->format.mSampleRate == rate) return YES;
    AudioStreamBasicDescription output = capture->format;
    output.mSampleRate = rate;
    if (!Status(AudioConverterNew(&capture->format, &output, &capture->converter), "CREATE_RATE_CONVERTER")) return NO;
    UInt32 complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
    UInt32 quality = kAudioConverterQuality_Max;
    if (!Status(AudioConverterSetProperty(capture->converter, kAudioConverterSampleRateConverterComplexity,
        sizeof(complexity), &complexity), "SET_RATE_CONVERTER_COMPLEXITY") ||
        !Status(AudioConverterSetProperty(capture->converter, kAudioConverterSampleRateConverterQuality,
        sizeof(quality), &quality), "SET_RATE_CONVERTER_QUALITY")) return NO;
    UInt32 actualComplexity = 0, actualQuality = 0, size = sizeof(UInt32);
    if (!Status(AudioConverterGetProperty(capture->converter, kAudioConverterSampleRateConverterComplexity,
        &size, &actualComplexity), "READ_RATE_CONVERTER_COMPLEXITY") || size != sizeof(UInt32)) return NO;
    size = sizeof(UInt32);
    if (!Status(AudioConverterGetProperty(capture->converter, kAudioConverterSampleRateConverterQuality,
        &size, &actualQuality), "READ_RATE_CONVERTER_QUALITY") || size != sizeof(UInt32)) return NO;
    if (actualComplexity != complexity || actualQuality != quality) {
        fprintf(stderr, "The audio rate converter did not accept the requested quality.\n");
        return NO;
    }
    printf("PCM_RATE_CONVERSION input=%.9g output=%.9g native=AudioConverter complexity=%08X quality=%u\n",
        capture->format.mSampleRate, rate, actualComplexity, actualQuality);
    return YES;
}

static BOOL ReconfigureCapture(Capture *capture, Float64 rate) {
    if (capture->converter) {
        OSStatus status = AudioConverterDispose(capture->converter);
        capture->converter = NULL;
        if (!Status(status, "DISPOSE_RATE_CONVERTER")) return NO;
    }
    return CreateConverter(capture, rate);
}

static float IndexedSample(uint64_t frame) {
    return (float)(frame % 131072) / 131072 - 0.5f;
}

static void AppendIndexedCapture(Capture *capture) {
    float pcm[512];
    uint64_t first = atomic_load(&capture->produced);
    for (UInt32 frame = 0; frame < 256; ++frame) {
        pcm[frame * 2] = IndexedSample(first + frame);
        pcm[frame * 2 + 1] = -pcm[frame * 2];
    }
    assert(RingWrite(capture, pcm, 256));
}

static void CheckStreamRates(void) {
    Float64 rates[] = {44100, 48000, 88200, 96000};
    for (UInt32 source = 0; source < 4; ++source) {
        for (UInt32 target = 0; target < 4; ++target) {
            Capture capture = {0};
            capture.format = (AudioStreamBasicDescription){rates[source], kAudioFormatLinearPCM,
                kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
            capture.capacity = (UInt32)ceil(32768 * rates[source] / 48000);
            assert(fabs(capture.capacity / rates[source] - 32768.0 / 48000) <= 1 / rates[source]);
            capture.pcm = calloc(capture.capacity * 2, sizeof(float));
            assert(capture.pcm);
            UInt32 inputFrames = (UInt32)(rates[source] / 10);
            for (UInt32 frame = 0; frame < inputFrames; ++frame) {
                capture.pcm[frame * 2] = 0.5 * sin(2 * M_PI * 997 * frame / rates[source]);
                capture.pcm[frame * 2 + 1] = -capture.pcm[frame * 2];
            }
            assert(CreateConverter(&capture, rates[target]));
            if (capture.converter) {
                float initial[2048];
                AudioBufferList initialOutput = {1, {{2, sizeof(initial), initial}}};
                UInt32 initialFrames = 1024;
                assert(AudioConverterFillComplexBuffer(capture.converter, ConverterInput, &capture,
                    &initialFrames, &initialOutput, NULL) == 'ndta' && initialFrames == 0);
                atomic_store(&capture.produced, inputFrames);
                capture.converterLimit = inputFrames;
                UInt32 total = 0;
                double squares = 0;
                for (UInt32 iteration = 0; iteration < 32; ++iteration) {
                    float samples[2048];
                    AudioBufferList output = {1, {{2, sizeof(samples), samples}}};
                    UInt32 frames = 1024;
                    assert(AudioConverterFillComplexBuffer(capture.converter, ConverterInput, &capture,
                        &frames, &output, NULL) == noErr);
                    for (UInt32 frame = 0; frame < frames; ++frame) {
                        assert(isfinite(samples[frame * 2]) && isfinite(samples[frame * 2 + 1]));
                        assert(fabs(samples[frame * 2] + samples[frame * 2 + 1]) < 0.0001);
                        squares += samples[frame * 2] * samples[frame * 2];
                    }
                    total += frames;
                    if (!frames) break;
                }
                assert(fabs(total - rates[target] / 10) < 256 && total > 0 && squares / total > 0.01);
                assert(atomic_load(&capture.consumed) == inputFrames);
                assert(AudioConverterDispose(capture.converter) == noErr);
            } else assert(rates[source] == rates[target]);
            free(capture.pcm);
        }
    }
    puts("STREAM_RATE_CHECK passed: all four rates and native conversion; no capture or Bluetooth.");
}

static BOOL StreamAudioWithClock(Capture *capture, int fd, double duration, pid_t parentPID, BOOL liveRate,
                                UInt32 streamRate, BOOL *clockFrozen, BOOL (^quiesce)(void)) {
    double deadline = duration ? MonotonicTime() + duration : INFINITY;
    enum { Running, Freezing, Frozen, Parked } state = Running;
    uint64_t parkStart = 0;
    char command[32];
    size_t pending = 0;
    BOOL retiring = NO;
    while (!interrupted && !atomic_load(&capture->failed) && MonotonicTime() < deadline) {
        if (parentPID > 1 && getppid() != parentPID) {
            printf("PCM_PARENT_EXIT pid=%d\n", parentPID);
            return !atomic_load(&capture->failed);
        }
        uint64_t consumed = atomic_load_explicit(&capture->consumed, memory_order_relaxed);
        uint64_t produced = atomic_load_explicit(&capture->produced, memory_order_acquire);
        if (liveRate) {
            struct pollfd input = {STDIN_FILENO, POLLIN, 0};
            if (poll(&input, 1, 0) > 0) {
                ssize_t length = read(STDIN_FILENO, command + pending, 1);
                if (length < 0 && errno == EINTR) continue;
                if (length != 1) break;
                if (command[pending] == '\n') {
                    command[pending] = 0;
                    pending = 0;
                    BOOL freezeClock = strcmp(command, "clock-freeze") == 0;
                    if (state == Running && strcmp(command, "park") == 0) {
                        parkStart = consumed;
                        state = Parked;
                        printf("PARK_CAPTURE_PAUSED rate=%u\n", streamRate);
                    } else if (state == Parked && strcmp(command, "warm-resume") == 0) {
                        if (!ReconfigureCapture(capture, streamRate)) {
                            atomic_store(&capture->failed, 7);
                            break;
                        }
                        produced = atomic_load_explicit(&capture->produced, memory_order_acquire);
                        atomic_store_explicit(&capture->consumed, produced, memory_order_release);
                        state = Running;
                        printf("PARK_CAPTURE_RESUMED rate=%u discardedFrames=%llu\n", streamRate,
                               (unsigned long long)(produced - parkStart));
                        continue;
                    } else if (state == Running && (strcmp(command, "freeze") == 0 || (freezeClock && quiesce))) {
                        if (freezeClock && !quiesce()) {
                            atomic_store(&capture->failed, 9);
                            break;
                        }
                        retiring = freezeClock;
                        produced = atomic_load_explicit(&capture->produced, memory_order_acquire);
                        UInt32 observed = atomic_load_explicit(&capture->largestCallback, memory_order_relaxed);
                        uint64_t reserve = (uint64_t)(capture->format.mSampleRate * LiveRateChangeBufferSeconds)
                            + MAX(capture->callbackFrameBound, observed);
                        uint64_t queued = produced - consumed;
                        if (!retiring && reserve > capture->capacity - queued) {
                            printf("CAPTURE_FREEZE_DECLINED rate=%u queuedFrames=%llu reserveFrames=%llu capacityFrames=%u\n",
                                streamRate, (unsigned long long)queued, (unsigned long long)reserve, capture->capacity);
                            continue;
                        }
                        capture->converterLimit = retiring ? produced : consumed;
                        state = Freezing;
                    } else {
                        char *end = NULL;
                        long rate = strncmp(command, "rate ", 5) == 0 ? strtol(command + 5, &end, 10) : 0;
                        if (state != Frozen || !SupportedSampleRate(rate) || *end) {
                            atomic_store(&capture->failed, 8);
                            break;
                        }
                        if (!ReconfigureCapture(capture, rate)) {
                            atomic_store(&capture->failed, 7);
                            break;
                        }
                        streamRate = (UInt32)rate;
                        state = Running;
                        printf("PCM_CAPTURE_RESUMED rate=%ld\n", rate);
                        continue;
                    }
                } else {
                    if (!command[pending] || ++pending == sizeof(command)) {
                        atomic_store(&capture->failed, 8);
                        break;
                    }
                    continue;
                }
            }
        }
        if (state == Parked) {
            atomic_store_explicit(&capture->consumed, produced, memory_order_release);
            [NSThread sleepForTimeInterval:0.001];
            continue;
        }
        if (state == Frozen || (state == Running && produced == consumed)) {
            [NSThread sleepForTimeInterval:0.001];
            continue;
        }
        if (state == Freezing) produced = capture->converterLimit;
        UInt32 offset = consumed % capture->capacity;
        UInt32 frames = (UInt32)MIN(produced - consumed, MIN(capture->capacity - offset, 1024));
        const float *samples = capture->pcm + offset * 2;
        float converted[2048];
        OSStatus status = noErr;
        if (capture->converter) {
            AudioBufferList output = {1, {{2, sizeof(converted), converted}}};
            frames = 1024;
            status = AudioConverterFillComplexBuffer(capture->converter, ConverterInput, capture,
                &frames, &output, NULL);
            if (status != noErr && status != 'ndta') {
                Status(status, "CONVERT_PCM_RATE");
                atomic_store(&capture->failed, 7);
                break;
            }
            samples = converted;
        }
        if (!frames) {
            if (state == Freezing && status == noErr &&
                atomic_load_explicit(&capture->consumed, memory_order_relaxed) == capture->converterLimit) {
                printf("CAPTURE_FROZEN rate=%u bytes=%llu sourceFrames=%llu\n", streamRate,
                    (unsigned long long)(capture->frames * 8), (unsigned long long)capture->converterLimit);
                if (retiring) {
                    *clockFrozen = YES;
                    return YES;
                }
                state = Frozen;
            }
            [NSThread sleepForTimeInterval:0.001];
            continue;
        }
        for (UInt32 index = 0; index < frames * 2; index++) {
            if (!isfinite(samples[index])) {
                atomic_store(&capture->failed, 2);
                break;
            }
        }
        if (atomic_load(&capture->failed)) break;
        size_t bytes = frames * 8, written = 0;
        double stallDeadline = MonotonicTime() + 0.5;
        while (written < bytes && !interrupted && !atomic_load(&capture->failed) && MonotonicTime() < deadline) {
            if (parentPID > 1 && getppid() != parentPID) {
                printf("PCM_PARENT_EXIT pid=%d\n", parentPID);
                return !atomic_load(&capture->failed);
            }
            ssize_t result = write(fd, (const uint8_t *)samples + written, bytes - written);
            if (result > 0) {
                written += result;
                capture->pipeBytes += (uint64_t)result;
                stallDeadline = MonotonicTime() + 0.5;
            } else if (result < 0 && errno == EINTR) continue;
            else if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (MonotonicTime() >= stallDeadline) {
                    fprintf(stderr, "PCM_PIPE_STALL milliseconds=500\n");
                    atomic_store(&capture->failed, 5);
                    break;
                }
                struct pollfd writable = {fd, POLLOUT, 0};
                int ready = poll(&writable, 1, 10);
                if ((ready < 0 && errno != EINTR) || (ready > 0 && (writable.revents & (POLLERR | POLLHUP | POLLNVAL)))) {
                    fprintf(stderr, "PCM_PIPE_CLOSED revents=%d errno=%d\n", writable.revents, errno);
                    atomic_store(&capture->failed, 6);
                }
            } else {
                fprintf(stderr, "PCM_PIPE_WRITE result=%zd errno=%d\n", result, errno);
                atomic_store(&capture->failed, 6);
            }
        }
        if (written != bytes) break;
        for (UInt32 frame = 0; frame < frames; frame++) {
            BOOL nonzero = NO;
            for (UInt32 channel = 0; channel < 2; channel++) {
                double sample = samples[frame * 2 + channel];
                capture->squares[channel] += sample * sample;
                capture->peak[channel] = fmax(capture->peak[channel], fabs(sample));
                nonzero |= sample != 0;
            }
            capture->nonzeroFrames += nonzero;
        }
        capture->frames += frames;
        if (!capture->converter) atomic_store_explicit(&capture->consumed, consumed + frames, memory_order_release);
    }
    return !atomic_load(&capture->failed);
}

static BOOL StreamAudio(Capture *capture, int fd, double duration, pid_t parentPID, BOOL liveRate, UInt32 streamRate) {
    return StreamAudioWithClock(capture, fd, duration, parentPID, liveRate, streamRate, NULL, nil);
}

static void ReadCaptureFixture(int fd, void *buffer, size_t length) {
    size_t received = 0;
    while (received < length) {
        struct pollfd readable = {fd, POLLIN, 0};
        assert(poll(&readable, 1, 1000) == 1 && (readable.revents & POLLIN));
        ssize_t count = read(fd, (uint8_t *)buffer + received, length - received);
        assert(count > 0);
        received += count;
    }
}

static void ReadCaptureEvent(int fd, const char *prefix, char line[static 256]) {
    do {
        size_t length = 0;
        do {
            assert(length + 1 < 256);
            ReadCaptureFixture(fd, line + length, 1);
        } while (line[length++] != '\n');
        line[length - 1] = 0;
    } while (strncmp(line, prefix, strlen(prefix)) != 0);
}

static void CheckCaptureEpochPCM(const float *pcm, UInt32 rate, uint64_t start, UInt32 frames) {
    for (UInt32 frame = 0; frame < frames; ++frame) {
        float expected = IndexedSample(start + frame * 96000 / rate);
        assert(fabs(pcm[frame * 2] + pcm[frame * 2 + 1]) < 0.0001);
        if (rate == 96000) assert(pcm[frame * 2] == expected);
        else if (frame >= 256 && frame + 256 < frames) assert(fabs(pcm[frame * 2] - expected) < 0.0001);
    }
}

static void CheckCapturePark(void) {
    const UInt32 rate = 96000;
    Capture capture = {.capacity = LiveRateCaptureBufferSeconds * rate};
    capture.format = (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
    capture.pcm = calloc(capture.capacity * 2, sizeof(float));
    uint64_t first = capture.capacity - 512;
    atomic_init(&capture.produced, first);
    atomic_init(&capture.consumed, first);
    assert(capture.pcm && CreateConverter(&capture, rate));
    AppendIndexedCapture(&capture);

    int pcm[2], commands[2], events[2];
    assert(pipe(pcm) == 0 && pipe(commands) == 0 && pipe(events) == 0 && fcntl(pcm[1], F_SETFL, O_NONBLOCK) == 0);
    int savedInput = dup(STDIN_FILENO), savedOutput = dup(STDOUT_FILENO);
    assert(savedInput >= 0 && savedOutput >= 0);
    assert(dup2(commands[0], STDIN_FILENO) >= 0 && dup2(events[1], STDOUT_FILENO) >= 0);
    dispatch_group_t group = dispatch_group_create();
    Capture *stream = &capture;
    int output = pcm[1];
    __block BOOL completed;
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { completed = StreamAudio(stream, output, 5, 0, YES, rate); }
    });

    float samples[512];
    ReadCaptureFixture(pcm[0], samples, sizeof(samples));
    CheckCaptureEpochPCM(samples, rate, first, 256);
    assert(write(commands[1], "park\n", 5) == 5);
    char line[256];
    ReadCaptureEvent(events[0], "PARK_CAPTURE_PAUSED ", line);
    assert(strcmp(line, "PARK_CAPTURE_PAUSED rate=96000") == 0);
    for (UInt32 block = 0; block < 8; ++block) AppendIndexedCapture(&capture);
    struct pollfd readable = {pcm[0], POLLIN, 0};
    assert(poll(&readable, 1, 30) == 0);
    assert(write(commands[1], "warm-resume\n", 12) == 12);
    ReadCaptureEvent(events[0], "PARK_CAPTURE_RESUMED ", line);
    assert(strcmp(line, "PARK_CAPTURE_RESUMED rate=96000 discardedFrames=2048") == 0);
    AppendIndexedCapture(&capture);
    ReadCaptureFixture(pcm[0], samples, sizeof(samples));
    CheckCaptureEpochPCM(samples, rate, first + 256 + 2048, 256);

    close(commands[1]);
    assert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 && completed);
    assert(capture.pipeBytes == 2 * sizeof(samples));
    assert(dup2(savedInput, STDIN_FILENO) >= 0 && dup2(savedOutput, STDOUT_FILENO) >= 0);
    close(savedInput);
    close(savedOutput);
    close(commands[0]);
    close(events[0]);
    close(events[1]);
    close(pcm[0]);
    close(pcm[1]);
    free(capture.pcm);
}

static int CheckCaptureRateBoundary(void) {
    UInt32 rates[][2] = {{96000, 48000}, {48000, 96000}, {48000, 48000}, {44100, 48000}};
    enum { epochFrames = 3840 };
    for (UInt32 run = 0; run < sizeof(rates) / sizeof(rates[0]); ++run) {
        UInt32 oldRate = rates[run][0], newRate = rates[run][1];
        Capture capture = {.capacity = LiveRateCaptureBufferSeconds * 96000};
        capture.format = (AudioStreamBasicDescription){96000, kAudioFormatLinearPCM,
            kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
        capture.pcm = calloc(capture.capacity * 2, sizeof(float));
        uint64_t first = capture.capacity - 2048;
        atomic_init(&capture.produced, first);
        atomic_init(&capture.consumed, first);
        assert(capture.pcm && CreateConverter(&capture, oldRate));
        for (UInt32 block = 0; block < epochFrames / 256; ++block) AppendIndexedCapture(&capture);

        int pcm[2], commands[2], events[2];
        assert(pipe(pcm) == 0 && pipe(commands) == 0 && pipe(events) == 0);
        assert(fcntl(pcm[1], F_SETFL, O_NONBLOCK) == 0);
        size_t filled = 0;
        char filler[4096] = {0};
        ssize_t result;
        while ((result = write(pcm[1], filler, sizeof(filler))) > 0) filled += result;
        assert(result == -1 && errno == EAGAIN && filled > sizeof(filler));
        const size_t room = 257;
        ReadCaptureFixture(pcm[0], filler, room);

        int savedInput = dup(STDIN_FILENO), savedOutput = dup(STDOUT_FILENO);
        assert(savedInput >= 0 && savedOutput >= 0);
        assert(dup2(commands[0], STDIN_FILENO) >= 0 && dup2(events[1], STDOUT_FILENO) >= 0);
        dispatch_group_t group = dispatch_group_create();
        Capture *stream = &capture;
        int output = pcm[1];
        __block BOOL completed;
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { completed = StreamAudio(stream, output, 5, 0, YES, oldRate); }
        });

        int queued = 0;
        double deadline = MonotonicTime() + 1;
        do {
            assert(ioctl(pcm[0], FIONREAD, &queued) == 0 && MonotonicTime() < deadline);
            if (queued != filled) [NSThread sleepForTimeInterval:0.001];
        } while (queued != filled);
        uint64_t boundary = capture.converter ? atomic_load(&capture.consumed) : first + 1024;
        for (UInt32 block = 0; block < epochFrames / 256; ++block) AppendIndexedCapture(&capture);
        uint64_t end = atomic_load(&capture.produced);
        assert(first < boundary && boundary < end);
        assert(write(commands[1], "freeze\n", 7) == 7);
        struct pollfd acknowledgment = {events[0], POLLIN, 0};
        assert(poll(&acknowledgment, 1, 30) == 0);
        for (size_t remaining = filled - room; remaining;) {
            size_t length = MIN(remaining, sizeof(filler));
            ReadCaptureFixture(pcm[0], filler, length);
            remaining -= length;
        }

        char line[256];
        float samples[epochFrames * 4];
        unsigned long long delivered = 0;
        uint64_t epochStart = first;
        for (UInt32 epoch = 0; epoch < 2; ++epoch) {
            UInt32 rate = rates[run][epoch];
            uint64_t epochEnd = epoch ? end : boundary;
            size_t received = 0;
            if (epoch) {
                assert(dprintf(commands[1], "rate %u\n", rate) > 0);
                ReadCaptureEvent(events[0], "PCM_CAPTURE_RESUMED ", line);
                char expected[128];
                snprintf(expected, sizeof(expected), "PCM_CAPTURE_RESUMED rate=%u", rate);
                assert(strcmp(line, expected) == 0);

                struct pollfd readable = {pcm[0], POLLIN, 0};
                double drainDeadline = MonotonicTime() + 1;
                while (atomic_load(&capture.consumed) < epochEnd) {
                    assert(received < sizeof(samples) && MonotonicTime() < drainDeadline);
                    int ready = poll(&readable, 1, 10);
                    assert(ready >= 0);
                    if (!ready) continue;
                    assert(readable.revents & POLLIN);
                    ssize_t count = read(pcm[0], (uint8_t *)samples + received, sizeof(samples) - received);
                    assert(count > 0);
                    received += count;
                }
                assert(write(commands[1], "freeze\n", 7) == 7);
            }

            double expectedFrames = (epochEnd - epochStart) * (double)rate / 96000;
            size_t minimumBytes = (size_t)floor(expectedFrames) * 8;
            if (received < minimumBytes) {
                ReadCaptureFixture(pcm[0], (uint8_t *)samples + received, minimumBytes - received);
                received = minimumBytes;
            }
            ReadCaptureEvent(events[0], "CAPTURE_FROZEN ", line);
            unsigned rateReceipt;
            unsigned long long bytes, sourceFrames;
            assert(sscanf(line, "CAPTURE_FROZEN rate=%u bytes=%llu sourceFrames=%llu",
                &rateReceipt, &bytes, &sourceFrames) == 3);
            assert(rateReceipt == rate && sourceFrames == epochEnd);
            assert(bytes >= delivered + received && bytes - delivered <= sizeof(samples) && (bytes - delivered) % 8 == 0);
            size_t epochBytes = bytes - delivered;
            assert(fabs(epochBytes / 8 - expectedFrames) < 1);
            ReadCaptureFixture(pcm[0], (uint8_t *)samples + received, epochBytes - received);
            CheckCaptureEpochPCM(samples, rate, epochStart, (UInt32)(epochBytes / 8));
            assert(ioctl(pcm[0], FIONREAD, &queued) == 0 && queued == 0);
            assert(atomic_load(&capture.consumed) == epochEnd);
            delivered = bytes;
            epochStart = epochEnd;
        }
        if (oldRate == newRate) {
            for (UInt32 block = 0; block < capture.capacity / 256; ++block) AppendIndexedCapture(&capture);
            float excess[2] = {1, -1};
            assert(!RingWrite(&capture, excess, 1));
            assert(atomic_load(&capture.rejectedFrames) == 1);
        }

        close(commands[1]);
        assert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert(completed == (oldRate != newRate));
        assert(atomic_load(&capture.consumed) == end);
        assert(dup2(savedInput, STDIN_FILENO) >= 0 && dup2(savedOutput, STDOUT_FILENO) >= 0);
        close(savedInput);
        close(savedOutput);
        close(commands[0]);
        close(events[0]);
        close(events[1]);
        close(pcm[0]);
        close(pcm[1]);
        if (capture.converter) assert(AudioConverterDispose(capture.converter) == noErr);
        free(capture.pcm);
    }
    CheckCapturePark();
    puts("CAPTURE_BOUNDARY_CHECK passed: cumulative watermarks, unread native carryover, short writes, bidirectional conversion, same-rate return, warm discard, and bounded overflow.");
    return 0;
}

static OSStatus ReadAudio(AudioDeviceID device, const AudioTimeStamp *now,
                          const AudioBufferList *input, const AudioTimeStamp *inputTime,
                          AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    Capture *capture = context;
    if (atomic_load(&capture->failed)) return noErr;
    BOOL planar = (capture->format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 count = planar ? 2 : 1;
    if (input->mNumberBuffers != count) {
        atomic_store(&capture->failed, 1);
        return noErr;
    }
    UInt32 frames = input->mBuffers[0].mDataByteSize / capture->format.mBytesPerFrame;
    for (UInt32 buffer = 0; buffer < count; buffer++) {
        const AudioBuffer *value = &input->mBuffers[buffer];
        if (value->mNumberChannels != (planar ? 1 : 2) ||
            value->mDataByteSize % capture->format.mBytesPerFrame != 0 ||
            value->mDataByteSize / capture->format.mBytesPerFrame != frames ||
            (frames && !value->mData)) {
            atomic_store(&capture->failed, 1);
            return noErr;
        }
    }
    if (capture->checkingPermission) {
        if (frames) atomic_fetch_add_explicit(&capture->streamCallbacks, 1, memory_order_relaxed);
        return noErr;
    }
    if (capture->streaming) {
        atomic_fetch_add_explicit(&capture->streamCallbacks, 1, memory_order_relaxed);
        RingWrite(capture, input->mBuffers[0].mData, frames);
        return noErr;
    }
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
    UInt32 width = capture->format.mBitsPerChannel / 8;
    if (!capture->callbacks) capture->firstTime = *inputTime;
    capture->lastTime = *inputTime;
    capture->callbacks++;
    UInt32 available = capture->capacity - capture->frames;
    if (frames > available) frames = available;
    for (UInt32 frame = 0; frame < frames; frame++) {
        BOOL nonzero = NO;
        for (UInt32 channel = 0; channel < 2; channel++) {
            const AudioBuffer *buffer = &input->mBuffers[planar ? channel : 0];
            UInt32 index = planar ? frame : frame * 2 + channel;
            double sample = width == 4 ? ((const float *)buffer->mData)[index]
                                       : ((const double *)buffer->mData)[index];
            if (!isfinite(sample)) {
                atomic_store(&capture->failed, 2);
                return noErr;
            }
            capture->pcm[(capture->frames + frame) * 2 + channel] = (float)sample;
            capture->squares[channel] += sample * sample;
            if (fabs(sample) > capture->peak[channel]) capture->peak[channel] = fabs(sample);
            nonzero |= sample != 0;
        }
        capture->nonzeroFrames += nonzero;
    }
    capture->frames += frames;
#endif
    return noErr;
}

#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
static BOOL SaveCapture(NSString *path, Capture *capture) {
    AudioStreamBasicDescription format = {
        capture->format.mSampleRate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        8, 1, 8, 2, 32, 0
    };
    AudioFileID file = NULL;
    if (!Status(AudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                      kAudioFileCAFType, &format, 0, &file), "CREATE_CAF")) return NO;
    UInt32 packets = (UInt32)capture->frames;
    BOOL saved = Status(AudioFileWritePackets(file, NO, packets * 8, NULL,
                                              0, &packets, capture->pcm), "WRITE_CAF");
    BOOL closed = Status(AudioFileClose(file), "CLOSE_CAF");
    return saved && closed && packets == capture->frames;
}
#endif

static BOOL CaptureFormatsMatch(AudioObjectID tap, AudioDeviceID aggregate, const AudioStreamBasicDescription *format) {
    AudioStreamBasicDescription currentTap = {0}, currentAggregate = {0};
    return ReadFormat(tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, 0, &currentTap) &&
        ReadFormat(aggregate, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, 0, &currentAggregate) &&
        memcmp(format, &currentTap, sizeof(currentTap)) == 0 &&
        memcmp(format, &currentAggregate, sizeof(currentAggregate)) == 0;
}

static BOOL StopWatchingCaptureFormats(AudioObjectID tap, AudioDeviceID aggregate, dispatch_queue_t queue,
                                       AudioObjectPropertyListenerBlock listener, BOOL *tapListening, BOOL *aggregateListening) {
    if (*tapListening) {
        AudioObjectPropertyAddress address = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        if (Status(AudioObjectRemovePropertyListenerBlock(tap, &address, queue, listener), "UNLISTEN_TAP_FORMAT"))
            *tapListening = NO;
    }
    if (*aggregateListening) {
        AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        if (Status(AudioObjectRemovePropertyListenerBlock(aggregate, &address, queue, listener), "UNLISTEN_AGGREGATE_FORMAT"))
            *aggregateListening = NO;
    }
    if (queue) dispatch_sync(queue, ^{});
    return !*tapListening && !*aggregateListening;
}

static NSString *ReadCaptureTapUID(AudioObjectID tap) {
    AudioObjectPropertyAddress address = {kAudioTapPropertyUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    if (!Status(AudioObjectGetPropertyData(tap, &address, 0, NULL, &size, &uid), "READ_TAP_UID")) return nil;
    NSString *value = CFBridgingRelease(uid);
    if (size != sizeof(uid) || !value.length) return nil;
    return value;
}

static BOOL SetCaptureTapList(AudioDeviceID aggregate, NSArray<NSString *> *uids, const char *operation) {
    AudioObjectPropertyAddress address = {kAudioAggregateDevicePropertyTapList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFArrayRef taps = (__bridge CFArrayRef)uids;
    return Status(AudioObjectSetPropertyData(aggregate, &address, 0, NULL, sizeof(taps), &taps), operation);
}

static BOOL ReplaceClockCaptureTap(AudioObjectID *tap, AudioDeviceID aggregate, CATapDescription *description) {
    if (!SetCaptureTapList(aggregate, @[], "CLOCK_DETACH_TAP") ||
        !Status(AudioHardwareDestroyProcessTap(*tap), "CLOCK_DESTROY_TAP")) return NO;
    *tap = kAudioObjectUnknown;
    description.UUID = NSUUID.UUID;
    if (!Status(AudioHardwareCreateProcessTap(description, tap), "CLOCK_CREATE_TAP")) return NO;
    NSString *uid = ReadCaptureTapUID(*tap);
    return uid && SetCaptureTapList(aggregate, @[uid], "CLOCK_ATTACH_TAP");
}

static BOOL ReadClockCaptureFormat(AudioDeviceID device, AudioObjectID tap, AudioDeviceID aggregate,
                                    Float64 rate, AudioStreamBasicDescription *format) {
    AudioObjectPropertyAddress nominal = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectPropertyAddress tapAddress = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectPropertyAddress aggregateAddress = {kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    double deadline = MonotonicTime() + 1;
    do {
        Float64 nativeRate = 0;
        AudioStreamBasicDescription selectedTap = {0}, selectedAggregate = {0};
        UInt32 nativeSize = sizeof(nativeRate), tapSize = sizeof(selectedTap), aggregateSize = sizeof(selectedAggregate);
        if (AudioObjectGetPropertyData(device, &nominal, 0, NULL, &nativeSize, &nativeRate) == noErr &&
            nativeSize == sizeof(nativeRate) && nativeRate == rate &&
            AudioObjectGetPropertyData(tap, &tapAddress, 0, NULL, &tapSize, &selectedTap) == noErr &&
            tapSize == sizeof(selectedTap) && selectedTap.mSampleRate == rate &&
            AudioObjectGetPropertyData(aggregate, &aggregateAddress, 0, NULL, &aggregateSize, &selectedAggregate) == noErr &&
            aggregateSize == sizeof(selectedAggregate) && memcmp(&selectedTap, &selectedAggregate, sizeof(selectedTap)) == 0) {
            *format = selectedTap;
            return YES;
        }
        [NSThread sleepForTimeInterval:0.01];
    } while (!interrupted && MonotonicTime() < deadline);
    return NO;
}

static UInt32 WaitForClockRate(Capture *capture, pid_t parentPID, double deadline) {
    char command[24];
    size_t received = 0;
    while (!interrupted && getppid() == parentPID && MonotonicTime() < deadline) {
        struct pollfd input = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&input, 1, 50);
        if (ready < 0 && errno == EINTR) continue;
        if (!ready) continue;
        if (ready < 0 || !(input.revents & POLLIN) || (input.revents & (POLLERR | POLLNVAL))) break;
        char byte;
        ssize_t length = read(STDIN_FILENO, &byte, 1);
        if (length < 0 && errno == EINTR) continue;
        if (length != 1) break;
        if (byte == '\n') {
            command[received] = 0;
            char *end = NULL;
            if (strncmp(command, "clock-rate ", 11) == 0 && command[11] >= '0' && command[11] <= '9') {
                long rate = strtol(command + 11, &end, 10);
                if (!*end && SupportedSampleRate(rate)) return (UInt32)rate;
            }
            atomic_store(&capture->failed, 8);
            break;
        }
        if (!byte || received == sizeof(command) - 1) {
            atomic_store(&capture->failed, 8);
            break;
        }
        command[received++] = byte;
    }
    return 0;
}

static BOOL WaitForCaptureStart(Capture *capture, pid_t parentPID, double deadline) {
    const char command[] = "capture\n";
    size_t received = 0;
    while (!interrupted && !atomic_load(&capture->failed) && getppid() == parentPID && MonotonicTime() < deadline) {
        if (received == sizeof(command) - 1) return YES;
        struct pollfd input = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&input, 1, 50);
        if (ready < 0 && errno == EINTR) continue;
        if (!ready) continue;
        if (ready < 0 || (input.revents & (POLLERR | POLLHUP | POLLNVAL))) return NO;
        char byte;
        ssize_t length = read(STDIN_FILENO, &byte, 1);
        if (length < 0 && errno == EINTR) continue;
        if (length != 1) return NO;
        if (byte != command[received]) {
            atomic_store(&capture->failed, 8);
            return NO;
        }
        ++received;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--check-stream-ring") == 0) return CheckStreamRing();
        if (argc == 2 && strcmp(argv[1], "--check-stream-rates") == 0) {
            setbuf(stdout, NULL);
            CheckStreamRates();
            return CheckCaptureRateBoundary();
        }
        int argumentCount = argc;
        NSString *deviceUID = nil;
        Float64 sampleRate = 48000;
        Float64 deviceRate = 0;
        BOOL selectedRate = NO;
        while (argumentCount >= 3) {
            const char *option = argv[argumentCount - 2];
            const char *value = argv[argumentCount - 1];
            if (strcmp(option, "--device-uid") == 0 && !deviceUID) {
                deviceUID = [NSString stringWithUTF8String:value];
                if (!deviceUID.length || deviceUID.length > 1024) {
                    fprintf(stderr, "The output device UID must be nonempty and at most 1024 characters.\n");
                    return 2;
                }
            } else if ((strcmp(option, "--sample-rate") == 0 && !selectedRate) ||
                       (strcmp(option, "--device-rate") == 0 && !deviceRate)) {
                char *end = NULL;
                long rate = strtol(value, &end, 10);
                if (!*value || *end || !SupportedSampleRate(rate)) {
                    fprintf(stderr, "Sample rate must be 44100, 48000, 88200, or 96000.\n");
                    return 2;
                }
                if (strcmp(option, "--device-rate") == 0) deviceRate = rate;
                else { sampleRate = rate; selectedRate = YES; }
            } else break;
            argumentCount -= 2;
        }
        BOOL nativeEpoch = argumentCount == 7 && strcmp(argv[6], "--native-epoch") == 0;
        if (nativeEpoch) argumentCount--;
        BOOL awaitStart = argumentCount == 6 && strcmp(argv[5], "--await-start") == 0;
        if (awaitStart) argumentCount--;
        BOOL liveRate = argumentCount == 5 && strcmp(argv[4], "--live-rate") == 0;
        if (liveRate) argumentCount--;
#if ACOUPLET_AUDIO_HELPER_STREAM_ONLY
        BOOL sampleComposition = YES;
#else
        BOOL sampleComposition = argumentCount == 3 && strcmp(argv[1], "--sample-composition") == 0;
#endif
        BOOL streaming = argumentCount == 4 && strcmp(argv[1], "--stream") == 0;
        BOOL checkingPermission = argumentCount == 2 && strcmp(argv[1], "--check-permission") == 0;
        if (checkingPermission) sampleComposition = YES;
        if (((ACOUPLET_AUDIO_HELPER_STREAM_ONLY || deviceUID || selectedRate || deviceRate) && !streaming && !checkingPermission) ||
            (deviceRate && !deviceUID) || (awaitStart && (!streaming || !liveRate)) ||
            (nativeEpoch && (!awaitStart || !deviceUID || deviceRate != sampleRate))) {
            fprintf(stderr, "Usage: %s --stream PCM_FD DURATION_SECONDS [--live-rate [--await-start [--native-epoch]]] | --check-permission; options: [--device-uid UID [--device-rate N]] [--sample-rate N]\n", argv[0]);
            return 2;
        }
        int pcmFD = -1;
        double duration = 30;
        if (streaming) {
            char *end = NULL;
            long fd = strtol(argv[2], &end, 10);
            if (!*argv[2] || *end || fd < 3 || fd > INT_MAX) {
                fprintf(stderr, "PCM fd must be an inherited write pipe descriptor above stderr.\n");
                return 2;
            }
            pcmFD = (int)fd;
            duration = strtod(argv[3], &end);
            if (!*argv[3] || *end || !isfinite(duration) || (duration != 0 && (duration < 1 || duration > 65))) {
                fprintf(stderr, "Stream duration must be zero for continuous capture or between 1 and 65 seconds.\n");
                return 2;
            }
            struct stat pipeInfo;
            int flags = fcntl(pcmFD, F_GETFL);
            if (fstat(pcmFD, &pipeInfo) != 0 || !S_ISFIFO(pipeInfo.st_mode) || flags < 0 ||
                (flags & O_ACCMODE) == O_RDONLY || fcntl(pcmFD, F_SETFL, flags | O_NONBLOCK) != 0) {
                fprintf(stderr, "PCM fd must be an open writable pipe.\n");
                return 2;
            }
            sampleComposition = YES;
        }
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
        if (argumentCount != 2 && !sampleComposition && !streaming) {
            fprintf(stderr, "Usage: %s [--sample-composition] NEW_OUTPUT.caf\n       %s --stream PCM_FD DURATION_SECONDS\n       %s --check-stream-ring\n", argv[0], argv[0], argv[0]);
            return 2;
        }
#endif
        if (@available(macOS 15.4, *)) {
            setbuf(stdout, NULL);
            signal(SIGINT, Interrupt);
            signal(SIGTERM, Interrupt);
            sigset_t stopSignals, inheritedSignals;
            sigemptyset(&stopSignals);
            sigaddset(&stopSignals, SIGINT);
            sigaddset(&stopSignals, SIGTERM);
            pthread_sigmask(SIG_UNBLOCK, &stopSignals, &inheritedSignals);
            printf("STOP_SIGNALS inheritedINT=%d inheritedTERM=%d unblocked=1\n",
                   sigismember(&inheritedSignals, SIGINT), sigismember(&inheritedSignals, SIGTERM));
            if (streaming || checkingPermission) signal(SIGPIPE, SIG_IGN);
            pid_t parentPID = getppid();
            dispatch_source_t parentWatcher = NULL;
            if (streaming || checkingPermission) {
                parentWatcher = WatchParent(parentPID);
                if (!parentWatcher) return 1;
            }
            AudioDeviceID selectedDevice = kAudioObjectUnknown;
            AudioObjectID tap = kAudioObjectUnknown;
            AudioDeviceID aggregate = kAudioObjectUnknown;
            __block AudioDeviceIOProcID io = NULL;
            __block BOOL started = NO;
            BOOL captured = NO;
            BOOL cancelledBeforeStream = NO;
            BOOL cleaned = YES;
            __block BOOL tapListening = NO, aggregateListening = NO;
            AudioObjectPropertyListenerBlock formatListener = nil;
            dispatch_queue_t formatQueue = nil;
            Capture capture = {0};
            atomic_init(&capture.failed, 0);
            capture.streaming = streaming;
            capture.checkingPermission = checkingPermission;
            atomic_init(&capture.produced, 0);
            atomic_init(&capture.consumed, 0);
            atomic_init(&capture.streamCallbacks, 0);
            atomic_init(&capture.highWater, 0);
            atomic_init(&capture.rejectedFrames, 0);
            double startupDeadline = MonotonicTime() + 5;
            do {
                NSString *identifier = @ACOUPLET_AUDIO_HELPER_BUNDLE_ID;
                id usage = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSAudioCaptureUsageDescription"];
                if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:identifier] ||
                    ![usage isKindOfClass:NSString.class] || ![usage length]) {
                    fprintf(stderr, "Run the signed helper with its supplied Info.plist and identity.\n");
                    break;
                }
                if (deviceUID) {
                    AudioObjectPropertyAddress deviceAddress = {kAudioHardwarePropertyTranslateUIDToDevice,
                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                    CFStringRef selectedUID = (__bridge CFStringRef)deviceUID;
                    UInt32 selectedSize = sizeof(selectedDevice);
                    if (!Status(AudioObjectGetPropertyData(kAudioObjectSystemObject, &deviceAddress,
                        sizeof(selectedUID), &selectedUID, &selectedSize, &selectedDevice), "RESOLVE_CAPTURE_DEVICE") ||
                        selectedDevice == kAudioObjectUnknown) break;
                    deviceAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
                    Float64 nativeRate = 0;
                    selectedSize = sizeof(nativeRate);
                    if (!Status(AudioObjectGetPropertyData(selectedDevice, &deviceAddress, 0, NULL,
                        &selectedSize, &nativeRate), "READ_CAPTURE_DEVICE_RATE")) break;
                    Float64 expectedRate = deviceRate ? deviceRate : sampleRate;
                    printf("CAPTURE_DEVICE_RATE actual=%.9g requested=%.9g\n", nativeRate, expectedRate);
                    if (nativeRate != expectedRate) {
                        fprintf(stderr, "The selected output device has not committed the requested sample rate.\n");
                        break;
                    }
                }
                CATapDescription *description = deviceUID
                    ? [[CATapDescription alloc] initExcludingProcesses:@[] andDeviceUID:deviceUID withStream:0]
                    : [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
                description.name = streaming ? @"Acouplet Live System Audio" : @"Acouplet Unmuted System Audio";
                description.privateTap = YES;
                description.muteBehavior = streaming ? CATapMutedWhenTapped : CATapUnmuted;
                if (@available(macOS 26.0, *)) description.bundleIDs = @[identifier];
                printf("START pid=%d excludedBundle=%s duration=%.9g muteBehavior=%s streaming=%d\n",
                       NSProcessInfo.processInfo.processIdentifier, identifier.UTF8String, duration,
                       streaming ? "mutedWhenTapped" : "unmuted", streaming);
                if (deviceUID) printf("CAPTURE_DEVICE uid=%s stream=0\n", deviceUID.UTF8String);
                if (!Status(AudioHardwareCreateProcessTap(description, &tap), "CREATE_TAP")) break;
                AudioStreamBasicDescription tapFormat = {0};
                if (!ReadFormat(tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, 0, &tapFormat)) break;
                NSString *tapUID = ReadCaptureTapUID(tap);
                if (!tapUID) { fprintf(stderr, "Tap did not return a valid UID.\n"); break; }
                AudioObjectPropertyAddress address = {0, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                UInt32 size;
                printf("TAP_UID actual=%s description=%s sampleComposition=%d\n",
                       tapUID.UTF8String, description.UUID.UUIDString.UTF8String, sampleComposition);
                NSMutableDictionary *composition = [@{
                    @kAudioAggregateDeviceNameKey: @"Acouplet Private Tap",
                    @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
                    @kAudioAggregateDeviceIsPrivateKey: @YES,
                    @kAudioAggregateDeviceTapAutoStartKey: @NO
                } mutableCopy];
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
                if (!sampleComposition)
                    composition[@kAudioAggregateDeviceTapListKey] = @[@{
                        @kAudioSubTapUIDKey: tapUID,
                        @kAudioSubTapDriftCompensationKey: @YES
                    }];
#endif
                if (!Status(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition,
                                                               &aggregate), "CREATE_AGGREGATE")) break;
                if (sampleComposition && !SetCaptureTapList(aggregate, @[tapUID], "SET_TAP_LIST")) break;
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
                AudioObjectPropertySelector selectors[] = {
                    kAudioAggregateDevicePropertyComposition, kAudioAggregateDevicePropertyTapList,
                    kAudioAggregateDevicePropertyMainSubDevice, kAudioAggregateDevicePropertyClockDevice
                };
                const char *labels[] = {"COMPOSITION", "TAP_LIST", "MAIN_DEVICE", "CLOCK_DEVICE"};
                for (UInt32 index = 0; index < 4; index++) {
                    address.mSelector = selectors[index];
                    CFTypeRef value = NULL;
                    size = sizeof(value);
                    if (Status(AudioObjectGetPropertyData(aggregate, &address, 0, NULL, &size, &value), labels[index])) {
                        id state = CFBridgingRelease(value);
                        printf("%s value=%s\n", labels[index], state ? [state description].UTF8String : "(null)");
                    }
                }
                address.mSelector = kAudioAggregateDevicePropertySubTapList;
                UInt32 subtapSize = 0;
                if (Status(AudioObjectGetPropertyDataSize(aggregate, &address, 0, NULL, &subtapSize), "SUBTAP_LIST_SIZE")) {
                    AudioObjectID *subtaps = calloc(1, subtapSize ? subtapSize : sizeof(AudioObjectID));
                    if (!subtaps) { perror("Subtap allocation"); break; }
                    if (Status(AudioObjectGetPropertyData(aggregate, &address, 0, NULL, &subtapSize, subtaps), "SUBTAP_LIST")) {
                        printf("ACTIVE_SUBTAPS count=%u", subtapSize / (UInt32)sizeof(AudioObjectID));
                        for (UInt32 index = 0; index < subtapSize / sizeof(AudioObjectID); index++)
                            printf(" %u", subtaps[index]);
                        printf("\n");
                    }
                    free(subtaps);
                }
#endif
                BOOL retainingAggregate = NO;
                for (;;) {
                    if (retainingAggregate) {
                        if (!ReplaceClockCaptureTap(&tap, aggregate, description)) break;
                        if (!ReadClockCaptureFormat(selectedDevice, tap, aggregate, deviceRate, &tapFormat)) {
                            fprintf(stderr, "PCM_CAPTURE_CLOCK_FORMAT_UNCONFIRMED rate=%.9g\n", deviceRate);
                            break;
                        }
                        capture.format = tapFormat;
                    } else if (!ReadFormat(aggregate, kAudioDevicePropertyStreamFormat,
                                           kAudioObjectPropertyScopeInput, startupDeadline, &capture.format)) break;
                    AudioStreamBasicDescription format = capture.format;
                    UInt32 width = format.mBitsPerChannel / 8;
                    BOOL planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
                    if (format.mFormatID != kAudioFormatLinearPCM || format.mChannelsPerFrame != 2 ||
                        !(format.mFormatFlags & kAudioFormatFlagIsFloat) ||
                        !(format.mFormatFlags & kAudioFormatFlagIsPacked) ||
                        (format.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
                        (format.mBitsPerChannel != 32 && format.mBitsPerChannel != 64) ||
                        format.mBytesPerFrame != width * (planar ? 1 : 2) ||
                        format.mFramesPerPacket != 1 || format.mBytesPerPacket != format.mBytesPerFrame ||
                        !isfinite(format.mSampleRate) || format.mSampleRate <= 0 ||
                        ceil(format.mSampleRate * 30) > UINT32_MAX / 8) {
                        fprintf(stderr, "Unsupported actual capture format; no samples reinterpreted.\n");
                        break;
                    }
                    if ((streaming || checkingPermission) && (!SupportedSampleRate(format.mSampleRate) || format.mBitsPerChannel != 32 ||
                        planar || format.mFormatFlags != (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) ||
                        memcmp(&tapFormat, &format, sizeof(format)) != 0 ||
                        (nativeEpoch && format.mSampleRate != deviceRate))) {
                        fprintf(stderr, "Streaming requires matching verified tap and aggregate packed native Float32 interleaved stereo formats at a supported rate.\n");
                        break;
                    }
                    if ((streaming || checkingPermission) && !CreateConverter(&capture, sampleRate)) break;
                    if (!checkingPermission) {
#if ACOUPLET_AUDIO_HELPER_STREAM_ONLY
                        capture.capacity = (UInt32)ceil(32768 * format.mSampleRate / 48000);
#else
                        capture.capacity = streaming ? (UInt32)ceil(32768 * format.mSampleRate / 48000) : (UInt32)ceil(format.mSampleRate * 30);
#endif
                        if (liveRate) {
                            capture.capacity = (UInt32)(LiveRateCaptureBufferSeconds * format.mSampleRate);
                            capture.callbackFrameBound = ReadCallbackFrameBound(aggregate);
                        }
                        capture.pcm = calloc((size_t)capture.capacity * 2, sizeof(float));
                        if (!capture.pcm) { perror("Capture allocation"); break; }
                    }
                    if (streaming || checkingPermission) {
                        Capture *state = &capture;
                        formatQueue = dispatch_queue_create("dev.baglayan.Acouplet.tap-format", DISPATCH_QUEUE_SERIAL);
                        formatListener = ^(UInt32 count, const AudioObjectPropertyAddress *changes) {
                            if (!CaptureFormatsMatch(tap, aggregate, &state->format))
                                atomic_store(&state->failed, 4);
                        };
                        address = (AudioObjectPropertyAddress){kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                        tapListening = Status(AudioObjectAddPropertyListenerBlock(tap, &address, formatQueue, formatListener), "LISTEN_TAP_FORMAT");
                        if (!tapListening) break;
                        address = (AudioObjectPropertyAddress){kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
                        aggregateListening = Status(AudioObjectAddPropertyListenerBlock(aggregate, &address, formatQueue, formatListener), "LISTEN_AGGREGATE_FORMAT");
                        if (!aggregateListening) break;
                    }
                    printf("BEFORE_CREATE_IOPROC monotonic=%.9f\n", MonotonicTime());
                    if (!Status(AudioDeviceCreateIOProcID(aggregate, ReadAudio, &capture, &io), "CREATE_IOPROC")) break;
                    pid_t ownPID = getpid();
                    AudioObjectID ownProcess = kAudioObjectUnknown;
                    address = (AudioObjectPropertyAddress){kAudioHardwarePropertyTranslatePIDToProcessObject,
                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                    size = sizeof(ownProcess);
                    if (!Status(AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(ownPID),
                                                           &ownPID, &size, &ownProcess), "READ_OWN_PROCESS")) break;
                    if (ownProcess != kAudioObjectUnknown) {
                        description.processes = @[@(ownProcess)];
                        address.mSelector = kAudioTapPropertyDescription;
                        CATapDescription *updatedDescription = description;
                        if (!Status(AudioObjectSetPropertyData(tap, &address, 0, NULL, sizeof(updatedDescription),
                                                               &updatedDescription), "SET_SELF_EXCLUSION")) break;
                        printf("SELF_EXCLUSION pid=%d processObject=%u method=process\n", ownPID, ownProcess);
                    } else {
                        if (@available(macOS 26.0, *))
                            printf("SELF_EXCLUSION pid=%d processObject=0 method=bundleID\n", ownPID);
                        else {
                            fprintf(stderr, "No audio process object for this helper; refusing to start without self exclusion.\n");
                            break;
                        }
                    }
                    if (awaitStart) {
                        BOOL prepared = !interrupted && !atomic_load(&capture.failed) && MonotonicTime() < startupDeadline;
                        BOOL authorized = NO;
                        if (prepared) {
                            if (nativeEpoch) {
                                started = StartCaptureIO(aggregate, io);
                                if (!started) break;
                                printf("PCM_CAPTURE_CLOCK_PREPARED rate=%.9g\n", capture.format.mSampleRate);
                            } else {
                                printf("PCM_CAPTURE_SOURCE rate=%.9g\n", capture.format.mSampleRate);
                                printf("PCM_CAPTURE_PREPARED rate=%.9g\n", sampleRate);
                            }
                            authorized = WaitForCaptureStart(&capture, parentPID, MonotonicTime() + CaptureStartWaitSeconds);
                            if (authorized && !CaptureFormatsMatch(tap, aggregate, &capture.format)) atomic_store(&capture.failed, 4);
                            if (authorized && nativeEpoch) {
                                AudioObjectPropertyAddress nominal = {kAudioDevicePropertyNominalSampleRate,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                                Float64 actualRate = 0;
                                UInt32 nominalSize = sizeof(actualRate);
                                if (!Status(AudioObjectGetPropertyData(selectedDevice, &nominal, 0, NULL, &nominalSize, &actualRate),
                                            "CONFIRM_CAPTURE_DEVICE_RATE") || nominalSize != sizeof(actualRate) || actualRate != deviceRate)
                                    atomic_store(&capture.failed, 4);
                            }
                        }
                        if (!authorized || interrupted || atomic_load(&capture.failed) || getppid() != parentPID) {
                            int error = atomic_load(&capture.failed);
                            cancelledBeforeStream = (interrupted == SIGINT || interrupted == SIGTERM) && !error;
                            if (!cancelledBeforeStream) fprintf(stderr, "PCM_CAPTURE_START_FAILED prepared=%d error=%d\n", prepared, error);
                            break;
                        }
                        startupDeadline = MonotonicTime() + 5;
                    }
                    if (!started) {
                        started = StartCaptureIO(aggregate, io);
                        if (!started) break;
                    }
                    if (checkingPermission) {
                        double deadline = MonotonicTime() + 5;
                        while (!interrupted && !atomic_load(&capture.failed) &&
                               !atomic_load(&capture.streamCallbacks) && MonotonicTime() < deadline) {
                            if (NSThread.isMainThread)
                                [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                            else
                                [NSThread sleepForTimeInterval:0.01];
                        }
                        captured = !interrupted && !atomic_load(&capture.failed) && atomic_load(&capture.streamCallbacks) > 0;
                        break;
                    }
                    if (streaming) {
                        if (interrupted || atomic_load(&capture.failed) || MonotonicTime() >= startupDeadline) {
                            cancelledBeforeStream = (interrupted == SIGINT || interrupted == SIGTERM) && !atomic_load(&capture.failed);
                            if (!cancelledBeforeStream)
                                fprintf(stderr, "PCM_STARTUP_FAILED timeoutOrInterruption=1 error=%d\n", atomic_load(&capture.failed));
                            break;
                        }
                        if (liveRate && (!awaitStart || nativeEpoch)) printf("PCM_CAPTURE_SOURCE rate=%.9g\n", capture.format.mSampleRate);
                        printf("PCM_CAPTURE_READY rate=%.9g channels=2 format=F32 interleaved=1 bytesPerFrame=8\n", sampleRate);
                        BOOL clockFrozen = NO;
                        BOOL (^quiesce)(void) = nil;
                        if (deviceUID && awaitStart) quiesce = ^BOOL{
                            if (!Status(AudioDeviceStop(aggregate, io), "CLOCK_STOP_AUDIO")) return NO;
                            started = NO;
                            if (!Status(AudioDeviceDestroyIOProcID(aggregate, io), "CLOCK_DESTROY_IOPROC")) return NO;
                            io = NULL;
                            return StopWatchingCaptureFormats(tap, aggregate, formatQueue, formatListener, &tapListening, &aggregateListening);
                        };
                        captured = StreamAudioWithClock(&capture, pcmFD, duration, parentPID, liveRate, (UInt32)sampleRate, &clockFrozen, quiesce);
                        if (!clockFrozen) break;
                        if (capture.converter && !Status(AudioConverterDispose(capture.converter), "DISPOSE_RATE_CONVERTER")) {
                            capture.converter = NULL;
                            cleaned = NO;
                            break;
                        }
                        free(capture.pcm);
                        capture = (Capture){.streaming = YES};
                        retainingAggregate = YES;
                        nativeEpoch = YES;
                        UInt32 rate = WaitForClockRate(&capture, parentPID, MonotonicTime() + LiveRateChangeBufferSeconds);
                        if (!rate) break;
                        sampleRate = deviceRate = rate;
                        startupDeadline = MonotonicTime() + 5;
                        captured = NO;
                        continue;
                    }
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
                    double deadline = MonotonicTime() + duration;
                    while (!interrupted && !atomic_load(&capture.failed) && MonotonicTime() < deadline) {
                        if (NSThread.isMainThread)
                            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                        else
                            [NSThread sleepForTimeInterval:0.05];
                    }
                    captured = !interrupted && !atomic_load(&capture.failed);
#endif
                    break;
                }
            } while (NO);
            printf("BEFORE_AUDIO_CLEANUP interrupted=%d error=%d\n", interrupted, atomic_load(&capture.failed));
            BOOL listenersQuiesced = StopWatchingCaptureFormats(tap, aggregate, formatQueue, formatListener, &tapListening, &aggregateListening);
            cleaned &= listenersQuiesced;
            BOOL quiesced = !started;
            if (started) {
                quiesced = Status(AudioDeviceStop(aggregate, io), "STOP_AUDIO");
                cleaned &= quiesced;
            }
            if (io) {
                BOOL destroyed = Status(AudioDeviceDestroyIOProcID(aggregate, io), "DESTROY_IOPROC");
                quiesced |= destroyed;
                cleaned &= destroyed;
            }
            if (aggregate != kAudioObjectUnknown)
                cleaned &= Status(AudioHardwareDestroyAggregateDevice(aggregate), "DESTROY_AGGREGATE");
            if (tap != kAudioObjectUnknown) cleaned &= Status(AudioHardwareDestroyProcessTap(tap), "DESTROY_TAP");
            if (!quiesced || !listenersQuiesced) {
                fprintf(stderr, "Audio callback or format listener could not be stopped; terminating without releasing its buffer.\n");
                if (checkingPermission) puts("AUDIO_PERMISSION_FAILED cleanup=0");
                _Exit(1);
            }
            if (capture.converter) cleaned &= Status(AudioConverterDispose(capture.converter), "DISPOSE_RATE_CONVERTER");
            if (parentWatcher) dispatch_source_cancel(parentWatcher);
            if (checkingPermission) {
                const char *deniedOperation = atomic_load(&permissionDeniedOperation);
                if (cleaned && deniedOperation) {
                    printf("AUDIO_PERMISSION_DENIED operation=%s status=%d cleanup=1\n",
                           deniedOperation, (int)kAudioDevicePermissionsError);
                    return 3;
                }
                if (captured && cleaned && !interrupted && !atomic_load(&capture.failed)) {
                    printf("AUDIO_PERMISSION_ALLOWED cleanup=1 callbacks=%llu\n",
                           (unsigned long long)atomic_load(&capture.streamCallbacks));
                    return 0;
                }
                printf("AUDIO_PERMISSION_FAILED cleanup=%d callbacks=%llu error=%d interrupted=%d\n",
                       cleaned, (unsigned long long)atomic_load(&capture.streamCallbacks),
                       atomic_load(&capture.failed), interrupted);
                return 1;
            }
            if (streaming) {
                capture.callbacks = atomic_load(&capture.streamCallbacks);
                UInt32 rejectedFrames = atomic_load(&capture.rejectedFrames);
                if (rejectedFrames)
                    printf("PCM_CAPTURE_OVERFLOW rejectedFrames=%u capacity=%u\n", rejectedFrames, capture.capacity);
                printf("PCM_STREAM produced=%llu delivered=%llu highWater=%u capacity=%u error=%d\n",
                       (unsigned long long)atomic_load(&capture.produced),
                       (unsigned long long)capture.frames, atomic_load(&capture.highWater),
                       capture.capacity, atomic_load(&capture.failed));
                if (close(pcmFD) != 0) { perror("Close PCM pipe"); cleaned = NO; }
                if (cancelledBeforeStream && cleaned && !atomic_load(&capture.failed))
                    printf("PCM_CAPTURE_CANCELLED cleanup=1 error=0 interrupted=%d\n", interrupted);
            }
            printf("CAPTURE callbacks=%llu frames=%llu samples=%llu nonzeroFrames=%llu error=%d interrupted=%d\n",
                   (unsigned long long)capture.callbacks, (unsigned long long)capture.frames,
                   (unsigned long long)capture.frames * 2, (unsigned long long)capture.nonzeroFrames,
                   atomic_load(&capture.failed), interrupted);
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
            printf("TIMESTAMPS firstFlags=%08X firstHost=%llu firstSample=%.9g lastFlags=%08X lastHost=%llu lastSample=%.9g\n",
                   capture.firstTime.mFlags, (unsigned long long)capture.firstTime.mHostTime,
                   capture.firstTime.mSampleTime, capture.lastTime.mFlags,
                   (unsigned long long)capture.lastTime.mHostTime, capture.lastTime.mSampleTime);
#endif
            for (int channel = 0; channel < 2; channel++)
                printf("CHANNEL %d rms=%.9g peak=%.9g\n", channel,
                       capture.frames ? sqrt(capture.squares[channel] / capture.frames) : 0, capture.peak[channel]);
            BOOL saved = NO;
            if (streaming) saved = captured && cleaned && !atomic_load(&capture.failed);
#if !ACOUPLET_AUDIO_HELPER_STREAM_ONLY
            else if (captured && cleaned && capture.frames && capture.nonzeroFrames)
                saved = SaveCapture([NSString stringWithUTF8String:argv[sampleComposition ? 2 : 1]], &capture);
            else fprintf(stderr, "Capture failed, was interrupted, or contained no nonzero audio.\n");
#endif
            if (nativeEpoch) printf("PCM_CAPTURE_CLOCK_CLOSED cleanup=%d bytes=%llu\n", cleaned,
                (unsigned long long)capture.pipeBytes);
            free(capture.pcm);
            return saved ? 0 : 1;
        }
        fprintf(stderr, "This helper requires macOS 15.4 or later.\n");
        return 2;
    }
}
