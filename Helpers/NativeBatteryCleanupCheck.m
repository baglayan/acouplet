#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/IOCFUnserialize.h>
#import <IOBluetooth/IOBluetooth.h>

@interface CheckBluetoothDevice : IOBluetoothDevice
@end

@implementation CheckBluetoothDevice
+ (instancetype)deviceWithAddressString:(NSString *)address { return nil; }
@end

static CFTypeRef checkCopyPowerSourcesByType(int type);
static CFArrayRef checkCopyPowerSourcesList(CFTypeRef info);
static CFDictionaryRef checkGetPowerSourceDescription(CFTypeRef info, CFTypeRef source);

#define IOPSCopyPowerSourcesByType checkCopyPowerSourcesByType
#define IOPSCopyPowerSourcesList checkCopyPowerSourcesList
#define IOPSGetPowerSourceDescription checkGetPowerSourceDescription
#define IOBluetoothDevice CheckBluetoothDevice
#define ACOUPLET_BATTERY_CLEANUP_CHECK
#include "SonyNativeBatteryBridge.m"

static NSMutableArray *checkRecords;
static NSMutableArray *checkRemoved;
static BOOL checkUnavailable;
static BOOL checkRetainAfterRemoval;
static BOOL checkStall;
static int checkFailures;
static int checkNextSource;
static NSString *checkReleasePath;

static CFTypeRef checkCopyPowerSourcesByType(int type) {
    assert(type == 4);
    return checkUnavailable ? NULL : CFBridgingRetain(checkRecords.copy);
}

static CFArrayRef checkCopyPowerSourcesList(CFTypeRef info) { return CFRetain(info); }
static CFDictionaryRef checkGetPowerSourceDescription(CFTypeRef info, CFTypeRef source) { return source; }

static kern_return_t checkRemoveSource(mach_port_t connection, int source) {
    assert(connection == 0);
    [checkRemoved addObject:@(source)];
    if (checkStall) while (YES) pause();
    if (checkFailures) { checkFailures--; return kIOReturnError; }
    if (!checkRetainAfterRemoval) {
        NSIndexSet *matching = [checkRecords indexesOfObjectsPassingTest:^BOOL(NSDictionary *record, NSUInteger index, BOOL *stop) {
            return [record[@"Power Source ID"] isEqual:@(source)];
        }];
        [checkRecords removeObjectsAtIndexes:matching];
        if (checkReleasePath) assert([NSData.data writeToFile:checkReleasePath atomically:YES]);
    }
    return KERN_SUCCESS;
}

static kern_return_t checkCreateSource(mach_port_t connection, int *source, int *result) {
    assert(connection == 0);
    *source = ++checkNextSource;
    *result = kIOReturnSuccess;
    return KERN_SUCCESS;
}

static kern_return_t checkUpdateSource(mach_port_t connection, int source, vm_offset_t data, mach_msg_type_number_t length, int *result) {
    assert(connection == 0 && length > 0);
    NSMutableDictionary *record = [CFBridgingRelease(IOCFUnserialize((const char *)data, NULL, 0, NULL)) mutableCopy];
    record[@"Power Source ID"] = @(source);
    NSUInteger index = [checkRecords indexOfObjectPassingTest:^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
        return [candidate[@"Power Source ID"] isEqual:@(source)];
    }];
    if (index == NSNotFound) [checkRecords addObject:record];
    else checkRecords[index] = record;
    *result = kIOReturnSuccess;
    return KERN_SUCCESS;
}

static void reset(NSArray *records) {
    checkRecords = records.mutableCopy;
    checkRemoved = NSMutableArray.array;
    checkUnavailable = checkRetainAfterRemoval = checkStall = NO;
    checkFailures = 0;
    checkNextSource = 100;
    creationFinished = NO;
    stopped = 0;
    removeSource = checkRemoveSource;
    createSource = checkCreateSource;
    updateSource = checkUpdateSource;
}

