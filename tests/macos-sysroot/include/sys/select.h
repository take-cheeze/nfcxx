/*
 * sys/select.h for the clean-room macOS sysroot. select and FD_* are POSIX.1-2008; FD_SETSIZE and the fd_set layout (an
 * array of 32-bit words) are the arm64 macOS values, stated as an assumption and checked by the Mac run (IO.select).
 * Not Apple's header.
 */
#ifndef _SYS_SELECT_H_
#define _SYS_SELECT_H_

#include <sys/time.h>
#include <stdint.h>

#define FD_SETSIZE 1024
typedef struct { int32_t fds_bits[FD_SETSIZE / 32]; } fd_set;
#define FD_ZERO(s)   do { int _i; for (_i = 0; _i < FD_SETSIZE / 32; _i++) (s)->fds_bits[_i] = 0; } while (0)
#define FD_SET(d, s) ((s)->fds_bits[(d) / 32] |= (int32_t)(1u << ((d) % 32)))
#define FD_CLR(d, s) ((s)->fds_bits[(d) / 32] &= ~(int32_t)(1u << ((d) % 32)))
#define FD_ISSET(d, s) (((s)->fds_bits[(d) / 32] >> ((d) % 32)) & 1)

int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout);

#endif /* _SYS_SELECT_H_ */
