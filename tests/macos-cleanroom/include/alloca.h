/* Clean-room minimal <alloca.h> for macOS arm64 compile checks. Compile checks only. */
#ifndef CLEANROOM_ALLOCA_H
#define CLEANROOM_ALLOCA_H
#include <stddef.h>
void *alloca(size_t);
#endif
