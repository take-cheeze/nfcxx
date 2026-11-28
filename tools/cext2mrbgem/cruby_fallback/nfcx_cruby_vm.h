/* Prototype (opt-in, --cruby-fallback): an embedded CRuby VM that runs the original CRuby extension for a refused method.
 * This header has no mruby or CRuby types, so it can be included from either side. Values cross as Marshal bytes: each
 * argument is Marshal.dump of the value, and the result is Marshal.dump of the result. */
#ifndef NFCX_CRUBY_VM_H
#define NFCX_CRUBY_VM_H

#include <stddef.h>

/* Boots the embedded VM once and requires the original extension at so_path (an absolute path to its .so). Returns 0 on
 * success; on failure returns nonzero and fills err (NUL-terminated, at most errlen bytes). */
int nfcx_cruby_boot(const char *so_path, char *err, size_t errlen);

/* Calls recv_path.meth(*args) in the embedded VM, where recv_path is a constant path such as "CF" or "Foo::Bar". arg_data[i]
 * (arg_len[i] bytes) is Marshal.dump of argument i. On success the Marshal.dump of the result is copied into ret_buf
 * (capacity ret_cap; *ret_len is its length) and 0 is returned. On a Ruby exception, a Marshal error or a too-small ret_buf,
 * returns nonzero and fills err. */
int nfcx_cruby_call(const char *recv_path, const char *meth, int argc, const char *const *arg_data, const size_t *arg_len,
                    char *ret_buf, size_t ret_cap, size_t *ret_len, char *err, size_t errlen);

#endif
