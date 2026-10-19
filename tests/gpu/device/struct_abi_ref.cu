// nvcc's reference for struct_abi.cpp: the same structs, functions and kernel, written for nvcc (__device__ __noinline__
// functions, threadIdx and blockIdx). run_struct_abi.sh compares the ABI-visible parts of its PTX with the PTX of
// struct_abi.cpp, and runs its cubin beside the nfcxx one.
struct P8 { int a; int b; };
struct M12 { int a; short b; char c; float d; };
struct alignas(16) V16 { float x, y, z, w; };
union U { int i; float f; };
struct Outer { P8 p; float f; };
struct E {};

extern "C" __device__ __noinline__ int sum_p8(P8 p) { return p.a + p.b; }
extern "C" __device__ __noinline__ P8 mk_p8(int a, int b) { P8 r; r.a = a; r.b = b; return r; }
extern "C" __device__ __noinline__ int sum_m12(M12 m) { return m.a + m.b + m.c + (int)m.d; }
extern "C" __device__ __noinline__ M12 bump_m12(M12 m) { m.a += 1; m.d *= 2.0f; return m; }
extern "C" __device__ __noinline__ float sum_v16(V16 v) { return v.x + v.y + v.z + v.w; }
extern "C" __device__ __noinline__ V16 scale_v16(V16 v, float s) { V16 r; r.x = v.x * s; r.y = v.y * s; r.z = v.z * s; r.w = v.w * s; return r; }
extern "C" __device__ __noinline__ int u_read(U u) { return u.i; }
extern "C" __device__ __noinline__ int nest_outer(Outer o) { return o.p.a + o.p.b + (int)o.f; }
extern "C" __device__ __noinline__ int empty_arg(E e, int k) { return k; }

extern "C" __global__ void struct_kernel(int *out, int n, P8 p, U u, V16 v, M12 m) {
  int i = (int)threadIdx.x + (int)blockIdx.x * (int)blockDim.x;
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
