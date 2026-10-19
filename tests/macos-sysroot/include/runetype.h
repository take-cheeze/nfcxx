/* Clean-room _RuneLocale layout (the runetype.h struct of Apple's Libc, apple-oss-distributions/Libc commit
 * 71bbe350ab79eef58113991d817ccc6165061a64, include/runetype.h). Only the layout libc++ reads is kept: the fields
 * that the classic table and its case maps use are the same offsets as on macOS. */
#ifndef CLEANROOM_RUNETYPE_H
#define CLEANROOM_RUNETYPE_H
#include <ctype.h>
#ifdef __cplusplus
extern "C" {
#endif

#define _CACHED_RUNES (1 << 8)
#define _RUNE_MAGIC_A "RuneMagA"

typedef int __darwin_rune_t;
typedef unsigned long __darwin_size_t;

typedef struct {
  __darwin_rune_t __min;
  __darwin_rune_t __max;
  __darwin_rune_t __map;
  __uint32_t *__types;
} _RuneEntry;

typedef struct {
  int __nranges;
  _RuneEntry *__ranges;
} _RuneRange;

typedef struct {
  char __name[14];
  __uint32_t __mask;
} _RuneCharClass;

typedef struct {
  char __magic[8];
  char __encoding[32];
  __darwin_rune_t (*__sgetrune)(const char *, __darwin_size_t, char const **);
  int (*__sputrune)(__darwin_rune_t, char *, __darwin_size_t, char **);
  __darwin_rune_t __invalid_rune;
  __uint32_t __runetype[_CACHED_RUNES];
  __darwin_rune_t __maplower[_CACHED_RUNES];
  __darwin_rune_t __mapupper[_CACHED_RUNES];
  _RuneRange __runetype_ext;
  _RuneRange __maplower_ext;
  _RuneRange __mapupper_ext;
  void *__variable;
  int __variable_len;
  int __ncharclasses;
  _RuneCharClass *__charclasses;
} _RuneLocale;

extern _RuneLocale _DefaultRuneLocale;
extern _RuneLocale *_CurrentRuneLocale;

#ifdef __cplusplus
}
#endif
#endif
