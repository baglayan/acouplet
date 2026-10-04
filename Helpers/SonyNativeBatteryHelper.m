#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/IOReturn.h>
#import <assert.h>
#import <math.h>
#import <notify.h>
#import <poll.h>
#import <signal.h>
#import <unistd.h>

typedef struct OpaqueIOPSPowerSourceID *IOPSPowerSourceID;
extern IOReturn IOPSCreatePowerSource(IOPSPowerSourceID *source);
extern IOReturn IOPSSetPowerSourceDetails(IOPSPowerSourceID source, CFDictionaryRef details);
extern IOReturn IOPSReleasePowerSource(IOPSPowerSourceID source);
extern CFTypeRef IOPSCopyPowerSourcesByType(int type);

static NSString *const ownerKey = @"Acouplet Native Battery Owner";
static volatile sig_atomic_t stopped;
static void stop(int signalNumber) { stopped = signalNumber; }

static BOOL number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && isfinite([value doubleValue]);
}

static BOOL level(id value) {
    return number(value) && [value doubleValue] == [value intValue] && [value intValue] > 0 && [value intValue] <= 100;
}

static BOOL part(id value, double now) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 3) return NO;
    id charging = value[@"isCharging"], observed = value[@"observedAt"];
    return level(value[@"level"]) && charging && CFGetTypeID((__bridge CFTypeRef)charging) == CFBooleanGetTypeID()
        && number(observed) && now - [observed doubleValue] <= 20 && [observed doubleValue] - now <= 5;
}

static BOOL valid(NSDictionary *sample, NSString *identifier, NSDictionary *previous, double now) {
    if (![sample isKindOfClass:NSDictionary.class] || sample.count != 5
        || ![sample[@"identifier"] isEqual:identifier]
        || ![sample[@"address"] isKindOfClass:NSString.class]
        || !number(sample[@"controlSession"]) || [sample[@"controlSession"] doubleValue] < 0
        || [sample[@"controlSession"] doubleValue] != floor([sample[@"controlSession"] doubleValue])
        || !part(sample[@"left"], now) || !part(sample[@"right"], now)) return NO;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$" options:0 error:nil];
    NSString *address = sample[@"address"];
    if (![pattern numberOfMatchesInString:address options:0 range:NSMakeRange(0, address.length)]) return NO;
    if (!previous) return YES;
    return [sample[@"address"] isEqual:previous[@"address"]] && [sample[@"controlSession"] isEqual:previous[@"controlSession"]]
        && [sample[@"left"][@"observedAt"] doubleValue] > [previous[@"left"][@"observedAt"] doubleValue]
        && [sample[@"right"][@"observedAt"] doubleValue] > [previous[@"right"][@"observedAt"] doubleValue];
}

static NSArray<NSDictionary *> *inventory(NSString *identifier) {
    CFTypeRef info = IOPSCopyPowerSourcesByType(4);
    if (!info) return nil;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    if (!list) { CFRelease(info); return nil; }
    NSMutableArray *records = [NSMutableArray array];
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        NSDictionary *record = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        if ([record[@"Accessory Identifier"] isEqual:identifier] || [record[@"Group Identifier"] isEqual:identifier])
            [records addObject:record.copy];
    }
    CFRelease(list);
    CFRelease(info);
    return records;
}

static BOOL nativeSingle(NSDictionary *record, NSString *identifier) {
    return [record[@"Accessory Identifier"] isEqual:identifier]
        && (!record[@"Group Identifier"] || [record[@"Group Identifier"] isEqual:identifier])
        && [record[@"Part Identifier"] isEqual:@"Single"] && !record[ownerKey] && !record[@"Acouplet Research Source Owner"]
        && (!record[@"Combined Parts"] || [record[@"Combined Parts"] isEqual:@[]])
        && number(record[@"Power Source ID"]) && [record[@"Power Source ID"] longLongValue] != 0
        && [record[@"Vendor ID"] isEqual:@1356] && [record[@"Product ID"] isEqual:@3683]
        && [record[@"Vendor ID Source"] isEqual:@2] && [record[@"Name"] isEqual:@"WF-1000XM5"]
        && [record[@"Type"] isEqual:@"Accessory Source"] && [record[@"Transport Type"] isEqual:@"Bluetooth"]
        && [record[@"Accessory Category"] isEqual:@"Headset"] && [record[@"Max Capacity"] isEqual:@100]
        && [record[@"Is Present"] isEqual:@YES] && level(record[@"Current Capacity"]);
}

