// nfcast: the numeric operators that the interpreter and the code the tier generates (nfcast_tier.cpp, docs/notes/ast.md) share.
//
// Lua's integer and float arithmetic, the shifts, the comparison of an integer with a float, and the arithmetic of a numeric `for`
// loop are written once, here. The engine includes this header (nfcast_impl.hpp builds its operators on these functions); the
// tier pastes the text of this file into every generated translation unit, so the compiled code runs the same functions. The
// file must stay self-contained: no #include of another local file, and system headers only when NFCAST_RT_GENERATED is not
// defined (the generated code declares the few libm functions it needs itself, which compiles twice as fast as <math.h>).
#ifndef NFCAST_TIER_RT_H
#define NFCAST_TIER_RT_H

#ifdef NFCAST_RT_GENERATED
typedef long long nfcr_i64;
typedef unsigned long long nfcr_u64;
#else
#include <cmath>
#include <cstdint>
typedef std::int64_t nfcr_i64;
typedef std::uint64_t nfcr_u64;
#endif

#ifndef NFCR_POW
#define NFCR_POW(a, b) pow((a), (b))
#endif

#define NFCR_INT_MAX 9223372036854775807LL
#define NFCR_INT_MIN (-9223372036854775807LL - 1)

// ---- integers (wrapping) -----------------------------------------------------------------------------------------------------
static inline nfcr_i64 nfcr_add(nfcr_i64 a, nfcr_i64 b) { return (nfcr_i64)((nfcr_u64)a + (nfcr_u64)b); }
static inline nfcr_i64 nfcr_sub(nfcr_i64 a, nfcr_i64 b) { return (nfcr_i64)((nfcr_u64)a - (nfcr_u64)b); }
static inline nfcr_i64 nfcr_mul(nfcr_i64 a, nfcr_i64 b) { return (nfcr_i64)((nfcr_u64)a * (nfcr_u64)b); }
static inline nfcr_i64 nfcr_neg(nfcr_i64 a) { return (nfcr_i64)(0u - (nfcr_u64)a); }

// `a // b` and `a % b` for B != 0 (the caller raises the error for a zero divisor): the quotient rounds towards minus infinity,
// the remainder takes the sign of the divisor, and a divisor of -1 neither traps nor overflows.
static inline nfcr_i64 nfcr_idiv(nfcr_i64 a, nfcr_i64 b) {
  if ((nfcr_u64)b + 1u <= 1u) return (nfcr_i64)(0u - (nfcr_u64)a);  // b is -1
  nfcr_i64 q = a / b;
  if ((a ^ b) < 0 && a % b != 0) --q;
  return q;
}

static inline nfcr_i64 nfcr_imod(nfcr_i64 a, nfcr_i64 b) {
  if ((nfcr_u64)b + 1u <= 1u) return 0;  // b is -1
  nfcr_i64 r = a % b;
  if (r != 0 && (r ^ b) < 0) r += b;
  return r;
}

// Shifts: a count of 64 or more (in either direction) gives 0, a negative count shifts the other way, both are logical.
static inline nfcr_i64 nfcr_shl(nfcr_i64 x, nfcr_i64 y) {
  if (y <= -64 || y >= 64) return 0;
  if (y >= 0) return (nfcr_i64)((nfcr_u64)x << y);
  return (nfcr_i64)((nfcr_u64)x >> (-y));
}
static inline nfcr_i64 nfcr_shr(nfcr_i64 x, nfcr_i64 y) { return nfcr_shl(x, (nfcr_i64)(0u - (nfcr_u64)y)); }

// ---- floats ------------------------------------------------------------------------------------------------------------------
// `a % b`: C's fmod, moved to the sign of the divisor.
static inline double nfcr_fmod(double a, double b) {
  double m = fmod(a, b);
  if ((m > 0) ? b < 0 : (m < 0 && b > 0)) m += b;
  return m;
}
static inline double nfcr_fpow(double a, double b) { return b == 2 ? a * a : NFCR_POW(a, b); }
static inline double nfcr_fidiv(double a, double b) { return floor(a / b); }

// A float with an exact integer value as that integer.
static inline int nfcr_f2i(double d, nfcr_i64* out) {
  if (d >= -9223372036854775808.0 && d < 9223372036854775808.0) {
    nfcr_i64 i = (nfcr_i64)d;
    if ((double)i == d) {
      *out = i;
      return 1;
    }
  }
  return 0;
}

