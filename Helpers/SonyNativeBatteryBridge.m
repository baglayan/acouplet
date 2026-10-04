#define main originalNativeBatteryHelperMain
#include "SonyNativeBatteryHelper.m"
#undef main
#import <IOKit/IOCFSerialize.h>
#import <dlfcn.h>
#import <IOBluetooth/IOBluetooth.h>

typedef struct { int identifier; BOOL allocated; } EnvelopeSource;
static mach_port_t server;
static BOOL creationFinished;
static const int nativeDisconnectedExit = 76;
static const int nativeUnavailableExit = 77;
static IOReturn (*connectServer)(mach_port_t *);
static IOReturn (*disconnectServer)(mach_port_t);
static kern_return_t (*createSource)(mach_port_t, int *, int *);
static kern_return_t (*updateSource)(mach_port_t, int, vm_offset_t, mach_msg_type_number_t, int *);
static kern_return_t (*removeSource)(mach_port_t, int);

static BOOL openServer(void) {
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!library) return NO;
    connectServer = dlsym(library, "_pm_connect");
    disconnectServer = dlsym(library, "_pm_disconnect");
    createSource = dlsym(library, "io_ps_new_pspowersource");
    updateSource = dlsym(library, "io_ps_update_pspowersource");
    removeSource = dlsym(library, "io_ps_release_pspowersource");
    return connectServer && disconnectServer && createSource && updateSource && removeSource
        && connectServer(&server) == kIOReturnSuccess;
}

static IOReturn allocateSource(EnvelopeSource *source) {
    if (creationFinished) return kIOReturnNotPermitted;
    int result = kIOReturnError;
    kern_return_t status = createSource(server, &source->identifier, &result);
    source->allocated = status == KERN_SUCCESS && result == kIOReturnSuccess;
    return status == KERN_SUCCESS ? result : status;
}

static IOReturn setSource(EnvelopeSource source, NSDictionary *details) {
    CFDataRef data = IOCFSerialize((__bridge CFDictionaryRef)details, 0);
    if (!data) return kIOReturnBadArgument;
    int result = kIOReturnError;
    kern_return_t status = updateSource(server, source.identifier, (vm_offset_t)CFDataGetBytePtr(data),
        (mach_msg_type_number_t)CFDataGetLength(data), &result);
    CFRelease(data);
    return status == KERN_SUCCESS ? result : status;
}

static void event(NSString *name, NSDictionary *fields) {
    NSMutableDictionary *value = fields.mutableCopy ?: NSMutableDictionary.dictionary;
    value[@"event"] = name;
    value[@"pid"] = @(getpid());
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static BOOL message(NSFileHandle *output, NSDictionary *value) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    NSError *error = nil;
    return [output writeData:data error:&error];
}

