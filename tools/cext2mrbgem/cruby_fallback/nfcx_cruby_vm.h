/* Prototype (opt-in, --cruby-fallback): an embedded CRuby VM that runs the original CRuby extension for a refused method.
 * This header has no mruby or CRuby types, so it can be included from either side. Values cross as nfcx_val: nil, true,
 * false, a Fixnum-sized integer, a Float, a String and a Symbol. Other types are not converted (an error). */
#ifndef NFCX_CRUBY_VM_H
#define NFCX_CRUBY_VM_H

#include <stddef.h>

typedef enum { NFCX_NIL, NFCX_TRUE, NFCX_FALSE, NFCX_INT, NFCX_FLOAT, NFCX_STR, NFCX_SYM } nfcx_tag;

typedef struct {
  nfcx_tag tag;
  long long i;       /* NFCX_INT */
  double f;          /* NFCX_FLOAT */
  const char *s;     /* NFCX_STR, NFCX_SYM: bytes, not necessarily NUL-terminated */
  size_t len;        /* length of s */
} nfcx_val;

/* Boots the embedded VM once and requires the original extension at so_path (an absolute path to its .so). Returns 0 on
 * success; on failure returns nonzero and fills err (NUL-terminated, at most errlen bytes). */
int nfcx_cruby_boot(const char *so_path, char *err, size_t errlen);

/* Calls recv_path.meth(*argv) in the embedded VM, where recv_path is a constant path such as "CF" or "Foo::Bar". On
 * success fills *ret and returns 0. A string or symbol result is copied into ret_buf (capacity ret_cap); ret->s points
 * into it. On a Ruby exception or a conversion error returns nonzero and fills err. */
int nfcx_cruby_call(const char *recv_path, const char *meth, int argc, const nfcx_val *argv,
                    nfcx_val *ret, char *ret_buf, size_t ret_cap, char *err, size_t errlen);

#endif
