/* nfcxx: an empty glibc features.h for Path B's hosted front end on macOS. The front end targets x86-64 Linux, so
   Apple's libc++ (__configuration/platform.h) includes <features.h> and reads __GLIBC_PREREQ, which macOS does not have.
   Found first on the include path, this file makes that include succeed, and libc++ takes its portable path
   (_LIBCPP_GLIBC_PREREQ is 0). Used only on Darwin (nfcxx). */
#ifndef NFCXX_PATHB_DARWIN_FEATURES_H
#define NFCXX_PATHB_DARWIN_FEATURES_H
#endif
