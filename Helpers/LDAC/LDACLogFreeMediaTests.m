#include <sys/event.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include "ldacBT.h"

static int CheckedEncode(HANDLE_LDAC_BT encoder, void *pcm, int *used,
                         unsigned char *stream, int *bytes, int *frames);

static useconds_t sendStall, waitStall;

static ssize_t StalledSend(int fd, const void *buffer, size_t length, int flags) {
    ssize_t count = send(fd, buffer, length, flags);
    if (sendStall) { usleep(sendStall); sendStall = 0; }
    return count;
}

static int StalledKevent(int fd, const struct kevent *changes, int changeCount,
                         struct kevent *events, int eventCount, const struct timespec *timeout) {
    int count = kevent(fd, changes, changeCount, events, eventCount, timeout);
    if (waitStall && timeout && timeout->tv_nsec) { usleep(waitStall); waitStall = 0; }
    return count;
}

#define send StalledSend
#define kevent(...) StalledKevent(__VA_ARGS__)
#define ldacBT_encode CheckedEncode
#define main LogFreeMediaMain
#include "DirectAVDTPLiveMediaProbe.m"
#undef main
#undef send
#undef kevent
#undef ldacBT_encode

static DirectMediaProbe *checkedProbe;
static uint64_t checkedInputFrames;
static uint64_t checkedBoundaryFrames;
static BOOL checkedPCM;
static atomic_bool checkWarmMute;
static BOOL checkedWarmMute;
static uint64_t checkedWarmBlocks;

static float ClockedSample(uint64_t frame, unsigned int channel) {
    return ((int)((frame * 17 + channel * 997) % 4093) - 2046) / 8192.0f;
}

static int CheckedEncode(HANDLE_LDAC_BT encoder, void *pcm, int *used,
                         unsigned char *stream, int *bytes, int *frames) {
    uint64_t validFrames = 128;
    if (pcm && checkedProbe) {
        uint64_t first = checkedInputFrames + checkedProbe.pcmSkippedBytes / 8;
        if (first < checkedBoundaryFrames) validFrames = MIN(validFrames, checkedBoundaryFrames - first);
        float *input = pcm;
        for (unsigned int frame = 0; frame < 128; frame++)
            for (unsigned int channel = 0; channel < 2; channel++)
                checkedPCM &= input[frame * 2 + channel] == (frame < validFrames ? ClockedSample(first + frame, channel) : 0);
    }
    if (pcm && atomic_load(&checkWarmMute)) {
        const float *input = pcm;
        for (unsigned int sample = 0; sample < 256; ++sample) checkedWarmMute &= input[sample] == 0;
        checkedWarmBlocks++;
    }
    int result = ldacBT_encode(encoder, pcm, used, stream, bytes, frames);
    if (pcm && checkedProbe) checkedInputFrames += MIN((uint64_t)*used / 8, validFrames);
    return result;
}

@interface TestMediaChannel : NSObject
@property UInt16 PSM;
@property UInt16 cid;
@property UInt16 outgoingMTU;
@property int socketFD;
@end
@implementation TestMediaChannel
@end

@interface TestMediaManager : NSObject
@property(strong) id peer;
- (id)peerWithIdentifier:(NSUUID *)identifier;
@end
@implementation TestMediaManager
- (id)peerWithIdentifier:(NSUUID *)identifier { return self.peer; }
@end

@interface TestMediaPeer : NSObject
@property(weak) TestMediaManager *manager;
@property(strong) NSUUID *identifier;
@property NSInteger internalState;
@property(strong) id reply;
@property NSUInteger queries;
@property NSUInteger updates;
@property NSUInteger closes;
@property BOOL ignoreUpdate;
@property(copy) void (^onQuery)(void);
@property(copy) void (^onUpdate)(void);
@property(copy) void (^onClose)(void);
- (id)sendInternalSyncMsg:(int)message args:(NSDictionary *)arguments;
- (void)handleGetPeerState:(NSDictionary *)reply;
- (void)closeL2CAPChannel:(UInt16)psm;
@end
@implementation TestMediaPeer
- (id)sendInternalSyncMsg:(int)message args:(NSDictionary *)arguments {
    if (message != 0x2f || arguments) abort();
    self.queries++;
    if (self.onQuery) self.onQuery();
    return self.reply;
}
- (void)handleGetPeerState:(NSDictionary *)reply {
    self.updates++;
    if (!self.ignoreUpdate) self.internalState = [reply[@"kCBMsgArgState"][@"kCBMsgArgInternalState"] integerValue];
    if (self.onUpdate) self.onUpdate();
}
- (void)closeL2CAPChannel:(UInt16)psm {
    if (psm != 0x19) abort();
    self.closes++;
    if (self.onClose) self.onClose();
}
@end

static BOOL Check(BOOL condition, const char *name) {
    printf("LIFECYCLE_CHECK name=%s result=%s\n", name, condition ? "PASS" : "FAIL");
    return condition;
}

static DirectMediaProbe *TestProbe(void) {
    DirectMediaProbe *probe = [DirectMediaProbe new];
    probe.pcmFD = -1;
    probe.controlPending = [NSMutableData data];
    return probe;
}

static CBL2CAPChannel *TestChannel(UInt16 psm, UInt16 cid, UInt16 mtu) {
    TestMediaChannel *channel = [TestMediaChannel new];
    channel.PSM = psm;
    channel.cid = cid;
    channel.outgoingMTU = mtu;
    return (CBL2CAPChannel *)channel;
}

static BOOL RefreshChecks(void) {
    TestMediaManager *manager = [TestMediaManager new];
    TestMediaPeer *peer = [TestMediaPeer new];
    manager.peer = peer;
    peer.manager = manager;
    peer.identifier = [NSUUID UUID];
    peer.reply = @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @2}};
    BOOL passed = Check(!RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) &&
                        peer.queries == 1 && peer.updates == 1 && peer.internalState == 2, "fresh-query-updates-owned-peer");
    NSArray *invalid = @[@[], @{}, @{@"kCBMsgArgState": @2}, @{@"kCBMsgArgState": @{}},
                         @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @"2"}},
                         @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @0}}];
    for (id reply in invalid) {
        peer.reply = reply;
        passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                        peer.updates == 1, "invalid-or-disconnected-query-rejected");
    }
    peer.reply = @{@"kCBMsgArgState": @{@"kCBMsgArgInternalState": @2}};
    peer.internalState = 0;
    peer.ignoreUpdate = YES;
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                    peer.internalState == 0, "refresh-update-failure-rejected");
    peer.ignoreUpdate = NO;
    manager.peer = nil;
    NSUInteger queries = peer.queries;
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                    peer.queries == queries, "foreign-peer-not-queried");
    manager.peer = peer;
    __weak TestMediaManager *weakManager = manager;
    peer.onQuery = ^{ weakManager.peer = nil; };
    NSUInteger updates = peer.updates;
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL &&
                    peer.updates == updates, "owner-loss-during-query-rejected");
    peer.onQuery = nil;
    manager.peer = peer;
    peer.onUpdate = ^{ weakManager.peer = nil; };
    passed &= Check(RefreshOwnedPeer((CBClassicPeer *)peer, (CBClassicManager *)manager) != NULL, "owner-loss-during-update-rejected");
    return passed;
}

