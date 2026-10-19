/*
 * wctype.h for the clean-room macOS sysroot, written from POSIX.1-2008 <wctype.h>: wint_t and the wide-character
 * classification functions the libc++ sources call (iswupper, iswspace, iswprint).
 */
#ifndef NFCXX_CLEANROOM_WCTYPE_H
#define NFCXX_CLEANROOM_WCTYPE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef CLEANROOM_WINT_T
#define CLEANROOM_WINT_T
typedef int32_t wint_t;
#endif

int iswupper(wint_t);
int iswspace(wint_t);
int iswprint(wint_t);

#ifdef __cplusplus
}
#endif

#endif /* NFCXX_CLEANROOM_WCTYPE_H */
