/* Clean-room wchar.h: declarations from C11 7.29 (Wide character utilities). Written from the standard, not from any SDK.
 * mbstate_t is a struct chosen here (C11 only requires an object type); its size and layout are not Darwin's. */
#ifndef CLEANROOM_WCHAR_H
#define CLEANROOM_WCHAR_H
/* C++ has no restrict keyword: map it to __restrict here (compile checks only). */
#if defined(__cplusplus)
#define restrict __restrict
#endif

#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>

typedef unsigned int wint_t;

typedef struct {
  int __count;
  union {
    unsigned int __wch;
    unsigned char __wchb[4];
  } __value;
} mbstate_t;

#define WEOF ((wint_t)0xffffffffu)

struct tm;

wint_t btowc(int);
int wctob(wint_t);
int mbsinit(const mbstate_t *);
size_t mbrlen(const char *restrict, size_t, mbstate_t *restrict);
size_t mbrtowc(wchar_t *restrict, const char *restrict, size_t, mbstate_t *restrict);
size_t wcrtomb(char *restrict, wchar_t, mbstate_t *restrict);
size_t mbsrtowcs(wchar_t *restrict, const char **restrict, size_t, mbstate_t *restrict);
size_t wcsrtombs(char *restrict, const wchar_t **restrict, size_t, mbstate_t *restrict);

int fwprintf(FILE *restrict, const wchar_t *restrict, ...);
int fwscanf(FILE *restrict, const wchar_t *restrict, ...);
int swprintf(wchar_t *restrict, size_t, const wchar_t *restrict, ...);
int swscanf(const wchar_t *restrict, const wchar_t *restrict, ...);
int vfwprintf(FILE *restrict, const wchar_t *restrict, va_list);
int vfwscanf(FILE *restrict, const wchar_t *restrict, va_list);
int vswprintf(wchar_t *restrict, size_t, const wchar_t *restrict, va_list);
int vswscanf(const wchar_t *restrict, const wchar_t *restrict, va_list);
int vwprintf(const wchar_t *restrict, va_list);
int vwscanf(const wchar_t *restrict, va_list);
int wprintf(const wchar_t *restrict, ...);
int wscanf(const wchar_t *restrict, ...);

wint_t fgetwc(FILE *);
wchar_t *fgetws(wchar_t *restrict, int, FILE *restrict);
wint_t fputwc(wchar_t, FILE *);
int fputws(const wchar_t *restrict, FILE *restrict);
int fwide(FILE *, int);
wint_t getwc(FILE *);
wint_t getwchar(void);
wint_t putwc(wchar_t, FILE *);
wint_t putwchar(wchar_t);
wint_t ungetwc(wint_t, FILE *);

double wcstod(const wchar_t *restrict, wchar_t **restrict);
float wcstof(const wchar_t *restrict, wchar_t **restrict);
long double wcstold(const wchar_t *restrict, wchar_t **restrict);
long wcstol(const wchar_t *restrict, wchar_t **restrict, int);
long long wcstoll(const wchar_t *restrict, wchar_t **restrict, int);
unsigned long wcstoul(const wchar_t *restrict, wchar_t **restrict, int);
unsigned long long wcstoull(const wchar_t *restrict, wchar_t **restrict, int);

wchar_t *wcscpy(wchar_t *restrict, const wchar_t *restrict);
wchar_t *wcsncpy(wchar_t *restrict, const wchar_t *restrict, size_t);
wchar_t *wmemcpy(wchar_t *restrict, const wchar_t *restrict, size_t);
wchar_t *wmemmove(wchar_t *, const wchar_t *, size_t);
wchar_t *wcscat(wchar_t *restrict, const wchar_t *restrict);
wchar_t *wcsncat(wchar_t *restrict, const wchar_t *restrict, size_t);
int wcscmp(const wchar_t *, const wchar_t *);
int wcscoll(const wchar_t *, const wchar_t *);
int wcsncmp(const wchar_t *, const wchar_t *, size_t);
size_t wcsxfrm(wchar_t *restrict, const wchar_t *restrict, size_t);
int wmemcmp(const wchar_t *, const wchar_t *, size_t);
wchar_t *wcschr(const wchar_t *, wchar_t);
size_t wcscspn(const wchar_t *, const wchar_t *);
wchar_t *wcspbrk(const wchar_t *, const wchar_t *);
wchar_t *wcsrchr(const wchar_t *, wchar_t);
size_t wcsspn(const wchar_t *, const wchar_t *);
wchar_t *wcsstr(const wchar_t *, const wchar_t *);
wchar_t *wcstok(wchar_t *restrict, const wchar_t *restrict, wchar_t **restrict);
wchar_t *wmemchr(const wchar_t *, wchar_t, size_t);
size_t wcslen(const wchar_t *);
wchar_t *wmemset(wchar_t *, wchar_t, size_t);

size_t wcsftime(wchar_t *restrict, size_t, const wchar_t *restrict, const struct tm *restrict);

#endif
