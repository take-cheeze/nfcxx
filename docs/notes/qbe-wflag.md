# QBE amd64: a long `and` feeds the flags of a word `jnz` (struct with a 4-byte member and padding)

Upstream-ready bug report for QBE (c9x.me/git/qbe.git), with the patch nfcxx applies (`the fork commit 'nfcxx patch: wflag'`, applied by
`scripts/setup-qbe.sh`). Regression test: `tests/cases/qbe_wflag_padding.cpp`.

## Symptom

A struct with a 4-byte member next to padding, for example `struct { union { long long i; double d; } w; int f; }` (16 bytes, the
last 4 are padding), that is copied by value and then tested through the member, takes the wrong branch when the padding bytes are not
zero. nfcast's `nfcr_N` (number that is an integer or a float, `f` says which) came back as its integer part. The same C passes with
gcc and with QBE at `-O0`-like code shapes where the optimizer does not fuse the test.

## Root cause

Not cproc, and not the struct copy itself (cproc copies a 16-byte struct as two `loadl`/`storel` pairs, which is fine). It is the
combination of two QBE passes and the amd64 instruction selector:

1. Load elimination (`load.c`): the 4-byte member store `storew 0, %m` is followed by a copy of the struct that reads the slot as
   8 bytes (`%x =l loadl %m`). The wider load is rebuilt from the narrower store and the older contents of the padding half:
   `%r =l or (and 0, 0xffffffff), (and %old, 0xffffffff00000000)`. Then a 4-byte load of the member from the copy becomes
   `%f =w copy %r`.
2. Copy elimination makes the `jnz` read `%r` (class `l`) instead of `%f` (class `w`).
3. amd64 `seljmp()` (and `selsel()`) see that the flag-setting instruction feeding the `jnz` is an `and` with a single use, rewrite
   it to `Oxtest`, and drop the use of the word. `Oxtest` keeps the class of the `and`: `testq $0xffffffff00000000, %r`. But `jnz`
   branches on a word, so only the low 32 bits count: the result is the *padding* half. (Without the fusion the code is right:
   `cmpl $0, %eax`.) The same holds for any class-`l` instruction with the `zflag` bit (`add`, `sub`, `or`...): the flags describe
   all 64 bits.

Minimal QBE IL (the `copy` is what the optimizer produces; `%b =w copy %a` of a long is legal input):

```
export function w $t(l %x) {
@s
	%a =l and %x, -4294967296
	%b =w copy %a
	jnz %b, @y, @n
@y
	ret 1
@n
	ret 0
}
```

Wrong (`t(1<<32)` returns 1; the word of `%a` is always 0, so the answer must be 0):

```
	movq $-4294967296, %rax
	testq %rax, %rdi          # 64-bit test of the high half
	jnz .Lbb2
```

Fixed:

```
	movq $-4294967296, %rax
	andq %rdi, %rax
	cmpl $0, %eax             # the word
	jnz .Lbb2
```

C reproduction (cproc + qbe; the padding is made non-zero by the call to `dirty()`; the function that returns the struct by value
and copies it stays out of line, `num_*` are what an inliner leaves behind; `tests/cases/qbe_wflag_padding.cpp` is the C++ version):

```c
typedef union { long long i; double d; } W;
typedef struct { W w; int f; char pad[4]; } N;     /* the pad is explicit in EDG's C; the C struct has it anyway */
static long long depth, maxd = 100;
static void bail(void) { depth = 0; }
static N f0(long long p0, long long p1) {
  N T1, T2, T3, T6, T7, T8, v2, t0; double T9;
  T1.w.i = 0; T1.f = 0; T2 = T1; v2 = T2;
  if (depth >= maxd) bail();
  ++depth;
  T1.w.i = p0; T1.f = 0; T2 = T1; v2 = T2;
  if (p1 > 2) {
    T6 = v2;
    T9 = (T6.f ? T6.w.d : (double)T6.w.i) * 1.5;
    T8.w.i = 0; T8.w.d = T9; T8.f = 1; T7 = T8; v2 = T7;
  }
  t0 = v2; --depth; T3 = t0; return T3;
}
/* main: fill the stack with 0xff (memset of a 512-byte local in a helper), then f0(3, 5): QBE prints 1.97626e-323 for
   the float 4.5, gcc and the patched QBE print 4.5 */
```

## Fix

`amd64/isel.c`: use the flags of the instruction before a `jnz`/select only if it is a comparison or has class `w`; otherwise
test the word explicitly (`cmpl $0`), as already done when no flag-setting instruction is there. See `the fork commit 'nfcxx patch: wflag'`:

```c
static int
wflagi(Ins *fi, Ref r, int *k, int *c)
{
	if (!fi || !req(fi->to, r))
		return 0;
	if (iscmp(fi->op, k, c))
		return 1;
	return !KWIDE(fi->cls);
}
```

`seljmp()` and `selsel()` call it in place of `!fi || !req(fi->to, r)`. arm64 and rv64 do not fuse an `and` into a branch, so they
are not affected (not tested here: only amd64 is built and run).

An alternative upstream fix is to keep copy elimination from replacing a word use with a long temporary, or to make `load.c` emit
the truncation as a real instruction; the isel change is the narrowest.

## Status

Not sent upstream yet. Found with nfcast's tier (`lib/ast/nfcast_tier_rt.h`, `docs/notes/ast.md`), whose `nfcr_N` flag was a 64-bit
word as a workaround; with the patch it is a 32-bit `int` again.
