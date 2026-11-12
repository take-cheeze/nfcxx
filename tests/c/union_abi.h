/* Unions passed and returned by value, System V x86-64 classes (union_abi.c is compiled by the backend under test,
   union_abi_gcc.c by the host gcc). */
typedef union { int i; double d; } ui;                        /* 8: INTEGER (int and double merge) */
typedef union { double d; float f; } ud;                      /* 8: SSE */
typedef union { double d[2]; } u2d;                           /* 16: SSE SSE */
typedef union { struct { double a; long b; } s; double d[2]; } umix;  /* 16: SSE, INTEGER (merge of long and double) */
typedef union { struct { float x, y; } p; double d; } ust;    /* 8: SSE (a struct inside) */
typedef union { char c[24]; long l; } ubig;                   /* 24: memory */
typedef union { float f[3]; int i[3]; } u12;                  /* 12: SSE+SSE vs INTEGER+INTEGER merged: INTEGER, INTEGER */
typedef union { float f[3]; } u12f;                           /* 12: SSE, SSE */
typedef union { struct { char a, b, c; } t; } u3;             /* 3 bytes: INTEGER */
/* gcc-compiled functions */
ui g_ui(int k, ui u, int m); ud g_ud(ud u, double x); u2d g_u2d(double x, u2d u); umix g_umix(long k, umix u);
ust g_ust(ust u); ubig g_ubig(long k, ubig u, long m); u12 g_u12(u12 u, int k); u12f g_u12f(u12f u, float k); u3 g_u3(u3 u);
ui g_mk_ui(int k); ud g_mk_ud(double x); umix g_mk_umix(long a, double b); ubig g_mk_ubig(long k); u12f g_mk_u12f(float a);
/* the gcc side calls these, defined by the backend under test */
ui p_ui(int k, ui u, int m); ud p_ud(ud u, double x); u2d p_u2d(double x, u2d u); umix p_umix(long k, umix u);
ust p_ust(ust u); ubig p_ubig(long k, ubig u, long m); u12 p_u12(u12 u, int k); u12f p_u12f(u12f u, float k); u3 p_u3(u3 u);
int g_calls_p(void);
