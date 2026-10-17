/* Clean-room minimal <ctype.h> for macOS arm64 compile checks (C11 7.4). Compile checks only. */
#ifndef CLEANROOM_CTYPE_H
#define CLEANROOM_CTYPE_H
#ifdef __cplusplus
extern "C" {
#endif

/* Character class masks used by libc++'s __locale on __APPLE__ (the class names are libc++'s; the bit values are
 * ours, chosen to be distinct and to avoid 0x80, 0x0100 and 0x00ff, which libc++ reserves for regex). */
#ifndef NFCXX_CTYPE_MASKS
#define NFCXX_CTYPE_MASKS
typedef unsigned int __uint32_t;
#define _CTYPE_U 0x00010000
#define _CTYPE_L 0x00020000
#define _CTYPE_A 0x00040000
#define _CTYPE_D 0x00080000
#define _CTYPE_P 0x00100000
#define _CTYPE_X 0x00200000
#define _CTYPE_S 0x00400000
#define _CTYPE_R 0x00800000
#define _CTYPE_C 0x01000000
#define _CTYPE_B 0x02000000
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
