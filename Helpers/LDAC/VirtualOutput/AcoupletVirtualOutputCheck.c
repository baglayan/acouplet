#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#define ACOUPLET_PRIORITY_CHECK 1
#include "AcoupletVirtualOutput.c"

static dispatch_semaphore_t requested;
static atomic_uint_fast64_t requestedAction;
static atomic_uint volumeNotifications;
static atomic_uint muteNotifications;
static atomic_uint iconNotifications;
static atomic_uint terminalNotifications;
static CFBundleRef iconBundle;
static atomic_bool rejectRequest;
static AudioServerPlugInDriverRef driver;
static pid_t owner;
static atomic_uint timerWakeups;

static OSStatus Changed(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count,
                         const AudioObjectPropertyAddress *properties) {
    assert(pthread_mutex_trylock(&gPlugIn_StateMutex) == 0);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (object == kObjectID_Device) {
        for (UInt32 i = 0; i < count; ++i) {
            assert(properties[i].mSelector != kAudioDevicePropertyDeviceIsAlive);
            assert(properties[i].mSelector != kAudioDevicePropertyIsHidden);
            if (properties[i].mSelector == kAudioDevicePropertyVolumeScalar) atomic_fetch_add(&volumeNotifications, 1);
            if (properties[i].mSelector == kAudioDevicePropertyMute) atomic_fetch_add(&muteNotifications, 1);
            if (properties[i].mSelector == kAudioDevicePropertyIcon) atomic_fetch_add(&iconNotifications, 1);
        }
    }
    if (object == kObjectID_Stream_Output) {
        for (UInt32 i = 0; i < count; ++i)
            if (properties[i].mSelector == kAudioStreamPropertyTerminalType) atomic_fetch_add(&terminalNotifications, 1);
    }
    return noErr;
}

static OSStatus Request(AudioServerPlugInHostRef host, AudioObjectID object, UInt64 action, void *info) {
    assert(object == kObjectID_Device && action && info == NULL);
    assert(pthread_mutex_trylock(&gPlugIn_StateMutex) == 0);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    atomic_store(&requestedAction, action);
    dispatch_semaphore_signal(requested);
    return atomic_load(&rejectRequest) ? kAudioHardwareUnspecifiedError : noErr;
}

static OSStatus EmptyStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *data) {
    *data = NULL;
    return noErr;
}

static AudioObjectPropertyAddress Property(UInt32 selector, UInt32 scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}

static OSStatus Set(AudioObjectID object, pid_t client, UInt32 selector, UInt32 scope,
                     UInt32 size, const void *data) {
    AudioObjectPropertyAddress property = Property(selector, scope);
    return (*driver)->SetPropertyData(driver, object, client, &property, 0, NULL, size, data);
}

static void Get(AudioObjectID object, pid_t client, UInt32 selector, UInt32 scope,
                 UInt32 capacity, void *data) {
    AudioObjectPropertyAddress property = Property(selector, scope);
    UInt32 size = 0;
    assert((*driver)->GetPropertyData(driver, object, client, &property, 0, NULL,
                                     capacity, &size, data) == noErr && size == capacity);
}

static UInt32 Available(UInt32 selector, UInt32 scope) {
    UInt32 value;
    Get(kObjectID_Device, owner, selector, scope, sizeof(value), &value);
    return value;
}

static Boolean Lease(pid_t client) {
    CFBooleanRef value;
    Get(kObjectID_Device, client, kAcoupletLease, kAudioObjectPropertyScopeGlobal, sizeof(value), &value);
    Boolean leased = CFBooleanGetValue(value);
    CFRelease(value);
    return leased;
}

static void SetLease(pid_t client, Boolean claim) {
    CFBooleanRef value = claim ? kCFBooleanTrue : kCFBooleanFalse;
    assert(Set(kObjectID_Device, client, kAcoupletLease, kAudioObjectPropertyScopeGlobal,
               sizeof(value), &value) == noErr);
}

