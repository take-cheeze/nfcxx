/* stddef.h: the C11 definitions of section 7.19 (size_t, ptrdiff_t, wchar_t, NULL, offsetof), for the clean-room sysroot.
 * Written from the C11 standard. The LP64 arm64 widths are the ones the standard permits for this target; no SDK header
 * was read. Used by the cross compile path, where nfcxx's front end runs without clang's resource headers. */
#ifndef NFCXX_CLEANROOM_STDDEF_H
#define NFCXX_CLEANROOM_STDDEF_H

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long size_t;
typedef long ptrdiff_t;
/* C11 7.19p2: a type whose alignment is the greatest fundamental alignment; built from the fundamental types */
typedef struct { long long __ll; long double __ld; } max_align_t;
#ifndef __cplusplus
typedef int wchar_t; /* a keyword in C++ */
#endif

#ifndef NULL
#ifdef __cplusplus
#define NULL 0
#else
#define NULL ((void *)0)
#endif
#endif

#define offsetof(type, member) ((size_t)&(((type *)0)->member))

#ifdef __cplusplus
}
#endif

#endif /* NFCXX_CLEANROOM_STDDEF_H */
