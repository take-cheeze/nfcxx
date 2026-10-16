#!/usr/bin/env bash
# Writes the memory cases for diff-arith.sh to stdout: the load, load.v, bitcast, offset and index forms over the scalar
# types, with the address operands the IR gives them (registers, the null pointer, @name module symbols, $slot frame
# slots), and the store and store.v statements over the same types. Each case is
#   (mem DEST_TYPE PRESETS SYMBOLS INSTR)  or  (stmt PRESETS SYMBOLS STMT)
# read by --eval-arith and by lower-arith-driver.rb. Refusals (volatile loads and stores of bytes, extern and static
# symbols, pointers that are not) and mismatched types are included, so both sides refuse or fail the same way.
set -eu

ints="char signed_char unsigned_char short unsigned_short int unsigned_int long unsigned_long bool"
flts="float double"
all="$ints $flts"

# The preset register of an IR type for a value (the class of reg_class).
value_reg() {
  case $1 in
    char|signed_char|unsigned_char|short|unsigned_short|int|unsigned_int) echo '%r2' ;;
    long|unsigned_long) echo '%rd2' ;;
    float) echo '%f2' ;;
    double) echo '%fd2' ;;
    bool) echo '%p2' ;;
  esac
}

# The address preset: a pointer register %1.
addr='(%1 %rd1 (ptr))'

for t in $all; do
  v=$(value_reg "$t")
  # loads: from a register, the null pointer, each module symbol, a frame slot; and the module symbols of the other kinds
  printf '(mem %s ((%%1 %%rd1 (ptr))) () (load %s %%1))\n' "$t" "$t"
  printf '(mem %s () () (load %s (null (ptr))))\n' "$t" "$t"
  for sk in shared:sm global:gm const:cm string:ss; do
    printf '(mem %s () ((%s %s)) (load %s @"%s"))\n' "$t" "${sk%%:*}" "${sk##*:}" "$t" "${sk##*:}"
  done
  printf '(mem %s () ((slot sl 16)) (load %s $"sl"))\n' "$t" "$t"
  printf '(mem %s () ((extern em)) (load %s @"em"))\n' "$t" "$t"
  printf '(mem %s () () (load %s @"ux"))\n' "$t" "$t"
  # volatile loads: the 4- and 8-byte integers and the floats; the rest are refused
  printf '(mem %s ((%%1 %%rd1 (ptr))) () (load.v %s %%1))\n' "$t" "$t"
  # stores, plain and volatile, from a register and from a constant
  printf '(stmt ((%%1 %%rd1 (ptr)) (%%2 %s %s)) () (store %s %%1 %%2))\n' "$v" "$t" "$t"
  printf '(stmt ((%%1 %%rd1 (ptr)) (%%2 %s %s)) () (store.v %s %%1 %%2))\n' "$v" "$t" "$t"
  printf '(stmt ((%%2 %s %s)) ((shared sm)) (store %s @"sm" %%2))\n' "$v" "$t" "$t"
  printf '(stmt ((%%2 %s %s)) ((extern em)) (store %s @"em" %%2))\n' "$v" "$t" "$t"
  printf '(stmt ((%%1 %%rd1 (ptr))) () (store %s %%1 (const %s 5)))\n' "$t" "$t"
  printf '(stmt ((%%1 %%rd1 (ptr))) () (store.v %s %%1 (const %s 5)))\n' "$t" "$t"
done

# Pointer forms: offset and index with register and constant indices, bitcast of a pointer.
for n in 0 8 4096 -8; do
  printf '(mem (ptr) ((%%1 %%rd1 (ptr))) () (offset %%1 %s))\n' "$n"
done
printf '(mem (ptr) ((%%1 %%rd1 (ptr))) () (offset %%1 4))\n'
printf '(mem (ptr) ((%%2 %%r2 int)) () (offset %%2 4))\n'
printf '(mem int ((%%1 %%rd1 (ptr))) () (offset %%1 4))\n'
for it in 'int %r2' 'unsigned_int %r2' 'long %rd2' 'unsigned_long %rd2' 'char %r2' 'bool %p2'; do
  set -- $it
  for size in 1 4 8 16; do
    printf '(mem (ptr) ((%%1 %%rd1 (ptr)) (%%2 %s %s)) () (index %%1 %%2 %s))\n' "$2" "$1" "$size"
  done
done
for c in '(const int 3)' '(const long 5)'; do
  printf '(mem (ptr) ((%%1 %%rd1 (ptr))) () (index %%1 %s 8))\n' "$c"
done
printf '(mem (ptr) () () (index (null (ptr)) (const int 2) 4))\n'
printf '(mem (ptr) ((%%2 %%r2 int)) () (index %%2 %%2 4))\n'
printf '(mem (ptr) ((%%1 %%rd1 (ptr)) (%%2 %%fd2 double)) () (index %%1 %%2 4))\n'
printf '(mem (ptr) ((%%1 %%rd1 (ptr))) ((shared sm)) (index @"sm" %%1 4))\n'
printf '(mem (ptr) ((%%1 %%rd1 (ptr))) () (bitcast (ptr) %%1))\n'
printf '(mem (ptr) ((%%2 %%r2 int)) () (bitcast (ptr) %%2))\n'
printf '(mem int ((%%1 %%rd1 (ptr))) () (bitcast int %%1))\n'
printf '(mem (ptr) ((%%1 %%rd1 (ptr))) () (bitcast (ptr) (null (ptr))))\n'
# A pointer value stored and loaded back (the pointer types of the memory forms).
printf '(mem (ptr) ((%%1 %%rd1 (ptr))) () (load (ptr) %%1))\n'
printf '(stmt ((%%1 %%rd1 (ptr)) (%%2 %%rd2 (ptr))) () (store (ptr) %%1 %%2))\n'
printf '(stmt ((%%1 %%rd1 (ptr)) (%%2 %%rd2 (ptr))) () (store.v (ptr) %%1 %%2))\n'
# A value of the wrong type for the memory type (the expect check).
printf '(stmt ((%%1 %%rd1 (ptr)) (%%2 %%fd2 double)) () (store int %%1 %%2))\n'
printf '(stmt ((%%1 %%rd1 (ptr)) (%%2 %%r2 int)) () (store.v long %%1 %%2))\n'
