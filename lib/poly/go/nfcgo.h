/* libnfcgo: the Go interpreter (yaegi) of nfcpoly's Go backend, as a C shared library. lib/poly/nfcpoly_go.cpp is its only
 * client; the wire format of the messages is described in lib/poly/go/codec.go. The functions are exported by main.go
 * (cgo); scripts/setup-poly-go.sh checks that they match the header cgo generates. This header is written by hand
 * because cgo's own mentions _Complex and its own string type.
 *
 * Threads: a function of this library must be called from the thread that owns the interpreter (one thread per
 * interpreter at a time). While nfcgo_do runs, the library calls the host function set by nfcgo_set_host on the same
 * thread, with the interpreter's id. A script's own goroutines run on other threads and are refused by the Go side
 * before they reach the host function; the host function refuses a call from a thread it did not enter on, too.
 * Neither side lets an exception or a Go panic cross the boundary.
 */
#ifndef NFCGO_H
#define NFCGO_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The function the library calls to run host code: INTERP the interpreter, OP the operation (1: call a bound
 * function), IN/N the request. The reply is malloc'ed by the host (OUT, OUTN point to the pointer and the length) and freed by the library. Returns a
 * status (see interp.go, "What the host answers"). */
typedef int (*nfcgo_host_fn)(long long interp, int op, const char* in, size_t n, char** out, size_t* outn);

void nfcgo_set_host(void* fn);
long long nfcgo_open(void);   /* a new interpreter; 0 when it cannot be started */
void nfcgo_close(long long id);

/* One operation (interp.go: opEval, opDecl, ...) on interpreter ID. MSG/N is the request. The reply is malloc'ed (OUT and
 * OUTN receive the pointer and the length; the caller frees it). Returns the status. */
int nfcgo_do(long long id, int op, char* msg, size_t n, char** out, size_t* outn);

#ifdef __cplusplus
}
#endif

#endif
