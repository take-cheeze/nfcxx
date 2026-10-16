#!/usr/bin/env bash
# Writes the call and asm cases for diff-arith.sh to stdout: the device intrinsics, the warp shuffles, votes and reduce,
# the atomics (lower_call.cpp, FnCtx::call), and the ptx-asm statement (FnCtx::asm_stmt), over register and constant
# operands, the full-mask and partial-mask forms, and the refused operand types and counts. Each case is
# (call DEST_TYPE PRESETS (call ...)) or (asm PRESETS (ptx-asm ...)), read by --eval-arith and lower-arith-driver.rb.
set -eu

P='((%1 %r1 int) (%2 %r2 int) (%3 %f3 float) (%4 %rd4 (ptr)) (%5 %r5 unsigned_int) (%6 %h6 unsigned_short) (%7 %fd7 double))'

# Each case of a call: its result type, its callee, and the arguments.
call() { printf '(call %s %s (call %s &"%s"%s))\n' "$1" "$P" "$1" "$2" "${3:+ $3}"; }
# The same form with an empty preset list (the intrinsics take no operands).
call0() { printf '(call %s () (call %s &"%s"%s))\n' "$1" "$1" "$2" "${3:+ $3}"; }

# The device intrinsics: each of the twelve, and the refused forms (an argument, a float result).
for n in __nfcxx_tid_x __nfcxx_tid_y __nfcxx_tid_z __nfcxx_ctaid_x __nfcxx_ctaid_y __nfcxx_ctaid_z \
         __nfcxx_ntid_x __nfcxx_ntid_y __nfcxx_ntid_z __nfcxx_nctaid_x __nfcxx_nctaid_y __nfcxx_nctaid_z; do
  call0 unsigned_int "$n"
  call0 unsigned_int "$n" "(const int 1)"
  call0 float "$n"
done

MASKS=("(const unsigned_int 4294967295)" "(const int -1)" "(const unsigned_int 5)" "%5" "%1")
# The warp shuffles: each of the eight, with the full and partial masks, the value and lane operands, and the result.
for n in __nfcxx_shfl_sync_i __nfcxx_shfl_sync_f __nfcxx_shfl_xor_sync_i __nfcxx_shfl_xor_sync_f \
         __nfcxx_shfl_down_sync_i __nfcxx_shfl_down_sync_f __nfcxx_shfl_up_sync_i __nfcxx_shfl_up_sync_f; do
  case $n in *_f) vals=("%3" "(const float 1.5)"); ret=float ;; *) vals=("%2" "%1" "(const int 7)"); ret=int ;; esac
  for m in "${MASKS[@]}"; do
    for v in "${vals[@]}"; do
      for l in %1 "(const int 3)" %2; do
        call "$ret" "$n" "$m $v $l"
      done
    done
  done
  call unsigned_int "$n" "(const unsigned_int 4294967295) %2 %1"      # an unsigned result is accepted for the int forms
  call "$ret" "$n" "(const unsigned_int 4294967295) %2"               # two arguments: refused
  call "$ret" "$n" "(const unsigned_int 4294967295) %2 %1 %1"         # four arguments: refused
done

# The votes: each of the three, with the predicate as a register, a constant and a float (refused).
for n in __nfcxx_ballot_sync __nfcxx_any_sync __nfcxx_all_sync; do
  for m in "${MASKS[@]}"; do
    for pv in %1 "(const int 1)" "(const int 0)" %3 %2; do
      call int "$n" "$m $pv"
    done
  done
  call int "$n" "(const unsigned_int 4294967295)"                    # one argument: refused
  call float "$n" "(const unsigned_int 4294967295) %1"               # float result: refused
done

# The reduce: the full mask, the register and constant values, and the refused forms.
for m in "${MASKS[@]}"; do
  for v in %1 %2 "(const int 9)" %3; do
    call int __nfcxx_reduce_add_sync "$m $v"
  done
done
call int __nfcxx_reduce_add_sync "(const unsigned_int 4294967295)"  # one argument: refused

# The atomics: add, add of a float, max, and cas (three arguments), with the pointer, the values and the refusals.
for m in "%4" "%1" "%5"; do
  call int __nfcxx_atomic_add_i "$m %1"
  call int __nfcxx_atomic_add_i "$m (const int 1)"
  call int __nfcxx_atomic_add_i "$m %3"                             # float value: refused
  call int __nfcxx_atomic_max_i "$m %2"
  call int __nfcxx_atomic_cas_i "$m %1 %2"
  call int __nfcxx_atomic_cas_i "$m %1"                             # two arguments: refused
  call float __nfcxx_atomic_add_f "$m %3"
  call float __nfcxx_atomic_add_f "$m (const float 2.0)"
  call float __nfcxx_atomic_add_f "$m %1"                           # int value: refused
done
call int __nfcxx_atomic_add_i "(const unsigned_int 4294967295) %1" # the pointer is an int: refused

# The inline PTX statements: each operand kind and type, the template's %N, and the refused and bad operands.
asm() { printf '(asm %s (ptx-asm "%s"%s))\n' "$P" "$1" "${2:+ $2}"; }
asm "add.s32 %0, %1, %2;" "(opnd in %1 int) (opnd in (const int 3) int) (opnd out %4 int)"
asm "add.s32 %0, %0, %1;" "(opnd inout %4 int) (opnd in %2 int)"
asm "mov.u32 %0, %1;" "(opnd out %4 unsigned_int) (opnd in %5 unsigned_int)"
asm "cvt.u32.u16 %0, %1;" "(opnd out %4 int) (opnd in %6 unsigned_short)"
asm "mov.f32 %0, %1;" "(opnd out %4 float) (opnd in %3 float)"
asm "add.f64 %0, %1, %1;" "(opnd out %4 double) (opnd in %7 double)"
asm "ld.global.u32 %0, [%1];" "(opnd out %5 unsigned_int) (opnd in %4 (ptr))"
asm "st.global.u32 [%1], %0;" "(opnd in %5 unsigned_int) (opnd in %4 (ptr))"
asm "bar.sync 0;"
asm "  mov.u32 %0, %1;  " "(opnd out %4 int) (opnd in (const int 5) int)"
asm "mov.u32 %0, 100%;" "(opnd out %4 int)"
asm "mov.u32 %0, %1;" "(opnd out %4 int) (opnd in %1 char)"       # a 1-byte operand: refused
asm "mov.pred %0, %1;" "(opnd out %4 int) (opnd in (const bool true) bool)"  # a bool operand: refused
asm "mov.u32 %0, %9;" "(opnd out %4 int)"                          # %9 of one operand: bad IR
asm "mov.u32 %0, %1;" "%1"                                         # an operand that is not opnd: bad IR
asm "mov.u32 %0, %1;" "(opnd out %4 int) (opnd in %1)"             # an operand without a type: bad IR
