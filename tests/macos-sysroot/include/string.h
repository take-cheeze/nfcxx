/* Clean-room minimal <string.h> for macOS arm64 compile checks (C11 7.24, POSIX). Compile checks only. */
#ifndef CLEANROOM_STRING_H
#define CLEANROOM_STRING_H
/* C++ has no restrict keyword: map it to __restrict here (compile checks only). */
#if defined(__cplusplus)
#define restrict __restrict
#endif
#include <stddef.h>

void *memcpy(void *restrict, const void *restrict, size_t);
void *memmove(void *, const void *, size_t);
char *strcpy(char *restrict, const char *restrict);
char *strncpy(char *restrict, const char *restrict, size_t);
char *strcat(char *restrict, const char *restrict);
char *strncat(char *restrict, const char *restrict, size_t);
int memcmp(const void *, const void *, size_t);
int strcmp(const char *, const char *);
int strcoll(const char *, const char *);
int strncmp(const char *, const char *, size_t);
size_t strxfrm(char *restrict, const char *restrict, size_t);
void *memchr(const void *, int, size_t);
char *strchr(const char *, int);
size_t strcspn(const char *, const char *);
char *strpbrk(const char *, const char *);
char *strrchr(const char *, int);
size_t strspn(const char *, const char *);
char *strstr(const char *, const char *);
char *strtok(char *restrict, const char *restrict);
void *memset(void *, int, size_t);
char *strerror(int);
size_t strlen(const char *);
char *strdup(const char *);
char *strndup(const char *, size_t);
size_t strnlen(const char *, size_t);
#endif