static BOOL LifecycleChecks(void) {
    CBL2CAPChannel *channel = TestChannel(0x19, 0x0042, 679);
    DirectMediaProbe *probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    BOOL passed = Check(probe.openDone && probe.channel == channel && probe.realCID == 0x0042 &&
                        !probe.failed && !probe.closed, "valid-open-retained");
    RecordOwnedClose(probe, TestChannel(0x19, 0x0042, 679), 0);
    passed &= Check(!probe.closed && probe.failed, "same-cid-foreign-object-rejected");
    RecordOwnedClose(probe, channel, 0);
    passed &= Check(probe.closed, "exact-owned-close-confirmed");
    RecordOwnedClose(probe, channel, 0);
    passed &= Check(probe.closed, "duplicate-owned-close-idempotent");
    probe = TestProbe();
    RecordOwnedOpen(probe, nil, 0);
    passed &= Check(probe.openDone && probe.failed && !probe.openFailed && !probe.closed, "nil-zero-open-indeterminate");
    TestMediaPeer *peer = [TestMediaPeer new];
    passed &= Check(!CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) && peer.closes == 1 &&
                    !probe.closed, "nil-zero-open-cleanup-unconfirmed");
    probe = TestProbe();
    RecordOwnedOpen(probe, nil, 5);
    peer = [TestMediaPeer new];
    passed &= Check(probe.openFailed && CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) &&
                    peer.closes == 0 && !probe.closed, "explicit-open-failure-terminal");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 5);
    peer = [TestMediaPeer new];
    passed &= Check(!probe.openFailed && !CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) &&
                    peer.closes == 1, "non-nil-error-channel-still-needs-close");
    probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x19, 0, 679), 0);
    passed &= Check(probe.failed && !probe.openFailed, "zero-cid-open-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x19, 0x0042, 13), 0);
    passed &= Check(probe.failed && !probe.openFailed, "undersized-mtu-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x11, 0x0042, 679), 0);
    passed &= Check(probe.failed && !probe.channel, "foreign-psm-open-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    RecordOwnedOpen(probe, TestChannel(0x19, 0x0043, 679), 0);
    passed &= Check(probe.failed && probe.channel == channel && probe.realCID == 0x0042, "duplicate-open-preserves-original");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    RecordOwnedClose(probe, nil, 0);
    passed &= Check(probe.failed && !probe.closed, "nil-disconnect-rejected");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    RecordOwnedClose(probe, channel, 7);
    passed &= Check(probe.failed && probe.closed, "owned-disconnect-error-fails-session");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    probe.stdinEnded = YES;
    probe.inputEnded = YES;
    peer = [TestMediaPeer new];
    double began = MonotonicTime();
    passed &= Check(!CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.02) &&
                    MonotonicTime() - began < 0.2 && !probe.closed, "eof-not-close-proof-bounded");
    probe = TestProbe();
    RecordOwnedOpen(probe, channel, 0);
    peer = [TestMediaPeer new];
    DirectMediaProbe *closingProbe = probe;
    peer.onClose = ^{ dispatch_async(dispatch_get_main_queue(), ^{ RecordOwnedClose(closingProbe, channel, 0); }); };
    passed &= Check(CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.1) && !probe.failed, "asynchronous-owned-close-confirmed");
    probe = TestProbe();
    peer = [TestMediaPeer new];
    DirectMediaProbe *lateProbe = probe;
    __weak TestMediaPeer *weakPeer = peer;
    peer.onClose = ^{
        if (weakPeer.closes == 1) dispatch_async(dispatch_get_main_queue(), ^{ RecordOwnedOpen(lateProbe, channel, 0); });
        else dispatch_async(dispatch_get_main_queue(), ^{ RecordOwnedClose(lateProbe, channel, 0); });
    };
    passed &= Check(CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.1) && peer.closes == 2 &&
                    !probe.failed, "late-open-closed-after-pending-cancel");
    return passed;
}

static BOOL RejectDaemonCloseCheck(void) {
    int controls[2];
    if (pipe(controls) != 0) return NO;
    int savedInput = dup(STDIN_FILENO);
    if (savedInput < 0 || dup2(controls[0], STDIN_FILENO) < 0) {
        if (savedInput >= 0) close(savedInput);
        close(controls[0]); close(controls[1]);
        return NO;
    }
    BOOL passed = write(controls[1], "transport-closed\n", 17) == 17;
    DirectMediaProbe *probe = TestProbe();
    RecordOwnedOpen(probe, TestChannel(0x19, 0x0042, 679), 0);
    TestMediaPeer *peer = [TestMediaPeer new];
    passed &= !CloseOwnedChannel(probe, (CBClassicPeer *)peer, 0.01) && !probe.closed && probe.failed;
    passed &= dup2(savedInput, STDIN_FILENO) >= 0;
    close(savedInput); close(controls[0]); close(controls[1]);
    return Check(passed, "daemon-close-command-rejected");
}

static BOOL AdaptiveChecks(void) {
    const double audio = 512.0 / 96000;
    LDACAdaptivePolicy policy = LDACAdaptivePolicyInit();
    int decision = 0;
    unsigned int packets = 0;
    double debt = 0;
    while (!decision && packets++ < 150) {
        decision = LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.006, 0.001, debt, true);
        debt += 0.006 - audio;
    }
    BOOL passed = Check(decision == LDACBT_EQMID_INC_CONNECTION && debt < 0.1,
                        "adaptive-sustained-subthreshold-deficit");
    policy = LDACAdaptivePolicyInit();
    decision = 0;
    for (int packet = 0; !decision && packet < 60; packet++)
        decision = LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.001, 0, packet * 0.001, true);
    passed &= Check(decision == LDACBT_EQMID_INC_CONNECTION, "adaptive-debt-includes-between-packet-work");
    policy = LDACAdaptivePolicyInit();
    passed &= !LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.080, 0.075, 0.080, true);
    for (int packet = 0; packet < 100; packet++)
        passed &= !LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.001, 0, 0.080, true);
    passed &= Check(policy.deficitSeconds == 0, "adaptive-local-stall-does-not-demote");
    policy = LDACAdaptivePolicyInit();
    passed &= !LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.019, 0, 0, true);
    for (int packet = 0; packet < 100; packet++)
        passed &= !LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.001, 0, 0, true);
    passed &= Check(policy.deficitSeconds == 0, "adaptive-isolated-jitter-recovers");
    policy.deficitSeconds = 0.019;
    passed &= !LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.030, 0, 0.050, false);
    passed &= Check(policy.deficitSeconds == 0, "adaptive-source-starvation-resets-deficit");
    passed &= Check(LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_HQ, audio, 0.030, 0, 0, true) ==
                    LDACBT_EQMID_INC_CONNECTION, "adaptive-long-service-demotes");
    policy = LDACAdaptivePolicyInit();
    for (int packet = 0; packet < 599; packet++)
        passed &= !LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_SQ, 0.01, 0.001, 0, 0, true);
    passed &= Check(LDACAdaptivePolicyObserve(&policy, LDACBT_EQMID_SQ, 0.011, 0.001, 0, 0, true) ==
                    LDACBT_EQMID_INC_QUALITY, "adaptive-six-second-promotion");
    return passed;
}