static int receive(int descriptor, NSMutableData *buffer, NSDictionary **value) {
    const void *newline = memchr(buffer.bytes, '\n', buffer.length);
    if (!newline) {
        struct pollfd descriptorState = {descriptor, POLLIN, 0};
        int ready = poll(&descriptorState, 1, 100);
        if (ready < 0) return errno == EINTR ? 0 : -2;
        if (!ready) return 0;
        char bytes[4096];
        ssize_t count = read(descriptor, bytes, sizeof(bytes));
        if (count <= 0) return count == 0 && buffer.length == 0 ? -1 : -2;
        [buffer appendBytes:bytes length:(NSUInteger)count];
        if (buffer.length > 16384) return -2;
        newline = memchr(buffer.bytes, '\n', buffer.length);
        if (!newline) return 0;
    }
    NSUInteger length = (const char *)newline - (const char *)buffer.bytes;
    NSData *line = [buffer subdataWithRange:NSMakeRange(0, length)];
    [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
    id decoded = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return -2;
    *value = decoded;
    return 1;
}

static void tick(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

static BOOL inventoryDue(double *nextCheck, double now, BOOL inputReady) {
    if (!inputReady && now < *nextCheck) return NO;
    *nextCheck = now + 0.5;
    return YES;
}

static BOOL sameReadings(NSDictionary *first, NSDictionary *second) {
    return [first[@"left"][@"level"] isEqual:second[@"left"][@"level"]]
        && [first[@"right"][@"level"] isEqual:second[@"right"][@"level"]]
        && [first[@"left"][@"isCharging"] isEqual:second[@"left"][@"isCharging"]]
        && [first[@"right"][@"isCharging"] isEqual:second[@"right"][@"isCharging"]];
}

static NSDictionary *single(NSDictionary *baseline, NSString *marker) {
    NSMutableDictionary *value = baseline.mutableCopy;
    [value removeObjectForKey:@"Power Source ID"];
    value[ownerKey] = marker;
    return value;
}

static NSDictionary *envelope(NSDictionary *sample, NSString *marker) {
    NSMutableDictionary *value = [publication(sample, marker) mutableCopy];
    value[@"Combined Parts"] = @[];
    return value;
}

static NSInteger indexOfMarker(NSArray *records, NSString *marker) {
    NSInteger found = NSNotFound;
    for (NSUInteger index = 0; index < records.count; index++) {
        if (![records[index][ownerKey] isEqual:marker]) continue;
        if (found != NSNotFound) return NSNotFound;
        found = (NSInteger)index;
    }
    return found;
}

static BOOL guarded(NSArray *records, NSString *identifier, NSString *parent, NSString *child, NSString *pairMarker, NSString *trailer, BOOL nativeRequired) {
    if (!records || records.count != (nativeRequired ? 5 : 4)) return NO;
    NSInteger parentIndex = indexOfMarker(records, parent), childIndex = indexOfMarker(records, child);
    NSInteger pairIndex = indexOfMarker(records, pairMarker), trailerIndex = indexOfMarker(records, trailer);
    if (parentIndex == NSNotFound || childIndex == NSNotFound || pairIndex == NSNotFound || trailerIndex == NSNotFound
        || parentIndex >= pairIndex || childIndex >= pairIndex || trailerIndex <= pairIndex) return NO;
    NSDictionary *tail = records[trailerIndex];
    if (![tail[@"Part Identifier"] isEqual:@"Single"] || [tail[@"Combined Parts"] count]
        || !level(tail[@"Current Capacity"])) return NO;
    NSMutableSet *ownedIDs = NSMutableSet.set;
    for (NSDictionary *record in records) {
        if (!record[ownerKey]) continue;
        id sourceID = record[@"Power Source ID"];
        if (!number(sourceID) || [sourceID longLongValue] == 0 || [ownedIDs containsObject:sourceID]) return NO;
        [ownedIDs addObject:sourceID];
    }
    NSUInteger natives = 0;
    for (NSUInteger index = 0; index < records.count; index++) {
        NSDictionary *record = records[index];
        if (record[ownerKey]) continue;
        if (!nativeSingle(record, identifier) || index >= (NSUInteger)pairIndex) return NO;
        id sourceID = record[@"Power Source ID"];
        if ([ownedIDs containsObject:sourceID] && ![sourceID isEqual:tail[@"Power Source ID"]]) return NO;
        natives++;
    }
    return natives == (nativeRequired ? 1 : 0);
}

static BOOL primed(NSArray *records, NSString *identifier, NSString *parent, NSString *child, NSString *pairMarker, NSString *trailer) {
    if (!guarded(records, identifier, parent, child, pairMarker, trailer, YES)) return NO;
    NSMutableSet *identifiers = NSMutableSet.set;
    for (NSDictionary *record in records) {
        if ([identifiers containsObject:record[@"Power Source ID"]]) return NO;
        [identifiers addObject:record[@"Power Source ID"]];
        if (!record[ownerKey]) continue;
        if (![record[@"Part Identifier"] isEqual:@"Single"] || [record[@"Combined Parts"] count]
            || !level(record[@"Current Capacity"])) return NO;
    }
    return YES;
}

static BOOL expired(NSDictionary *sample, double deadline) {
    double now = NSDate.date.timeIntervalSince1970;
    return stopped || NSProcessInfo.processInfo.systemUptime >= deadline
        || now >= MIN([sample[@"left"][@"observedAt"] doubleValue], [sample[@"right"][@"observedAt"] doubleValue]) + 45;
}

static int resultBeforeCleanup(int result, NSDictionary *sample, double deadline) {
    return expired(sample, deadline) ? 1 : result;
}

static double sampleDeadline(NSDictionary *sample) {
    double observed = MIN([sample[@"left"][@"observedAt"] doubleValue], [sample[@"right"][@"observedAt"] doubleValue]);
    return NSProcessInfo.processInfo.systemUptime + observed + 45 - NSDate.date.timeIntervalSince1970;
}

static BOOL markersAbsent(NSArray *records, NSArray<NSString *> *markers) {
    if (!records) return NO;
    for (NSDictionary *record in records) if ([markers containsObject:record[ownerKey]]) return NO;
    return YES;
}

static BOOL componentsAbsentReport(NSDictionary *report, NSString *session) {
    if (![report[@"event"] isEqual:@"components-absent"]) return NO;
    NSSet *expected = [NSSet setWithArray:@[[session stringByAppendingString:@"/a"],
        [session stringByAppendingString:@"/b"], [session stringByAppendingString:@"/c"]]];
    return [expected isEqual:[NSSet setWithArray:@[report[@"guard"] ?: NSNull.null,
        report[@"pair"] ?: NSNull.null, report[@"trailer"] ?: NSNull.null]]];
}

static NSArray *allInventory(void) {
    CFTypeRef info = IOPSCopyPowerSourcesByType(4);
    if (!info) return nil;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    if (!list) { CFRelease(info); return nil; }
    NSMutableArray *records = NSMutableArray.array;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        NSDictionary *record = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        if (!record) { CFRelease(list); CFRelease(info); return nil; }
        [records addObject:record.copy];
    }
    CFRelease(list);
    CFRelease(info);
    return records;
}

static NSDictionary *unassociatedSingle(NSDictionary *baseline, NSString *marker) {
    NSMutableDictionary *details = [single(baseline, marker) mutableCopy];
    [details removeObjectForKey:@"Accessory Identifier"];
    [details removeObjectForKey:@"Group Identifier"];
    return details;
}

static BOOL releaseOwned(EnvelopeSource *source, NSString *identifier, NSArray<NSString *> *markers, double deadline) {
    IOReturn result = 0;
    double nextRelease = 0;
    deadline = MIN(deadline, NSProcessInfo.processInfo.systemUptime + 5);
    while (YES) {
        @autoreleasepool {
            double now = NSProcessInfo.processInfo.systemUptime;
            if (source->allocated && now >= nextRelease) {
                result = removeSource(server, source->identifier);
                if (result == 0) source->allocated = NO;
                nextRelease = now + 0.5;
            }
            NSArray *records = identifier ? inventory(identifier) : allInventory();
            if (!source->allocated && markersAbsent(records, markers)) {
                event(@"owned-sources-absent", @{@"markers": markers, @"releaseStatus": @(result)});
                return YES;
            }
            if (NSProcessInfo.processInfo.systemUptime >= deadline) {
                event(@"source-disposal-unconfirmed", @{@"markers": markers, @"releaseStatus": @(result), @"waitingForAbsence": @YES});
                return NO;
            }
            tick();
        }
    }
}

static NSNumber *classicConnected(NSString *address) {
    IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
    return device && device.isPaired ? @(device.isConnected) : nil;
}

static NSArray *completeInventory(NSString *identifier) {
    NSArray *records = allInventory();
    if (!records) return nil;
    NSMutableArray *matching = NSMutableArray.array;
    for (NSDictionary *record in records)
        if ([record[@"Accessory Identifier"] isEqual:identifier] || [record[@"Group Identifier"] isEqual:identifier]) [matching addObject:record];
    return matching;
}

static int nativeLossResult(NSArray *records, NSString *identifier, NSString *parent, NSString *child, NSString *pairMarker, NSString *trailer, NSNumber *connected) {
    if (!records || records.count != 4) return 1;
    for (NSDictionary *record in records) {
        if (![record isKindOfClass:NSDictionary.class]) return 1;
        id parts = record[@"Combined Parts"];
        if (parts && ![parts isKindOfClass:NSArray.class]) return 1;
        NSMutableDictionary *baseline = record.mutableCopy;
        [baseline removeObjectForKey:ownerKey];
        [baseline removeObjectForKey:@"Combined Parts"];
        baseline[@"Part Identifier"] = @"Single";
        if (!nativeSingle(baseline, identifier)) return 1;
        if ([record[ownerKey] isEqual:trailer]) {
            if (![record[@"Part Identifier"] isEqual:@"Single"] || [parts count]) return 1;
        } else {
            if (![record[@"Part Identifier"] isEqual:@"Combined"]) return 1;
            if ([record[ownerKey] isEqual:pairMarker]) {
                if ([parts count] != 2) return 1;
                for (NSUInteger index = 0; index < 2; index++) {
                    id component = parts[index];
                    if (![component isKindOfClass:NSDictionary.class]
                        || ![component[@"Part Identifier"] isEqual:index == 0 ? @"Left" : @"Right"]
                        || !level(component[@"Current Capacity"]) || component[ownerKey]
                        || ![component[@"Accessory Identifier"] isEqual:identifier]
                        || ![component[@"Group Identifier"] isEqual:identifier]
                        || component[@"Power Source ID"] || component[@"Combined Parts"]) return 1;
                }
            } else if ([parts count]) return 1;
        }
    }
    if (!guarded(records, identifier, parent, child, pairMarker, trailer, NO)) return 1;
    return connected && !connected.boolValue ? nativeDisconnectedExit : nativeUnavailableExit;
}

static int finalInventoryResult(NSArray *records, NSString *identifier, NSNumber *connected) {
    if (records.count == 1 && nativeSingle(records.firstObject, identifier))
        return connected && !connected.boolValue ? nativeDisconnectedExit : 0;
    return records && records.count == 0 && connected && !connected.boolValue ? nativeDisconnectedExit : 1;
}

static int withdrawalResult(int previous, int next) {
    if (previous == 1 || next == 1) return 1;
    if (previous == nativeDisconnectedExit || next == nativeDisconnectedExit) return nativeDisconnectedExit;
    return MAX(previous, next);
}

static int finalWithdrawalResult(int previous, int final) {
    int result = withdrawalResult(previous, final);
    return stopped || result == nativeUnavailableExit ? 1 : result;
}

static int finishInventory(NSString *identifier, NSString *session, NSString *address, BOOL requireDisconnect) {
    double deadline = NSProcessInfo.processInfo.systemUptime + 5;
    int result = 1;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        @autoreleasepool {
            NSArray *records = completeInventory(identifier);
            result = finalInventoryResult(records, identifier, address ? classicConnected(address) : nil);
            if (result != 1 && (!requireDisconnect || result == nativeDisconnectedExit)) break;
            tick();
        }
    }
    if (requireDisconnect && result != nativeDisconnectedExit) result = 1;
    for (NSUInteger pass = 0; pass < 2; pass++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        NSArray *records = completeInventory(identifier);
        int next = finalInventoryResult(records, identifier, address ? classicConnected(address) : nil);
        result = withdrawalResult(result, next);
        event(@"final-inventory", @{@"session": session, @"pass": @(pass + 1), @"result": @(result), @"nativeSingle": @(result == 0),
            @"nativeDisconnected": @(result == nativeDisconnectedExit), @"records": records ?: @[]});
    }
    event(@"consumer-proof-pending", @{@"reason": @"IOPS inventory does not acknowledge actual menu/cache imports"});
    return result;
}

