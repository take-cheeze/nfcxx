/* Clean-room minimal <stdio.h> for macOS arm64 compile checks. Written from the C11 standard (7.21) and POSIX;
 * the stream objects use Darwin's public libc convention (__stdinp and friends). Compile checks only. */
#ifndef CLEANROOM_STDIO_H
#define CLEANROOM_STDIO_H
#ifdef __cplusplus
extern "C" {
#endif

/* C++ has no restrict keyword: map it to __restrict here (compile checks only). */
#if defined(__cplusplus)
#define restrict __restrict
#endif
#include <stddef.h>
#include <stdarg.h>

typedef struct __sFILE FILE;
typedef long fpos_t;
typedef long long off_t;

#define BUFSIZ 1024
#define EOF (-1)
#define FOPEN_MAX 20
#define FILENAME_MAX 1024
#define L_tmpnam 1024
#define TMP_MAX 308915776
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

extern FILE *__stdinp;
extern FILE *__stdoutp;
extern FILE *__stderrp;
#define stdin __stdinp
#define stdout __stdoutp
#define stderr __stderrp

int remove(const char *);
int rename(const char *, const char *);
FILE *tmpfile(void);
char *tmpnam(char *);
int fclose(FILE *);
int fflush(FILE *);
FILE *fopen(const char *restrict, const char *restrict);
FILE *fdopen(int, const char *);  /* POSIX.1-2008 <stdio.h> */
FILE *freopen(const char *restrict, const char *restrict, FILE *restrict);
void setbuf(FILE *restrict, char *restrict);
int setvbuf(FILE *restrict, char *restrict, int, size_t);
int fprintf(FILE *restrict, const char *restrict, ...);
int fscanf(FILE *restrict, const char *restrict, ...);
int printf(const char *restrict, ...);
int scanf(const char *restrict, ...);
int snprintf(char *restrict, size_t, const char *restrict, ...);
int sprintf(char *restrict, const char *restrict, ...);
int sscanf(const char *restrict, const char *restrict, ...);
int vfprintf(FILE *restrict, const char *restrict, va_list);
int vprintf(const char *restrict, va_list);
int vsnprintf(char *restrict, size_t, const char *restrict, va_list);
int vsprintf(char *restrict, const char *restrict, va_list);
int vsscanf(const char *restrict, const char *restrict, va_list);
int fgetc(FILE *);
char *fgets(char *restrict, int, FILE *restrict);
int fputc(int, FILE *);
int fputs(const char *restrict, FILE *restrict);
int getc(FILE *);
int getchar(void);
char *gets(char *);
int putc(int, FILE *);
int putchar(int);
int puts(const char *);
int ungetc(int, FILE *);
size_t fread(void *restrict, size_t, size_t, FILE *restrict);
size_t fwrite(const void *restrict, size_t, size_t, FILE *restrict);
int fgetpos(FILE *restrict, fpos_t *restrict);
int fseek(FILE *, long, int);
int fseeko(FILE *, off_t, int);
off_t ftello(FILE *);
int fsetpos(FILE *, const fpos_t *);
long ftell(FILE *);
void rewind(FILE *);
void clearerr(FILE *);
int feof(FILE *);
int ferror(FILE *);
void perror(const char *);
int getc_unlocked(FILE *);
int putc_unlocked(int, FILE *);
int fileno(FILE *);
#ifdef __cplusplus
}
#endif

#endif
