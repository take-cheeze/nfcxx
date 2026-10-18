/* mach-o/dyld.h for the clean-room sysroot: only the declaration libunwind calls, written from the public description of
   _dyld_register_func_for_remove_image (dyld(3) and the open dyld sources' signature). Not read from any SDK. */
#ifndef NFCXX_CLEANROOM_MACHO_DYLD_H
#define NFCXX_CLEANROOM_MACHO_DYLD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct mach_header;

void _dyld_register_func_for_remove_image(void (*func)(const struct mach_header *mh, intptr_t vmaddr_slide));

#ifdef __cplusplus
}
#endif

#endif /* NFCXX_CLEANROOM_MACHO_DYLD_H */
