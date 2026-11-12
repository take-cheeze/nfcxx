// EXPECT: 42
// GCC: union_abi_gcc.c
// unions passed and returned by value with the System V x86-64 classes, between this backend's code and gcc's
// (union_abi_gcc.c), directly and through function pointers
// X86-ONLY: the classes checked are System V x86-64's
#include "union_abi.h"
ui p_ui(int k, ui u, int m) { ui r; r.i = u.i * k + m; return r; }
ud p_ud(ud u, double x) { ud r; r.d = u.d * x; return r; }
u2d p_u2d(double x, u2d u) { u2d r; r.d[0] = u.d[0] + x; r.d[1] = u.d[1] * x; return r; }
umix p_umix(long k, umix u) { umix r; r.s.a = u.s.a + k; r.s.b = u.s.b * 2; return r; }
ust p_ust(ust u) { ust r; r.p.x = u.p.y; r.p.y = u.p.x; return r; }
ubig p_ubig(long k, ubig u, long m) { ubig r = u; r.l = u.l * k + m; return r; }
u12 p_u12(u12 u, int k) { u12 r; r.i[0] = u.i[0] + k; r.i[1] = u.i[1] + k; r.i[2] = u.i[2] + k; return r; }
u12f p_u12f(u12f u, float k) { u12f r; r.f[0] = u.f[0] * k; r.f[1] = u.f[1] * k; r.f[2] = u.f[2] * k; return r; }
u3 p_u3(u3 u) { u3 r; r.t.a = u.t.c; r.t.b = u.t.b; r.t.c = u.t.a; return r; }
int main(void) {
	/* this side calls gcc's, direct and by pointer */
	ui a = g_mk_ui(5); if (g_ui(3, a, 1).i != 16) return 1;
	ui (*fui)(int, ui, int) = g_ui; if (fui(4, a, 2).i != 22) return 2;
	ud b = g_mk_ud(2.5); if (g_ud(b, 4.0).d != 10.0) return 3;
	u2d c; c.d[0] = 1.5; c.d[1] = 3.0; u2d rc = g_u2d(2.0, c); if (rc.d[0] != 3.5 || rc.d[1] != 6.0) return 4;
	umix d = g_mk_umix(9, 1.5); umix rd = g_umix(10, d); if (rd.s.a != 11.5 || rd.s.b != 18) return 5;
	ust e; e.p.x = 1; e.p.y = 2; ust re = g_ust(e); if (re.p.x != 2 || re.p.y != 1) return 6;
	ubig f = g_mk_ubig(6); if (f.l != 6 || f.c[23] != 7) return 7;
	ubig rf = g_ubig(4, f, 1); if (rf.l != 25 || rf.c[23] != 7) return 8;
	u12 g; g.i[0] = 1; g.i[1] = 2; g.i[2] = 3; u12 rg = g_u12(g, 10); if (rg.i[0] != 11 || rg.i[1] != 12 || rg.i[2] != 13) return 9;
	u12f h = g_mk_u12f(1); u12f rh = g_u12f(h, 2); if (rh.f[0] != 2 || rh.f[1] != 4 || rh.f[2] != 6) return 10;
	u3 i; i.t.a = 1; i.t.b = 2; i.t.c = 3; u3 ri = g_u3(i); if (ri.t.a != 3 || ri.t.b != 2 || ri.t.c != 1) return 11;
	/* and this side's own, through a pointer, as gcc's call them */
	ubig (*fub)(long, ubig, long) = p_ubig; ubig q = fub(2, f, 1); if (q.l != 13) return 12;
	umix (*fum)(long, umix) = p_umix; umix qm = fum(1, d); if (qm.s.a != 2.5 || qm.s.b != 18) return 13;
	int r = g_calls_p(); if (r) return 20 + r;
	return 42;
}
