/* Clean-room minimal <stdlib.h> for macOS arm64 compile checks. Written from the C11 standard (7.22) and POSIX.
 * Compile checks only. */
#ifndef CLEANROOM_STDLIB_H
#define CLEANROOM_STDLIB_H
#include <stddef.h>

#define EXIT_FAILURE 1
#define EXIT_SUCCESS 0
#define RAND_MAX 0x7fffffff
#define MB_CUR_MAX 1

typedef struct { int quot; int rem; } div_t;
typedef struct { long quot; long rem; } ldiv_t;
typedef struct { long long quot; long long rem; } lldiv_t;

void *malloc(size_t);
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
void free(void *);
void *aligned_alloc(size_t, size_t);
int posix_memalign(void **, size_t, size_t);
void abort(void) __attribute__((__noreturn__));
int atexit(void (*)(void));
void exit(int) __attribute__((__noreturn__));
void _Exit(int) __attribute__((__noreturn__));
char *getenv(const char *);
int system(const char *);
int atoi(const char *);
long atol(const char *);
long long atoll(const char *);
double atof(const char *);
long strtol(const char *restrict, char **restrict, int);
long long strtoll(const char *restrict, char **restrict, int);
unsigned long strtoul(const char *restrict, char **restrict, int);
unsigned long long strtoull(const char *restrict, char **restrict, int);
float strtof(const char *restrict, char **restrict);
double strtod(const char *restrict, char **restrict);
long double strtold(const char *restrict, char **restrict);
int rand(void);
void srand(unsigned);
void *bsearch(const void *, const void *, size_t, size_t, int (*)(const void *, const void *));
void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
int abs(int);
long labs(long);
long long llabs(long long);
div_t div(int, int);
ldiv_t ldiv(long, long);
lldiv_t lldiv(long long, long long);
int mblen(const char *, size_t);
size_t mbstowcs(wchar_t *restrict, const char *restrict, size_t);
size_t wcstombs(char *restrict, const wchar_t *restrict, size_t);
#endif
