/* stdarg.h: the C11 definitions of section 7.16 (va_list, va_start, va_arg, va_end, va_copy), for the clean-room sysroot.
 * Written from the C11 standard, mapped to the front end's __builtin_va_* builtins. No SDK header was read. */
#ifndef NFCXX_CLEANROOM_STDARG_H
#define NFCXX_CLEANROOM_STDARG_H

typedef __builtin_va_list va_list;
#define va_start(ap, parmN) __builtin_va_start(ap, parmN)
#define va_arg(ap, type) __builtin_va_arg(ap, type)
#define va_end(ap) __builtin_va_end(ap)
#define va_copy(dest, src) __builtin_va_copy(dest, src)

#endif /* NFCXX_CLEANROOM_STDARG_H */
