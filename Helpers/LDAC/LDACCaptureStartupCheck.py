from pathlib import Path
import os
import select
import signal
import subprocess
import sys
import tempfile

source = Path(__file__).with_name("SystemAudioTapProbe.m").read_text()
read_format = source[source.index("static BOOL ReadFormat("):source.index("static BOOL RingWrite(")]
status = source[source.index("static BOOL Status("):source.index("static BOOL ReadFormat(")]
fixture = r'''#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <assert.h>
#include <signal.h>
#include <stdatomic.h>
static volatile sig_atomic_t interrupted;
static _Atomic(const char *) permissionDeniedOperation;
static double now;
static unsigned calls, unavailable;
static OSStatus result;
static BOOL wrongSize, interruptOnWait;
static double MonotonicTime(void) { return now; }
static OSStatus CaptureFormatProperty(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    assert(object == 23 && address->mSelector == kAudioDevicePropertyStreamFormat);
    assert(address->mScope == kAudioObjectPropertyScopeInput && *size == sizeof(AudioStreamBasicDescription));
    ++calls;
    if (calls <= unavailable) { *size = 0; return kAudioHardwareUnknownPropertyError; }
    if (result) return result;
    *(AudioStreamBasicDescription *)data = (AudioStreamBasicDescription){.mSampleRate = 96000, .mChannelsPerFrame = 2};
    if (wrongSize) *size = 0;
    return noErr;
}
@interface CaptureClock : NSObject
+ (void)sleepForTimeInterval:(NSTimeInterval)interval;
@end
@implementation CaptureClock
+ (void)sleepForTimeInterval:(NSTimeInterval)interval {
    assert(interval > 0 && calls < 10);
    now += interval;
    if (interruptOnWait) interrupted = SIGTERM;
}
@end
#define NSThread CaptureClock
#define AudioObjectGetPropertyData CaptureFormatProperty
''' + status + read_format + r'''
static BOOL Read(double deadline) {
    AudioStreamBasicDescription format = {0};
    BOOL ok = ReadFormat(23, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, deadline, &format);
    if (ok) assert(format.mSampleRate == 96000 && format.mChannelsPerFrame == 2);
    return ok;
}
static void Reset(void) {
    calls = unavailable = 0;
    now = 1;
    result = noErr;
    interrupted = 0;
    wrongSize = interruptOnWait = NO;
    atomic_store(&permissionDeniedOperation, NULL);
}
int main(void) {
    Reset(); assert(Read(2) && calls == 1);
    Reset(); unavailable = 2; assert(Read(2) && calls == 3);
    Reset(); unavailable = 100; assert(!Read(1.025) && calls == 3 && now < 1.04);
    Reset(); unavailable = 100; assert(!Read(0) && calls == 1);
    Reset(); unavailable = 100; assert(!Read(0.5) && calls == 1);
    Reset(); unavailable = 100; interruptOnWait = YES; assert(!Read(2) && calls == 1 && interrupted == SIGTERM);
    Reset(); result = kAudioDevicePermissionsError; assert(!Read(2) && calls == 1 && atomic_load(&permissionDeniedOperation));
    Reset(); result = kAudioHardwareBadObjectError; assert(!Read(2) && calls == 1 && !atomic_load(&permissionDeniedOperation));
    Reset(); wrongSize = YES; assert(!Read(2) && calls == 1);
    puts("Capture startup: 9 checks passed; delayed stream, deadline, cancellation, permission and invalid format.");
}
'''
gate_start = source.index("                if (awaitStart) {")
gate_end = source.index("                    if (checkingPermission)", gate_start)
gate = source[gate_start:gate_end]
assert source.index('"SET_SELF_EXCLUSION"') < gate_start
gate_fixture = r'''#define ACOUPLET_AUDIO_HELPER_STREAM_ONLY 1
#define main TapCaptureMain
#include "SystemAudioTapProbe.m"
#undef main

static BOOL formatsMatch;
static Float64 formatRate, nominalRate;
static BOOL FixtureFormatsMatch(AudioObjectID tap, AudioDeviceID aggregate, const AudioStreamBasicDescription *format) {
    assert(tap == 11 && aggregate == 12 && format->mSampleRate == formatRate);
    return formatsMatch;
}

static OSStatus FixtureGetDeviceProperty(AudioObjectID device, const AudioObjectPropertyAddress *address,
                                         UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    assert(device == 13 && address->mSelector == kAudioDevicePropertyNominalSampleRate &&
           qualifierSize == 0 && qualifier == NULL && *size == sizeof(nominalRate));
    *(Float64 *)data = nominalRate;
    return noErr;
}

static BOOL FixtureStart(AudioDeviceID device, AudioDeviceIOProcID io) {
    assert(device == 12 && io == NULL);
    puts("FIXTURE_AUDIO_DEVICE_STARTED");
    return YES;
}

#define StartCaptureIO FixtureStart
#define AudioObjectGetPropertyData FixtureGetDeviceProperty
#define CaptureFormatsMatch FixtureFormatsMatch
#define CaptureStartWaitSeconds waitSeconds
int main(int argc, const char *argv[]) {
    setbuf(stdout, NULL);
    signal(SIGINT, Interrupt);
    signal(SIGTERM, Interrupt);
    assert(argc == 2);
    const char *scenario = argv[1];
    formatsMatch = strcmp(scenario, "format-recheck") != 0;
    BOOL nativeEpoch = strncmp(scenario, "native-", 7) == 0;
    Float64 deviceRate = 96000;
    AudioObjectID selectedDevice = 13;
    formatRate = nativeEpoch ? deviceRate : 48000;
    nominalRate = strcmp(scenario, "native-wrong-rate") == 0 ? 48000 : deviceRate;
    double waitSeconds = strcmp(scenario, "timeout") == 0 ? 0.15 : 2;
    pid_t parentPID = getppid();
    Capture capture = {.format = {.mSampleRate = formatRate}};
    BOOL awaitStart = YES, started = NO, cancelledBeforeStream = NO;
    AudioObjectID tap = 11;
    AudioDeviceID aggregate = 12;
    AudioDeviceIOProcID io = NULL;
    Float64 sampleRate = 96000;
    double startupDeadline = MonotonicTime() + 0.15;
    if (strcmp(scenario, "expired-setup") == 0) startupDeadline = 0;
    if (strcmp(scenario, "format-loss") == 0) {
        atomic_int *failed = &capture.failed;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            atomic_store(failed, 4);
        });
    }
    BOOL admitted = NO;
    do {
''' + gate + r'''
        admitted = YES;
    } while (NO);
    assert(!admitted || (started && startupDeadline - MonotonicTime() > 4));
    printf("FIXTURE_GATE_EXIT admitted=%d cancelled=%d error=%d interrupted=%d callbacks=%llu\n",
           admitted, cancelledBeforeStream, atomic_load(&capture.failed), interrupted,
           (unsigned long long)atomic_load(&capture.streamCallbacks));
    return admitted ? 0 : 1;
}
'''


