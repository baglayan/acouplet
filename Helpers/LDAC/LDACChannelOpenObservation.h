#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <errno.h>
#include <float.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

enum { LDACChannelOpenObservationLimit = 8 };

typedef struct {
    BOOL present;
    const char *type;
    char value[32];
} LDACOpenField;

static const char *LDACOpenValueType(id value) {
    if (!value) return "missing";
    if ([value isKindOfClass:NSNumber.class]) return "number";
    if (value == NSNull.null) return "null";
    if ([value isKindOfClass:NSString.class]) return "string";
    if ([value isKindOfClass:NSData.class]) return "data";
    if ([value isKindOfClass:NSArray.class]) return "array";
    if ([value isKindOfClass:NSDictionary.class]) return "dictionary";
    return "other";
}

static LDACOpenField LDACObserveOpenField(NSDictionary *info, NSString *key) {
    id value = info[key];
    LDACOpenField field = {.present = value != nil, .type = LDACOpenValueType(value), .value = "none"};
    if ([value isKindOfClass:NSNumber.class]) {
        switch (((NSNumber *)value).objCType[0]) {
            case 'C': case 'S': case 'I': case 'L': case 'Q':
                snprintf(field.value, sizeof(field.value), "%llu", [value unsignedLongLongValue]);
                break;
            case 'f': case 'd':
                snprintf(field.value, sizeof(field.value), "%.*g", DBL_DECIMAL_DIG, [value doubleValue]);
                break;
            default:
                snprintf(field.value, sizeof(field.value), "%lld", [value longLongValue]);
        }
    }
    return field;
}

static BOOL LDACObserveChannelOpens(id peer, const char *role) {
    SEL selector = sel_registerName("handleL2CAPChannelOpened:");
    Class peerClass = object_getClass(peer);
    Method method = class_getInstanceMethod(peerClass, selector);
    if (!method || strcmp(method_getTypeEncoding(method), "v24@0:8@16")) return NO;
    void (*original)(id, SEL, id) = (void *)method_getImplementation(method);
    __weak id ownedPeer = peer;
    __block atomic_uint observations = 0;
    IMP observer = imp_implementationWithBlock(^(id receiver, id info) {
        int savedError = errno;
        unsigned index = LDACChannelOpenObservationLimit;
        if (receiver == ownedPeer && atomic_load_explicit(&observations, memory_order_relaxed) < LDACChannelOpenObservationLimit)
            index = atomic_fetch_add_explicit(&observations, 1, memory_order_relaxed);
        if (index >= LDACChannelOpenObservationLimit) {
            errno = savedError;
            original(receiver, selector, info);
            return;
        }
        uint64_t observed = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        const char *infoType = LDACOpenValueType(info);
        NSDictionary *fields = [info isKindOfClass:NSDictionary.class] ? info : nil;
        LDACOpenField result = LDACObserveOpenField(fields, @"kCBMsgArgResult");
        LDACOpenField psm = LDACObserveOpenField(fields, @"kCBMsgArgPSM");
        LDACOpenField cid = LDACObserveOpenField(fields, @"kCBMsgArgCID");
        LDACOpenField mtu = LDACObserveOpenField(fields, @"kCBMsgArgOutMTU");
        LDACOpenField socket = LDACObserveOpenField(fields, @"kCBMsgArgSocket");
        LDACOpenField incoming = LDACObserveOpenField(fields, @"kCBMsgArgIsIncoming");
        errno = savedError;
        original(receiver, selector, info);
        savedError = errno;
        printf("RAW_CHANNEL_OPEN role=%s event=%u time_ns=%" PRIu64 " info_type=%s "
               "result_present=%d result_type=%s result_value=%s psm_present=%d psm_type=%s psm_value=%s "
               "cid_present=%d cid_type=%s cid_value=%s mtu_present=%d mtu_type=%s mtu_value=%s "
               "socket_present=%d socket_type=%s socket_value=%s incoming_present=%d incoming_type=%s incoming_value=%s\n",
               role, index + 1, observed, infoType, result.present, result.type, result.value,
               psm.present, psm.type, psm.value, cid.present, cid.type, cid.value,
               mtu.present, mtu.type, mtu.value, socket.present, socket.type, socket.value,
               incoming.present, incoming.type, incoming.value);
        errno = savedError;
    });
    class_replaceMethod(peerClass, selector, observer, method_getTypeEncoding(method));
    return YES;
}
