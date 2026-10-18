/* Clean-room locale extensions for the macOS sysroot (compile checks only).
 *
 * Written from the POSIX.1-2008 locale functions (newlocale, freelocale, uselocale, duplocale, the LC_*_MASK
 * categories) and the BSD *_l names that libc++'s __APPLE__ branch calls (libc++ includes <xlocale.h> there).
 * Declarations only: no behaviour, no code. It is not Apple's xlocale.h; no claim of ABI parity is made.
 */
#ifndef NFCXX_CLEANROOM_XLOCALE_H
#define NFCXX_CLEANROOM_XLOCALE_H

#include <locale.h>
#include <stddef.h>
#include <wchar.h>
#include <time.h>
#include <ctype.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __nfcxx_locale_s *locale_t;

#define LC_CTYPE_MASK    (1 << 0)
#define LC_NUMERIC_MASK  (1 << 1)
#define LC_TIME_MASK     (1 << 2)
#define LC_COLLATE_MASK  (1 << 3)
#define LC_MONETARY_MASK (1 << 4)
#define LC_MESSAGES_MASK (1 << 5)
#define LC_ALL_MASK      (LC_CTYPE_MASK | LC_NUMERIC_MASK | LC_TIME_MASK | LC_COLLATE_MASK | LC_MONETARY_MASK | LC_MESSAGES_MASK)

#define LC_GLOBAL_LOCALE ((locale_t)-1)

locale_t newlocale(int, const char *, locale_t);
void freelocale(locale_t);
locale_t uselocale(locale_t);
locale_t duplocale(locale_t);

struct lconv *localeconv_l(locale_t);
double strtod_l(const char *, char **, locale_t);
float strtof_l(const char *, char **, locale_t);
long double strtold_l(const char *, char **, locale_t);
long strtol_l(const char *, char **, int, locale_t);
long long strtoll_l(const char *, char **, int, locale_t);
unsigned long strtoul_l(const char *, char **, int, locale_t);
unsigned long long strtoull_l(const char *, char **, int, locale_t);
int strcoll_l(const char *, const char *, locale_t);
size_t strxfrm_l(char *, const char *, size_t, locale_t);
size_t strftime_l(char *, size_t, const char *, const struct tm *, locale_t);
int vsnprintf_l(char *, size_t, locale_t, const char *, va_list);
int snprintf_l(char *, size_t, locale_t, const char *, ...);
/* BSD-style scanf and printf with a locale, as libc++'s bsd_locale_defaults.h calls them (its signature for asprintf_l is
   the one in libc++'s locale_win32.h). Declarations only. */
int sscanf_l(const char *, locale_t, const char *, ...);
int asprintf_l(char **, locale_t, const char *, ...);
int toupper_l(int, locale_t);
int tolower_l(int, locale_t);
int isalnum_l(int, locale_t);
int isalpha_l(int, locale_t);
int isblank_l(int, locale_t);
int iscntrl_l(int, locale_t);
int isdigit_l(int, locale_t);
int isgraph_l(int, locale_t);
int islower_l(int, locale_t);
int isprint_l(int, locale_t);
int ispunct_l(int, locale_t);
int isspace_l(int, locale_t);
int isupper_l(int, locale_t);
int isxdigit_l(int, locale_t);

#ifdef __cplusplus
}
#endif

#endif
