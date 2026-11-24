/* Clean-room minimal <limits.h> for macOS arm64 compile checks (C11 5.2.4.2, LP64). Compile checks only. */
#ifndef CLEANROOM_LIMITS_H
#define CLEANROOM_LIMITS_H
#ifdef __cplusplus
extern "C" {
#endif

#define CHAR_BIT 8
#define SCHAR_MIN (-128)
#define SCHAR_MAX 127
#define UCHAR_MAX 255
#define CHAR_MIN (-128)
#define CHAR_MAX 127
#define MB_LEN_MAX 6
#define SHRT_MIN (-32768)
#define SHRT_MAX 32767
#define USHRT_MAX 65535
#define INT_MIN (-2147483647-1)
#define INT_MAX 2147483647
#define UINT_MAX 4294967295U
#define LONG_MIN (-9223372036854775807L-1)
#define LONG_MAX 9223372036854775807L
#define ULONG_MAX 18446744073709551615UL
#define LLONG_MIN (-9223372036854775807LL-1)
#define LLONG_MAX 9223372036854775807LL
#define ULLONG_MAX 18446744073709551615ULL
#ifdef __cplusplus
}
#endif

/* PATH_MAX is the BSD value on macOS (1024), an assumption checked by the Mac run. */
#define PATH_MAX 1024
#endif