static BOOL ManualQualityChecks(void) {
    BOOL passed = YES;
    for (NSNumber *rate in @[@44100, @48000, @88200, @96000]) {
        DirectMediaProbe *probe = TestProbe();
        LDACProfile profile;
        SelectProfile(rate.unsignedIntValue, @"high", &profile);
        probe.profile = profile;
        probe.encoder = ldacBT_get_handle();
        passed &= ldacBT_init_handle_encode(probe.encoder, 679, profile.eqmid,
            LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, profile.sampleRate) == 0;
        LDACAdaptivePolicy policy = LDACAdaptivePolicyInit();
        BOOL adaptive = NO;
        uint64_t timestamp = 0;
        NSUInteger sequence = 0;
        for (NSString *quality in @[@"low", @"mid", @"high", @"auto", @"high", @"low"]) {
            probe.pendingQuality = quality;
            ApplyLiveQuality(probe, &profile, &policy, &adaptive);
            passed &= !probe.failed && adaptive == [quality isEqualToString:@"auto"];
            LDACFrameFormat format = {0};
            for (int block = 0; block < 100; block++) {
                float pcm[256] = {0};
                uint8_t packet[LDACBT_MAX_NBYTES + 13];
                NSUInteger length = 0;
                int frames = 0;
                passed &= EncodePacket(probe.encoder, profile, pcm, sequence, timestamp, 679, 679,
                    packet, &length, &frames, &format);
                if (frames) { sequence++; timestamp += frames * profile.frameSamples; }
            }
            LDACProfile expected;
            SelectProfile(profile.sampleRate, quality, &expected);
            passed &= format.bitrateKbps == expected.bitrateKbps;
        }
        ldacBT_free_handle(probe.encoder);
        probe.encoder = NULL;
    }
    return Check(passed, "manual-quality-transitions-all-sample-rates");
}

static BOOL FullRingCheck(void) {
    int descriptors[2];
    if (pipe(descriptors) != 0) return NO;
    DirectMediaProbe *probe = TestProbe();
    LDACProfile profile;
    if (!SelectProfile(96000, @"high", &profile)) abort();
    probe.profile = profile;
    probe.pcmFD = descriptors[0];
    probe.pcmRing = calloc(1, profile.capacityBytes);
    if (!probe.pcmRing || fcntl(probe.pcmFD, F_SETFL, O_NONBLOCK) != 0) abort();
    probe.pcmActive = probe.pcmStarted = probe.pcmContinuous = YES;
    probe.pcmBytes = profile.capacityBytes;
    uint8_t input[PCMBlockBytes];
    memset(input, 0x37, sizeof(input));
    BOOL passed = write(descriptors[1], input, sizeof(input)) == sizeof(input);
    [probe pollPCM];
    passed &= !probe.failed && !probe.pcmReadBytes && probe.pcmBytes == profile.capacityBytes;
    probe.pcmHead += sizeof(input);
    probe.pcmBytes -= sizeof(input);
    [probe pollPCM];
    passed &= !probe.failed && probe.pcmReadBytes == sizeof(input) &&
        probe.pcmBytes == profile.capacityBytes && !memcmp(probe.pcmRing, input, sizeof(input));
    probe.pcmComplete = YES;
    close(descriptors[1]);
    [probe pollPCM];
    return Check(passed && probe.pcmEnded && !probe.failed, "full-ring-defers-read-until-encoder-frees-space");
}

static void WriteClockedFrames(int fd, uint64_t first, NSUInteger frames) {
    while (frames) {
        float samples[256];
        NSUInteger block = MIN(frames, 128);
        for (NSUInteger frame = 0; frame < block; frame++)
            for (unsigned int channel = 0; channel < 2; channel++)
                samples[frame * 2 + channel] = ClockedSample(first + frame, channel);
        if (write(fd, samples, block * 8) != (ssize_t)(block * 8)) abort();
        frames -= block;
        first += block;
    }
}

static BOOL RateDrainControlCheck(void) {
    const struct { const char *command; uint64_t readBytes; BOOL valid; } cases[] = {
        {"drain 0\n", 0, YES},
        {"drain 4294967296\n", 8, YES},
        {"drain 9\n", 0, NO},
        {"drain 0\n", 8, NO},
        {"drain -1\n", 0, NO},
        {"drain 18446744073709551616\n", 0, NO}
    };
    int input = dup(STDIN_FILENO);
    if (input < 0) abort();
    BOOL passed = YES;
    for (NSUInteger index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        int control[2];
        if (pipe(control) || dup2(control[0], STDIN_FILENO) < 0) abort();
        size_t length = strlen(cases[index].command);
        if (write(control[1], cases[index].command, length) != (ssize_t)length) abort();
        DirectMediaProbe *probe = TestProbe();
        probe.pcmContinuous = YES;
        probe.pcmReadBytes = cases[index].readBytes;
        PollLiveControls(probe);
        passed &= probe.rateDrainRequested == cases[index].valid && probe.failed != cases[index].valid;
        close(control[0]); close(control[1]);
    }
    if (dup2(input, STDIN_FILENO) < 0) abort();
    close(input);
    int pcm[2];
    if (pipe(pcm) || fcntl(pcm[0], F_SETFL, O_NONBLOCK) != 0) abort();
    DirectMediaProbe *probe = TestProbe();
    LDACProfile profile;
    if (!SelectProfile(48000, @"low", &profile)) abort();
    probe.profile = profile;
    probe.pcmFD = pcm[0];
    probe.pcmRing = calloc(1, profile.capacityBytes);
    if (!probe.pcmRing) abort();
    probe.pcmActive = probe.pcmStarted = probe.rateDrainRequested = YES;
    probe.rateDrainBytes = 8;
    uint8_t samples[16] = {0};
    if (write(pcm[1], samples, sizeof(samples)) != sizeof(samples)) abort();
    [probe pollPCM];
    passed &= probe.pcmBytes == 8 && probe.pcmReadBytes == 8;
    probe.pcmBytes = 0;
    passed &= !PrepareLiveRate(probe, profile) && !probe.ratePrepared;
    close(pcm[1]);
    close(pcm[0]);
    if (pipe(pcm) || fcntl(pcm[0], F_SETFL, O_NONBLOCK) != 0) abort();
    probe.pcmFD = pcm[0];
    probe.ratePaused = probe.ratePrepared = YES;
    probe.pcmBytes = profile.prefillBytes - 8;
    if (write(pcm[1], samples, sizeof(samples)) != sizeof(samples)) abort();
    [probe pollPCM];
    passed &= probe.pcmReady && probe.pcmBytes == profile.prefillBytes;
    probe.ratePaused = probe.ratePrepared = probe.rateDrainRequested = NO;
    [probe pollPCM];
    passed &= probe.pcmBytes == profile.prefillBytes + 8;

    probe.ratePaused = probe.ratePrepared = probe.parkRequested = YES;
    probe.pcmHead = probe.pcmBytes = 0;
    probe.pcmReady = NO;
    uint64_t bytesRead = probe.pcmReadBytes, discarded = probe.pcmDiscardedBytes;
    uint8_t fresh[4096];
    memset(fresh, 0x5A, sizeof(fresh));
    for (NSUInteger bytes = 0; bytes < profile.capacityBytes;) {
        size_t length = MIN(sizeof(fresh), profile.capacityBytes - bytes);
        if (write(pcm[1], fresh, length) != (ssize_t)length) abort();
        [probe pollPCM];
        bytes += length;
    }
    if (write(pcm[1], samples, sizeof(samples)) != sizeof(samples)) abort();
    [probe pollPCM];
    BOOL held = probe.pcmReady && probe.pcmBytes == profile.capacityBytes &&
        probe.pcmReadBytes - bytesRead == profile.capacityBytes && probe.pcmDiscardedBytes == discarded &&
        probe.pcmHead == 0 && probe.pcmRing[0] == 0x5A;
    close(pcm[1]);
    return Check(passed, "rate-drain-controls-limit-old-and-new-epoch-reads") &&
        Check(held, "warm-prefill-keeps-all-fresh-PCM-within-owned-ring");
}

