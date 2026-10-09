#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include "SonyClassicConnection.h"

@interface OfflineClassicPeer : NSObject
@property NSInteger state;
@end
@implementation OfflineClassicPeer
@end

@interface OfflinePeripheral : NSObject
@property BOOL connected;
- (BOOL)isConnectedToSystem;
@end
@implementation OfflinePeripheral
- (BOOL)isConnectedToSystem { return self.connected; }
@end

static id peer;
static id peripheral;
static BOOL legacyConnected;
static id Peer(id self, SEL selector) { return peer; }
static id Peripheral(id self, SEL selector) { return peripheral; }

@interface OfflineLegacyDevice : NSObject
- (BOOL)isConnected;
@end
@implementation OfflineLegacyDevice
- (BOOL)isConnected { return legacyConnected; }
@end

@interface OfflineUnsupportedPeerDevice : OfflineLegacyDevice
- (id)classicPeer;
@end
@implementation OfflineUnsupportedPeerDevice
- (id)classicPeer { return peer; }
@end

static void Check(IOBluetoothDevice *device, NSString *name, BOOL classic) {
    BOOL generic = device.isConnected;
    BOOL connected = SonyClassicIsConnected(device);
#if defined(ACOUPLET_PUBLIC_APIS_ONLY)
    assert(connected == generic);
#else
    assert(connected == classic);
#endif
    printf("PASS %s generic=%d classic=%d\n", name.UTF8String, generic, connected);
}

int main(void) {
    @autoreleasepool {
        Class fixture = objc_allocateClassPair(IOBluetoothDevice.class, "OfflineSonyClassicConnectionDevice", 0);
        assert(class_addMethod(fixture, sel_registerName("peer"), (IMP)Peer, "@@:"));
        assert(class_addMethod(fixture, sel_registerName("peripheral"), (IMP)Peripheral, "@@:"));
        objc_registerClassPair(fixture);
        IOBluetoothDevice *device = class_createInstance(fixture, 0);
        OfflineClassicPeer *classic = OfflineClassicPeer.new;
        OfflinePeripheral *ble = OfflinePeripheral.new;
        classic.state = 2;
        peer = classic;
        Check(device, @"Classic2/no-LE", YES);
        peripheral = ble;
        Check(device, @"Classic2/LEfalse", YES);
        ble.connected = YES;
        Check(device, @"Classic2/LEtrue", YES);
        for (NSNumber *state in @[@0, @1, @3]) {
            classic.state = state.integerValue;
            Check(device, [NSString stringWithFormat:@"Classic%@/LEtrue", state], NO);
        }
        peer = nil;
        Check(device, @"supported-nil-peer/LEtrue", NO);
        OfflineLegacyDevice *legacy = OfflineLegacyDevice.new;
        OfflineUnsupportedPeerDevice *unsupported = OfflineUnsupportedPeerDevice.new;
        peer = NSObject.new;
        for (NSNumber *state in @[@NO, @YES]) {
            legacyConnected = state.boolValue;
            Check((IOBluetoothDevice *)legacy, @"unsupported-classicPeer", legacyConnected);
            Check((IOBluetoothDevice *)unsupported, @"unsupported-state", legacyConnected);
        }
        Check(nil, @"nil-device", NO);
        puts("PASS actual production header with inert real-framework receiver; no device initialization or connection actions");
        fflush(stdout);
        _exit(0);
    }
}
