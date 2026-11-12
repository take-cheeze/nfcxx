#include "union_abi.h"
__attribute__((noinline)) ui g_ui(int k, ui u, int m) { ui r; r.i = u.i * k + m; return r; }
__attribute__((noinline)) ud g_ud(ud u, double x) { ud r; r.d = u.d * x; return r; }
__attribute__((noinline)) u2d g_u2d(double x, u2d u) { u2d r; r.d[0] = u.d[0] + x; r.d[1] = u.d[1] * x; return r; }
__attribute__((noinline)) umix g_umix(long k, umix u) { umix r; r.s.a = u.s.a + k; r.s.b = u.s.b * 2; return r; }
__attribute__((noinline)) ust g_ust(ust u) { ust r; r.p.x = u.p.y; r.p.y = u.p.x; return r; }
__attribute__((noinline)) ubig g_ubig(long k, ubig u, long m) { ubig r = u; r.l = u.l * k + m; return r; }
__attribute__((noinline)) u12 g_u12(u12 u, int k) { u12 r; r.i[0] = u.i[0] + k; r.i[1] = u.i[1] + k; r.i[2] = u.i[2] + k; return r; }
__attribute__((noinline)) u12f g_u12f(u12f u, float k) { u12f r; r.f[0] = u.f[0] * k; r.f[1] = u.f[1] * k; r.f[2] = u.f[2] * k; return r; }
__attribute__((noinline)) u3 g_u3(u3 u) { u3 r; r.t.a = u.t.c; r.t.b = u.t.b; r.t.c = u.t.a; return r; }
__attribute__((noinline)) ui g_mk_ui(int k) { ui r; r.i = k; return r; }
__attribute__((noinline)) ud g_mk_ud(double x) { ud r; r.d = x; return r; }
__attribute__((noinline)) umix g_mk_umix(long a, double b) { umix r; r.s.b = a; r.s.a = b; return r; }
__attribute__((noinline)) ubig g_mk_ubig(long k) { ubig r; for (int i = 0; i < 24; i++) r.c[i] = 0; r.l = k; r.c[23] = 7; return r; }
__attribute__((noinline)) u12f g_mk_u12f(float a) { u12f r; r.f[0] = a; r.f[1] = a + 1; r.f[2] = a + 2; return r; }
/* the gcc side calls the backend's functions, and through a function pointer */
int g_calls_p(void) {
	ui (*fp)(int, ui, int) = p_ui; ui a; a.i = 5;
	if (fp(3, a, 1).i != 16) return 1;
	ud b; b.d = 2.5; if (p_ud(b, 4.0).d != 10.0) return 2;
	u2d c; c.d[0] = 1.5; c.d[1] = 3.0; u2d rc = p_u2d(2.0, c); if (rc.d[0] != 3.5 || rc.d[1] != 6.0) return 3;
	umix d; d.s.a = 1.5; d.s.b = 9; umix rd = p_umix(10, d); if (rd.s.a != 11.5 || rd.s.b != 18) return 4;
	ust e; e.p.x = 1; e.p.y = 2; ust re = p_ust(e); if (re.p.x != 2 || re.p.y != 1) return 5;
	ubig f; for (int i = 0; i < 24; i++) f.c[i] = 0; f.l = 6; f.c[23] = 7; ubig rf = p_ubig(4, f, 1); if (rf.l != 25 || rf.c[23] != 7) return 6;
	u12 g; g.i[0] = 1; g.i[1] = 2; g.i[2] = 3; u12 rg = p_u12(g, 10); if (rg.i[0] != 11 || rg.i[1] != 12 || rg.i[2] != 13) return 7;
	u12f h; h.f[0] = 1; h.f[1] = 2; h.f[2] = 3; u12f rh = p_u12f(h, 2); if (rh.f[0] != 2 || rh.f[1] != 4 || rh.f[2] != 6) return 8;
	u3 i; i.t.a = 1; i.t.b = 2; i.t.c = 3; u3 ri = p_u3(i); if (ri.t.a != 3 || ri.t.b != 2 || ri.t.c != 1) return 9;
	return 0;
}
