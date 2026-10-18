/* <sys/sysctl.h>: the sysctl call only. The process-information structures are deliberately not declared here:
 * their layout is not in any public standard, so this header does not supply it. */
#ifndef NFCXX_CLEANROOM_SYSCTL_H
#define NFCXX_CLEANROOM_SYSCTL_H
#include <sys/types.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int sysctl(int *, unsigned int, void *, size_t *, void *, size_t);
#ifdef __cplusplus
}
#endif
#endif
