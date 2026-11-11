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
#endif