static int pulse(NSString *identifier, NSString *session) {
    NSMutableData *input = NSMutableData.data;
    NSDictionary *command = nil;
    EnvelopeSource source = {0};
    NSString *marker = [NSString stringWithFormat:@"%@/pulse/%d", session, getpid()];
    double deadline = NSProcessInfo.processInfo.systemUptime + 3;
    int result = 1;
    while (!stopped && NSProcessInfo.processInfo.systemUptime < deadline) {
        @autoreleasepool {
            int received = receive(STDIN_FILENO, input, &command);
            if (received < 0) goto cleanup;
            if (received > 0) break;
        }
    }
    {
        NSDictionary *sample = command[@"sample"];
        if (!valid(sample, identifier, nil, NSDate.date.timeIntervalSince1970)) goto cleanup;
        double lease = MIN(deadline, sampleDeadline(sample));
        NSArray *records = inventory(identifier);
        if (!guarded(records, identifier, [session stringByAppendingString:@"/parent"], command[@"guard"], command[@"pair"], command[@"trailer"], YES)) goto cleanup;
        NSDictionary *baseline = nil;
        for (NSDictionary *record in records) if (nativeSingle(record, identifier)) baseline = record;
        if (!baseline || expired(sample, lease) || allocateSource(&source)) goto cleanup;
        creationFinished = YES;
        if (expired(sample, lease) || setSource(source, unassociatedSingle(baseline, marker))) goto cleanup;
        event(@"pulse-submitted", @{@"marker": marker, @"sample": sample, @"associationOmitted": @YES});
        result = expired(sample, lease) ? 1 : 0;
    }
cleanup:
    if (!releaseOwned(&source, nil, @[marker], deadline + 1)) result = 1;
    event(@"pulse-exit", @{@"result": @(result)});
    return result;
}

static BOOL trigger(NSString *executable, NSString *identifier, NSString *session, NSString *guard, NSString *pairMarker, NSString *trailer, NSDictionary *sample, double deadline) {
    if (expired(sample, deadline)) return NO;
    NSTask *task = NSTask.new;
    NSPipe *input = NSPipe.pipe, *output = NSPipe.pipe;
    NSMutableData *buffer = NSMutableData.data;
    NSDictionary *report = nil;
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"--pulse", identifier, session];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithStandardError;
    if (fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC) < 0) return NO;
    if (![task launchAndReturnError:nil]) return NO;
    [input.fileHandleForReading closeFile];
    [output.fileHandleForWriting closeFile];
    BOOL sent = message(input.fileHandleForWriting, @{@"sample": sample, @"guard": guard, @"pair": pairMarker, @"trailer": trailer});
    [input.fileHandleForWriting closeFile];
    event(@"pulse-started", @{@"pulsePID": @(task.processIdentifier)});
    double stopAt = MIN(deadline, NSProcessInfo.processInfo.systemUptime + 4);
    while (task.running && !expired(sample, stopAt)) {
        @autoreleasepool {
            if (receive(output.fileHandleForReading.fileDescriptor, buffer, &report) > 0)
                event(@"pulse-report", @{@"report": report});
            tick();
        }
    }
    BOOL forced = task.running;
    if (task.running) kill(task.processIdentifier, SIGKILL);
    [task waitUntilExit];
    while (receive(output.fileHandleForReading.fileDescriptor, buffer, &report) > 0)
        event(@"pulse-report", @{@"report": report});
    EnvelopeSource none = {0};
    NSString *marker = [NSString stringWithFormat:@"%@/pulse/%d", session, task.processIdentifier];
    alarm(6);
    BOOL absent = releaseOwned(&none, nil, @[marker], NSProcessInfo.processInfo.systemUptime + 5);
    alarm(0);
    event(@"pulse-terminated", @{@"pulsePID": @(task.processIdentifier), @"reason": @(task.terminationReason), @"status": @(task.terminationStatus), @"forced": @(forced)});
    return sent && absent && !forced && !expired(sample, deadline)
        && task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
}

