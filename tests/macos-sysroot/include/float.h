/* float.h: the C11 characteristics of floating types (5.2.4.2.2), for the clean-room sysroot. Written from the C11
 * standard. On this target long double is 64-bit (the same format as double; see docs/notes/cross-macos.md), so its
 * values are the double values. No SDK header was read. */
#ifndef NFCXX_CLEANROOM_FLOAT_H
#define NFCXX_CLEANROOM_FLOAT_H

#define FLT_RADIX 2
#define FLT_MANT_DIG 24
#define FLT_DIG 6
#define FLT_MIN_EXP (-125)
#define FLT_MIN_10_EXP (-37)
#define FLT_MAX_EXP 128
#define FLT_MAX_10_EXP 38
#define FLT_MAX 3.40282346638528859812e+38F
#define FLT_EPSILON 1.19209289550781250000e-7F
#define FLT_MIN 1.17549435082228750797e-38F
#define FLT_TRUE_MIN 1.40129846432481707092e-45F
#define FLT_DECIMAL_DIG 9
#define FLT_EVAL_METHOD 0
#define FLT_ROUNDS 1

#define DBL_MANT_DIG 53
#define DBL_DIG 15
#define DBL_MIN_EXP (-1021)
#define DBL_MIN_10_EXP (-307)
#define DBL_MAX_EXP 1024
#define DBL_MAX_10_EXP 308
#define DBL_MAX 1.7976931348623157e+308
#define DBL_EPSILON 2.2204460492503131e-16
#define DBL_MIN 2.2250738585072014e-308
#define DBL_TRUE_MIN 4.9406564584124654e-324
#define DBL_DECIMAL_DIG 17

#define LDBL_MANT_DIG 53
#define LDBL_DIG 15
#define LDBL_MIN_EXP (-1021)
#define LDBL_MIN_10_EXP (-307)
#define LDBL_MAX_EXP 1024
#define LDBL_MAX_10_EXP 308
#define LDBL_MAX 1.7976931348623157e+308L
#define LDBL_EPSILON 2.2204460492503131e-16L
#define LDBL_MIN 2.2250738585072014e-308L
#define LDBL_TRUE_MIN 4.9406564584124654e-324L
#define LDBL_DECIMAL_DIG 17

#endif /* NFCXX_CLEANROOM_FLOAT_H */
