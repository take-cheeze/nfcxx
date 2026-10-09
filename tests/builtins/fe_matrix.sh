#!/usr/bin/env bash
# Front-end acceptance matrix for the builtins in docs/notes/builtins.md: does the EDG front end (cpfe) accept
# each builtin in an expression, in g++ mode (default GNU version), g++ mode with --gnu-version=130000, and clang
# mode? Only the front end runs here (nfcxx --emit-c); whether the emitted C compiles and runs is tests/builtins/run.sh.
# Prints one TSV row per builtin: name, g++, g++ gnu13, clang. OK, or the first diagnostic.
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pre='struct A {}; struct B : A {}; struct F final {}; union U { int i; }; enum E { e0 };
enum class EC : short { x };
void sink(...);'
# name|function body (inside void f() { ... })
cases=(
"is_same|sink(__is_same(int,int));"
"is_class|sink(__is_class(A));"
"is_enum|sink(__is_enum(E));"
"is_union|sink(__is_union(U));"
"is_empty|sink(__is_empty(A));"
"is_final|sink(__is_final(F));"
"is_pod|sink(__is_pod(A));"
"is_trivially_copyable|sink(__is_trivially_copyable(A));"
"is_trivially_constructible|sink(__is_trivially_constructible(A));"
"is_trivially_destructible|sink(__is_trivially_destructible(A));"
"is_constructible|sink(__is_constructible(A));"
"is_base_of|sink(__is_base_of(A,B));"
"underlying_type|sink((__underlying_type(EC))0);"
"launder|int i; sink(__builtin_launder(&i));"
"memcpy|char a[4], b[4]; sink(__builtin_memcpy(a,b,4));"
"memmove|char a[4], b[4]; sink(__builtin_memmove(a,b,4));"
"memset|char a[4]; sink(__builtin_memset(a,0,4));"
"memcmp|char a[4], b[4]; sink(__builtin_memcmp(a,b,4));"
"unreachable|__builtin_unreachable();"
"expect|sink(__builtin_expect(1,1));"
"addressof|int i; sink(__builtin_addressof(i));"
"add_overflow|int r; sink(__builtin_add_overflow(1,2,&r));"
"sub_overflow|int r; sink(__builtin_sub_overflow(1,2,&r));"
"mul_overflow|int r; sink(__builtin_mul_overflow(1,2,&r));"
"add_overflow_p|sink(__builtin_add_overflow_p(1,2,(int)0));"
"clz|sink(__builtin_clz(1u));"
"ctz|sink(__builtin_ctz(1u));"
"popcount|sink(__builtin_popcount(1u));"
"trap|__builtin_trap();"
"is_constant_evaluated|sink(__builtin_is_constant_evaluated());"
"FILE|sink(__builtin_FILE());"
"LINE|sink(__builtin_LINE());"
"FUNCTION|sink(__builtin_FUNCTION());"
"bit_cast|sink(__builtin_bit_cast(unsigned,1.0f));"
"offsetof|sink(__builtin_offsetof(U,i));"
)
# Builtins that are type-level (not usable in an expression), checked at namespace scope.
global=(
"make_integer_seq|template<typename T, T... I> struct S {}; typedef __make_integer_seq<S,int,3> T1;"
"type_pack_element|typedef __type_pack_element<0,int,char> T2;"
)
probe() { # $1 = dialect args, $2 = file
  local out; out=$(cd build/edg-base && ../../build/edg/bin/cpfe -D_POSIX_SOURCE -D__CHAR_BIT__=8 --c++23 $1 \
      --sys_include="$PWD/../../3rd/edg/include_c++" --sys_include="$PWD/../../3rd/edg/include_c99" \
      --gen_c_file_name="$tmp/out.c" "$2" 2>&1) && rc=0 || rc=$?
  if [ $rc = 0 ]; then echo OK; else echo "FAIL: $(echo "$out" | grep -m1 'error:' | sed 's/.*error: *//' | cut -c1-60)"; fi
}
printf 'builtin\tg++\tg++ gnu13\tclang\n'
for c in "${cases[@]}" ; do
  n=${c%%|*}; body=${c#*|}; f="$tmp/$n.cpp"
  printf '%s\nvoid f() { %s }\n' "$pre" "$body" > "$f"
  printf '%s\t%s\t%s\t%s\n' "$n" "$(probe --g++ "$f")" "$(probe "--g++ --gnu_version=130000" "$f")" "$(probe --clang "$f")"
done
for c in "${global[@]}" ; do
  n=${c%%|*}; body=${c#*|}; f="$tmp/$n.cpp"
  printf '%s\n' "$body" > "$f"
  printf '%s\t%s\t%s\t%s\n' "$n" "$(probe --g++ "$f")" "$(probe "--g++ --gnu_version=130000" "$f")" "$(probe --clang "$f")"
done
