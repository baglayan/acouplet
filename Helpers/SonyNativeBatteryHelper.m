#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/IOReturn.h>
#import <assert.h>
#import <math.h>
#import <poll.h>
#import <signal.h>
#import <unistd.h>

extern CFTypeRef IOPSCopyPowerSourcesByType(int type);

static const double maximumSampleAge = 20;
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

static BOOL partWithMaximumAge(id value, double now, double maximumAge) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 3) return NO;
    id charging = value[@"isCharging"], observed = value[@"observedAt"];
    return level(value[@"level"]) && charging && CFGetTypeID((__bridge CFTypeRef)charging) == CFBooleanGetTypeID()
        && number(observed) && now - [observed doubleValue] <= maximumAge && [observed doubleValue] - now <= 5;
}

static BOOL validIdentity(NSDictionary *sample, NSString *identifier, NSUInteger fields) {
    if (![sample isKindOfClass:NSDictionary.class] || sample.count != fields
        || ![sample[@"identifier"] isEqual:identifier]
        || ![sample[@"name"] isKindOfClass:NSString.class] || ![sample[@"name"] length]
        || ![sample[@"address"] isKindOfClass:NSString.class]
        || !number(sample[@"controlSession"]) || [sample[@"controlSession"] doubleValue] < 0
        || [sample[@"controlSession"] doubleValue] != floor([sample[@"controlSession"] doubleValue])) return NO;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$" options:0 error:nil];
    NSString *address = sample[@"address"];
    return [pattern numberOfMatchesInString:address options:0 range:NSMakeRange(0, address.length)] != 0;
}

static BOOL validWithMaximumAge(NSDictionary *sample, NSString *identifier, NSDictionary *previous, double now, double maximumAge) {
    if (![sample isKindOfClass:NSDictionary.class] || !validIdentity(sample, identifier, sample[@"caseBattery"] ? 7 : 6)) return NO;
    BOOL changed = !previous;
    for (NSString *key in @[@"left", @"right", @"caseBattery"]) {
        id part = sample[key], old = previous[key];
        if (!part && [key isEqual:@"caseBattery"]) { if (old) changed = YES; continue; }
        BOOL unchanged = old && [part isEqual:old];
        if (!partWithMaximumAge(part, now, previous && unchanged ? ([key isEqual:@"caseBattery"] ? INFINITY : 45) : maximumAge)) return NO;
        if (previous && !unchanged && old && [part[@"observedAt"] doubleValue] <= [old[@"observedAt"] doubleValue]) return NO;
        if (!unchanged) changed = YES;
    }
    if (!previous) return YES;
    BOOL samePair = [sample[@"left"] isEqual:previous[@"left"]] && [sample[@"right"] isEqual:previous[@"right"]];
    BOOL newerPair = [sample[@"left"][@"observedAt"] doubleValue] > [previous[@"left"][@"observedAt"] doubleValue]
        && [sample[@"right"][@"observedAt"] doubleValue] > [previous[@"right"][@"observedAt"] doubleValue];
    return changed && (samePair || newerPair) && [sample[@"address"] isEqual:previous[@"address"]]
        && [sample[@"controlSession"] isEqual:previous[@"controlSession"]];
}

static BOOL caseProgresses(NSDictionary *sample, NSDictionary *previous, double latestObservation) {
    return !sample[@"caseBattery"] || [sample[@"caseBattery"] isEqual:previous[@"caseBattery"]]
        || [sample[@"caseBattery"][@"observedAt"] doubleValue] > latestObservation;
}

static BOOL valid(NSDictionary *sample, NSString *identifier, NSDictionary *previous, double now) {
    return validWithMaximumAge(sample, identifier, previous, now, maximumSampleAge);
}

static BOOL validCaseWithMaximumAge(NSDictionary *sample, NSString *identifier, NSDictionary *previous, double now, double maximumAge) {
    if (!validIdentity(sample, identifier, 5)) return NO;
    id value = sample[@"caseBattery"];
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 3) return NO;
    id capacity = value[@"level"], charging = value[@"isCharging"], observed = value[@"observedAt"];
    if (!number(capacity) || [capacity doubleValue] != [capacity intValue] || [capacity intValue] < 0 || [capacity intValue] > 100
        || !charging || CFGetTypeID((__bridge CFTypeRef)charging) != CFBooleanGetTypeID()
        || !number(observed) || now - [observed doubleValue] > maximumAge || [observed doubleValue] - now > 5) return NO;
    return !previous || ([sample[@"address"] isEqual:previous[@"address"]]
        && [sample[@"controlSession"] isEqual:previous[@"controlSession"]]
        && [observed doubleValue] > [previous[@"caseBattery"][@"observedAt"] doubleValue]);
}

static BOOL validCase(NSDictionary *sample, NSString *identifier, NSDictionary *previous, double now) {
    return validCaseWithMaximumAge(sample, identifier, previous, now, maximumSampleAge);
}

static NSDictionary *casePublication(NSDictionary *sample, NSString *marker) {
    return @{@"Type": @"Accessory Source", @"Transport Type": @"Bluetooth", @"Name": [sample[@"name"] stringByAppendingString:@" Case"],
        @"Accessory Category": @"Headset", @"Vendor ID": @1356, @"Product ID": @3683, @"Vendor ID Source": @2,
        @"Part Identifier": @"Case", @"Current Capacity": sample[@"caseBattery"][@"level"], @"Max Capacity": @100,
        @"Is Present": @YES, @"Is Charging": sample[@"caseBattery"][@"isCharging"], @"Is Charged": @NO,
        @"Power Source State": @"Battery Power", ownerKey: marker};
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
        && [record[@"Vendor ID Source"] isEqual:@2]
        && [record[@"Type"] isEqual:@"Accessory Source"] && [record[@"Transport Type"] isEqual:@"Bluetooth"]
        && [record[@"Accessory Category"] isEqual:@"Headset"] && [record[@"Max Capacity"] isEqual:@100]
        && [record[@"Is Present"] isEqual:@YES] && level(record[@"Current Capacity"]);
}

static NSDictionary *publication(NSDictionary *sample, NSString *marker) {
    NSDictionary *left = sample[@"left"], *right = sample[@"right"];
    NSMutableDictionary *record = [@{@"Type": @"Accessory Source", @"Transport Type": @"Bluetooth", @"Name": sample[@"name"],
        @"Accessory Identifier": sample[@"identifier"], @"Group Identifier": sample[@"identifier"], @"Accessory Category": @"Headset",
        @"Vendor ID": @1356, @"Product ID": @3683, @"Vendor ID Source": @2, @"Part Identifier": @"Combined",
        @"Current Capacity": @(MIN([left[@"level"] intValue], [right[@"level"] intValue])), @"Max Capacity": @100,
        @"Is Present": @YES, @"Is Charging": @([left[@"isCharging"] boolValue] && [right[@"isCharging"] boolValue]),
        @"Is Charged": @NO, @"Power Source State": @"Battery Power", ownerKey: marker} mutableCopy];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in (sample[@"caseBattery"] ? @[@"left", @"right", @"caseBattery"] : @[@"left", @"right"])) {
        NSMutableDictionary *component = record.mutableCopy;
        [component removeObjectForKey:ownerKey];
        component[@"Part Identifier"] = [key isEqual:@"caseBattery"] ? @"Case" : key.capitalizedString;
        component[@"Current Capacity"] = sample[key][@"level"];
        component[@"Is Charging"] = sample[key][@"isCharging"];
        [parts addObject:component];
    }
    record[@"Combined Parts"] = parts;
    return record;
}