// ---- an integer and a float ------------------------------------------------------------------------------------------------
// Compared exactly, not by converting the integer to a double (which loses bits above 2^53).
static inline int nfcr_fits_double(nfcr_i64 i) { return -(1LL << 53) <= i && i <= (1LL << 53); }

// F rounded down (or up, with CEIL_MODE) to an integer; 0 when it is out of range.
static inline int nfcr_f2i_mode(double f, int ceil_mode, nfcr_i64* out) {
  double fl = floor(f);
  if (fl != f && ceil_mode) fl += 1;
  if (fl >= -9223372036854775808.0 && fl < 9223372036854775808.0) {
    *out = (nfcr_i64)fl;
    return 1;
  }
  return 0;
}

static inline int nfcr_lt_if(nfcr_i64 a, double b) {  // a < b
  nfcr_i64 fi;
  if (nfcr_fits_double(a)) return (double)a < b;
  if (nfcr_f2i_mode(b, 1, &fi)) return a < fi;
  return b > 0;
}
static inline int nfcr_lt_fi(double a, nfcr_i64 b) {  // a < b
  nfcr_i64 fi;
  if (nfcr_fits_double(b)) return a < (double)b;
  if (nfcr_f2i_mode(a, 0, &fi)) return fi < b;
  return a < 0;
}
static inline int nfcr_le_if(nfcr_i64 a, double b) {  // a <= b
  nfcr_i64 fi;
  if (nfcr_fits_double(a)) return (double)a <= b;
  if (nfcr_f2i_mode(b, 0, &fi)) return a <= fi;
  return b > 0;
}
static inline int nfcr_le_fi(double a, nfcr_i64 b) {  // a <= b
  nfcr_i64 fi;
  if (nfcr_fits_double(b)) return a <= (double)b;
  if (nfcr_f2i_mode(a, 1, &fi)) return fi <= b;
  return a < 0;
}
static inline int nfcr_eq_if(nfcr_i64 a, double b) {  // a == b
  nfcr_i64 k;
  return nfcr_f2i(b, &k) && k == a;
}

// ---- numeric for loops ----------------------------------------------------------------------------------------------------------
// The limit of an integer loop (integer start and step) given as a float FL: clipped to an integer the way Lua does. Returns 0 when
// the loop does not run at all (a NaN, or a limit beyond the range on the side the step moves away from).
static inline int nfcr_forlimit(double fl, nfcr_i64 step, nfcr_i64* out) {
  if (fl != fl) return 0;
  double r = step < 0 ? ceil(fl) : floor(fl);
  if (r >= -9223372036854775808.0 && r < 9223372036854775808.0) {
    *out = (nfcr_i64)r;
    return 1;
  }
  if (fl > 0) {
    if (step < 0) return 0;
    *out = NFCR_INT_MAX;
  } else {
    if (step > 0) return 0;
    *out = NFCR_INT_MIN;
  }
  return 1;
}

// For an integer loop that runs at least once (I0 <= LIMIT with a positive step, I0 >= LIMIT with a negative one): the number of
// iterations after the first, computed in unsigned arithmetic so that no limit or step overflows.
static inline nfcr_u64 nfcr_forcount(nfcr_i64 i0, nfcr_i64 limit, nfcr_i64 step) {
  nfcr_u64 count;
  if (step > 0) {
    count = (nfcr_u64)limit - (nfcr_u64)i0;
    if (step != 1) count /= (nfcr_u64)step;
  } else {
    count = (nfcr_u64)i0 - (nfcr_u64)limit;
    count /= (nfcr_u64)(-(step + 1)) + 1u;
  }
  return count;
}

typedef union nfcr_W {  // one unboxed value: an integer, a float, or a boolean (in I)
  nfcr_i64 i;
  double d;
} nfcr_W;

// ---- a number whose kind is known only at run time (generated code) ---------------------------------------------------------------
// A variable that holds an integer here and a float there (`local s = 0` ... `s = s + 0.5`) is an nfcr_N: the value and a flag that
// says which. The operators do what the interpreter's do on a pair of numbers, with the same functions as above.
// The flag is a full 64-bit word on purpose: the QBE back end miscompiles a 4-byte member that shares a word with padding in a struct
// that is copied by value (it tests the wrong half of the word), and the generated code copies these a lot.
typedef struct nfcr_N {
  nfcr_W w;
  nfcr_i64 f;  // 1: the value is the float w.d; 0: the integer w.i
} nfcr_N;