static BOOL baselinePresent(NSArray<NSDictionary *> *records, NSDictionary *baseline, NSString *marker) {
    if (!records) return NO;
    NSUInteger singles = 0, owned = 0;
    for (NSDictionary *record in records) {
        if ([record[ownerKey] isEqual:marker] && [record[@"Part Identifier"] isEqual:@"Combined"]) { owned++; continue; }
        if (!nativeSingle(record, baseline[@"Accessory Identifier"]) || ![record[@"Power Source ID"] isEqual:baseline[@"Power Source ID"]]) return NO;
        singles++;
    }
    return singles == 1 && owned <= 1;
}

static NSDictionary *publication(NSDictionary *sample, NSString *marker) {
    NSDictionary *left = sample[@"left"], *right = sample[@"right"];
    NSMutableDictionary *record = [@{@"Type": @"Accessory Source", @"Transport Type": @"Bluetooth", @"Name": @"WF-1000XM5",
        @"Accessory Identifier": sample[@"identifier"], @"Group Identifier": sample[@"identifier"], @"Accessory Category": @"Headset",
        @"Vendor ID": @1356, @"Product ID": @3683, @"Vendor ID Source": @2, @"Part Identifier": @"Combined",
        @"Current Capacity": @(MIN([left[@"level"] intValue], [right[@"level"] intValue])), @"Max Capacity": @100,
        @"Is Present": @YES, @"Is Charging": @([left[@"isCharging"] boolValue] && [right[@"isCharging"] boolValue]),
        @"Is Charged": @NO, @"Power Source State": @"Battery Power", ownerKey: marker} mutableCopy];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in @[@"left", @"right"]) {
        NSMutableDictionary *component = record.mutableCopy;
        [component removeObjectForKey:ownerKey];
        component[@"Part Identifier"] = key.capitalizedString;
        component[@"Current Capacity"] = sample[key][@"level"];
        component[@"Is Charging"] = sample[key][@"isCharging"];
        [parts addObject:component];
    }
    record[@"Combined Parts"] = parts;
    return record;
}

