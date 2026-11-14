// Clang's feature-test macros for Path B's hosted front end when the host C++ library is libc++ (macOS). EDG's g++ mode
// does not define them, and libc++'s __config evaluates them in #if (a function-like macro that is not defined is a
// call in a constant expression). All answer 0: libc++ then takes its portable fallbacks, as for a compiler without the
// feature. Pre-included by the driver for Path B when the host dialect is clang (nfcxx). Linux's libstdc++ does not use them.
#ifndef NFCXX_PATHB_CLANG_MACROS_H
#define NFCXX_PATHB_CLANG_MACROS_H
#ifndef __has_feature
#define __has_feature(x) 0
#endif
#ifndef __has_extension
#define __has_extension(x) 0
#endif
#ifndef __has_keyword
#define __has_keyword(x) 0
#endif
#ifndef __has_builtin
#define __has_builtin(x) 0
#endif
/* The built-in types clang's resource headers name (__stddef_ptrdiff_t.h, stdint, stdarg): EDG does not predefine them in
   the clang dialect, so Path B's macOS front end failed on every C file that includes stdio.h or stddef.h (LP64 types). */
#ifndef __PTRDIFF_TYPE__
#define __PTRDIFF_TYPE__ long
#endif
#ifndef __SIZE_TYPE__
#define __SIZE_TYPE__ unsigned long
#endif
#ifndef __INTPTR_TYPE__
#define __INTPTR_TYPE__ long
#endif
#ifndef __UINTPTR_TYPE__
#define __UINTPTR_TYPE__ unsigned long
#endif
#ifndef __INTMAX_TYPE__
#define __INTMAX_TYPE__ long
#endif
#ifndef __UINTMAX_TYPE__
#define __UINTMAX_TYPE__ unsigned long
#endif
#ifndef __WCHAR_TYPE__
#define __WCHAR_TYPE__ int
#endif
#ifndef __WINT_TYPE__
#define __WINT_TYPE__ int
#endif
/* clang's resource headers test a builtin module query in #if (__stddef_ptrdiff_t.h line 15): EDG has none, and it is 0 here. */
#ifndef __building_module
#define __building_module(x) 0
#endif
#endif
