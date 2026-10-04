#include "NativeHUDABI.h"

typedef void * __attribute__((swiftcall)) (*InitFunction)(void * __attribute__((swift_context)));
typedef bool __attribute__((swiftcall)) (*PresentFunction)(const void *, void *, void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*MakeViewFunction)(void * __attribute__((swift_indirect_result)), intptr_t, void * __attribute__((swift_context)));
typedef bool __attribute__((swiftcall)) (*IsPresentingFunction)(void *, void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*HostSetter)(void *, void *, void * __attribute__((swift_context)));
typedef bool __attribute__((swiftcall)) (*DismissFunction)(bool, void *, void *, void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*GlassGetter)(void * __attribute__((swift_indirect_result)));
typedef void __attribute__((swiftcall)) (*GlassMixer)(void * __attribute__((swift_indirect_result)), const void *, double, const void * __attribute__((swift_context)));
typedef void __attribute__((swiftcall)) (*GlassInitializer)(void * __attribute__((swift_indirect_result)), const void *);
extern void *swift_unknownObjectRetain(void *) __attribute__((swiftcall));

void *native_banner_init(void *function, void *metadata) {
    return ((InitFunction)function)(metadata);
}

bool native_banner_present(void *function, const void *content, void *metadata, void *witness, void *presenter) {
    return ((PresentFunction)function)(content, metadata, witness, presenter);
}

void native_banner_make_view(void *function, void *result, intptr_t kind, void *presenter) {
    ((MakeViewFunction)function)(result, kind, presenter);
}

bool native_banner_is_presenting(void *function, void *metadata, void *witness, void *presenter) {
    return ((IsPresentingFunction)function)(metadata, witness, presenter);
}

void native_banner_set_host(void *function, void *host, void *witness, void *presenter) {
    ((HostSetter)function)(host ? swift_unknownObjectRetain(host) : 0, witness, presenter);
}

static void __attribute__((swiftcall)) dismissal_complete(void *context __attribute__((swift_context))) {
    (void)context;
}

bool native_banner_dismiss(void *function, bool animated, void *presenter) {
    return ((DismissFunction)function)(animated, dismissal_complete, 0, presenter);
}

void native_glass_get(void *function, void *result) {
    ((GlassGetter)function)(result);
}

void native_glass_mix(void *function, void *result, const void *identity, double fraction, const void *glass) {
    ((GlassMixer)function)(result, identity, fraction, glass);
}

void native_glass_explicit(void *function, void *result, const void *glass) {
    ((GlassInitializer)function)(result, glass);
}