static int child(NSString *identifier, NSString *session) {
    NSString *parentMarker = [session stringByAppendingString:@"/parent"];
    NSArray *markers = @[[session stringByAppendingString:@"/a"], [session stringByAppendingString:@"/b"], [session stringByAppendingString:@"/c"]];
    EnvelopeSource sources[3] = {{0}};
    pid_t supervisorPID = getppid();
    NSUInteger guardIndex = 0, pairIndex = 1, trailerIndex = 2;
    NSMutableData *buffer = NSMutableData.data;
    NSDictionary *command = nil, *sample = nil, *trailerDetails = nil;
    double deadline = INFINITY;
    double lease = 0;
    int result = 1;
    double inputDeadline = NSProcessInfo.processInfo.systemUptime + 20;
    while (!stopped && NSProcessInfo.processInfo.systemUptime < inputDeadline) {
        @autoreleasepool {
            int received = receive(STDIN_FILENO, buffer, &command);
            if (received < 0) goto cleanup;
            if (!received) continue;
            sample = command[@"sample"];
            if (![command[@"command"] isEqual:@"prepare"] || !valid(sample, identifier, nil, NSDate.date.timeIntervalSince1970)) goto cleanup;
            lease = sampleDeadline(sample);
            break;
        }
    }
    if (!sample) goto cleanup;
    {
        NSArray *records = inventory(identifier);
        NSDictionary *baseline = nil;
        for (NSDictionary *record in records) if (nativeSingle(record, identifier)) baseline = record;
        if (records.count != 2 || !baseline || indexOfMarker(records, parentMarker) == NSNotFound) goto cleanup;
        for (NSUInteger index = 0; index < 3; index++) {
            if (allocateSource(&sources[index]) || setSource(sources[index], single(baseline, markers[index]))) goto cleanup;
        }
        creationFinished = YES;
        if (sources[0].identifier == sources[1].identifier || sources[0].identifier == sources[2].identifier
            || sources[1].identifier == sources[2].identifier) goto cleanup;
        records = inventory(identifier);
        NSArray<NSNumber *> *ordered = [@[@0, @1, @2] sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            NSInteger x = indexOfMarker(records, markers[a.unsignedIntegerValue]);
            NSInteger y = indexOfMarker(records, markers[b.unsignedIntegerValue]);
            return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
        }];
        guardIndex = ordered[0].unsignedIntegerValue;
        pairIndex = ordered[1].unsignedIntegerValue;
        trailerIndex = ordered[2].unsignedIntegerValue;
        if (!primed(records, identifier, parentMarker, markers[guardIndex], markers[pairIndex], markers[trailerIndex])) {
            event(@"unsafe-preflight-order", @{@"records": records ?: @[]});
            goto cleanup;
        }
        event(@"preflight-passed", @{@"records": records, @"childSourceIDs": @[@(sources[0].identifier), @(sources[1].identifier), @(sources[2].identifier)],
            @"guard": markers[guardIndex], @"pair": markers[pairIndex], @"trailer": markers[trailerIndex]});
        if (expired(sample, MIN(deadline, lease))
            || setSource(sources[guardIndex], envelope(sample, markers[guardIndex]))) goto cleanup;
        event(@"prepared", @{@"guard": markers[guardIndex], @"pair": markers[pairIndex], @"trailer": markers[trailerIndex]});
    }
    {
        BOOL active = NO;
        BOOL nativeUnavailable = NO;
        double nextInventory = 0;
        while (!expired(sample, MIN(deadline, lease))) {
            @autoreleasepool {
                int received = receive(STDIN_FILENO, buffer, &command);
                if (received < 0) { result = received == -1 ? (nativeUnavailable ? result : 0) : 1; break; }
                if (!nativeUnavailable && inventoryDue(&nextInventory, NSProcessInfo.processInfo.systemUptime, received > 0)
                    && !guarded(inventory(identifier), identifier, parentMarker, markers[guardIndex], markers[pairIndex], markers[trailerIndex], YES)) {
                    result = nativeLossResult(completeInventory(identifier), identifier, parentMarker, markers[guardIndex], markers[pairIndex], markers[trailerIndex], classicConnected(sample[@"address"]));
                    event(result == 1 ? @"guard-lost" : result == nativeDisconnectedExit ? @"native-disconnected" : @"native-unavailable", @{@"phase": @"child"});
                    if (result == 1) break;
                    nativeUnavailable = YES;
                }
                if (!received) continue;
                NSString *kind = command[@"command"];
                if ([kind isEqual:@"stop"]) { result = nativeUnavailable ? result : 0; break; }
                NSDictionary *next = command[@"sample"];
                BOOL activating = !active && [kind isEqual:@"activate"];
                if (!(activating || (active && [kind isEqual:@"sample"]))
                    || !valid(next, identifier, activating ? nil : sample, NSDate.date.timeIntervalSince1970)
                    || (activating && ![next isEqual:sample])) { result = 1; break; }
                if (nativeUnavailable) continue;
                double nextLease = activating ? lease : sampleDeadline(next);
                NSArray *records = inventory(identifier);
                NSInteger parentIndex = indexOfMarker(records, parentMarker);
                if (parentIndex == NSNotFound || ![records[parentIndex][@"Part Identifier"] isEqual:@"Combined"]
                    || [records[parentIndex][@"Combined Parts"] count]) { result = 1; break; }
                NSDictionary *native = nil;
                for (NSDictionary *record in records) if (nativeSingle(record, identifier)) native = record;
                if (!native) {
                    result = nativeLossResult(completeInventory(identifier), identifier, parentMarker, markers[guardIndex], markers[pairIndex], markers[trailerIndex], classicConnected(sample[@"address"]));
                    event(result == 1 ? @"guard-lost" : result == nativeDisconnectedExit ? @"native-disconnected" : @"native-unavailable", @{@"phase": @"child"});
                    if (result == 1) break;
                    nativeUnavailable = YES;
                    continue;
                }
                NSDictionary *nextTrailer = single(native, markers[trailerIndex]);
                BOOL sourcesUnchanged = active && sameReadings(sample, next) && [nextTrailer isEqual:trailerDetails];
                if (expired(sample, lease) || expired(next, nextLease)
                    || !guarded(records, identifier, parentMarker, markers[guardIndex], markers[pairIndex], markers[trailerIndex], YES)
                    || (!sourcesUnchanged && setSource(sources[trailerIndex], nextTrailer))) { result = 1; break; }
                if (!sourcesUnchanged && !guarded(inventory(identifier), identifier, parentMarker, markers[guardIndex], markers[pairIndex], markers[trailerIndex], YES)) { result = 1; break; }
                if (expired(sample, MIN(deadline, lease)) || expired(next, MIN(deadline, nextLease))
                    || (!sourcesUnchanged && setSource(sources[guardIndex], envelope(next, markers[guardIndex])))) { result = 1; break; }
                if (!sourcesUnchanged && !guarded(inventory(identifier), identifier, parentMarker, markers[guardIndex], markers[pairIndex], markers[trailerIndex], YES)) { result = 1; break; }
                if (expired(sample, MIN(deadline, lease)) || expired(next, MIN(deadline, nextLease))
                    || (!sourcesUnchanged && setSource(sources[pairIndex], publication(next, markers[pairIndex])))
                    || expired(next, MIN(deadline, nextLease))) { result = 1; break; }
                trailerDetails = nextTrailer;
                sample = next;
                lease = nextLease;
                active = YES;
                result = 0;
                event(@"pair-submitted", @{@"guard": markers[guardIndex], @"pair": markers[pairIndex], @"sample": sample, @"sourcesUnchanged": @(sourcesUnchanged)});
            }
        }
        result = resultBeforeCleanup(result, sample, MIN(deadline, lease));
    }
cleanup:
    alarm(12);
    double cleanupDeadline = NSProcessInfo.processInfo.systemUptime + 10;
    if (!releaseOwned(&sources[pairIndex], identifier, @[markers[pairIndex]], cleanupDeadline)) { result = 1; goto finished; }
    if (!releaseOwned(&sources[guardIndex], identifier, @[markers[guardIndex]], cleanupDeadline)) { result = 1; goto finished; }
    event(@"components-absent", @{@"guard": markers[guardIndex], @"pair": markers[pairIndex], @"trailer": markers[trailerIndex]});
    {
        EnvelopeSource none = {0};
        if (!releaseOwned(&none, identifier, @[parentMarker], cleanupDeadline)) { result = 1; goto finished; }
    }
    if (!releaseOwned(&sources[trailerIndex], identifier, @[markers[trailerIndex]], cleanupDeadline)) { result = 1; goto finished; }
    if (getppid() == supervisorPID && supervisorPID != 1) {
        event(@"final-inventory-delegated", @{@"supervisorPID": @(supervisorPID)});
    } else {
        EnvelopeSource none = {0};
        if (!releaseOwned(&none, identifier, @[parentMarker], cleanupDeadline)) { result = 1; goto finished; }
        int final = finishInventory(identifier, session, sample[@"address"], result == nativeUnavailableExit);
        result = finalWithdrawalResult(result, final);
    }