enum LiveRateScenario { ImmediatePause, PreserveDrain, RollbackDrain, CancelDrain, WarmResume };

static BOOL LiveRateCheck(enum LiveRateScenario scenario) {
    BOOL warm = scenario == WarmResume;
    BOOL preserving = scenario != ImmediatePause && !warm;
    BOOL rollback = scenario == RollbackDrain;
    BOOL cancelling = scenario == CancelDrain;
    int sockets[2], controls[2], pcm[2], logs[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) || pipe(controls) || pipe(pcm) || pipe(logs)) abort();
    int savedInput = dup(STDIN_FILENO), savedOutput = dup(STDOUT_FILENO);
    if (savedInput < 0 || savedOutput < 0 || dup2(controls[0], STDIN_FILENO) < 0) abort();
    LDACProfile oldRate, newRate;
    if (!SelectProfile(48000, @"low", &oldRate) ||
        !SelectProfile(warm || rollback ? 48000 : 96000, warm ? @"low" : @"high", &newRate)) abort();
    DirectMediaProbe *probe = TestProbe();
    probe.encoderMTU = 679;
    if (!PrepareLiveRate(probe, oldRate)) abort();
    probe.ratePrepared = NO;
    memset(probe.pcmRing, 0, oldRate.prefillBytes);
    uint64_t oldPrefillFrames = oldRate.prefillBytes / 8;
    uint64_t oldSourceFrames = oldPrefillFrames + 851;
    if (preserving) {
        float *initial = (float *)probe.pcmRing;
        for (uint64_t frame = 0; frame < oldPrefillFrames; frame++)
            for (unsigned int channel = 0; channel < 2; channel++)
                initial[frame * 2 + channel] = ClockedSample(frame, channel);
        probe.pcmReadBytes = oldRate.prefillBytes;
        checkedBoundaryFrames = oldSourceFrames;
        checkedProbe = probe;
        checkedInputFrames = 0;
        checkedPCM = YES;
    }
    probe.pcmBytes = oldRate.prefillBytes;
    probe.pcmReady = YES;
    probe.pcmFD = pcm[0];
    probe.pcmActive = YES;
    if (fcntl(pcm[0], F_SETFL, O_NONBLOCK) != 0) abort();
    TestMediaChannel *channel = (TestMediaChannel *)TestChannel(0x19, 0x42, 679);
    channel.socketFD = sockets[0];
    RecordOwnedOpen(probe, (CBL2CAPChannel *)channel, 0);
    if (dup2(logs[1], STDOUT_FILENO) < 0) abort();
    close(logs[1]);
    __block NSUInteger oldPackets = 0, newPackets = 0;
    __block BOOL wireValid = YES, verified = NO, drainVerified = NO;
    __block BOOL cancelled = NO;
    __block atomic_bool drainSubmitted;
    atomic_init(&drainSubmitted, false);
    __block atomic_ulong heldPackets;
    atomic_init(&heldPackets, ULONG_MAX);
    checkedWarmMute = YES;
    checkedWarmBlocks = 0;
    uint64_t oldEncodedFrames = EncodedSampleLimit(oldSourceFrames, oldRate);
    int socketReader = sockets[1], controlWriter = controls[1], pcmWriter = pcm[1], logReader = logs[0];
    dispatch_group_t readers = dispatch_group_create();
    dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        uint32_t timestamp = 0;
        double firstPacketAt = 0;
        while (YES) {
            struct pollfd input = {socketReader, POLLIN, 0};
            if (poll(&input, 1, 4000) != 1) { wireValid = NO; break; }
            uint8_t packet[1024];
            ssize_t count = recv(socketReader, packet, sizeof(packet), 0);
            if (!count) break;
            if (count < 16) { wireValid = NO; break; }
            LDACFrameFormat format;
            BOOL afterHold = warm && oldPackets >= atomic_load(&heldPackets);
            if (afterHold && !atomic_load(&checkWarmMute)) wireValid = NO;
            BOOL newFrame = (!warm || afterHold) && FrameHeadersMatch(packet + 13, count - 13, packet[12], newRate, &format) &&
                format.bitrateKbps == (warm ? 330 : 990);
            wireValid &= newFrame || (!newPackets && FrameHeadersMatch(packet + 13, count - 13, packet[12], oldRate, &format) && format.bitrateKbps == 330);
            wireValid &= (((NSUInteger)packet[2] << 8) | packet[3]) == oldPackets + newPackets;
            wireValid &= (((uint32_t)packet[4] << 24) | ((uint32_t)packet[5] << 16) |
                          ((uint32_t)packet[6] << 8) | packet[7]) == timestamp;
            if (newFrame) {
                if (!newPackets && preserving) wireValid &= timestamp == oldEncodedFrames;
                if (++newPackets == 8 && write(controlWriter, "stop\n", 5) != 5) abort();
            } else {
                double now = MonotonicTime();
                if (!oldPackets) firstPacketAt = now;
                if (preserving && timestamp + packet[12] * oldRate.frameSamples == oldEncodedFrames)
                    wireValid &= now - firstPacketAt >= (double)timestamp / oldRate.sampleRate - 0.04;
                oldPackets++;
                if (cancelling && !cancelled && oldPackets >= 3 && atomic_load(&drainSubmitted)) {
                    if (write(controlWriter, "stop\n", 5) != 5) abort();
                    cancelled = YES;
                }
            }
            timestamp += packet[12] * (newFrame ? newRate.frameSamples : oldRate.frameSamples);
        }
        if (cancelling) wireValid &= timestamp < oldEncodedFrames;
        if (!wireValid) { shutdown(socketReader, SHUT_RDWR); if (write(controlWriter, "stop\n", 5) != 5) abort(); }
    });
    dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FILE *log = fdopen(logReader, "r");
        if (!log) abort();
        char line[2048];
        char expected[256];
        snprintf(expected, sizeof(expected), "RATE_DRAINED rate=48000 bytes=%llu sourceFrames=%llu paddingFrames=%llu\n",
                 oldSourceFrames * 8, oldSourceFrames, oldEncodedFrames - oldSourceFrames);
        while (fgets(line, sizeof(line), log)) {
            if (strncmp(line, "LIVE_SENT ", 10) == 0) {
                if (warm) {
                    if (write(controlWriter, "park\n", 5) != 5) abort();
                } else if (preserving) {
                    WriteClockedFrames(pcmWriter, oldPrefillFrames, oldSourceFrames - oldPrefillFrames);
                    if (dprintf(controlWriter, "drain %llu\n", oldSourceFrames * 8) < 0) abort();
                    atomic_store(&drainSubmitted, true);
                } else if (write(controlWriter, "pause\n", 6) != 6) abort();
            } else if (warm && strncmp(line, "PARK_MEDIA_PAUSED ", 18) == 0) {
                unsigned long packets;
                if (sscanf(line, "PARK_MEDIA_PAUSED CID=0042 packets=%lu", &packets) != 1 || !packets) abort();
                atomic_store(&heldPackets, packets);
                float stale[256];
                for (NSUInteger index = 0; index < 256; index++) stale[index] = NAN;
                if (write(pcmWriter, stale, sizeof(stale)) != sizeof(stale)) abort();
                RunLoopFor(0.15);
                if (write(controlWriter, "warm-prefill\n", 13) != 13) abort();
            } else if (preserving && strncmp(line, "RATE_DRAINED ", 13) == 0) {
                drainVerified = strcmp(line, expected) == 0;
                if (write(controlWriter, "rate 96000 high\n", 16) != 16) abort();
            } else if (strcmp(line, "RATE_PAUSED rate=48000\n") == 0) {
                float stale[256];
                for (NSUInteger index = 0; index < 256; index++) stale[index] = NAN;
                if (write(pcmWriter, stale, sizeof(stale)) != sizeof(stale) || write(controlWriter, "rate 96000 high\n", 16) != 16) abort();
            } else if (strcmp(line, warm ? "PARK_MEDIA_PREFILL_PREPARED rate=48000\n" : "RATE_PREPARED rate=96000\n") == 0) {
                if (rollback) {
                    if (write(controlWriter, "rate 48000 high\n", 16) != 16) abort();
                } else if (preserving) {
                    dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        WriteClockedFrames(pcmWriter, oldSourceFrames, newRate.capacityBytes / 8 + 2048);
                    });
                } else {
                    float input[256];
                    for (NSUInteger index = 0; index < 256; index++) input[index] = index % 2 ? -0.25 : 0.25;
                    for (NSUInteger bytes = 0; bytes < newRate.prefillBytes; bytes += sizeof(input))
                        if (write(pcmWriter, input, sizeof(input)) != sizeof(input)) abort();
                }
            } else if (rollback && strcmp(line, "RATE_PREPARED rate=48000\n") == 0) {
                dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    WriteClockedFrames(pcmWriter, oldSourceFrames, newRate.capacityBytes / 8 + 2048);
                });
            } else if (strncmp(line, "PCM_READY ", 10) == 0) {
                if (warm) atomic_store(&checkWarmMute, true);
                if (write(controlWriter, "resume\n", 7) != 7) abort();
            } else if (warm ? strncmp(line, "PARK_LIVE CID=0042 rate=48000 ", 29) == 0 :
                       strcmp(line, rollback ? "RATE_LIVE rate=48000 channels=2 bitrateKbps=990 eqmid=0\n" :
                                              "RATE_LIVE rate=96000 channels=2 bitrateKbps=990 eqmid=0\n") == 0) {
                verified = YES;
            }
        }
        fclose(log);
    });
    BOOL fed = FeedLive(probe, (CBL2CAPChannel *)channel, 1, 0);
    checkedProbe = nil;
    checkedBoundaryFrames = 0;
    shutdown(sockets[0], SHUT_WR);
    if (dup2(savedOutput, STDOUT_FILENO) < 0 || dup2(savedInput, STDIN_FILENO) < 0) abort();
    if (dispatch_group_wait(readers, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) abort();
    close(savedInput); close(savedOutput); close(controls[0]); close(controls[1]); close(pcm[1]);
    close(sockets[0]); close(sockets[1]);
    atomic_store(&checkWarmMute, false);
    if (warm) return Check(fed && verified && wireValid && oldPackets == atomic_load(&heldPackets) && newPackets >= 8 &&
                           probe.channel == (CBL2CAPChannel *)channel && !probe.closed &&
                           probe.pcmDiscardedBytes > 0 && checkedWarmMute && checkedWarmBlocks > 0,
                           "same-rate-warm-hold-discards-PCM-and-resumes-muted-on-owned-socket");
    if (cancelling) return Check(fed && wireValid && cancelled && !drainVerified && !verified && !newPackets && checkedPCM,
                                 "live-rate-drain-cancels-without-completion");
    BOOL content = preserving ? drainVerified && checkedPCM && checkedInputFrames > oldSourceFrames : probe.pcmDiscardedBytes > 0;
    return Check(fed && verified && wireValid && oldPackets > 0 && newPackets >= 8 && content &&
                 probe.channel == (CBL2CAPChannel *)channel && !probe.closed, rollback ? "live-rate-drain-rollback-retains-PCM" :
                 preserving ? "live-rate-drain-preserves-paced-and-padded-PCM" : "live-rate-same-socket-packets-and-stale-PCM-rejection");
}