static int selfTest(void) {
    NSString *identifier = @"00000000-0000-4000-8000-000000000019";
    NSDictionary *part = @{@"level": @40, @"isCharging": @NO, @"observedAt": @100};
    NSDictionary *sample = @{@"identifier": identifier, @"address": @"02:00:00:00:00:19", @"controlSession": @1, @"left": part, @"right": part};
    assert(valid(sample, identifier, nil, 100));
    assert(!valid(sample, identifier, sample, 100));
    assert(!valid(sample, identifier, nil, 121));
    assert(!valid(sample, identifier, nil, 94));
    NSMutableDictionary *bad = sample.mutableCopy;
    bad[@"right"] = @{@"level": @0, @"isCharging": @NO, @"observedAt": @100};
    assert(!valid(bad, identifier, nil, 100));
    NSDictionary *record = publication(sample, @"fixture");
    assert([record[@"Combined Parts"] count] == 2 && !record[@"Power Source ID"]);
    for (NSDictionary *child in record[@"Combined Parts"]) assert(![child[@"Part Identifier"] isEqual:@"Case"] && !child[@"Power Source ID"]);
    NSMutableDictionary *baseline = record.mutableCopy;
    [baseline removeObjectForKey:ownerKey];
    [baseline removeObjectForKey:@"Combined Parts"];
    baseline[@"Part Identifier"] = @"Single";
    baseline[@"Power Source ID"] = @123;
    assert(nativeSingle(baseline, identifier));
    assert(baselinePresent(@[baseline, record], baseline, @"fixture"));
    NSMutableDictionary *replacement = baseline.mutableCopy;
    replacement[@"Power Source ID"] = @124;
    assert(!baselinePresent(@[replacement, record], baseline, @"fixture"));
    NSMutableDictionary *reflection = record.mutableCopy;
    [reflection removeObjectForKey:ownerKey];
    assert(!baselinePresent(@[baseline, reflection, record], baseline, @"fixture"));
    assert(!baselinePresent(@[record], baseline, @"fixture"));
    assert(!baselinePresent(@[baseline, record, record], baseline, @"fixture"));
    puts("MODEL PASS: exact full pair, identity, freshness, no replay, no Case or caller-supplied source ID; no IOPS calls");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return selfTest();
        BOOL model = argc == 4 && strcmp(argv[1], "--model") == 0;
        if (argc != (model ? 4 : 3)) return 2;
        NSString *identifier = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[model ? 2 : 1]]].UUIDString;
        NSString *marker = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[model ? 3 : 2]]].UUIDString;
        if (!identifier || !marker) return 2;
        signal(SIGPIPE, SIG_IGN);
        signal(SIGINT, stop);
        signal(SIGTERM, stop);
        IOPSPowerSourceID source = NULL;
        NSDictionary *previous = nil, *baseline = nil;
        NSMutableData *pending = NSMutableData.data;
        double hardDeadline = NSProcessInfo.processInfo.systemUptime + 120;
        double lease = hardDeadline;
        int result = 0;
        while (!stopped && NSProcessInfo.processInfo.systemUptime < MIN(hardDeadline, lease)) {
            if (previous && NSDate.date.timeIntervalSince1970 >= MIN([previous[@"left"][@"observedAt"] doubleValue], [previous[@"right"][@"observedAt"] doubleValue]) + 45) break;
            if (previous && !model && !baselinePresent(inventory(identifier), baseline, marker)) {
                fputs("NATIVE_BATTERY baseline changed; releasing owned source only\n", stderr); result = 3; break;
            }
            struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
            int ready = poll(&descriptor, 1, 200);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) { result = 4; break; }
            if (!ready) continue;
            char bytes[2048];
            ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
            if (count == 0) { fputs("NATIVE_BATTERY parent EOF\n", stderr); break; }
            if (count < 0) { result = 4; break; }
            [pending appendBytes:bytes length:count];
            if (pending.length > 8192) { result = 2; break; }
            const char *newline;
            while ((newline = memchr(pending.bytes, '\n', pending.length))) {
                NSUInteger length = newline - (const char *)pending.bytes;
                NSData *line = [pending subdataWithRange:NSMakeRange(0, length)];
                [pending replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
                NSDictionary *sample = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                double now = NSDate.date.timeIntervalSince1970;
                if (!valid(sample, identifier, previous, now)) { result = 2; break; }
                if (!previous && !model) {
                    NSArray *records = inventory(identifier);
                    if (records.count != 1 || !nativeSingle(records.firstObject, identifier)) { result = 3; break; }
                    baseline = records.firstObject;
                }
                NSDictionary *record = publication(sample, marker);
                IOReturn created = !source && !model ? IOPSCreatePowerSource(&source) : 0;
                IOReturn updated = !created && !model ? IOPSSetPowerSourceDetails(source, (__bridge CFDictionaryRef)record) : created;
                uint32_t notified = !updated && !model ? notify_post("com.apple.system.accpowersources.timeremaining") : 0;
                fprintf(stderr, "NATIVE_BATTERY %s create=0x%08x set=0x%08x notify=%u\n", model ? "MODEL" : "published", created, updated, notified);
                if (updated || notified) { result = 5; break; }
                previous = sample;
                double observed = MIN([sample[@"left"][@"observedAt"] doubleValue], [sample[@"right"][@"observedAt"] doubleValue]);
                lease = NSProcessInfo.processInfo.systemUptime + observed + 45 - now;
            }
            if (result) break;
        }
        if (source) {
            IOReturn released = IOPSReleasePowerSource(source);
            fprintf(stderr, "NATIVE_BATTERY release=0x%08x\n", released);
            if (released) result = 6;
        }
        fprintf(stderr, "NATIVE_BATTERY exit=%d signal=%d\n", result, stopped);
        return result;
    }
}
