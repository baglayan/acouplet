#include <stdbool.h>
#include <stdint.h>

void *native_banner_init(void *function, void *metadata);
bool native_banner_present(void *function, const void *content, void *metadata, void *witness, void *presenter);
void native_banner_make_view(void *function, void *result, intptr_t kind, void *presenter);
bool native_banner_is_presenting(void *function, void *metadata, void *witness, void *presenter);
void native_banner_set_host(void *function, void *host, void *witness, void *presenter);
bool native_banner_dismiss(void *function, bool animated, void *presenter);
void native_glass_get(void *function, void *result);
void native_glass_mix(void *function, void *result, const void *identity, double fraction, const void *glass);
void native_glass_explicit(void *function, void *result, const void *glass);