static int checkChild(NSDictionary *sample, NSString *session, NSDictionary *native, BOOL stall) {
    NSMutableDictionary *parent = [single(native, [session stringByAppendingString:@"/parent"]) mutableCopy];
    parent[@"Power Source ID"] = @2;
    reset(@[native, parent]);
    checkFailures = 1000;
    checkStall = stall;
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    NSMutableData *commands = [[NSJSONSerialization dataWithJSONObject:@{@"command": @"prepare", @"sample": sample} options:0 error:nil] mutableCopy];
    [commands appendData:[@"\n{\"command\":\"stop\"}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    assert(write(descriptors[1], commands.bytes, commands.length) == commands.length);
    close(descriptors[1]);
    int savedInput = dup(STDIN_FILENO);
    assert(savedInput >= 0 && dup2(descriptors[0], STDIN_FILENO) == STDIN_FILENO);
    close(descriptors[0]);
    int result = child(sample[@"identifier"], session);
    alarm(0);
    assert(dup2(savedInput, STDIN_FILENO) == STDIN_FILENO);
    close(savedInput);
    return result;
}

static int checkPreparingChild(NSString *session) {
    NSString *directory = NSProcessInfo.processInfo.environment[@"ACOUPLET_BATTERY_CHECK_DIRECTORY"];
    NSMutableData *buffer = NSMutableData.data;
    NSDictionary *command = nil;
    double deadline = NSProcessInfo.processInfo.systemUptime + 2;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        if (receive(STDIN_FILENO, buffer, &command) > 0) break;
    }
    if (![command[@"command"] isEqual:@"prepare"]) return 2;
    if (getenv("ACOUPLET_BATTERY_CHECK_EOF")) {
        command = nil;
        while (NSProcessInfo.processInfo.systemUptime < deadline) {
            int received = receive(STDIN_FILENO, buffer, &command);
            if (received < 0 || received > 0) break;
        }
        if (![command[@"command"] isEqual:@"stop"]) return 3;
    }
    event(@"components-absent", @{@"guard": [session stringByAppendingString:@"/a"],
        @"pair": [session stringByAppendingString:@"/b"], @"trailer": [session stringByAppendingString:@"/c"]});
    NSString *released = [directory stringByAppendingPathComponent:@"parent-removed"];
    while (![[NSFileManager defaultManager] fileExistsAtPath:released] && NSProcessInfo.processInfo.systemUptime < deadline) tick();
    if (![[NSFileManager defaultManager] fileExistsAtPath:released]) return 4;
    assert([NSData.data writeToFile:[directory stringByAppendingPathComponent:@"child-finished"] atomically:YES]);
    event(@"child-exit", @{@"result": @0});
    return 0;
}

static void checkSupervisor(NSDictionary *sample, NSDictionary *native, BOOL closesInput) {
    reset(@[native]);
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil]);
    checkReleasePath = [directory stringByAppendingPathComponent:@"parent-removed"];
    assert(setenv("ACOUPLET_BATTERY_CHECK_DIRECTORY", directory.fileSystemRepresentation, 1) == 0);
    if (closesInput) assert(setenv("ACOUPLET_BATTERY_CHECK_EOF", "1", 1) == 0);
    int descriptors[2];
    assert(pipe(descriptors) == 0 && fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0);
    NSMutableData *input = [[NSJSONSerialization dataWithJSONObject:sample options:0 error:nil] mutableCopy];
    [input appendBytes:"\n" length:1];
    assert(write(descriptors[1], input.bytes, input.length) == input.length);
    if (closesInput) close(descriptors[1]);
    int savedInput = dup(STDIN_FILENO);
    assert(savedInput >= 0 && dup2(descriptors[0], STDIN_FILENO) == STDIN_FILENO);
    close(descriptors[0]);
    assert(supervisor(NSProcessInfo.processInfo.arguments.firstObject, sample[@"identifier"], @"cleanup-check") == (closesInput ? 0 : 1));
    alarm(0);
    assert(dup2(savedInput, STDIN_FILENO) == STDIN_FILENO);
    close(savedInput);
    if (!closesInput) close(descriptors[1]);
    assert([[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:@"child-finished"]]);
    assert([checkRemoved isEqual:@[@101]] && [checkRecords isEqual:@[native]]);
    checkReleasePath = nil;
    assert(unsetenv("ACOUPLET_BATTERY_CHECK_DIRECTORY") == 0 && unsetenv("ACOUPLET_BATTERY_CHECK_EOF") == 0);
    assert([[NSFileManager defaultManager] removeItemAtPath:directory error:nil]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if (argc == 4 && !strcmp(argv[1], "--child")) return checkPreparingChild([NSString stringWithUTF8String:argv[3]]);
        NSString *identifier = @"00000000-0000-4000-8000-000000000019";
        NSDictionary *reading = @{@"level": @40, @"isCharging": @NO, @"observedAt": @(NSDate.date.timeIntervalSince1970)};
        NSDictionary *sample = @{@"identifier": identifier, @"address": @"02:00:00:00:00:19", @"controlSession": @1, @"left": reading, @"right": reading};
        NSMutableDictionary *baseline = [publication(sample, @"unused") mutableCopy];
        [baseline removeObjectForKey:ownerKey];
        [baseline removeObjectForKey:@"Combined Parts"];
        baseline[@"Part Identifier"] = @"Single";
        baseline[@"Power Source ID"] = @1;
        if (argc == 2 && !strcmp(argv[1], "--stall")) return checkChild(sample, @"cleanup-check", baseline, YES);
        NSDictionary *native = @{@"Power Source ID": @1, @"Accessory Identifier": identifier};
        NSDictionary *owned = @{@"Power Source ID": @101, @"Accessory Identifier": identifier, ownerKey: @"owned"};
        EnvelopeSource source = {101, YES};
        reset(@[native, owned]);
        checkFailures = 1;
        assert(releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 1));
        assert((!source.allocated && [checkRemoved isEqual:@[@101, @101]] && [checkRecords isEqual:@[native]]));

        reset(@[native, owned]);
        source.allocated = YES;
        checkRetainAfterRemoval = YES;
        assert(!releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(!source.allocated && [checkRemoved isEqual:@[@101]]);

        reset(@[native, owned]);
        source.allocated = YES;
        checkFailures = 1000;
        assert(!releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert((source.allocated && [checkRemoved isEqual:@[@101]] && [checkRecords isEqual:@[native, owned]]));

        reset(@[native, owned]);
        source.allocated = YES;
        checkUnavailable = YES;
        assert(!releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(!source.allocated && [checkRemoved isEqual:@[@101]]);

        reset(@[native, owned]);
        EnvelopeSource none = {0};
        assert(!releaseOwned(&none, nil, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert((checkRemoved.count == 0 && [checkRecords isEqual:@[native, owned]]));
        reset(@[native]);
        assert(releaseOwned(&none, nil, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(checkRemoved.count == 0);
        source.allocated = YES;
        assert(releaseOwned(&source, identifier, @[@"owned"], NSProcessInfo.processInfo.systemUptime + 0.01));
        assert(!source.allocated && [checkRemoved isEqual:@[@101]] && [checkRecords isEqual:@[native]]);

        checkSupervisor(sample, baseline, NO);
        checkSupervisor(sample, baseline, YES);

        FILE *output = tmpfile();
        assert(output);
        fflush(stdout);
        int savedOutput = dup(STDOUT_FILENO);
        assert(savedOutput >= 0 && dup2(fileno(output), STDOUT_FILENO) == STDOUT_FILENO);
        double began = NSProcessInfo.processInfo.systemUptime;
        assert(checkChild(sample, @"cleanup-check", baseline, NO) == 1);
        assert(NSProcessInfo.processInfo.systemUptime - began < 6);
        assert(checkRemoved.count > 1 && [[NSSet setWithArray:checkRemoved] isEqual:[NSSet setWithObject:@102]]);
        assert(checkRecords.count == 5);
        fflush(stdout);
        assert(dup2(savedOutput, STDOUT_FILENO) == STDOUT_FILENO);
        close(savedOutput);
        rewind(output);
        char bytes[16384];
        size_t count = fread(bytes, 1, sizeof(bytes), output);
        fclose(output);
        NSString *events = [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
        assert([events containsString:@"source-disposal-unconfirmed"] && [events containsString:@"child-exit"]);
        assert(![events containsString:@"components-absent"] && ![events containsString:@"final-inventory"]);
        NSTask *task = NSTask.new;
        task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments.firstObject];
        task.arguments = @[@"--stall"];
        task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        assert([task launchAndReturnError:nil]);
        double deadline = NSProcessInfo.processInfo.systemUptime + 15;
        while (task.running && NSProcessInfo.processInfo.systemUptime < deadline) tick();
        BOOL overran = task.running;
        if (overran) kill(task.processIdentifier, SIGKILL);
        [task waitUntilExit];
        assert(!overran && task.terminationReason == NSTaskTerminationReasonUncaughtSignal && task.terminationStatus == SIGALRM);
        puts("PASS bounded native battery release retries, retained ownership, asynchronous absence, unavailable inventory, monitor-only cleanup, early setup withdrawal, app EOF, ordered child failure and stalled-call termination; no native source calls");
    }
    return 0;
}
