// Structs and unions passed and returned by value, with nvcc's PTX calling convention: a struct parameter is a .param
// array of its bytes, a struct result is a .param array (func_retval0) that the caller reads back. The device side of
// run_struct_abi.sh, which checks the ABI-visible parts of this file's PTX against nvcc's PTX of struct_abi_ref.cu and
// runs both on the GPU with the structs passed from the host. The device compile has no CUDA headers: the thread
// indices are the extern "C" intrinsics, as in helper.cpp.
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);

struct P8 { int a; int b; };                       // 8 bytes, alignment 4
struct M12 { int a; short b; char c; float d; };   // 12 bytes, alignment 4, mixed fields
struct alignas(16) V16 { float x, y, z, w; };      // 16 bytes, alignment 16
union U { int i; float f; };                       // 4 bytes, alignment 4
struct Outer { P8 p; float f; };                   // a nested struct: 12 bytes, alignment 4
struct E {};                                       // an empty struct: a device function gets no argument for it

extern "C" int sum_p8(P8 p) { return p.a + p.b; }
extern "C" P8 mk_p8(int a, int b) { P8 r; r.a = a; r.b = b; return r; }
extern "C" int sum_m12(M12 m) { return m.a + m.b + m.c + (int)m.d; }
extern "C" M12 bump_m12(M12 m) { m.a += 1; m.d *= 2.0f; return m; }
extern "C" float sum_v16(V16 v) { return v.x + v.y + v.z + v.w; }
extern "C" V16 scale_v16(V16 v, float s) { V16 r; r.x = v.x * s; r.y = v.y * s; r.z = v.z * s; r.w = v.w * s; return r; }
extern "C" int u_read(U u) { return u.i; }
extern "C" int nest_outer(Outer o) { return o.p.a + o.p.b + (int)o.f; }
extern "C" int empty_arg(E e, int k) { return k; }

extern "C" void struct_kernel(int *out, int n, P8 p, U u, V16 v, M12 m) {
  int i = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();
  if (i < n) {
    P8 q = mk_p8(p.a + i, p.b);
    M12 mi = m;
    mi.a += i;
    M12 bm = bump_m12(mi);
    V16 w = scale_v16(v, (float)n);
    Outer o;
    o.p = q;
    o.f = (float)n;
    out[i] = sum_p8(q) + u_read(u) + (int)sum_v16(w) + sum_m12(bm) + nest_outer(o) + empty_arg(E{}, i);
  }
}