finished:
    if (stopped) result = 1;
    event(@"child-exit", @{@"result": @(result)});
    return result;
}

static int supervisor(NSString *executable, NSString *identifier, NSString *session) {
    NSString *marker = [session stringByAppendingString:@"/parent"];
    NSMutableData *input = NSMutableData.data, *childInput = NSMutableData.data;
    NSDictionary *sample = nil, *incoming = nil;
    NSString *childGuard = nil, *childPair = nil, *childTrailer = nil;
    EnvelopeSource source = {0};
    NSTask *task = NSTask.new;
    NSPipe *toChild = NSPipe.pipe, *fromChild = NSPipe.pipe;
    double deadline = INFINITY;
    double lease = 0;
    int result = 1;
    double inputDeadline = NSProcessInfo.processInfo.systemUptime + 20;
    while (!stopped && NSProcessInfo.processInfo.systemUptime < inputDeadline) {
        @autoreleasepool {
            int received = receive(STDIN_FILENO, input, &incoming);
            if (received < 0) goto cleanup;
            if (!received) continue;
            if (!valid(incoming, identifier, nil, NSDate.date.timeIntervalSince1970)) goto cleanup;
            sample = incoming;
            lease = sampleDeadline(sample);
            break;
        }
    }
    if (!sample) goto cleanup;
    {
        NSArray *records = inventory(identifier);
        if (records.count != 1 || !nativeSingle(records.firstObject, identifier)) {
            event(@"prerequisite-unavailable", @{@"reason": @"No independent native Single baseline"});
            return 75;
        }
        if (allocateSource(&source) || setSource(source, single(records.firstObject, marker))) goto cleanup;
        creationFinished = YES;
        task.executableURL = [NSURL fileURLWithPath:executable];
        task.arguments = @[@"--child", identifier, session];
        task.standardInput = toChild;
        task.standardOutput = fromChild;
        task.standardError = NSFileHandle.fileHandleWithStandardError;
        if (fcntl(toChild.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC) < 0) goto cleanup;
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) goto cleanup;
        [toChild.fileHandleForReading closeFile];
        [fromChild.fileHandleForWriting closeFile];
        event(@"child-started", @{@"childPID": @(task.processIdentifier)});
        if (!message(toChild.fileHandleForWriting, @{@"command": @"prepare", @"sample": sample})) goto cleanup;
    }
    {
        BOOL childPrepared = NO;
        while (!expired(sample, MIN(deadline, lease)) && task.running) {
            @autoreleasepool {
                int parentReceived = receive(STDIN_FILENO, input, &incoming);
                if (parentReceived != 0) {
                    if (parentReceived == -1) result = resultBeforeCleanup(0, sample, MIN(deadline, lease));
                    goto cleanup;
                }
                int received = receive(fromChild.fileHandleForReading.fileDescriptor, childInput, &incoming);
                if (received < 0) goto cleanup;
                if (!received) continue;
                event(@"child-report", @{@"report": incoming});
                BOOL componentsAbsent = componentsAbsentReport(incoming, session);
                if (componentsAbsent || [incoming[@"event"] isEqual:@"preflight-passed"] || [incoming[@"event"] isEqual:@"prepared"]) {
                    childGuard = incoming[@"guard"];
                    childPair = incoming[@"pair"];
                    childTrailer = incoming[@"trailer"];
                }
                if (componentsAbsent) goto cleanup;
                if (![incoming[@"event"] isEqual:@"prepared"]) continue;
                childPrepared = YES;
                break;
            }
        }
        if (!childPrepared || !childGuard || !childPair || !childTrailer
            || !guarded(inventory(identifier), identifier, marker, childGuard, childPair, childTrailer, YES)) goto cleanup;
        if (expired(sample, MIN(deadline, lease)) || setSource(source, envelope(sample, marker))) goto cleanup;
        if (expired(sample, MIN(deadline, lease))
            || !message(toChild.fileHandleForWriting, @{@"command": @"activate", @"sample": sample})) goto cleanup;
        result = 0;
        NSDictionary *pending = sample;
        double pendingLease = lease;
        double nextInventory = 0;
        NSUInteger updates = 1;
        while (!expired(sample, MIN(deadline, lease)) && task.running) {
            @autoreleasepool {
                int childReceived = receive(fromChild.fileHandleForReading.fileDescriptor, childInput, &incoming);
                if (childReceived < 0) { if (childReceived != -1) result = 1; break; }
                if (childReceived > 0) {
                    event(@"child-report", @{@"report": incoming});
                    if ([incoming[@"event"] isEqual:@"native-disconnected"]) { result = nativeDisconnectedExit; break; }
                    if ([incoming[@"event"] isEqual:@"native-unavailable"]) { result = nativeUnavailableExit; break; }
                    if ([incoming[@"event"] isEqual:@"pair-submitted"]) {
                        if (!pending || ![incoming[@"sample"] isEqual:pending] || expired(sample, lease)
                            || expired(pending, pendingLease)) { result = 1; break; }
                        BOOL sourcesUnchanged = [incoming[@"sourcesUnchanged"] isEqual:@YES];
                        sample = pending;
                        lease = pendingLease;
                        pending = nil;
                        if (!sourcesUnchanged && !trigger(executable, identifier, session, childGuard, childPair, childTrailer, sample, lease)) { result = 1; break; }
                        if (expired(sample, MIN(deadline, lease))) { result = 1; break; }
                        if (!guarded(inventory(identifier), identifier, marker, childGuard, childPair, childTrailer, YES)) {
                            result = nativeLossResult(completeInventory(identifier), identifier, marker, childGuard, childPair, childTrailer, classicConnected(sample[@"address"]));
                            event(result == 1 ? @"guard-lost" : result == nativeDisconnectedExit ? @"native-disconnected" : @"native-unavailable", @{@"phase": @"supervisor-refresh"});
                            break;
                        }
                        event(@"refresh-completed", @{@"sample": sample, @"update": @(updates), @"sourcesUnchanged": @(sourcesUnchanged)});
                    }
                }
                if (inventoryDue(&nextInventory, NSProcessInfo.processInfo.systemUptime, childReceived > 0)
                    && !guarded(inventory(identifier), identifier, marker, childGuard, childPair, childTrailer, YES)) {
                    result = nativeLossResult(completeInventory(identifier), identifier, marker, childGuard, childPair, childTrailer, classicConnected(sample[@"address"]));
                    event(result == 1 ? @"guard-lost" : result == nativeDisconnectedExit ? @"native-disconnected" : @"native-unavailable", @{@"phase": @"supervisor"});
                    break;
                }
                int received = receive(STDIN_FILENO, input, &incoming);
                if (received < 0) { if (received != -1) result = 1; break; }
                if (!received) continue;
                if (pending || !valid(incoming, identifier, sample, NSDate.date.timeIntervalSince1970)) { result = 1; break; }
                if (!guarded(inventory(identifier), identifier, marker, childGuard, childPair, childTrailer, YES)) {
                    result = nativeLossResult(completeInventory(identifier), identifier, marker, childGuard, childPair, childTrailer, classicConnected(sample[@"address"]));
                    event(result == 1 ? @"guard-lost" : result == nativeDisconnectedExit ? @"native-disconnected" : @"native-unavailable", @{@"phase": @"supervisor-update"});
                    break;
                }
                double nextLease = sampleDeadline(incoming);
                if (expired(sample, lease) || expired(incoming, nextLease)
                    || (!sameReadings(sample, incoming) && setSource(source, envelope(incoming, marker)))
                    || expired(sample, lease) || expired(incoming, nextLease)
                    || !message(toChild.fileHandleForWriting, @{@"command": @"sample", @"sample": incoming})) { result = 1; break; }
                pending = incoming;
                pendingLease = nextLease;
                updates++;
            }
        }
        result = resultBeforeCleanup(result, sample, MIN(deadline, lease));
    }
