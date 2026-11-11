/*
 * sys/param.h for the clean-room macOS sysroot. MAXPATHLEN is the BSD value (1024 on macOS), an assumption checked by the
 * Mac run (path length handling). Not Apple's header.
 */
#ifndef _SYS_PARAM_H_
#define _SYS_PARAM_H_

#define MAXPATHLEN 1024
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

#endif /* _SYS_PARAM_H_ */