static BOOL SenderCheck(BOOL adaptive, useconds_t delay, int stall, int terminal) {
    int sockets[2], controls[2], pcm[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0 || pipe(controls) != 0 || pipe(pcm) != 0) abort();
    int savedInput = dup(STDIN_FILENO);
    if (savedInput < 0 || dup2(controls[0], STDIN_FILENO) < 0) abort();
    LDACProfile profile;
    if (!SelectProfile(96000, @"high", &profile)) abort();
    profile.adaptive = adaptive;
    DirectMediaProbe *probe = TestProbe();
    probe.profile = profile;
    probe.pcmRing = calloc(1, profile.capacityBytes);
    probe.pcmBytes = profile.prefillBytes;
    probe.pcmFD = pcm[0];
    probe.pcmActive = YES;
    if (fcntl(probe.pcmFD, F_SETFL, O_NONBLOCK) != 0 || fcntl(pcm[1], F_SETFL, O_NONBLOCK) != 0) abort();
    probe.encoderMTU = 679;
    probe.encoder = ldacBT_get_handle();
    if (!probe.pcmRing || !probe.encoder || ldacBT_init_handle_encode(probe.encoder, 679, profile.eqmid,
            LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, profile.sampleRate) != 0) abort();
    TestMediaChannel *channel = (TestMediaChannel *)TestChannel(0x19, 0x42, 679);
    channel.socketFD = sockets[0];
    RecordOwnedOpen(probe, (CBL2CAPChannel *)channel, 0);
    int flags = fcntl(sockets[0], F_GETFL), lowWater, noSigPipe;
    if (!ReadOption(sockets[0], SO_SNDLOWAT, &lowWater) || !ReadOption(sockets[0], SO_NOSIGPIPE, &noSigPipe)) abort();
    __block BOOL received = YES, callbackRan = NO;
    __block NSUInteger packets = 0;
    __block uint64_t samples = 0;
    __block double maximumDebt = 0, callbackDelay = 0;
    int reader = sockets[1], controlWriter = controls[1], pcmWriter = pcm[1];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        double first = 0;
        while (YES) {
            struct pollfd ready = {reader, POLLIN, 0};
            if (poll(&ready, 1, 3000) != 1) { received = NO; break; }
            uint8_t packet[1024], actual[1024];
            ssize_t count = recv(reader, packet, sizeof(packet), MSG_PEEK);
            if (!count) break;
            if (count < 16 || packet[0] != 0x80 || packet[1] != 0x60 ||
                (((NSUInteger)packet[2] << 8) | packet[3]) != packets ||
                (((uint32_t)packet[4] << 24) | ((uint32_t)packet[5] << 16) |
                 ((uint32_t)packet[6] << 8) | packet[7]) != samples ||
                !FrameHeadersMatch(packet + 13, count - 13, packet[12], profile, NULL)) {
                received = NO; break;
            }
            double now = MonotonicTime();
            if (!packets) first = now;
            maximumDebt = fmax(maximumDebt, now - first - (double)samples / profile.sampleRate);
            NSUInteger offset = 0;
            while (offset < (NSUInteger)count - 1) {
                ssize_t part = recv(reader, actual + offset, MIN((NSUInteger)97, count - 1 - offset), 0);
                if (part <= 0) { received = NO; break; }
                offset += part;
            }
            if (!received) break;
            if (packets == 5) {
                double queued = MonotonicTime();
                dispatch_async(dispatch_get_main_queue(), ^{
                    callbackDelay = MonotonicTime() - queued;
                    callbackRan = YES;
                    if (stall == 1) usleep(50000);
                    if (stall == 2) sendStall = 50000;
                    if (stall == 3) waitStall = 50000;
                    if (terminal == 2) RecordOwnedClose(probe, (CBL2CAPChannel *)channel, 0);
                });
                if (terminal == 1) { close(controlWriter); usleep(20000); }
                if (terminal == 3) { shutdown(reader, SHUT_RDWR); break; }
            }
            usleep(delay);
            uint8_t pending[2];
            received &= recv(reader, pending, sizeof(pending), MSG_PEEK | MSG_DONTWAIT) == 1;
            received &= recv(reader, actual + offset, 1, 0) == 1 && !memcmp(packet, actual, count);
            samples += packet[12] * profile.frameSamples;
            packets++;
            uint8_t source[15 * 256 * 8] = {0};
            NSUInteger sourceBytes = terminal ? 0 : packet[12] * profile.frameSamples * 8;
            double writeDeadline = MonotonicTime() + 1;
            while (sourceBytes && MonotonicTime() < writeDeadline) {
                ssize_t wrote = write(pcmWriter, source, sourceBytes);
                if (wrote > 0) sourceBytes -= wrote;
                else if (wrote < 0 && (errno == EINTR || errno == EAGAIN)) {
                    struct pollfd writable = {pcmWriter, POLLOUT, 0};
                    if (poll(&writable, 1, 100) < 0 && errno != EINTR) break;
                } else break;
            }
            received &= sourceBytes == 0;
            if (!terminal && packets == 240) received &= write(controlWriter, "stop\n", 5) == 5;
            if (!received) break;
        }
        shutdown(reader, SHUT_RDWR);
    });
    double began = MonotonicTime();
    BOOL fed = FeedLive(probe, (CBL2CAPChannel *)channel, 1, 0);
    double elapsed = MonotonicTime() - began;
    shutdown(sockets[0], SHUT_WR);
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) != 0) abort();
    int restoredLowWater, restoredNoSigPipe;
    BOOL restored = ReadOption(sockets[0], SO_SNDLOWAT, &restoredLowWater) &&
        ReadOption(sockets[0], SO_NOSIGPIPE, &restoredNoSigPipe) &&
        restoredLowWater == lowWater && restoredNoSigPipe == noSigPipe && fcntl(sockets[0], F_GETFL) == flags;
    BOOL passed = received && callbackRan && callbackDelay < 0.5 && elapsed < 10 && !probe.pcmSkippedBytes;
    if (terminal) passed &= terminal == 1 ? fed && probe.stdinEnded && restored :
        !fed && (terminal == 2 ? probe.closed : !probe.closed && restored);
    else passed &= fed && restored && probe.stopRequested && packets >= 240 && probe.pcmReadBytes > 0 &&
        (adaptive && !stall ? ldacBT_get_eqmid(probe.encoder) != LDACBT_EQMID_HQ : ldacBT_get_eqmid(probe.encoder) == LDACBT_EQMID_HQ);
    printf("SENDER_CHECK adaptive=%d delay=%u stall=%d terminal=%d packets=%lu samples=%llu debtMax=%.6f callbackDelay=%.6f elapsed=%.6f eqmid=%d result=%s\n",
           adaptive, delay, stall, terminal, packets, samples, maximumDebt, callbackDelay, elapsed,
           ldacBT_get_eqmid(probe.encoder), passed ? "PASS" : "FAIL");
    if (dup2(savedInput, STDIN_FILENO) < 0) abort();
    close(savedInput); close(controls[0]);
    if (terminal != 1) close(controls[1]);
    close(pcm[1]);
    close(sockets[0]); close(sockets[1]);
    return passed;
}

