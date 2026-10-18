/*
 * sys/wait.h for the clean-room macOS sysroot. waitpid and the WNOHANG / WIFEXITED family follow POSIX.1-2008; the status
 * encoding in the macros is the BSD one (WEXITSTATUS is the high byte, WTERMSIG the low 7 bits), as the assumption here.
 * Not Apple's header.
 */
#ifndef _SYS_WAIT_H_
#define _SYS_WAIT_H_

#include <sys/types.h>

#define WNOHANG 0x00000001
#define WUNTRACED 0x00000002
#define WIFEXITED(s)   (((s) & 0x7f) == 0)
#define WEXITSTATUS(s) (((s) >> 8) & 0xff)
#define WIFSIGNALED(s) (((s) & 0x7f) != 0x7f && ((s) & 0x7f) != 0)
#define WTERMSIG(s)    ((s) & 0x7f)
#define WIFSTOPPED(s)  (((s) & 0xff) == 0x7f)
#define WSTOPSIG(s)    (((s) >> 8) & 0xff)

pid_t waitpid(pid_t pid, int *status, int options);
pid_t wait(int *status);

#endif /* _SYS_WAIT_H_ */