static UInt64 WaitRequest(void) {
    assert(dispatch_semaphore_wait(requested, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0);
    dispatch_sync(gLeaseQueue, ^{});
    return atomic_load(&requestedAction);
}

static void RequestNow(void) {
    dispatch_sync(gLeaseQueue, ^{ AcoupletRequestAvailability(); });
}

static void CheckIdleTimer(void) {
    dispatch_sync(gLeaseQueue, ^{ assert(!gLeaseTimerArmed); });
    unsigned before = atomic_load(&timerWakeups);
    usleep(600000);
    dispatch_sync(gLeaseQueue, ^{ assert(!gLeaseTimerArmed); });
    assert(atomic_load(&timerWakeups) == before);
}

static void Perform(UInt64 action) {
    assert((*driver)->PerformDeviceConfigurationChange(driver, kObjectID_Device, action, NULL) == noErr);
    dispatch_sync(gLeaseQueue, ^{});
}

static OSStatus SetPriority(pid_t client, CFStringRef address, Boolean enabled, Boolean disconnected) {
    CFMutableDictionaryRef request = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(request, CFSTR("address"), address);
    CFDictionarySetValue(request, CFSTR("enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
    if (disconnected) CFDictionarySetValue(request, CFSTR("disconnected"), kCFBooleanTrue);
    OSStatus status = Set(kObjectID_Device, client, kAcoupletPriority, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request);
    CFRelease(request);
    return status;
}

static OSStatus PreparePriority(pid_t client, CFStringRef address, Boolean enabled, Boolean disconnected) {
    CFMutableDictionaryRef request = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(request, CFSTR("address"), address);
    CFDictionarySetValue(request, CFSTR("enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(request, CFSTR("prepare"), kCFBooleanTrue);
    if (disconnected) CFDictionarySetValue(request, CFSTR("disconnected"), kCFBooleanTrue);
    OSStatus status = Set(kObjectID_Device, client, kAcoupletPriority, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request);
    CFRelease(request);
    return status;
}

static void PriorityPhase(CFStringRef phase) {
    CFPropertyListRef state;
    Get(kObjectID_Device, owner, kAcoupletPriority, kAudioObjectPropertyScopeGlobal, sizeof(state), &state);
    assert(CFEqual(CFDictionaryGetValue(state, CFSTR("phase")), phase));
    if (CFEqual(phase, CFSTR("idle"))) assert(!CFDictionaryGetValue(state, CFSTR("address")));
    else assert(CFEqual(CFDictionaryGetValue(state, CFSTR("address")), CFSTR("AA:BB:CC:DD:EE:FF")));
    CFRelease(state);
}

static void PriorityPublication(const char *uid, const char *address, int64_t type) {
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t properties = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(properties, "kBTAudioMsgPropertyDeviceAddress", address);
    xpc_dictionary_set_value(args, "kBTAudioMsgArgDeviceProperties", properties);
    xpc_dictionary_set_int64(args, "kBTAudioMsgArgDeviceType", type);
    xpc_dictionary_set_value(event, "kBTAudioMsgArgs", args);
    xpc_dictionary_set_int64(event, "kBTAudioMsgId", 2);
    xpc_dictionary_set_string(event, "kBTAudioMsgDeviceUid", uid);
    dispatch_sync(gLeaseQueue, ^{ AcoupletPriorityEvent(event); });
    xpc_release(properties);
    xpc_release(args);
    xpc_release(event);
}

static void PriorityNotification(void) {
    dispatch_sync(gLeaseQueue, ^{ AcoupletPriorityNotification(); });
}

static void PriorityWithdrawal(const char *uid) {
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(event, "kBTAudioMsgId", 4);
    xpc_dictionary_set_string(event, "kBTAudioMsgDeviceUid", uid);
    dispatch_sync(gLeaseQueue, ^{ AcoupletPriorityEvent(event); });
    xpc_release(event);
}

static void CheckPriority(void) {
    CFStringRef address = CFSTR("aa-bb-cc-dd-ee-ff");
    PriorityPhase(CFSTR("idle"));
    assert(PreparePriority(owner + 1, address, false, false) == kAudioDevicePermissionsError);
    assert(PreparePriority(owner, address, true, false) == kAudioHardwareIllegalOperationError);
    assert(PreparePriority(owner, address, false, true) == kAudioHardwareIllegalOperationError);
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPhase(CFSTR("observing"));
    UInt64 bootstraps = gPriorityCheckBootstraps;
    UInt64 sends = gPriorityCheckSends;
    assert(gPriorityListening && !gPriorityDeadline && !gPrioritySent);
    assert(PreparePriority(owner, address, false, false) == noErr && gPriorityCheckBootstraps == bootstraps);
    PriorityPublication("passive-old", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityPublication("passive-replacement", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(!strcmp(gPriorityUID, "passive-replacement") && gPriorityCheckSends == sends);
    PriorityWithdrawal("passive-replacement");
    assert(!gPriorityUID && !gPriorityStopping && !gPriorityDeadline);
    PriorityPhase(CFSTR("observing"));
    PriorityPublication("passive-fresh", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityCheckSends == sends && SetPriority(owner, address, true, false) == noErr);
    assert(gPriorityCheckBootstraps == bootstraps && gPriorityCheckSends == sends + 1 &&
        gPriorityDeadline && gPriorityWaiting == 2 && !strcmp(gPriorityUID, "passive-fresh"));
    assert(PreparePriority(owner, address, false, false) == kAudioHardwareIllegalOperationError);
    PriorityNotification();
    assert(SetPriority(owner, address, false, false) == noErr);
    PriorityNotification();
    PriorityNotification();
    assert(PreparePriority(owner, address, false, false) == noErr);
    sends = gPriorityCheckSends;
    assert(SetPriority(owner, address, true, false) == noErr && !gPriorityUID && gPriorityDeadline &&
        gPriorityCheckSends == sends);
    PriorityPhase(CFSTR("configuring"));
    PriorityPublication("future-after-enable", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 2 && gPriorityCheckSends == sends + 1);
    PriorityNotification();
    assert(SetPriority(owner, address, false, false) == noErr);
    PriorityNotification();
    PriorityNotification();
    assert(PreparePriority(owner, address, false, false) == noErr);
    sends = gPriorityCheckSends;
    dispatch_sync(gLeaseQueue, ^{
        pthread_mutex_lock(&gPlugIn_StateMutex);
        gPriorityOwner = owner + 1;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        AcoupletPriorityTick();
    });
    PriorityPhase(CFSTR("idle"));
    assert(!gPriorityListening && gPriorityCheckSends == sends);
    assert(SetPriority(owner + 1, address, true, false) == kAudioDevicePermissionsError);
    assert(SetPriority(owner, CFSTR("not-an-address"), true, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(owner, address, true, true) == kAudioHardwareIllegalOperationError);
    CFPropertyListRef invalid = CFSTR("invalid");
    assert(Set(kObjectID_Device, owner, kAcoupletPriority, kAudioObjectPropertyScopeGlobal,
        sizeof(invalid), &invalid) == kAudioHardwareIllegalOperationError);
    assert(Set(kObjectID_Device, owner, kAcoupletPriority, kAudioObjectPropertyScopeGlobal,
        0, &invalid) == kAudioHardwareBadPropertySizeError);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPhase(CFSTR("configuring"));
    assert(!gPriorityConnection && gPriorityNotify == -1 && !gPrioritySent);
    PriorityPublication("unrelated", "00:00:00:00:00:01", 1952538980);
    PriorityPublication("wrong-type", "AA:BB:CC:DD:EE:FF", 1952538981);
    assert(!gPrioritySent && !gPriorityUID);
    PriorityPublication("opaque-published-uid", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPrioritySent && gPriorityWaiting == 2 && gPriorityCheckStatus == 2 &&
        !strcmp(gPriorityUID, "opaque-published-uid"));
    xpc_object_t request = AcoupletPriorityRequest(gPriorityUID, "AA:BB:CC:DD:EE:FF", 2);
    assert(xpc_dictionary_get_int64(request, "kBTAudioMsgId") == 3 &&
        !strcmp(xpc_dictionary_get_string(request, "kBTAudioMsgDeviceUid"), "opaque-published-uid"));
    xpc_object_t unified = xpc_dictionary_get_value(xpc_dictionary_get_value(request, "kBTAudioMsgArgs"),
        "kBTAudioMsgUnifiedUSBCDict");
    assert(xpc_dictionary_get_int64(unified, "kBTAudioMsgUnifiedUSBCStatus") == 2 &&
        !strcmp(xpc_dictionary_get_string(unified, "kBTAudioMsgUnifiedUSBCBTAddress"), "AA:BB:CC:DD:EE:FF"));
    xpc_release(request);
    PriorityPhase(CFSTR("configuring"));
    PriorityNotification();
    PriorityPhase(CFSTR("configured"));
    assert(!gPriorityDeadline && SetPriority(owner, address, true, false) == noErr);
    assert(SetPriority(owner, CFSTR("00:00:00:00:00:01"), true, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityCheckStatus == 1);
    UInt64 cleanupDeadline = gPriorityDeadline;
    PriorityPhase(CFSTR("stopping"));
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityWaiting == 1);
    PriorityNotification();
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0 && gPriorityDeadline == cleanupDeadline);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("opaque-old", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityWaiting == 2);
    PriorityNotification();
    assert(gPriorityWaiting == 1);
    PriorityNotification();
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("opaque-old", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    PriorityWithdrawal("opaque-old");
    PriorityPhase(CFSTR("cleanup-required"));
    PriorityPublication("opaque-new", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == -1 && gPriorityCheckStatus == 2);
    assert(SetPriority(owner, address, true, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityWaiting == -1);
    bootstraps = gPriorityCheckBootstraps;
    assert(SetPriority(owner, address, false, true) == noErr && !strcmp(gPriorityUID, "opaque-new") &&
        gPriorityCheckBootstraps == bootstraps);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityPhase(CFSTR("cleanup-required"));
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPublication("before-confirmed-disconnect", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityNotification();
    bootstraps = gPriorityCheckBootstraps;
    assert(SetPriority(owner, address, false, true) == noErr && !gPriorityUID &&
        gPriorityListening && gPriorityCheckBootstraps == bootstraps);
    PriorityPublication("after-confirmed-disconnect", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPublication("before-interruption", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityNotification();
    dispatch_sync(gLeaseQueue, ^{ AcoupletPriorityEvent((xpc_object_t)XPC_ERROR_CONNECTION_INTERRUPTED); });
    PriorityPhase(CFSTR("cleanup-required"));
    bootstraps = gPriorityCheckBootstraps;
    assert(!gPriorityListening && !gPriorityUID);
    assert(SetPriority(owner, address, false, true) == noErr && gPriorityListening &&
        gPriorityCheckBootstraps == bootstraps + 1);
    PriorityPublication("after-interruption", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("deadline", "AA:BB:CC:DD:EE:FF", 1952538980);
    dispatch_sync(gLeaseQueue, ^{ gPriorityDeadline = mach_absolute_time() - 1; });
    __block Boolean expiredDeadline = false;
    for (UInt32 attempt = 0; !expiredDeadline && attempt < 20; ++attempt) {
        usleep(100000);
        dispatch_sync(gLeaseQueue, ^{ expiredDeadline = CFEqual(gPriorityPhase, CFSTR("cleanup-required")); });
    }
    assert(expiredDeadline);
    PriorityPhase(CFSTR("cleanup-required"));
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityWaiting == 1);
    PriorityNotification();
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("owner-exit", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    dispatch_sync(gLeaseQueue, ^{
        AcoupletOwnerExited(owner, gOwnerWatchGeneration - 1);
        assert(gLeaseOwner == owner && AcoupletLeaseValid());
        AcoupletOwnerExited(owner, gOwnerWatchGeneration);
    });
    PriorityPhase(CFSTR("cleanup-required"));
    assert(gPriorityWaiting == 1);
    Perform(WaitRequest());
    dispatch_sync(gLeaseQueue, ^{ assert(!gLeaseOwner && !AcoupletAlive() && gLeaseTimerArmed); });
    PriorityNotification();
    PriorityNotification();
    RequestNow();
    PriorityPhase(CFSTR("idle"));
    CheckIdleTimer();
    SetLease(owner, true);
    Perform(WaitRequest());
}

static void CheckResourceBundle(void) {
    AudioObjectPropertyAddress property = Property(kAudioPlugInPropertyResourceBundle, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_PlugIn, owner, &property, 0, NULL, &size) == noErr && size == sizeof(CFStringRef));
    union { CFStringRef alignment; UInt8 bytes[sizeof(CFStringRef) + 8]; } buffer;
    for (UInt32 capacity = 0; capacity < sizeof(CFStringRef); ++capacity) {
        memset(buffer.bytes, 0xA5, sizeof(buffer.bytes));
        OSStatus status = (*driver)->GetPropertyData(driver, kObjectID_PlugIn, owner, &property,
            0, NULL, capacity, &size, buffer.bytes);
        for (UInt32 i = capacity; i < sizeof(buffer.bytes); ++i) assert(buffer.bytes[i] == 0xA5);
        assert(status == kAudioHardwareBadPropertySizeError);
    }
    memset(buffer.bytes, 0xA5, sizeof(buffer.bytes));
    assert((*driver)->GetPropertyData(driver, kObjectID_PlugIn, owner, &property,
        0, NULL, sizeof(CFStringRef), &size, buffer.bytes) == noErr && size == sizeof(CFStringRef));
    CFStringRef value;
    memcpy(&value, buffer.bytes, sizeof(value));
    assert(value && CFGetTypeID(value) == CFStringGetTypeID() && CFEqual(value, CFSTR("")));
    for (UInt32 i = sizeof(CFStringRef); i < sizeof(buffer.bytes); ++i) assert(buffer.bytes[i] == 0xA5);
    CFRelease(value);
}

static void CheckIdentity(CFStringRef icon, UInt32 terminal) {
    CFStringRef bundleID;
    Get(kObjectID_PlugIn, owner, kAudioPlugInPropertyBundleID, kAudioObjectPropertyScopeGlobal,
        sizeof(bundleID), &bundleID);
    assert(CFEqual(bundleID, CFSTR("dev.baglayan.Acouplet.LDACOutput")));
    CFRelease(bundleID);
    UInt32 value;
    Get(kObjectID_Device, owner, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
        sizeof(value), &value);
    assert(value == kAudioDeviceTransportTypeVirtual);
    Get(kObjectID_Stream_Output, owner, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal,
        sizeof(value), &value);
    assert(value == terminal);
    AudioObjectPropertyAddress property = Property(kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal);
    assert((*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    UInt32 size;
    Boolean settable = true;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, owner, &property, 0, NULL, &size) == noErr && size == sizeof(CFURLRef));
    assert((*driver)->IsPropertySettable(driver, kObjectID_Device, owner, &property, &settable) == noErr && !settable);
    CFURLRef url = NULL;
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(url) - 1, &size, &url) == kAudioHardwareBadPropertySizeError);
    OSStatus status = (*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(url), &size, &url);
    if (iconBundle) {
        assert(status == noErr && url && size == sizeof(url));
        CFStringRef filename = CFURLCopyLastPathComponent(url);
        assert(CFEqual(filename, icon));
        CFRelease(filename);
        CFRelease(url);
    } else assert(status == kAudioHardwareUnspecifiedError && !url);
    property.mScope = kAudioObjectPropertyScopeOutput;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mScope = kAudioObjectPropertyScopeGlobal;
    property.mElement = 1;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mElement = kAudioObjectPropertyElementMain;
    assert(!(*driver)->HasProperty(driver, kObjectID_Stream_Output, owner, &property));
}

static void CheckRevision(void) {
    AudioObjectPropertyAddress property = Property(kAcoupletRevision, kAudioObjectPropertyScopeGlobal);
    assert((*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    Boolean settable = true;
    assert((*driver)->IsPropertySettable(driver, kObjectID_Device, owner, &property, &settable) == noErr && !settable);
    CFNumberRef revision = NULL;
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, owner, &property, 0, NULL, &size) == noErr && size == sizeof(revision));
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(revision) - 1, &size, &revision) == kAudioHardwareBadPropertySizeError && !revision);
    Get(kObjectID_Device, owner, kAcoupletRevision, kAudioObjectPropertyScopeGlobal, sizeof(revision), &revision);
    SInt32 value = 0;
    assert(revision && CFGetTypeID(revision) == CFNumberGetTypeID());
    assert(CFNumberGetValue(revision, kCFNumberSInt32Type, &value) && value == kAcoupletDriverRevision && value == 2);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(revision), &revision) != noErr);
    CFRelease(revision);
    property.mScope = kAudioObjectPropertyScopeOutput;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mScope = kAudioObjectPropertyScopeGlobal;
    property.mElement = 1;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mElement = kAudioObjectPropertyElementMain;
    assert(!(*driver)->HasProperty(driver, kObjectID_PlugIn, owner, &property));
}

int main(int argc, const char *argv[]) {
    assert(argc == 1 || argc == 2);
    if (argc == 2) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), true);
        iconBundle = CFBundleCreate(NULL, url);
        CFRelease(url);
        assert(iconBundle && CFEqual(CFBundleGetIdentifier(iconBundle), CFSTR("dev.baglayan.Acouplet.LDACOutput")));
    }
    driver = AcoupletVirtualOutput_Create(NULL, kAudioServerPlugInTypeUUID);
    AudioServerPlugInHostInterface host = {.PropertiesChanged = Changed, .CopyFromStorage = EmptyStorage,
        .RequestDeviceConfigurationChange = Request};
    requested = dispatch_semaphore_create(0);
    assert(driver && (*driver)->AddRef(driver) == 1);
    assert((*driver)->Initialize(driver, &host) == noErr);
    dispatch_source_set_event_handler(gLeaseTimer, ^{
        atomic_fetch_add(&timerWakeups, 1);
        AcoupletRequestAvailability();
    });
    owner = getpid();
    CheckIdleTimer();
    CheckResourceBundle();
    CheckRevision();
    CheckIdentity(CFSTR("Earbuds.png"), kAudioStreamTerminalTypeHeadphones);
    assert(!Available(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal));
    assert(Available(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal));
    assert(!Available(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput));
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == kAudioHardwareNotRunningError);
    AudioObjectPropertyAddress property = Property(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    UInt32 size = 1;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, owner, &property, 0, NULL, &size) == noErr && !size);
    AudioObjectID unusedObject;
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL, 0, &size, &unusedObject) == noErr);
    AudioServerPlugInCustomPropertyInfo custom[4];
    Get(kObjectID_Device, owner, kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal,
        sizeof(custom), custom);
    assert(custom[0].mSelector == kAcoupletLease && custom[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(custom[1].mSelector == kAcoupletModel && custom[1].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFString);
    assert(custom[2].mSelector == kAcoupletPriority && custom[2].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(custom[3].mSelector == kAcoupletRevision && custom[3].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(!gPriorityConnection && gPriorityNotify == -1 && CFEqual(gPriorityPhase, CFSTR("idle")));
    CFStringRef initialName;
    Get(kObjectID_Device, owner, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
        sizeof(initialName), &initialName);
    assert(CFEqual(initialName, CFSTR("WF-1000XM5 LDAC")));
    CFRelease(initialName);
    CFStringRef uid;
    Get(kObjectID_Device, owner, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, sizeof(uid), &uid);
    assert(CFEqual(uid, CFSTR("dev.baglayan.Acouplet.ldac-output")));
    property = Property(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectID resolved;
    assert((*driver)->GetPropertyData(driver, kObjectID_PlugIn, owner, &property, sizeof(uid), &uid,
                                     sizeof(resolved), &size, &resolved) == noErr && resolved == kObjectID_Device);
    CFRelease(uid);
    Float32 volume;
    UInt32 mute;
    Get(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, sizeof(volume), &volume);
    Get(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, sizeof(mute), &mute);
    assert(volume == 0 && mute == 1);
    volume = 0.5625;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
               sizeof(volume), &volume) == noErr);
    Get(kObjectID_Volume_Output_Master, owner, kAudioLevelControlPropertyScalarValue,
        kAudioObjectPropertyScopeGlobal, sizeof(volume), &volume);
    assert(volume == 0.5625 && atomic_load(&volumeNotifications) == 1);
    Float32 invalid = NAN;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
               sizeof(invalid), &invalid) == kAudioHardwareIllegalOperationError);
    invalid = 1.1;
    assert(Set(kObjectID_Volume_Output_Master, owner, kAudioLevelControlPropertyScalarValue,
               kAudioObjectPropertyScopeGlobal, sizeof(invalid), &invalid) == kAudioHardwareIllegalOperationError);
    volume = kVolume_MinDB;
    assert(Set(kObjectID_Volume_Output_Master, owner, kAudioLevelControlPropertyDecibelValue,
               kAudioObjectPropertyScopeGlobal, sizeof(volume), &volume) == noErr);
    Get(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, sizeof(volume), &volume);
    assert(volume == 0 && atomic_load(&volumeNotifications) == 2);
    mute = 0;
    assert(Set(kObjectID_Mute_Output_Master, owner, kAudioBooleanControlPropertyValue,
               kAudioObjectPropertyScopeGlobal, sizeof(mute), &mute) == noErr);
    Get(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, sizeof(mute), &mute);
    assert(mute == 0 && atomic_load(&muteNotifications) == 1);
    mute = 1;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
               sizeof(mute), &mute) == noErr);
    Get(kObjectID_Mute_Output_Master, owner, kAudioBooleanControlPropertyValue,
        kAudioObjectPropertyScopeGlobal, sizeof(mute), &mute);
    assert(mute == 1 && atomic_load(&muteNotifications) == 2);
    mute = 2;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
               sizeof(mute), &mute) == kAudioHardwareIllegalOperationError);
    AudioStreamRangedDescription formats[4];
    Get(kObjectID_Stream_Output, owner, kAudioStreamPropertyAvailablePhysicalFormats,
        kAudioObjectPropertyScopeGlobal, sizeof(formats), formats);
    AudioValueRange rates[4];
    Get(kObjectID_Device, owner, kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal, sizeof(rates), rates);
    for (UInt32 i = 0; i < 4; ++i) {
        assert(formats[i].mFormat.mSampleRate == gSampleRates[i] && formats[i].mFormat.mChannelsPerFrame == 2 &&
            formats[i].mFormat.mBytesPerFrame == 8 && formats[i].mSampleRateRange.mMinimum == gSampleRates[i] &&
            formats[i].mSampleRateRange.mMaximum == gSampleRates[i]);
        assert(rates[i].mMinimum == gSampleRates[i] && rates[i].mMaximum == gSampleRates[i]);
    }
    Float64 rate = 32000;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
               kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDeviceUnsupportedFormatError);
    rate = 44100;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
               kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDevicePermissionsError);
    rate = 48000;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
               kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    CFStringRef model = CFSTR("WH-1000XM5");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioDevicePermissionsError);
    assert(Set(kObjectID_Device, owner, kAcoupletLease, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioHardwareIllegalOperationError);
    CFBooleanRef claim = kCFBooleanTrue;
    assert(Set(kObjectID_Device, 0, kAcoupletLease, kAudioObjectPropertyScopeGlobal,
               sizeof(claim), &claim) == kAudioHardwareIllegalOperationError);
    atomic_store(&rejectRequest, true);
    SetLease(owner, true);
    UInt64 failed = WaitRequest();
    assert(Lease(owner) && !Lease(owner + 1) && !AcoupletAlive());
    assert(gPendingAction == 0);
    atomic_store(&rejectRequest, false);
    RequestNow();
    UInt64 aborted = WaitRequest();
    assert(aborted != failed && !AcoupletAlive());
    assert((*driver)->AbortDeviceConfigurationChange(driver, kObjectID_Device, aborted, NULL) == noErr);
    Perform(aborted);
    UInt64 stale = WaitRequest();
    assert(!AcoupletAlive() && stale != aborted);
    assert(Set(kObjectID_Device, owner + 1, kAcoupletLease, kAudioObjectPropertyScopeGlobal,
               sizeof(claim), &claim) == kAudioDevicePermissionsError);
    CFBooleanRef release = kCFBooleanFalse;
    assert(Set(kObjectID_Device, owner + 1, kAcoupletLease, kAudioObjectPropertyScopeGlobal,
               sizeof(release), &release) == kAudioDevicePermissionsError);
    assert(Set(kObjectID_Device, owner + 1, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioDevicePermissionsError);
    model = CFSTR("");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioHardwareIllegalOperationError);
    model = CFSTR("   ");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioHardwareIllegalOperationError);
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(claim), &claim) == kAudioHardwareIllegalOperationError);
    CFMutableStringRef longModel = CFStringCreateMutable(NULL, 0);
    for (int i = 0; i < 129; ++i) CFStringAppend(longModel, CFSTR("X"));
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(longModel), &longModel) == kAudioHardwareIllegalOperationError);
    CFRelease(longModel);
    model = CFSTR(" WH-1000XM5 ");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == noErr);
    Get(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model);
    assert(CFEqual(model, CFSTR("WH-1000XM5")));
    CFRelease(model);
    Get(kObjectID_Device, owner, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof(model), &model);
    assert(CFEqual(model, CFSTR("WH-1000XM5 LDAC")));
    CFRelease(model);
    CheckIdentity(CFSTR("Headphones.png"), kAudioStreamTerminalTypeHeadphones);
    assert(atomic_load(&iconNotifications) == 1 && !atomic_load(&terminalNotifications));
    model = CFSTR("WH-1000XM5");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model) == noErr);
    assert(atomic_load(&iconNotifications) == 1 && !atomic_load(&terminalNotifications));
    model = CFSTR("WI-1000XM2");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model) == noErr);
    CheckIdentity(CFSTR("Earbuds.png"), kAudioStreamTerminalTypeHeadphones);
    assert(atomic_load(&iconNotifications) == 2 && !atomic_load(&terminalNotifications));
    model = CFSTR("MDR-XB950N1");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model) == noErr);
    CheckIdentity(CFSTR("Headphones.png"), kAudioStreamTerminalTypeHeadphones);
    assert(atomic_load(&iconNotifications) == 3 && !atomic_load(&terminalNotifications));
    model = CFSTR("SRS-ULT30");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model) == noErr);
    CheckIdentity(CFSTR("Speaker.png"), kAudioStreamTerminalTypeSpeaker);
    assert(atomic_load(&iconNotifications) == 4 && atomic_load(&terminalNotifications) == 1);
    model = CFSTR("WF-1000XM5");
    assert(Set(kObjectID_Device, owner, kAcoupletModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model) == noErr);
    CheckIdentity(CFSTR("Earbuds.png"), kAudioStreamTerminalTypeHeadphones);
    assert(atomic_load(&iconNotifications) == 5 && atomic_load(&terminalNotifications) == 2);
    SetLease(owner, false);
    SetLease(owner + 1, true);
    assert(!Lease(owner) && Lease(owner + 1));
    Perform(stale);
    UInt64 activation = WaitRequest();
    assert(!AcoupletAlive());
    Perform(stale);
    assert(!AcoupletAlive() && gPendingAction == activation);
    Perform(activation);
    assert(AcoupletAlive() && !Available(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal));
    assert(Available(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput));
    assert(Available(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput));
    pid_t rateOwner = owner + 1;
    for (UInt32 i = 0; i < 4; ++i) {
        Float64 before;
        Get(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(before), &before);
        rate = gSampleRates[i];
        UInt64 priorSeed = atomic_load(&gClockSeed);
        SetLease(rateOwner, true);
        assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDevicePermissionsError);
        assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
        UInt64 rateAction = WaitRequest();
        Float64 observed;
        Get(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(observed), &observed);
        assert(observed == before && atomic_load(&gClockSeed) == priorSeed);
        assert((*driver)->StartIO(driver, kObjectID_Device, 1) == kAudioHardwareIllegalOperationError);
        Perform(rateAction);
        Get(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(observed), &observed);
        assert(observed == rate && atomic_load(&gClockSeed) == priorSeed + 1);
        for (UInt32 selector = 0; selector < 2; ++selector) {
            AudioStreamBasicDescription format;
            Get(kObjectID_Stream_Output, rateOwner, selector ? kAudioStreamPropertyVirtualFormat : kAudioStreamPropertyPhysicalFormat,
                kAudioObjectPropertyScopeGlobal, sizeof(format), &format);
            assert(format.mSampleRate == rate && format.mReserved == 0 && format.mBytesPerFrame == 8);
        }
        Float64 ticks = atomic_load(&gClockTicksPerFrame);
        assert(fabs(ticks - gTicksPerSecond / rate) < 0.00001);
        UInt32 period = Available(kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal);
        assert(fabs(period / rate - kDevice_RingBufferSize / 48000.0) <= 1 / rate);
        atomic_store(&gClockAnchor, mach_absolute_time() - (UInt64)ceil(ticks * period * 3));
        Float64 stamp;
        UInt64 time, clockSeed;
        assert((*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1, &stamp, &time, &clockSeed) == noErr);
        assert(stamp >= 3 * period && stamp <= 4 * period &&
            time <= mach_absolute_time() && clockSeed == priorSeed + 1);
        assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
        Float64 different = rate == 96000 ? 48000 : 96000;
        assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(different), &different) == kAudioHardwareIllegalOperationError);
        assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    }
    rate = 48000;
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rateFailure = WaitRequest();
    assert((*driver)->AbortDeviceConfigurationChange(driver, kObjectID_Device, rateFailure, NULL) == noErr);
    atomic_store(&rejectRequest, true);
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rejectedRate = WaitRequest();
    assert(!gPendingRateAction && gDevice_SampleRate == 96000);
    atomic_store(&rejectRequest, false);
    Perform(rejectedRate);
    assert(gDevice_SampleRate == 96000);
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rateAbort = WaitRequest();
    assert((*driver)->AbortDeviceConfigurationChange(driver, kObjectID_Device, rateAbort, NULL) == noErr);
    Perform(rateAbort);
    assert(gDevice_SampleRate == 96000);
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rateStale = WaitRequest();
    SetLease(rateOwner, false);
    SetLease(owner, true);
    Perform(rateStale);
    assert(gDevice_SampleRate == 96000 && !gPendingRateAction);
    SetLease(owner, false);
    SetLease(rateOwner, true);
    AudioStreamBasicDescription selectedFormat = formats[1].mFormat;
    assert(Set(kObjectID_Stream_Output, rateOwner, kAudioStreamPropertyPhysicalFormat,
        kAudioObjectPropertyScopeGlobal, sizeof(selectedFormat), &selectedFormat) == noErr);
    Perform(WaitRequest());
    assert(gDevice_SampleRate == 48000);
    selectedFormat.mChannelsPerFrame = 1;
    assert(Set(kObjectID_Stream_Output, rateOwner, kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal, sizeof(selectedFormat), &selectedFormat) == kAudioDeviceUnsupportedFormatError);
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
    Float64 sampleTime;
    UInt64 hostTime, seed;
    assert((*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1, &sampleTime, &hostTime, &seed) == noErr);
    assert(isfinite(sampleTime) && hostTime > 0 && seed == atomic_load(&gClockSeed));
    Boolean willDo, inPlace;
    assert((*driver)->WillDoIOOperation(driver, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix,
                                       &willDo, &inPlace) == noErr && willDo && inPlace);
    pthread_mutex_lock(&gPlugIn_StateMutex);
    gLeaseDeadline = mach_absolute_time() - 1;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    assert(!Lease(owner + 1) && AcoupletAlive());
    AudioServerPlugInIOCycleInfo cycle = {0};
    Float32 buffer[2] = {0};
    assert((*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Output, 1,
        kAudioServerPlugInIOOperationWriteMix, 0, &cycle, buffer, NULL) == noErr);
    model = CFSTR("WH-1000XM5");
    assert(Set(kObjectID_Device, owner + 1, kAcoupletModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioDevicePermissionsError);
    RequestNow();
    UInt64 withdrawal = WaitRequest();
    assert(AcoupletAlive());
    SetLease(owner, true);
    Perform(withdrawal);
    assert(AcoupletAlive() && Lease(owner));
    assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    UInt64 expired = WaitRequest();
    assert(!Lease(owner) && AcoupletAlive());
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
    assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    Perform(expired);
    assert(!AcoupletAlive() && Available(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal));
    assert(atomic_load(&timerWakeups) > 0);
    CheckIdleTimer();
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == kAudioHardwareNotRunningError);
    SetLease(owner, true);
    Perform(WaitRequest());
    assert(AcoupletAlive());
    CheckPriority();
    SetLease(owner, false);
    withdrawal = WaitRequest();
    assert(AcoupletAlive() && !Lease(owner));
    Perform(withdrawal);
    assert(!AcoupletAlive());
    CheckIdleTimer();
    SetLease(owner, true);
    assert(SetPriority(owner, CFSTR("AA:BB:CC:DD:EE:FF"), true, false) == noErr);
    PriorityPublication("host-release", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    assert((*driver)->Release(driver) == 0);
    assert(gLeaseTimer == NULL && gLeaseQueue == NULL && gModel == NULL);
    assert(CFEqual(gPriorityPhase, CFSTR("cleanup-required")) && gPriorityError &&
        !gPriorityConnection && gPriorityNotify == -1 && !gOwnerWatcher && gPriorityCheckStatus == 1);
    dispatch_release(requested);
    printf("HAL_TIMER_CHECK passed: zero idle timer callbacks across four 600 ms windows; %u active timer callbacks; lease expiry, priority deadline and owner-exit cleanup retained.\n", atomic_load(&timerWakeups));
    puts("HAL_CALLBACK_CHECK passed: resource-bundle capacity/canary, activation/withdrawal, request failure, abort, stale generations, timer expiry, PID ownership, model identity, volume/mute, native rates and clocks; empty-bootstrap observing, explicit enable, publication replacement, passive owner loss, priority validation, opaque UID, notification ordering, deferred stop, disconnect-only removal with retained observer, deadline and owner-exit cleanup; no live XPC or Bluetooth.");
    return 0;
}