clock_fixture = r'''#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
static OSStatus ClockFixtureSet(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data);
static OSStatus ClockFixtureDestroy(AudioObjectID tap);
static OSStatus ClockFixtureCreate(CATapDescription *description, AudioObjectID *tap);
static OSStatus ClockFixtureProperty(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data);
#define AudioObjectGetPropertyData ClockFixtureProperty
#define AudioObjectSetPropertyData ClockFixtureSet
#define AudioHardwareDestroyProcessTap ClockFixtureDestroy
#define AudioHardwareCreateProcessTap ClockFixtureCreate
#define ACOUPLET_AUDIO_HELPER_STREAM_ONLY 1
#define main TapCaptureMain
#include "SystemAudioTapProbe.m"
#undef main
#undef AudioObjectGetPropertyData
#undef AudioObjectSetPropertyData
#undef AudioHardwareDestroyProcessTap
#undef AudioHardwareCreateProcessTap

static UInt32 nominalReads, replacementStep;
static BOOL stale, failAttach;
static NSUUID *oldUUID;

static OSStatus ClockFixtureSet(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    assert(object == 23 && address->mSelector == kAudioAggregateDevicePropertyTapList && !qualifierSize && !qualifier && size == sizeof(CFArrayRef));
    NSArray *list = (__bridge NSArray *)*(CFArrayRef const *)data;
    if (replacementStep++ == 0) assert(!list.count);
    else {
        assert(replacementStep == 5 && [list isEqual:@[@"fixture-new-tap"]]);
        if (failAttach) return kAudioHardwareIllegalOperationError;
    }
    return noErr;
}

static OSStatus ClockFixtureDestroy(AudioObjectID tap) {
    assert(replacementStep++ == 1 && tap == 22);
    return noErr;
}

static OSStatus ClockFixtureCreate(CATapDescription *description, AudioObjectID *tap) {
    assert(replacementStep++ == 2 && *tap == kAudioObjectUnknown && ![description.UUID isEqual:oldUUID]);
    *tap = 24;
    return noErr;
}
static OSStatus ClockFixtureProperty(AudioObjectID object, const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    assert(qualifierSize == 0 && !qualifier);
    if (address->mSelector == kAudioTapPropertyUID) {
        assert(replacementStep++ == 3 && object == 24 && *size == sizeof(CFStringRef));
        *(CFStringRef *)data = CFRetain(CFSTR("fixture-new-tap"));
        return noErr;
    }
    if (object == 21) {
        assert(address->mSelector == kAudioDevicePropertyNominalSampleRate && *size == sizeof(Float64));
        ++nominalReads;
        *(Float64 *)data = 96000;
    } else {
        assert((object == 24 && address->mSelector == kAudioTapPropertyFormat) ||
            (object == 23 && address->mSelector == kAudioDevicePropertyStreamFormat));
        assert(*size == sizeof(AudioStreamBasicDescription));
        UInt32 rate = object == 23 && (stale || nominalReads == 1) ? 48000 : 96000;
        *(AudioStreamBasicDescription *)data = (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM,
            kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
    }
    return noErr;
}

int main(int argc, const char *argv[]) {
    setbuf(stdout, NULL);
    assert(argc == 2);
    stale = strcmp(argv[1], "stale") == 0;
    BOOL unsupported = strcmp(argv[1], "malformed") == 0;
    failAttach = strcmp(argv[1], "failed-attach") == 0;
    Float32 pcm[16] = {0};
    Capture capture = {.format = {.mSampleRate = 48000}, .pcm = pcm, .capacity = 8};
    int input[2], output[2];
    assert(pipe(input) == 0 && pipe(output) == 0);
    const char freeze[] = "clock-freeze\n";
    assert(write(input[1], freeze, sizeof(freeze) - 1) == sizeof(freeze) - 1);
    assert(dup2(input[0], STDIN_FILENO) >= 0);
    Float32 first[] = {.01f, -.01f, .02f, -.02f}, last[] = {.03f, -.03f, .04f, -.04f};
    assert(RingWrite(&capture, first, 2));
    Capture *state = &capture;
    const Float32 *tail = last;
    BOOL frozen = NO;
    __block BOOL quiesced = NO;
    assert(StreamAudioWithClock(&capture, output[1], 1, getppid(), YES, 48000, &frozen, ^BOOL{
        assert(!quiesced);
        quiesced = YES;
        return RingWrite(state, tail, 2);
    }));
    assert(quiesced && frozen && capture.pipeBytes == 32 && atomic_load(&capture.consumed) == 4);
    Float32 retired[8];
    ReadCaptureFixture(output[0], retired, sizeof(retired));
    assert(!memcmp(retired, first, sizeof(first)) && !memcmp(retired + 4, last, sizeof(last)));
    UInt32 pending = UINT32_MAX;
    assert(ioctl(output[0], FIONREAD, &pending) == 0 && pending == 0);
    const char *command = unsupported ? "clock-rate 12345\n" : "clock-rate 96000\n";
    assert(write(input[1], command, strlen(command)) == strlen(command));
    UInt32 rate = WaitForClockRate(&capture, getppid(), MonotonicTime() + 0.5);
    if (unsupported) {
        assert(!rate && atomic_load(&capture.failed) == 8 && !nominalReads);
    } else {
        assert(rate == 96000 && !atomic_load(&capture.failed));
        CATapDescription *description = [CATapDescription new];
        oldUUID = NSUUID.UUID;
        description.UUID = oldUUID;
        AudioObjectID tap = 22;
        assert(ReplaceClockCaptureTap(&tap, 23, description) == !failAttach);
        assert(tap == 24 && replacementStep == 5);
        if (failAttach) assert(!nominalReads);
        else {
            AudioStreamBasicDescription next = {0};
            assert(ReadClockCaptureFormat(21, tap, 23, rate, &next) == !stale);
            assert(nominalReads >= 2 && next.mSampleRate == (stale ? 0 : 96000));
        }
    }
    for (int i = 0; i < 2; i++) { close(input[i]); close(output[i]); }
    return 0;
}
'''


