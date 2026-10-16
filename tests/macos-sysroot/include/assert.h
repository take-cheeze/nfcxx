/* Clean-room assert.h: the assert macro from C11 7.2. Written from the standard, not from any SDK.
 * A failed assertion calls abort() without a message, so this header needs no symbol beyond the C library. */
#ifndef CLEANROOM_ASSERT_H
#define CLEANROOM_ASSERT_H
#include <stdlib.h>

#ifdef NDEBUG
#define assert(e) ((void)0)
#else
#define assert(e) ((e) ? (void)0 : (void)abort())
#endif

#endif
