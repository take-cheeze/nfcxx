/* Synchronous Ruby operations on libuv. NULL callbacks complete before returning, so no Ruby stack/GC pointer escapes.
 * Every filesystem request is cleaned on success and failure. No event loop or worker callback owns a Ruby value. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "mrbrt_uv.h"
#include <uv.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>

int mrbbc_uv_open(const char *path, int writing) {
  uv_fs_t req;
  int flags = writing ? O_WRONLY | O_CREAT | O_TRUNC : O_RDONLY;
  int result = uv_fs_open(NULL, &req, path, flags, 0666, NULL);
  uv_fs_req_cleanup(&req);
  return result;
}

int mrbbc_uv_close(int fd) {
  uv_fs_t req;
  int result = uv_fs_close(NULL, &req, fd, NULL);
  uv_fs_req_cleanup(&req);
  return result;
}

long mrbbc_uv_read(int fd, char *data, unsigned int size) {
  uv_fs_t req;
  uv_buf_t buf = uv_buf_init(data, size);
  long result = (long)uv_fs_read(NULL, &req, fd, &buf, 1, -1, NULL);
  uv_fs_req_cleanup(&req);
  return result;
}

long mrbbc_uv_write(int fd, const char *data, unsigned int size) {
  uv_fs_t req;
  uv_buf_t buf = uv_buf_init((char *)data, size);
  long result = (long)uv_fs_write(NULL, &req, fd, &buf, 1, -1, NULL);
  uv_fs_req_cleanup(&req);
  return result;
}

int mrbbc_uv_test(const char *path, const char *method) {
  uv_fs_t req;
  int result;
  if (strcmp(method, "executable?") == 0) {
    result = uv_fs_access(NULL, &req, path, 1 /* X_OK */, NULL);
    uv_fs_req_cleanup(&req);
    return result == 0;
  }
  result = uv_fs_stat(NULL, &req, path, NULL);
  if (result == 0) {
    if (strcmp(method, "file?") == 0) result = S_ISREG(req.statbuf.st_mode) ? 1 : 0;
    else if (strcmp(method, "directory?") == 0) result = S_ISDIR(req.statbuf.st_mode) ? 1 : 0;
    else result = 1;
  } else result = 0;
  uv_fs_req_cleanup(&req);
  return result;
}

const char *mrbbc_uv_error(int code) { return uv_strerror(code); }
const char *mrbbc_uv_error_name(int code) { return uv_err_name(code); }
