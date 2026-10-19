// Structs and unions by value with integer members only, for the CPU check of run_interp.sh (the PTX interpreter has no
// floating point): a struct parameter is a .param array of its bytes, a struct result is the func_retval0 array, a
// struct argument of a call is copied into the callee's array, and a union is passed like a struct. The same convention
// as struct_abi.cpp, which the GPU check runs.
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);

struct P8 { int a; int b; };                 // 8 bytes, alignment 4
struct M12 { int a; short b; char c; int d; };  // 12 bytes, alignment 4, mixed fields
union U { int i; unsigned u; };              // 4 bytes

extern "C" int sum_p8(P8 p) { return p.a + p.b; }
extern "C" P8 mk_p8(int a, int b) { P8 r; r.a = a; r.b = b; return r; }
extern "C" int sum_m12(M12 m) { return m.a + m.b + m.c + m.d; }
extern "C" M12 bump_m12(M12 m) { m.a += 1; m.d *= 2; return m; }
extern "C" int u_read(U u) { return u.i; }

extern "C" void struct_kernel(int *out, int n, P8 p, U u, M12 m) {
  int i = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();
  if (i < n) {
    P8 q = mk_p8(p.a + i, p.b);
    M12 mi = m;
    mi.a += i;
    M12 bm = bump_m12(mi);
    out[i] = sum_p8(q) + u_read(u) + sum_m12(bm);
  }
}
