/* The libuv boundary uses only bytes, descriptors and error codes; it does not own Ruby values or GC roots. */
#ifndef MRBBC_MRBRT_UV_H
#define MRBBC_MRBRT_UV_H
#include <stddef.h>
int mrbbc_uv_open(const char *path, int writing);
int mrbbc_uv_close(int fd);
long mrbbc_uv_read(int fd, char *data, unsigned int size);
long mrbbc_uv_write(int fd, const char *data, unsigned int size);
int mrbbc_uv_test(const char *path, const char *method);
const char *mrbbc_uv_error(int code);
const char *mrbbc_uv_error_name(int code);
#endif
