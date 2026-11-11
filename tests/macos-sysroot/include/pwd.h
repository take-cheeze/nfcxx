/*
 * pwd.h for the clean-room macOS sysroot. getpwnam and struct passwd are POSIX.1-2008; the field order is the BSD one
 * (pw_change and pw_expire are time_t), as the assumption here, checked by the Mac run (File.expand_path with ~).
 * Not Apple's header.
 */
#ifndef _PWD_H_
#define _PWD_H_

#include <sys/types.h>
#include <time.h>

struct passwd {
  char *pw_name;
  char *pw_passwd;
  uid_t pw_uid;
  gid_t pw_gid;
  time_t pw_change;
  char *pw_class;
  char *pw_gecos;
  char *pw_dir;
  char *pw_shell;
  time_t pw_expire;
};

struct passwd *getpwnam(const char *name);
struct passwd *getpwuid(uid_t uid);

#endif /* _PWD_H_ */