enum { SourceSteady, SourceBursts, SourceRecovery, SourceDeficit };

static BOOL IndependentSourceCheck(BOOL adaptive, int scenario) {
    const char *names[] = {"steady", "recoverable-bursts", "shrinking-debt", "mild-deficit"};
    int sockets[2], controls[2], pcm[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0 || pipe(controls) != 0 || pipe(pcm) != 0) abort();
    int savedInput = dup(STDIN_FILENO);
    if (savedInput < 0 || dup2(controls[0], STDIN_FILENO) < 0) abort();
    LDACProfile profile;
    if (!SelectProfile(96000, @"high", &profile)) abort();
    profile.adaptive = adaptive;
    DirectMediaProbe *probe = TestProbe();
    probe.profile = profile;
    probe.pcmRing = calloc(1, profile.capacityBytes);
    probe.pcmBytes = profile.prefillBytes;
    probe.pcmFD = pcm[0];
    probe.pcmActive = YES;
    if (!probe.pcmRing || fcntl(pcm[0], F_SETFL, O_NONBLOCK) != 0 ||
        fcntl(pcm[1], F_SETFL, O_NONBLOCK) != 0) abort();
    float *prefill = (float *)probe.pcmRing;
    for (NSUInteger frame = 0; frame < profile.prefillBytes / 8; frame++)
        for (unsigned int channel = 0; channel < 2; channel++)
            prefill[frame * 2 + channel] = ClockedSample(frame, channel);
    probe.encoderMTU = 679;
    probe.encoder = ldacBT_get_handle();
    if (!probe.encoder || ldacBT_init_handle_encode(probe.encoder, 679, profile.eqmid,
            LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, profile.sampleRate) != 0) abort();
    TestMediaChannel *channel = (TestMediaChannel *)TestChannel(0x19, 0x42, 679);
    channel.socketFD = sockets[0];
    RecordOwnedOpen(probe, (CBL2CAPChannel *)channel, 0);
    int flags = fcntl(sockets[0], F_GETFL), lowWater, noSigPipe;
    if (!ReadOption(sockets[0], SO_SNDLOWAT, &lowWater) || !ReadOption(sockets[0], SO_NOSIGPIPE, &noSigPipe)) abort();
    double duration = scenario == SourceBursts ? 6 : scenario == SourceRecovery ? 12 :
        scenario == SourceDeficit ? 28 : adaptive ? 22 : 8;
    double began = MonotonicTime();
    double deadline = began + duration + 3;
    atomic_bool finished = false;
    atomic_bool *done = &finished;
    __block BOOL produced = YES, received = YES, stopSent = NO, sawLower = NO, returnedHQ = NO;
    __block uint64_t producedFrames = 0, packets = 0, samples = 0, timestampEnd = 0, timestampSkips = 0;
    __block double producerLateness = 0, maximumDebt = 0, recoveryDebt = 0, highDebtSeconds = 0;
    __block uint64_t maximumPacketSamples = 0;
    __block NSUInteger bursts = 0;
    int writer = pcm[1], reader = sockets[1], controlWriter = controls[1];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        while (!atomic_load(done) && MonotonicTime() < deadline) {
            double now = MonotonicTime();
            if (!stopSent && now >= began + duration) {
                stopSent = write(controlWriter, "stop\n", 5) == 5;
                if (!stopSent) { produced = NO; break; }
            }
            double due = began + (double)(producedFrames + 960) / profile.sampleRate;
            if (now < due) { usleep((useconds_t)fmin((due - now) * 1000000, 1000)); continue; }
            producerLateness = fmax(producerLateness, now - due);
            float source[960 * 2];
            for (unsigned int frame = 0; frame < 960; frame++)
                for (unsigned int channel = 0; channel < 2; channel++)
                    source[frame * 2 + channel] = ClockedSample(profile.prefillBytes / 8 + producedFrames + frame, channel);
            NSUInteger offset = 0;
            double writeDeadline = fmin(deadline, now + 1);
            while (offset < sizeof(source) && !atomic_load(done) && MonotonicTime() < writeDeadline) {
                ssize_t count = write(writer, (uint8_t *)source + offset, sizeof(source) - offset);
                if (count > 0) offset += count;
                else if (count < 0 && (errno == EINTR || errno == EAGAIN)) {
                    struct pollfd writable = {writer, POLLOUT, 0};
                    if (poll(&writable, 1, 10) < 0 && errno != EINTR) break;
                } else break;
            }
            if (offset != sizeof(source)) {
                produced &= atomic_load(done);
                break;
            }
            producedFrames += 960;
        }
        close(writer);
        if (!atomic_load(done)) shutdown(reader, SHUT_RDWR);
    });
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        double releaseAt = 0, highDebtBegan = 0;
        while (MonotonicTime() < deadline) {
            struct pollfd ready = {reader, POLLIN, 0};
            if (poll(&ready, 1, 1000) < 0) { if (errno == EINTR) continue; received = NO; break; }
            if (!(ready.revents & (POLLIN | POLLHUP))) continue;
            uint8_t packet[1024], actual[1024];
            ssize_t count = recv(reader, packet, sizeof(packet), MSG_PEEK | MSG_DONTWAIT);
            if (!count) break;
            if (count < 16) { received = NO; break; }
            uint32_t timestamp = ((uint32_t)packet[4] << 24) | ((uint32_t)packet[5] << 16) |
                ((uint32_t)packet[6] << 8) | packet[7];
            LDACFrameFormat format;
            if (packet[0] != 0x80 || packet[1] != 0x60 ||
                (((NSUInteger)packet[2] << 8) | packet[3]) != (packets & UINT16_MAX) ||
                timestamp < timestampEnd || (timestamp - timestampEnd) % 128 ||
                !FrameHeadersMatch(packet + 13, count - 13, packet[12], profile, &format)) {
                received = NO; break;
            }
            timestampSkips += timestamp - timestampEnd;
            double now = MonotonicTime();
            double debt = now - began - (double)timestamp / profile.sampleRate;
            maximumDebt = fmax(maximumDebt, debt);
            if (now >= began + (scenario == SourceSteady ? 18 : duration - 1))
                recoveryDebt = fmax(recoveryDebt, debt);
            if (debt >= 0.1) {
                if (!highDebtBegan) highDebtBegan = now;
                highDebtSeconds = fmax(highDebtSeconds, now - highDebtBegan);
            } else {
                highDebtBegan = 0;
            }
            sawLower |= format.frameBytes < 330;
            returnedHQ |= sawLower && format.frameBytes == 330;
            NSUInteger offset = 0;
            while (offset < (NSUInteger)count - 1) {
                ssize_t part = recv(reader, actual + offset, MIN((NSUInteger)97, count - 1 - offset), MSG_DONTWAIT);
                if (part <= 0) { received = NO; break; }
                offset += part;
            }
            if (!received) break;
            if (scenario == SourceSteady) {
                usleep(adaptive && now >= began + 2 && now < began + 5 ? 6000 : 1000);
            } else {
                double elapsed = now - began;
                double wait = 0.001;
                if (scenario == SourceBursts && elapsed >= 0.8 + bursts * 0.5 && elapsed < duration - 1) {
                    wait = bursts ? 0.12 : 0.18;
                    bursts++;
                } else if (scenario == SourceRecovery && elapsed >= 0.8) {
                    releaseAt = releaseAt ? releaseAt + 0.0048 + 0.0004 * fmin(1, (elapsed - 0.8) / 3) : now + 0.35;
                    wait = fmax(0, releaseAt - MonotonicTime());
                } else if (scenario == SourceDeficit) {
                    releaseAt = releaseAt ? releaseAt + 0.0055 : now + 0.0055;
                    wait = fmax(0, releaseAt - MonotonicTime());
                }
                mach_wait_until(mach_absolute_time() + (uint64_t)(wait * 1000000000) * timebase.denom / timebase.numer);
            }
            uint8_t pending[2];
            received &= recv(reader, pending, sizeof(pending), MSG_PEEK | MSG_DONTWAIT) == 1;
            received &= recv(reader, actual + offset, 1, MSG_DONTWAIT) == 1 && !memcmp(packet, actual, count);
            uint64_t packetSamples = packet[12] * profile.frameSamples;
            maximumPacketSamples = MAX(maximumPacketSamples, packetSamples);
            samples += packetSamples;
            timestampEnd = timestamp + packetSamples;
            packets++;
            if (!received) break;
        }
        shutdown(reader, SHUT_RDWR);
    });
    checkedProbe = probe;
    checkedInputFrames = 0;
    checkedPCM = YES;
    BOOL fed = FeedLive(probe, (CBL2CAPChannel *)channel, 1, 0);
    atomic_store(done, true);
    shutdown(sockets[0], SHUT_WR);
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) abort();
    double elapsed = MonotonicTime() - began;
    int restoredLowWater, restoredNoSigPipe;
    BOOL restored = ReadOption(sockets[0], SO_SNDLOWAT, &restoredLowWater) &&
        ReadOption(sockets[0], SO_NOSIGPIPE, &restoredNoSigPipe) && restoredLowWater == lowWater &&
        restoredNoSigPipe == noSigPipe && fcntl(sockets[0], F_GETFL) == flags;
    BOOL accounted = profile.prefillBytes + probe.pcmReadBytes ==
        checkedInputFrames * 8 + probe.pcmBytes + probe.pcmDiscardedBytes;
    BOOL passed = produced && received && checkedPCM && accounted && restored &&
        !probe.pcmSkippedBytes && timestampSkips == probe.pcmSkippedBytes / 8 &&
        samples <= EncodedSampleLimit(checkedInputFrames, profile) && elapsed < duration + 5 &&
        ldacBT_get_eqmid(probe.encoder) == LDACBT_EQMID_HQ && (adaptive ? sawLower && returnedHQ : !sawLower);
    if (scenario == SourceDeficit) {
        passed &= !fed && probe.failed && !stopSent && elapsed < duration &&
            maximumDebt >= ((double)(profile.capacityBytes - profile.prefillBytes) / 8 - 2 * maximumPacketSamples) / profile.sampleRate &&
            samples <= checkedInputFrames && checkedInputFrames - samples <= maximumPacketSamples;
    } else {
        passed &= fed && stopSent && samples >= checkedInputFrames &&
            checkedInputFrames > (duration - 1) * profile.sampleRate;
    }
    if (scenario == SourceBursts) passed &= bursts >= 4 && maximumDebt >= 0.1 && recoveryDebt < 0.1;
    if (scenario == SourceRecovery) passed &= maximumDebt >= 0.3 && highDebtSeconds > 3 && recoveryDebt < 0.1;
    printf("INDEPENDENT_SOURCE_CHECK scenario=%s adaptive=%d duration=%.0f packets=%llu producedFrames=%llu inputFrames=%llu encodedFrames=%llu skippedFrames=%llu bufferedFrames=%lu producerLateMax=%.6f debtMax=%.6f recoveryDebtMax=%.6f lower=%d returnedHQ=%d pcmExact=%d accounted=%d fed=%d elapsed=%.6f highDebtSeconds=%.6f bursts=%lu result=%s\n",
           names[scenario], adaptive, duration, packets, producedFrames, checkedInputFrames, samples, probe.pcmSkippedBytes / 8,
           probe.pcmBytes / 8, producerLateness, maximumDebt, recoveryDebt, sawLower, returnedHQ,
           checkedPCM, accounted, fed, elapsed, highDebtSeconds, bursts, passed ? "PASS" : "FAIL");
    checkedProbe = nil;
    if (dup2(savedInput, STDIN_FILENO) < 0) abort();
    close(savedInput); close(controls[0]); close(controls[1]);
    close(sockets[0]); close(sockets[1]);
    return passed;
}