cleanup:
    alarm(40);
    if (task.running) message(toChild.fileHandleForWriting, @{@"command": @"stop"});
    [toChild.fileHandleForWriting closeFile];
    {
        double exitDeadline = NSProcessInfo.processInfo.systemUptime + 12;
        while (task.running && NSProcessInfo.processInfo.systemUptime < exitDeadline) {
            @autoreleasepool {
                if (source.allocated && childGuard && childPair
                    && markersAbsent(inventory(identifier), @[childGuard, childPair])) {
                    if (!releaseOwned(&source, identifier, @[marker], exitDeadline)) { result = 1; break; }
                }
                int received = receive(fromChild.fileHandleForReading.fileDescriptor, childInput, &incoming);
                if (received > 0) {
                    event(@"child-report", @{@"report": incoming});
                    if (componentsAbsentReport(incoming, session)) {
                        childGuard = incoming[@"guard"];
                        childPair = incoming[@"pair"];
                    }
                }
                if (received == -2) result = 1;
                tick();
            }
        }
        if (task.running) { [task terminate]; result = 1; }
        exitDeadline = NSProcessInfo.processInfo.systemUptime + 2;
        while (task.running && NSProcessInfo.processInfo.systemUptime < exitDeadline) tick();
        if (task.running) { kill(task.processIdentifier, SIGKILL); result = 1; }
        if (task.processIdentifier) {
            [task waitUntilExit];
            int received;
            while ((received = receive(fromChild.fileHandleForReading.fileDescriptor, childInput, &incoming)) > 0)
                event(@"child-report", @{@"report": incoming});
            if (received == -2) result = 1;
            if (task.terminationReason != NSTaskTerminationReasonExit
                || (task.terminationStatus != 0 && task.terminationStatus != nativeDisconnectedExit && task.terminationStatus != nativeUnavailableExit)) result = 1;
            else result = withdrawalResult(result, task.terminationStatus);
            event(@"child-terminated", @{@"reason": @(task.terminationReason), @"status": @(task.terminationStatus)});
        }
    }
    {
        EnvelopeSource none = {0};
        if (!releaseOwned(&none, identifier, @[[session stringByAppendingString:@"/a"], [session stringByAppendingString:@"/b"], [session stringByAppendingString:@"/c"]], NSProcessInfo.processInfo.systemUptime + 5)) result = 1;
    }
    if (!releaseOwned(&source, identifier, @[marker], NSProcessInfo.processInfo.systemUptime + 5)) result = 1;
    int final = finishInventory(identifier, session, sample[@"address"], result == nativeUnavailableExit);
    result = finalWithdrawalResult(result, final);
    event(@"supervisor-exit", @{@"result": @(result)});
    return result;
}

