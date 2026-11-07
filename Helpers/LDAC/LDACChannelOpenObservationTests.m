#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>

static NSMutableArray<NSString *> *observedLines;

static int CapturePrintf(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:arguments];
    va_end(arguments);
    [observedLines addObject:line];
    errno = EIO;
    return (int)line.length;
}

#define printf CapturePrintf
#include "LDACChannelOpenObservation.h"
#undef printf

@interface NSObject (OpenEventTests)
- (void)handleL2CAPChannelOpened:(id)info;
@end

@interface CBL2CAPChannel (OpenEventTests)
@property(readonly) BOOL isPacketBased;
@property(readonly) UInt16 cid;
@property(readonly) UInt16 outgoingMTU;
@end

@interface OfflineOpenPeer : NSObject
@property(copy) void (^connectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
- (id)manager;
- (id)identifier;
- (id)serviceForPSM:(UInt16)psm;
- (id)L2CAPChannels;
@end
@implementation OfflineOpenPeer
- (id)manager { return nil; }
- (id)identifier { return nil; }
- (id)serviceForPSM:(UInt16)psm { return nil; }
- (id)L2CAPChannels { return nil; }
@end

@interface RecordingOpenPeer : NSObject
@property(strong) id received;
@property NSUInteger calls;
@property int incomingError;
@end
@implementation RecordingOpenPeer
- (void)handleL2CAPChannelOpened:(id)info {
    self.incomingError = errno;
    self.received = info;
    self.calls++;
    if ([info isKindOfClass:NSMutableDictionary.class]) info[@"kCBMsgArgResult"] = @999;
    errno = E2BIG;
}
@end

static NSUInteger checks;

static void Check(BOOL passed, const char *name) {
    checks++;
    if (!passed) { fprintf(stderr, "FAIL %s check=%lu\n", name, checks); exit(1); }
}

static BOOL LastContains(NSString *text) {
    return [observedLines.lastObject containsString:text];
}

static NSMutableDictionary *OpenInfo(NSNumber *result) {
    return [@{@"kCBMsgArgResult": result, @"kCBMsgArgPSM": @25, @"kCBMsgArgCID": @2827,
              @"kCBMsgArgOutMTU": @672, @"kCBMsgArgSocket": @(-1), @"kCBMsgArgIsIncoming": @NO,
              @"private-address": @"AA:BB:CC:DD:EE:FF"} mutableCopy];
}

static void FrameworkChecks(void) {
    SEL selector = sel_registerName("handleL2CAPChannelOpened:");
    Method method = class_getInstanceMethod(NSClassFromString(@"CBClassicPeer"), selector);
    Check(method && !strcmp(method_getTypeEncoding(method), "v24@0:8@16"), "native event handler ABI");
    IMP frameworkHandler = method_getImplementation(method);
    void (*nativeHandler)(id, SEL, id) = (void *)frameworkHandler;
    Check(class_addMethod(OfflineOpenPeer.class, selector, frameworkHandler, method_getTypeEncoding(method)),
          "inert receiver uses actual framework handler");
    OfflineOpenPeer *owned = [OfflineOpenPeer new];
    OfflineOpenPeer *foreign = [OfflineOpenPeer new];
    __block NSUInteger callbacks = 0;
    __block CBL2CAPChannel *channel;
    __block NSInteger code = -1;
    __block NSArray<NSNumber *> *outcome;
    owned.connectL2CAPCallback = foreign.connectL2CAPCallback = ^(CBL2CAPChannel *value, NSInteger status) {
        callbacks++;
        channel = value;
        code = status;
        outcome = @[@(value != nil), @(status), @(value.PSM), @(value.cid), @(value.outgoingMTU),
                    @([value respondsToSelector:@selector(isPacketBased)] ? value.isPacketBased : -1)];
    };
    NSMutableDictionary *info = OpenInfo(@454);
    NSDictionary *before = [info copy];
    nativeHandler(owned, selector, info);
    NSArray<NSNumber *> *expected = outcome;
    printf("RAW_CHANNEL_OPEN_HOST raw_result=454 nil_channel=%d callback_status=%ld\n", channel == nil, (long)code);
    Check(LDACObserveChannelOpens(owned, "signaling"), "observer installed on inert receiver class");
    Check(method_getImplementation(method) == frameworkHandler, "framework class unchanged by inert test");
    uint64_t began = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    [owned handleL2CAPChannelOpened:info];
    uint64_t ended = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    Check(callbacks == 2 && [outcome isEqual:expected], "native raw 454 callback outcome unchanged");
    Check([info isEqual:before], "event unchanged by observer and native handler");
    Check(LastContains(@"result_present=1 result_type=number result_value=454") &&
          LastContains(@"psm_present=1 psm_type=number psm_value=25") &&
          LastContains(@"cid_present=1 cid_type=number cid_value=2827") &&
          LastContains(@"mtu_present=1 mtu_type=number mtu_value=672") &&
          LastContains(@"socket_present=1 socket_type=number socket_value=-1") &&
          LastContains(@"incoming_present=1 incoming_type=number incoming_value=0"), "native raw fields preserved");
    NSArray<NSString *> *timeFields = [observedLines.lastObject componentsSeparatedByString:@"time_ns="];
    uint64_t timestamp = strtoull(timeFields.lastObject.UTF8String, NULL, 10);
    Check(timestamp >= began && timestamp <= ended, "raw event timestamp brackets native handler");
    [foreign handleL2CAPChannelOpened:info];
    Check(callbacks == 3 && [outcome isEqual:expected] && observedLines.count == 1, "foreign event forwarded without observation");
    info = OpenInfo(@0);
    nativeHandler(owned, selector, info);
    expected = outcome;
    printf("RAW_CHANNEL_OPEN_HOST raw_result=0 socket=-1 nil_channel=%d callback_status=%ld packet_based=%ld\n",
           channel == nil, (long)code, (long)outcome.lastObject.integerValue);
    [owned handleL2CAPChannelOpened:info];
    Check(callbacks == 5 && [outcome isEqual:expected], "native numeric socket callback outcome unchanged");
    [info removeObjectForKey:@"kCBMsgArgSocket"];
    nativeHandler(owned, selector, info);
    expected = outcome;
    [owned handleL2CAPChannelOpened:info];
    Check(callbacks == 7 && [outcome isEqual:expected] &&
          LastContains(@"socket_present=0 socket_type=missing socket_value=none"), "missing socket retained as missing");
    info[@"kCBMsgArgSocket"] = @"private-socket-text";
    nativeHandler(owned, selector, info);
    expected = outcome;
    [owned handleL2CAPChannelOpened:info];
    Check(callbacks == 9 && [outcome isEqual:expected] &&
          LastContains(@"socket_present=1 socket_type=string socket_value=none"), "wrong socket type retained without contents");
    info[@"kCBMsgArgSocket"] = @(-1);
    [info removeObjectForKey:@"kCBMsgArgResult"];
    nativeHandler(owned, selector, info);
    expected = outcome;
    [owned handleL2CAPChannelOpened:info];
    Check(callbacks == 11 && [outcome isEqual:expected] &&
          LastContains(@"result_present=0 result_type=missing result_value=none"), "absent result distinguished from zero");
    info = OpenInfo(@454);
    for (unsigned index = 0; index < LDACChannelOpenObservationLimit + 4; index++)
        [owned handleL2CAPChannelOpened:info];
    Check(observedLines.count == LDACChannelOpenObservationLimit && callbacks == LDACChannelOpenObservationLimit + 15,
          "bounded observations keep forwarding every native event");
    for (NSString *line in observedLines)
        Check(![line containsString:@"AA:BB"] && ![line containsString:@"private-"], "only allowlisted field values emitted");
}

static void BoundaryChecks(void) {
    [observedLines removeAllObjects];
    RecordingOpenPeer *owned = [RecordingOpenPeer new];
    Check(LDACObserveChannelOpens(owned, "media"), "local boundary observer installed");
    NSMutableDictionary *info = OpenInfo(@454);
    errno = EDOM;
    [owned handleL2CAPChannelOpened:info];
    Check(owned.received == info && owned.calls == 1 && owned.incomingError == EDOM && errno == E2BIG,
          "original receives identical object and errno exactly once");
    Check([info[@"kCBMsgArgResult"] isEqual:@999] && LastContains(@"result_value=454"),
          "capture precedes original handler mutation");
    NSDictionary *invalidFields = @{@"kCBMsgArgResult": NSNull.null, @"kCBMsgArgPSM": @"25",
                                   @"kCBMsgArgCID": @[], @"kCBMsgArgOutMTU": @{},
                                   @"kCBMsgArgSocket": [NSData dataWithBytes:"private" length:7]};
    [owned handleL2CAPChannelOpened:invalidFields];
    Check(owned.received == invalidFields && owned.calls == 2 &&
          LastContains(@"result_present=1 result_type=null result_value=none") &&
          LastContains(@"psm_present=1 psm_type=string psm_value=none") &&
          LastContains(@"cid_present=1 cid_type=array cid_value=none") &&
          LastContains(@"mtu_present=1 mtu_type=dictionary mtu_value=none") &&
          LastContains(@"socket_present=1 socket_type=data socket_value=none"), "wrong field types remain distinguishable");
    [owned handleL2CAPChannelOpened:@[@"private"]];
    Check(owned.calls == 3 && LastContains(@"info_type=array") && LastContains(@"result_present=0"),
          "non-dictionary event forwarded unchanged");
    NSDictionary *numeric = @{@"kCBMsgArgResult": @(UINT64_MAX), @"kCBMsgArgPSM": @(INT64_MIN),
                             @"kCBMsgArgCID": @1.25, @"kCBMsgArgOutMTU": @YES, @"kCBMsgArgSocket": @(-1)};
    [owned handleL2CAPChannelOpened:numeric];
    Check(LastContains(@"result_value=18446744073709551615") && LastContains(@"psm_value=-9223372036854775808") &&
          LastContains(@"cid_value=1.25") && LastContains(@"mtu_value=1"), "numeric values keep sign precision and fractions");
    Check(!LDACObserveChannelOpens([NSObject new], "media"), "missing handler leaves observation unavailable");
    SEL selector = sel_registerName("handleL2CAPChannelOpened:");
    Class incompatible = objc_allocateClassPair(NSObject.class, "IncompatibleOpenEventReceiver", 0);
    IMP original = method_getImplementation(class_getInstanceMethod(RecordingOpenPeer.class, selector));
    Check(class_addMethod(incompatible, selector, original, "i24@0:8@16"), "incompatible ABI fixture");
    objc_registerClassPair(incompatible);
    Check(!LDACObserveChannelOpens([incompatible new], "media") &&
          method_getImplementation(class_getInstanceMethod(incompatible, selector)) == original,
          "incompatible ABI not replaced");
    __weak RecordingOpenPeer *weakPeer = owned;
    owned = nil;
    Check(!weakPeer, "observer does not extend peer lifetime");
}

int main(void) {
    @autoreleasepool {
        observedLines = [NSMutableArray array];
        FrameworkChecks();
        BoundaryChecks();
        printf("RAW_CHANNEL_OPEN_CHECK result=PASS checks=%lu hardwareAccess=0 nativeManagerCreated=0\n", checks);
    }
    return 0;
}