int main(void) {
    setbuf(stdout, NULL);
    if (!ManualQualityChecks()) return 1;
    @autoreleasepool {
        BOOL refresh = RefreshChecks();
        BOOL lifecycle = LifecycleChecks();
        BOOL daemon = RejectDaemonCloseCheck();
        BOOL policy = AdaptiveChecks();
        BOOL ring = FullRingCheck() && RateDrainControlCheck();
        ring &= LiveRateCheck(ImmediatePause);
        ring &= LiveRateCheck(PreserveDrain);
        ring &= LiveRateCheck(RollbackDrain);
        ring &= LiveRateCheck(CancelDrain);
        ring &= LiveRateCheck(WarmResume);
        BOOL sender = SenderCheck(NO, 1000, NO, 0);
        sender &= SenderCheck(NO, 4000, NO, 0);
        sender &= SenderCheck(YES, 6000, NO, 0);
        sender &= SenderCheck(YES, 1000, YES, 0);
        sender &= SenderCheck(YES, 1000, 2, 0);
        sender &= SenderCheck(YES, 1000, 3, 0);
        sender &= SenderCheck(NO, 6000, NO, 1);
        sender &= SenderCheck(NO, 6000, NO, 2);
        sender &= SenderCheck(NO, 6000, NO, 3);
        sender &= IndependentSourceCheck(NO, SourceSteady);
        sender &= IndependentSourceCheck(YES, SourceSteady);
        sender &= IndependentSourceCheck(NO, SourceBursts);
        sender &= IndependentSourceCheck(NO, SourceRecovery);
        sender &= IndependentSourceCheck(NO, SourceDeficit);
        BOOL passed = refresh && lifecycle && daemon && policy && ring && sender;
        printf("MEDIA_LIFECYCLE_TESTS result=%s hardwareAccess=0\n", passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
