/* Clean-room minimal <ctype.h> for macOS arm64 compile checks (C11 7.4). Compile checks only. */
#ifndef CLEANROOM_CTYPE_H
#define CLEANROOM_CTYPE_H
#ifdef __cplusplus
extern "C" {
#endif

/* Character class masks: the values Apple's Libc publishes in include/_ctype.h (apple-oss-distributions/Libc, commit
 * 71bbe350ab79eef58113991d817ccc6165061a64). libc++ on Apple uses these bits with the system's rune table, so the
 * clean-room header must match them, or the inline classification macros read the wrong bits from the Mac's table. */
#ifndef NFCXX_CTYPE_MASKS
#define NFCXX_CTYPE_MASKS
typedef unsigned int __uint32_t;
#define _CTYPE_A 0x00000100L
#define _CTYPE_C 0x00000200L
#define _CTYPE_D 0x00000400L
#define _CTYPE_G 0x00000800L
#define _CTYPE_L 0x00001000L
#define _CTYPE_P 0x00002000L
#define _CTYPE_S 0x00004000L
#define _CTYPE_U 0x00008000L
#define _CTYPE_X 0x00010000L
#define _CTYPE_B 0x00020000L
#define _CTYPE_R 0x00040000L
#endif

int isalnum(int);
int isalpha(int);
int isblank(int);
int iscntrl(int);
int isdigit(int);
int isgraph(int);
int islower(int);
int isprint(int);
int ispunct(int);
int isspace(int);
int isupper(int);
int isxdigit(int);
int tolower(int);
int toupper(int);
int isascii(int);
#ifdef __cplusplus
}
#endif

#endif
