/*
nfcxx_edg_entry.c -- libclang-edg: the entry point of the EDG front end when it is linked into libclang-edg.so
instead of running as cpfe (scripts/setup-libclang-edg.sh builds it, with the front end, into libedgfe-pic.a).

The front end is built with EDG_MAIN=nfcxx_edg_main, so it is callable (MAKE_FRONT_END_CALLABLE, basics.h): EDG_MAIN
returns the exit status instead of exiting, a catastrophic error longjmps back to it, and fe_cleanup frees the
compilation's memory, so it can be called again. nfcxx_edg_run is the C entry point of lib/libclang-edg/clang_edg.c:
it runs one compilation of the command line argv, with the back end's records (be/nfcxx_decl.c) written to out.

The front end is not reentrant (its state is global): the caller serializes the calls. The front end sets handlers
for SIGINT, SIGTERM, SIGXFSZ and SIGSEGV on its first call (host_envir.c, set_signal_handlers); they belong to the
client's process, so the ones it had are put back after each call.
*/

#include "basic_hdrs.h"

#include <signal.h>
#include <stdio.h>

extern FILE *nfcxx_decl_out;   /* be/nfcxx_decl.c */

BEGIN_EDG_NAMESPACE
int EDG_MAIN(int argc, char *argv[]);
END_EDG_NAMESPACE
USING_NAMESPACE_EDG

extern "C" __attribute__((visibility("default"))) int nfcxx_edg_run(int argc, char **argv, FILE *out)
{
  static const int sigs[] = { SIGINT, SIGTERM, SIGXFSZ, SIGSEGV };
  struct sigaction saved[sizeof sigs / sizeof sigs[0]];
  unsigned i;
  int status;

  for (i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], NULL, &saved[i]);
  nfcxx_decl_out = out;
  status = EDG_MAIN(argc, argv);
  nfcxx_decl_out = NULL;
  for (i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &saved[i], NULL);
  return status;
}
