// EXPECT: 0
// __atomic_thread_fence / __atomic_signal_fence (libstdc++ shared_ptr): cproc has no fences, so scripts/qbe-prep
// calls a weak barrier stub from the assembly tail (mfence on x86-64, dmb ish on arm64).
static int g_val = 5;
int main() {
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  __atomic_signal_fence(__ATOMIC_SEQ_CST);
  __atomic_thread_fence(__ATOMIC_ACQUIRE);
  g_val = 6;
  __atomic_thread_fence(__ATOMIC_RELEASE);
  return g_val == 6 ? 0 : 1;
}
