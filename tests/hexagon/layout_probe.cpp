// Layout oracle for the Hexagon target: EDG's sizes/alignments/offsets become constants in the
// generated C, and tests/hexagon/layout.sh turns each into a _Static_assert checked by clang.
// long double is left out on purpose: EDG's linux_riscv32 has 16-byte long double, Hexagon has 8
// (see docs/notes/hexagon.md).
typedef __SIZE_TYPE__ size_t;
struct A { char c; long long x; };
struct B { char c; double d; };
struct C { char c; void *p; short s; };
struct E { char c; long x; char y; };
struct F { int a; char c[5]; double d; };
struct G { unsigned short s; unsigned char b; void *p; };
struct H { int (*fp)(int); const char *name; unsigned long n; };
struct J { char c; float f; int i; };
#define OBS(name, expr) extern const unsigned long nfcxx_##name; const unsigned long nfcxx_##name = (unsigned long)(expr);
OBS(sz_A, sizeof(A)) OBS(al_A, alignof(A)) OBS(off_A_x, __builtin_offsetof(A, x))
OBS(sz_B, sizeof(B)) OBS(al_B, alignof(B)) OBS(off_B_d, __builtin_offsetof(B, d))
OBS(sz_C, sizeof(C)) OBS(al_C, alignof(C)) OBS(off_C_s, __builtin_offsetof(C, s))
OBS(sz_E, sizeof(E)) OBS(off_E_y, __builtin_offsetof(E, y))
OBS(sz_F, sizeof(F)) OBS(off_F_d, __builtin_offsetof(F, d))
OBS(sz_G, sizeof(G)) OBS(off_G_p, __builtin_offsetof(G, p))
OBS(sz_H, sizeof(H)) OBS(off_H_n, __builtin_offsetof(H, n))
OBS(sz_J, sizeof(J)) OBS(off_J_i, __builtin_offsetof(J, i))
OBS(sz_ptr, sizeof(void *)) OBS(sz_long, sizeof(long)) OBS(sz_ll, sizeof(long long))
OBS(sz_wchar, sizeof(__WCHAR_TYPE__)) OBS(sz_size_t, sizeof(size_t)) OBS(al_ll, alignof(long long)) OBS(al_dbl, alignof(double))
A nfcxx_objA; B nfcxx_objB; C nfcxx_objC; E nfcxx_objE; F nfcxx_objF; G nfcxx_objG; H nfcxx_objH; J nfcxx_objJ;
