#!/usr/bin/env bash
# scripts/win-predef.sh against scripts/win-predef.rb. The compiler is a stub on PATH that prints the file named by
# RB_CC_OUTPUT and exits with RB_CC_STATUS.
NAME=win-predef
. "$(dirname "$0")/../lib.sh"

rb_stub x86_64-w64-mingw32-gcc 'cat "$RB_CC_OUTPUT"; exit "${RB_CC_STATUS:-0}"'

populate() { :; }

# A compiler's -dM -E output: object-like, function-like, valueless, tab-separated and dropped macros.
cat > "$RB_WORK/macros.txt" <<'EOF2'
#define __STDC__ 1
#define __STDC_HOSTED__ 1
#define __cplusplus 202302L
#define __cpp_rtti 199711L
#define __GNUC__ 15
#define __GCC_ASM_FLAG_OUTPUTS__ 1
#define __INT8_TYPE__ signed char
#define __SIZEOF_INT__ 4
#define __WCHAR_TYPE__ short unsigned int
#define __CHAR16_TYPE__ short unsigned int
#define __func_like(x) ((x)+1)
#define __VALUELESS
#define __TABBED	7
#define __TWO_TABS	a	b
#define __SPACES   spaced value  
#define __CET__ 3
#define __x86_64__ 1
#define __GXX_ABI_VERSION 1020
#define __OPTIMIZE__
#define __SEH__ 1
#define __UINT64_C(c) c ## ULL
#define __GCC_IEC_559 2
#define __DEFAULT
EOF2
export RB_CC_OUTPUT="$RB_WORK/macros.txt" RB_CC_STATUS=0
printf '' > "$RB_WORK/empty.txt"
printf '#define __GNUC__ 1\n' > "$RB_WORK/gcc.txt"

rb_case "table from the compiler" "" out.txt
rb_case "compiler named by the second argument" "" out.txt "$RB_WORK/bin/x86_64-w64-mingw32-gcc"
rb_case "empty compiler name uses the default" "" out.txt ""
RB_CC_STATUS=3 rb_case "compiler fails after printing" "" out.txt
RB_CC_OUTPUT="$RB_WORK/empty.txt" rb_case "compiler prints nothing: no macro kept" "" out.txt
RB_CC_OUTPUT="$RB_WORK/gcc.txt" RB_CC_STATUS=5 rb_case "compiler fails with nothing kept" "" out.txt
# The shell's "command not found" and "unbound variable" lines name the shell's own position: stderr is not compared.
RB_IGNORE_STDERR=1 rb_case "compiler missing: status 1, no macro kept" "" out.txt "$RB_WORK/no-such-compiler"
RB_IGNORE_STDERR=1 rb_case "no arguments: usage (the shell stops on an unbound \$1)" ""
rb_done
