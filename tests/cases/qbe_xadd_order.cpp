// EXPECT: 0
// X86-ONLY: the locked xadd (QBE's amd64 op) is the case: other targets use their own atomics, and clang for hexagon has no __atomic_fetch_add_4 declaration.
// __atomic_fetch_add/sub as a locked xadd (QBE's xadd op) must not reorder with the loads of the same global: a
// load after __atomic_fetch_sub reads the value the subtraction stored. QBE pins xadd and stops load forwarding
// at it (3rd/qbe, nfcxx-xadd-order): before that, the second load reused the value from before the xadd.
int g4 = 5;
long g8 = 1;
int main() {
    int old = __atomic_fetch_add(&g4, 3, __ATOMIC_SEQ_CST);   /* old 5, now 8 */
    if (old != 5) return 1;
    if (g4 != 8) return 2;
    old = __atomic_fetch_sub(&g4, 4, __ATOMIC_SEQ_CST);       /* old 8, now 4 */
    if (old != 8) return 3;
    if (g4 != 4) return 4;
    long o8 = __atomic_fetch_add(&g8, 41, __ATOMIC_SEQ_CST);  /* old 1, now 42 */
    if (o8 != 1) return 5;
    if (g8 != 42) return 6;
    return 0;
}
