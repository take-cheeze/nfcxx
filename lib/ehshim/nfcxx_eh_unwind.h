/* nfcxx: declarations for the gcc back end's throws that run cleanups in the system unwinder (NFCXX_EH_UNWIND=1).
   The generated C (EDG with --nfcxx_eh_unwind) attaches __nfcxx_eh_frame_unwind as the cleanup of each function's EH
   stack frame; lib_src/throw.c defines it and the weak flag below tells the runtime that the program was compiled so. */
#ifndef NFCXX_EH_UNWIND_H
#define NFCXX_EH_UNWIND_H

extern void __nfcxx_eh_frame_unwind(void *frame);
int __nfcxx_eh_unwind_frames __attribute__((weak)) = 1;

#endif
