// EXPECT: 42
// ELF-ONLY: weak definitions overridden at link time are ELF behaviour here
// GCC: weak_override_gcc_def.c
// A weak function defined here and called here is not inlined (another object's strong definition overrides it: the kernel's
// `__weak sched_clock` and `__weak __iowrite32_copy`), and a weak definition nothing refers to is still emitted, weak.
__attribute__((weak)) int overridden(void) { return 1; }
__attribute__((weak)) int kept(void) { return 5; }
int main(void) {
	return overridden() + kept();
}