def collect_gate(process, expected_exit, admitted=False, cancelled=0, error=0, interrupted=0, already_started=False):
    try:
        lines = []
        while select.select([process.stdout], [], [], 0.75)[0]:
            line = process.stdout.readline()
            if not line:
                break
            lines.append(line.decode().rstrip())
            if line.startswith(b"FIXTURE_GATE_EXIT "):
                break
        assert lines and lines[-1] == (
            f"FIXTURE_GATE_EXIT admitted={int(admitted)} cancelled={cancelled} error={error} "
            f"interrupted={interrupted} callbacks=0"), lines
        assert lines.count("FIXTURE_AUDIO_DEVICE_STARTED") == int(admitted and not already_started), lines
        assert process.wait(timeout=2) == expected_exit
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)


def prepared(process):
    for line in (b"PCM_CAPTURE_SOURCE rate=48000\n", b"PCM_CAPTURE_PREPARED rate=96000\n"):
        assert select.select([process.stdout], [], [], 2)[0]
        assert process.stdout.readline() == line


with tempfile.TemporaryDirectory(prefix="acouplet-capture-startup-") as directory:
    directory = Path(directory)
    path = directory / "Check.m"
    binary = directory / "check"
    path.write_text(fixture)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreAudio", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    path.write_text(gate_fixture)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Werror", "-framework", "Foundation",
                    "-framework", "AudioToolbox", "-framework", "CoreAudio", "-I", str(Path(__file__).resolve().parent),
                    str(path), "-o", str(binary)], check=True)

    def launch(mode="normal"):
        return subprocess.Popen([str(binary), mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)

    with launch() as process:
        prepared(process)
        process.stdin.write(b"cap")
        assert not select.select([process.stdout], [], [], 0.1)[0]
        process.stdin.write(b"ture")
        assert not select.select([process.stdout], [], [], 0.1)[0]
        process.stdin.write(b"\n")
        collect_gate(process, 0, admitted=True)

    reader, writer = os.pipe()
    try:
        os.write(writer, b"capture\n")
        with subprocess.Popen([str(binary), "normal"], stdin=reader, stdout=subprocess.PIPE, bufsize=0) as process:
            prepared(process)
            collect_gate(process, 0, admitted=True)
    finally:
        os.close(reader)
        os.close(writer)

    for payload in (b"start\n", b"capture\r\n", b"capturex\n"):
        with launch() as process:
            prepared(process)
            process.stdin.write(payload)
            collect_gate(process, 1, error=8)

    for payload in (b"", b"capt"):
        with launch() as process:
            prepared(process)
            process.stdin.write(payload)
            process.stdin.close()
            collect_gate(process, 1)

    for stop in (signal.SIGINT, signal.SIGTERM):
        with launch() as process:
            prepared(process)
            process.stdin.write(b"capt")
            process.send_signal(stop)
            collect_gate(process, 1, cancelled=1, interrupted=stop.value)

    for mode, error in (("timeout", 0), ("format-loss", 4)):
        with launch(mode) as process:
            prepared(process)
            process.stdin.write(b"capt")
            collect_gate(process, 1, error=error)

    with launch("format-recheck") as process:
        prepared(process)
        process.stdin.write(b"capture\n")
        collect_gate(process, 1, error=4)

    for scenario, expected_exit in (("native-confirmed-rate", 0), ("native-wrong-rate", 1), ("native-cancel", 1)):
        with launch(scenario) as process:
            assert select.select([process.stdout], [], [], 2)[0]
            assert process.stdout.readline() == b"FIXTURE_AUDIO_DEVICE_STARTED\n"
            assert process.stdout.readline() == b"PCM_CAPTURE_CLOCK_PREPARED rate=96000\n"
            assert not select.select([process.stdout], [], [], 0.1)[0]
            if scenario == "native-cancel":
                process.send_signal(signal.SIGTERM)
                collect_gate(process, 1, cancelled=1, interrupted=signal.SIGTERM, already_started=True)
                continue
            process.stdin.write(b"capture\n")
            collect_gate(process, expected_exit, admitted=expected_exit == 0, error=0 if expected_exit == 0 else 4,
                         already_started=True)

    with launch("expired-setup") as process:
        collect_gate(process, 1)

    command = "import subprocess,sys; subprocess.Popen(sys.argv[1:]).wait()"
    with subprocess.Popen([sys.executable, "-c", command, str(binary), "normal"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0) as supervisor:
        prepared(supervisor)
        supervisor.kill()
        collect_gate(supervisor, -signal.SIGKILL)

    print("Capture authorization: split and queued commands, malformed input, EOF, timeout, both stop signals, format loss and parent exit.")

    path.write_text(clock_fixture)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Werror", "-framework", "Foundation",
                    "-framework", "AudioToolbox", "-framework", "CoreAudio", "-I", str(Path(__file__).resolve().parent),
                    str(path), "-o", str(binary)], check=True)
    for mode in ("matched", "stale", "malformed", "failed-attach"):
        subprocess.run([str(binary), mode], check=True, timeout=3)
    print("Capture clock change: exact old-epoch bytes, new tap on the retained aggregate, staggered readback and safe rejection of stale format, malformed command and failed attachment.")