static inline nfcr_N nfcr_ni(nfcr_i64 i) {
  nfcr_N n;
  n.w.i = i;
  n.f = 0;
  return n;
}
static inline nfcr_N nfcr_nf(double d) {
  nfcr_N n;
  n.w.i = 0;
  n.w.d = d;
  n.f = 1;
  return n;
}
static inline double nfcr_nd(nfcr_N n) { return n.f ? n.w.d : (double)n.w.i; }

static inline nfcr_N nfcr_nadd(nfcr_N a, nfcr_N b) { return (a.f | b.f) ? nfcr_nf(nfcr_nd(a) + nfcr_nd(b)) : nfcr_ni(nfcr_add(a.w.i, b.w.i)); }
static inline nfcr_N nfcr_nsub(nfcr_N a, nfcr_N b) { return (a.f | b.f) ? nfcr_nf(nfcr_nd(a) - nfcr_nd(b)) : nfcr_ni(nfcr_sub(a.w.i, b.w.i)); }
static inline nfcr_N nfcr_nmul(nfcr_N a, nfcr_N b) { return (a.f | b.f) ? nfcr_nf(nfcr_nd(a) * nfcr_nd(b)) : nfcr_ni(nfcr_mul(a.w.i, b.w.i)); }
static inline nfcr_N nfcr_nneg(nfcr_N a) { return a.f ? nfcr_nf(-a.w.d) : nfcr_ni(nfcr_neg(a.w.i)); }
// `//` and `%`; two integers need a divisor that is not zero (the caller checks)
static inline nfcr_N nfcr_nidiv(nfcr_N a, nfcr_N b) { return (a.f | b.f) ? nfcr_nf(nfcr_fidiv(nfcr_nd(a), nfcr_nd(b))) : nfcr_ni(nfcr_idiv(a.w.i, b.w.i)); }
static inline nfcr_N nfcr_nmod(nfcr_N a, nfcr_N b) { return (a.f | b.f) ? nfcr_nf(nfcr_fmod(nfcr_nd(a), nfcr_nd(b))) : nfcr_ni(nfcr_imod(a.w.i, b.w.i)); }

static inline int nfcr_nlt(nfcr_N a, nfcr_N b) {
  if (!a.f) return b.f ? nfcr_lt_if(a.w.i, b.w.d) : a.w.i < b.w.i;
  return b.f ? a.w.d < b.w.d : nfcr_lt_fi(a.w.d, b.w.i);
}
static inline int nfcr_nle(nfcr_N a, nfcr_N b) {
  if (!a.f) return b.f ? nfcr_le_if(a.w.i, b.w.d) : a.w.i <= b.w.i;
  return b.f ? a.w.d <= b.w.d : nfcr_le_fi(a.w.d, b.w.i);
}
static inline int nfcr_neq(nfcr_N a, nfcr_N b) {
  if (!a.f) return b.f ? nfcr_eq_if(a.w.i, b.w.d) : a.w.i == b.w.i;
  return b.f ? a.w.d == b.w.d : nfcr_eq_if(b.w.i, a.w.d);
}
// The integer a bitwise operator works on: an integer, or a float with an integer value; 0 for any other float.
static inline int nfcr_ntoi(nfcr_N n, nfcr_i64* out) {
  if (!n.f) {
    *out = n.w.i;
    return 1;
  }
  return nfcr_f2i(n.w.d, out);
}

// ---- the interface between the engine and a generated unit -----------------------------------------------------------------------
typedef struct nfcr_Ctx {
  void* jb;            // the jmp_buf of the entry trampoline: an abandoned run longjmps there
  nfcr_i64 depth;      // nested calls, counted like State::depth (it starts at the engine's value)
  nfcr_i64 maxd;       // State::max_depth
  const nfcr_W* fv;    // the values of the free variables (upvalues and globals) the unit reads, gathered at entry
  nfcr_i64 rtag;       // the kind of a result that is an nfcr_N: 1 a float (the result is in W.d), 0 an integer
} nfcr_Ctx;

#endif  // NFCAST_TIER_RT_H
