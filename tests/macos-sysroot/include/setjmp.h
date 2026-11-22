/* Clean-room minimal <setjmp.h> for macOS arm64 compile checks (C11 7.13). The jmp_buf size is a placeholder that is
 * NOT checked against Darwin's buffer; do not use it for ABI checks. Compile checks only. */
#ifndef CLEANROOM_SETJMP_H
#define CLEANROOM_SETJMP_H
#ifdef __cplusplus
extern "C" {
#endif

typedef int jmp_buf[48];
typedef int sigjmp_buf[49];
int setjmp(jmp_buf);
void longjmp(jmp_buf, int) __attribute__((__noreturn__));
int _setjmp(jmp_buf);
void _longjmp(jmp_buf, int) __attribute__((__noreturn__));
int sigsetjmp(sigjmp_buf, int);
void siglongjmp(sigjmp_buf, int) __attribute__((__noreturn__));
#ifdef __cplusplus
}
#endif

#endif
