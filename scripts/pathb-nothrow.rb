# Path B: the functions a module does not define that let no exception out, for the nothrow analysis of the exception
# tables (scripts/pathb-ssa-qbe.rb): a call of such a function needs no call site entry, as gcc's calls of a nothrow
# declaration have none. scripts/pathb-ir-opt.rb's NOTHROW_EXTERN (--strip-leaf-eh, the EH frames) is the same list
# with the cancellation points (that file stays one file for the bc2cpp world).
module PathbNothrow
  # libc routines that never throw (glibc declares them __THROW or __THROWNL), the atomic builtins, the process enders
  # and the deallocation functions
  EXTERN = %w[memcpy memmove memset memcmp memchr strlen strcmp strncmp strchr strrchr strstr strcpy strncpy
              malloc calloc realloc free snprintf vsnprintf getenv
              pthread_mutex_lock pthread_mutex_unlock pthread_mutex_trylock pthread_self __errno_location
              clock_gettime _setjmp setjmp _mm_pause
              abort _exit __assert_fail __assert_perror_fail __stack_chk_fail _ZSt21__glibcxx_assert_failPKciS0_S0_ _ZSt9terminatev
              _ZdlPv _ZdlPvm _ZdaPv _ZdaPvm _ZdlPvSt11align_val_t _ZdlPvmSt11align_val_t _ZdaPvSt11align_val_t
              _ZdaPvmSt11align_val_t].freeze
  # (not stdio's output routines, which pathb-ir-opt.rb lists: they are thread cancellation points, the forced unwind of
  # pthread_cancel leaves them, and a call with no call site entry would terminate it)

  def self.extern?(name) = name.start_with?("__atomic_") || EXTERN.include?(name)
end