static int envelopeSelfTest(void) {
    NSString *identifier = @"00000000-0000-4000-8000-000000000019";
    NSDictionary *reading = @{@"level": @40, @"isCharging": @NO, @"observedAt": @100};
    NSDictionary *sample = @{@"identifier": identifier, @"address": @"02:00:00:00:00:19", @"controlSession": @1, @"left": reading, @"right": reading};
    NSMutableDictionary *native = [publication(sample, @"unused") mutableCopy];
    [native removeObjectForKey:ownerKey];
    [native removeObjectForKey:@"Combined Parts"];
    native[@"Part Identifier"] = @"Single";
    native[@"Power Source ID"] = @1;
    assert(nativeSingle(native, identifier));
    NSMutableDictionary *parent = [single(native, @"parent") mutableCopy];
    NSMutableDictionary *guard = [single(native, @"guard") mutableCopy];
    NSMutableDictionary *pairRecord = [single(native, @"pair") mutableCopy];
    NSMutableDictionary *trailer = [single(native, @"trailer") mutableCopy];
    parent[@"Power Source ID"] = @2;
    guard[@"Power Source ID"] = @3;
    pairRecord[@"Power Source ID"] = @4;
    trailer[@"Power Source ID"] = @5;
    double nextInventory = 0;
    NSUInteger scans = 0;
    for (NSUInteger tick = 0; tick < 100; tick++)
        if (inventoryDue(&nextInventory, tick / 10.0, NO)) scans++;
    assert(scans == 20);
    nextInventory = 0;
    scans = 0;
    for (NSUInteger tick = 0; tick < 50; tick++)
        if (inventoryDue(&nextInventory, tick / 5.0, NO)) scans++;
    assert(scans == 17);
    nextInventory = 20;
    assert(!inventoryDue(&nextInventory, 19.8, NO));
    assert(inventoryDue(&nextInventory, 19.8, YES));
    assert(!inventoryDue(&nextInventory, 19.9, NO));
    assert(inventoryDue(&nextInventory, 20.31, NO));
    assert(inventoryDue(&nextInventory, 20.32, YES));
    for (NSUInteger nativePosition = 0; nativePosition < 3; nativePosition++) {
        NSMutableArray *records = [@[parent, guard, pairRecord, trailer] mutableCopy];
        [records insertObject:native atIndex:nativePosition];
        assert(guarded(records, identifier, @"parent", @"guard", @"pair", @"trailer", YES));
        assert(primed(records, identifier, @"parent", @"guard", @"pair", @"trailer"));
    }
    assert(!guarded(@[native, guard, pairRecord, parent, trailer], identifier, @"parent", @"guard", @"pair", @"trailer", YES));
    assert(!guarded(@[native, parent, guard, pairRecord], identifier, @"parent", @"guard", @"pair", @"trailer", YES));
    assert(!guarded(@[parent, guard, pairRecord, native, trailer], identifier, @"parent", @"guard", @"pair", @"trailer", YES));
    assert(!guarded(@[native, parent, guard, trailer, pairRecord], identifier, @"parent", @"guard", @"pair", @"trailer", YES));
    NSMutableDictionary *aliasedNative = native.mutableCopy;
    aliasedNative[@"Power Source ID"] = pairRecord[@"Power Source ID"];
    assert(!guarded(@[aliasedNative, parent, guard, pairRecord, trailer], identifier, @"parent", @"guard", @"pair", @"trailer", YES));
    aliasedNative[@"Power Source ID"] = trailer[@"Power Source ID"];
    assert(guarded(@[aliasedNative, parent, guard, pairRecord, trailer], identifier, @"parent", @"guard", @"pair", @"trailer", YES));
    assert(!primed(@[aliasedNative, parent, guard, pairRecord, trailer], identifier, @"parent", @"guard", @"pair", @"trailer"));
    assert(!markersAbsent(nil, @[@"pair"]));
    assert(!markersAbsent(@[native, pairRecord, pairRecord], @[@"pair"]));
    assert(!markersAbsent(@[parent, pairRecord], @[@"guard", @"pair"]));
    assert(markersAbsent(@[native, parent, guard], @[@"pair"]));
    NSMutableDictionary *absenceReport = [@{@"event": @"components-absent", @"guard": @"session/c",
        @"pair": @"session/a", @"trailer": @"session/b"} mutableCopy];
    assert(componentsAbsentReport(absenceReport, @"session"));
    assert(!componentsAbsentReport(absenceReport, @"other-session"));
    absenceReport[@"trailer"] = @"session/a";
    assert(!componentsAbsentReport(absenceReport, @"session"));
    [absenceReport removeObjectForKey:@"trailer"];
    assert(!componentsAbsentReport(absenceReport, @"session"));
    absenceReport[@"trailer"] = @"session/b";
    absenceReport[@"event"] = @"prepared";
    assert(!componentsAbsentReport(absenceReport, @"session"));
    NSMutableDictionary *activeParent = [envelope(sample, @"parent") mutableCopy];
    NSMutableDictionary *activeGuard = [envelope(sample, @"guard") mutableCopy];
    NSMutableDictionary *activePair = [publication(sample, @"pair") mutableCopy];
    activeParent[@"Power Source ID"] = @2;
    activeGuard[@"Power Source ID"] = @3;
    activePair[@"Power Source ID"] = @4;
    NSArray *disconnectedRecords = @[activeParent, activeGuard, activePair, trailer];
    int (^loss)(NSArray *, NSNumber *) = ^int(NSArray *records, NSNumber *connected) {
        return nativeLossResult(records, identifier, @"parent", @"guard", @"pair", @"trailer", connected);
    };
    assert(loss(disconnectedRecords, @NO) == nativeDisconnectedExit);
    assert(loss(disconnectedRecords, @YES) == nativeUnavailableExit);
    assert(loss(disconnectedRecords, nil) == nativeUnavailableExit);
    assert(loss(@[activeGuard, activeParent, activePair, trailer], @YES) == nativeUnavailableExit);
    assert(loss(@[activeParent, activePair, activeGuard, trailer], @NO) == 1);
    assert(loss(@[activeParent, activeGuard, trailer, activePair], @NO) == 1);
    assert(loss(@[activeParent, activeGuard, activePair], @NO) == 1);
    assert(loss(@[activeParent, activeGuard, activePair, trailer, native], @NO) == 1);
    assert(loss(@[activeParent, activeGuard, activePair, activePair], @NO) == 1);
    assert(loss(nil, @NO) == 1);
    assert(loss(@[], @NO) == 1);
    NSMutableDictionary *malformed = activePair.mutableCopy;
    malformed[ownerKey] = @"foreign";
    assert(loss(@[activeParent, activeGuard, malformed, trailer], @NO) == 1);
    malformed = activePair.mutableCopy;
    malformed[@"Power Source ID"] = @3;
    assert(loss(@[activeParent, activeGuard, malformed, trailer], @NO) == 1);
    malformed = activePair.mutableCopy;
    malformed[@"Combined Parts"] = @"invalid";
    assert(loss(@[activeParent, activeGuard, malformed, trailer], @NO) == 1);
    malformed[@"Combined Parts"] = @[];
    assert(loss(@[activeParent, activeGuard, malformed, trailer], @NO) == 1);
    malformed = activePair.mutableCopy;
    NSMutableDictionary *foreignPart = [activePair[@"Combined Parts"][0] mutableCopy];
    foreignPart[@"Accessory Identifier"] = @"foreign";
    malformed[@"Combined Parts"] = @[foreignPart, activePair[@"Combined Parts"][1]];
    assert(loss(@[activeParent, activeGuard, malformed, trailer], @NO) == 1);
    malformed = activePair.mutableCopy;
    malformed[@"Current Capacity"] = @0;
    assert(loss(@[activeParent, activeGuard, malformed, trailer], @NO) == 1);
    malformed = activeParent.mutableCopy;
    malformed[@"Combined Parts"] = activePair[@"Combined Parts"];
    assert(loss(@[malformed, activeGuard, activePair, trailer], @NO) == 1);
    assert(finalInventoryResult(nil, identifier, @NO) == 1);
    assert(finalInventoryResult(@[], identifier, @YES) == 1);
    assert(finalInventoryResult(@[], identifier, nil) == 1);
    assert(finalInventoryResult(@[], identifier, @NO) == nativeDisconnectedExit);
    assert(finalInventoryResult(@[native], identifier, @YES) == 0);
    assert(finalInventoryResult(@[native], identifier, nil) == 0);
    assert(finalInventoryResult(@[native], identifier, @NO) == nativeDisconnectedExit);
    assert(finalInventoryResult(disconnectedRecords, identifier, @NO) == 1);
    assert(finalInventoryResult(@[native, disconnectedRecords.firstObject], identifier, @NO) == 1);
    assert(withdrawalResult(0, nativeDisconnectedExit) == nativeDisconnectedExit);
    assert(withdrawalResult(nativeDisconnectedExit, 0) == nativeDisconnectedExit);
    assert(withdrawalResult(1, nativeDisconnectedExit) == 1);
    assert(withdrawalResult(nativeDisconnectedExit, 1) == 1);
    assert(withdrawalResult(0, nativeUnavailableExit) == nativeUnavailableExit);
    assert(withdrawalResult(nativeUnavailableExit, 0) == nativeUnavailableExit);
    assert(finalWithdrawalResult(nativeUnavailableExit, 0) == 1);
    assert(finalWithdrawalResult(nativeUnavailableExit, 1) == 1);
    assert(finalWithdrawalResult(nativeUnavailableExit, nativeDisconnectedExit) == nativeDisconnectedExit);
    assert(finalWithdrawalResult(1, nativeDisconnectedExit) == 1);
    assert(finalWithdrawalResult(nativeDisconnectedExit, 1) == 1);
    assert(finalWithdrawalResult(withdrawalResult(nativeUnavailableExit, nativeDisconnectedExit), 0) == nativeDisconnectedExit);
    stopped = SIGTERM;
    assert(finalWithdrawalResult(nativeUnavailableExit, nativeDisconnectedExit) == 1);
    assert(finalWithdrawalResult(nativeDisconnectedExit, 0) == 1);
    stopped = 0;
    NSMutableData *invalidInput = [NSMutableData dataWithData:[@"invalid\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary *invalidReport = nil;
    assert(receive(-1, invalidInput, &invalidReport) == -2);
    NSDictionary *freshReading = @{@"level": @40, @"isCharging": @NO, @"observedAt": @(NSDate.date.timeIntervalSince1970)};
    NSMutableDictionary *freshSample = sample.mutableCopy;
    freshSample[@"left"] = freshReading;
    freshSample[@"right"] = freshReading;
    NSMutableDictionary *renewedSample = freshSample.mutableCopy;
    double renewedAt = [freshReading[@"observedAt"] doubleValue] + 1;
    NSDictionary *renewedReading = @{@"level": @40, @"isCharging": @NO, @"observedAt": @(renewedAt)};
    renewedSample[@"left"] = renewedSample[@"right"] = renewedReading;
    assert(valid(renewedSample, identifier, freshSample, renewedAt));
    assert(sameReadings(freshSample, renewedSample));
    assert([publication(freshSample, @"pair") isEqual:publication(renewedSample, @"pair")]);
    assert([envelope(freshSample, @"parent") isEqual:envelope(renewedSample, @"parent")]);
    assert(!valid(freshSample, identifier, renewedSample, renewedAt));
    assert(!valid(renewedSample, identifier, freshSample, renewedAt + 21));
    NSMutableDictionary *changedSample = renewedSample.mutableCopy;
    changedSample[@"left"] = @{@"level": @41, @"isCharging": @NO, @"observedAt": @(renewedAt)};
    assert(!sameReadings(freshSample, changedSample));
    changedSample[@"left"] = @{@"level": @40, @"isCharging": @YES, @"observedAt": @(renewedAt)};
    assert(!sameReadings(freshSample, changedSample));
    changedSample[@"left"] = renewedReading;
    changedSample[@"right"] = @{@"level": @39, @"isCharging": @NO, @"observedAt": @(renewedAt)};
    assert(!sameReadings(freshSample, changedSample));
    changedSample[@"right"] = @{@"level": @40, @"isCharging": @YES, @"observedAt": @(renewedAt)};
    assert(!sameReadings(freshSample, changedSample));
    NSMutableDictionary *changedNative = native.mutableCopy;
    changedNative[@"Power Source ID"] = @9;
    assert([single(native, @"trailer") isEqual:single(changedNative, @"trailer")]);
    changedNative[@"Current Capacity"] = @39;
    assert(![single(native, @"trailer") isEqual:single(changedNative, @"trailer")]);
    changedNative[@"Current Capacity"] = @40;
    changedNative[@"Is Charging"] = @YES;
    assert(![single(native, @"trailer") isEqual:single(changedNative, @"trailer")]);
    double lease = sampleDeadline(freshSample);
    assert(lease > NSProcessInfo.processInfo.systemUptime + 44 && lease <= NSProcessInfo.processInfo.systemUptime + 45);
    assert(expired(freshSample, NSProcessInfo.processInfo.systemUptime - 1));
    assert(expired(sample, NSProcessInfo.processInfo.systemUptime + 45));
    assert(resultBeforeCleanup(nativeDisconnectedExit, freshSample, INFINITY) == nativeDisconnectedExit);
    assert(resultBeforeCleanup(0, sample, INFINITY) == 1);
    assert(resultBeforeCleanup(nativeDisconnectedExit, sample, INFINITY) == 1);
    assert(resultBeforeCleanup(nativeUnavailableExit, sample, INFINITY) == 1);
    assert(finalWithdrawalResult(resultBeforeCleanup(nativeUnavailableExit, sample, INFINITY), nativeDisconnectedExit) == 1);
    assert(resultBeforeCleanup(0, freshSample, NSProcessInfo.processInfo.systemUptime - 1) == 1);
    assert(withdrawalResult(resultBeforeCleanup(0, sample, INFINITY), nativeDisconnectedExit) == 1);
    assert(withdrawalResult(resultBeforeCleanup(nativeDisconnectedExit, sample, INFINITY), 0) == 1);
    assert(!single(native, @"parent")[@"Power Source ID"]);
    assert([envelope(sample, @"parent")[@"Combined Parts"] count] == 0);
    assert([publication(sample, @"pair")[@"Combined Parts"] count] == 2);
    creationFinished = YES;
    EnvelopeSource closed = {0};
    assert(allocateSource(&closed) == kIOReturnNotPermitted && !closed.allocated);
    NSDictionary *unassociated = unassociatedSingle(native, @"pulse");
    assert(!unassociated[@"Accessory Identifier"] && !unassociated[@"Group Identifier"] && !unassociated[@"Power Source ID"]);
    assert([unassociated[@"Current Capacity"] isEqual:native[@"Current Capacity"]]);
    assert(!markersAbsent(@[unassociated], @[@"pulse"]));
    puts("PASS offline bounded idle inventory counts, forced update checks, trailer order, alias containment, expiry, owner, pending withdrawal and verified-disconnect checks; no source or hardware operation");
    return 0;
}

static int model(NSString *identifier) {
    NSMutableData *buffer = NSMutableData.data;
    NSDictionary *sample = nil, *incoming = nil;
    NSUInteger update = 0;
    while (!stopped) {
        @autoreleasepool {
            int received = receive(STDIN_FILENO, buffer, &incoming);
            if (received < 0) return received == -1 ? 0 : 2;
            if (!received) continue;
            if (!valid(incoming, identifier, sample, NSDate.date.timeIntervalSince1970)) return 2;
            sample = incoming;
            event(@"refresh-completed", @{@"sample": sample, @"update": @(++update)});
        }
    }
    return 0;
}

#ifndef ACOUPLET_BATTERY_CLEANUP_CHECK
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--self-test")) return envelopeSelfTest();
        if (argc != 4 || (strcmp(argv[1], "--publish") && strcmp(argv[1], "--child") && strcmp(argv[1], "--pulse") && strcmp(argv[1], "--model"))) return 2;
        NSString *identifier = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[2]]].UUIDString;
        NSString *session = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[3]]].UUIDString;
        if (!identifier || !session) return 2;
        signal(SIGPIPE, SIG_IGN);
        signal(SIGINT, stop);
        signal(SIGTERM, stop);
        signal(SIGALRM, SIG_DFL);
        if (!strcmp(argv[1], "--pulse")) alarm(5);
        if (!strcmp(argv[1], "--model")) return model(identifier);
        if (!openServer()) return 3;
        int result = !strcmp(argv[1], "--pulse") ? pulse(identifier, session)
            : !strcmp(argv[1], "--child") ? child(identifier, session)
            : supervisor(NSProcessInfo.processInfo.arguments.firstObject, identifier, session);
        disconnectServer(server);
        return result;
    }
}
#endif
