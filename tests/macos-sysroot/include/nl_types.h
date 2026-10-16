/* Clean-room message catalog declarations for the macOS sysroot (compile checks only).
 *
 * Written from POSIX.1-2008 <nl_types.h>: nl_catd, nl_item, NL_SETD, catopen, catgets, catclose.
 * Declarations only, no behaviour. Not Apple's header; no claim of ABI parity is made.
 */
#ifndef NFCXX_CLEANROOM_NL_TYPES_H
#define NFCXX_CLEANROOM_NL_TYPES_H

#ifdef __cplusplus
extern "C" {
#endif

typedef int nl_item;
typedef void *nl_catd;

#define NL_SETD 1

nl_catd catopen(const char *, int);
char *catgets(nl_catd, int, int, const char *);
int catclose(nl_catd);

#ifdef __cplusplus
}
#endif

#endif
