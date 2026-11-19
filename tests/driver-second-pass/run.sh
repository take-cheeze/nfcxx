#!/bin/bash
# scripts/nfcxx-second-pass.rb found must answer what the bash loop of nfcxx's second pass decides (verbatim below) for the host
# symbols and unresolved kernel names: found, not found, empty names, scoped names, names that are prefixes or contain regex
# characters, and missing files.   bash tests/driver-second-pass/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
bash_loop() {   # the driver's loop, verbatim (hsyms and the unresolved file set by the case)
  found=0
  while IFS= read -r k; do
    [ -n "$k" ] && grep -qE "(^|[ :])$k<" "$hsyms" && found=1
  done < "$unresolved"
  echo "$found"
}
run_case() {
  local label=$1 syms=$2 unres=$3
  printf '%b' "$syms" > "$t/syms"; printf '%b' "$unres" > "$t/unres"
  hsyms="$t/syms"; unresolved="$t/unres"
  want=$(bash_loop)
  got=$(ruby "$repo/scripts/nfcxx-second-pass.rb" found "$t/syms" "$t/unres")
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $label: bash $want ruby $got"; fi
}
run_case found 'void foo<int>(int)\n' 'foo\n'
run_case not-found 'void bar<int>(int)\n' 'foo\n'
run_case prefix-only 'void foobar<int>(int)\n' 'foo\n'
run_case scoped 'ns::kern<float>(int)\n' 'kern\n'
run_case inside-name 'x_kern<int>\n' 'kern\n'
run_case regex-chars 'a.b<int>\naxb<int>\n' 'a.b\n'
run_case empty-name 'foo<int>\n' '\n'
run_case multi 'bar<1>\n' 'foo\nbar\n'
run_case empty-syms '' 'foo\n'
run_case empty-unres 'foo<1>\n' ''
run_case internal-scope 'k<1>\n' 'k\n'
# the host symbols of a real object (nm -C | sed), as the driver writes them
printf 'namespace _INTERNAL_1234 { int kern(int x) { return x; } }\nint plain(int y) { return y; }\ntemplate<class T> T tmpl(T v) { return v; }\nint use() { return plain(1) + tmpl<int>(2) + _INTERNAL_1234::kern(3); }\n' > "$t/h.cpp"
if ! (cd "$t" && g++ -c h.cpp -o h.o); then fail=$((fail + 1)); echo "FAIL host symbols: the test object did not build"; elif true; then
  bash_syms=$(nm -C "$t/h.o" 2>/dev/null | sed 's/_INTERNAL_[A-Za-z0-9_]*:://g')
  ruby "$repo/scripts/nfcxx-second-pass.rb" host-symbols "$t/h.o" "$t/ruby.syms"
  if [ "$bash_syms" = "$(cat "$t/ruby.syms")" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL host symbols"; fi
fi
# the second pass's run: the driver with the host symbols and the cache left out, from a stub driver that prints its environment
# and arguments and returns a status
stub="$t/stubroot"; mkdir -p "$stub"
cat > "$stub/nfcxx" <<'STUB'
#!/bin/bash
printf 'hs=%s cache=%s remote=%s args=' "$NFCXX_CUDA_HOST_SYMBOLS" "$NFCXX_CACHE" "$NFCXX_CACHE_REMOTE"; printf '[%s]' "$@"; echo
exit 7
STUB
chmod +x "$stub/nfcxx"
want=$(NFCXX_CUDA_HOST_SYMBOLS=/h/syms NFCXX_CACHE= NFCXX_CACHE_REMOTE= "$stub/nfcxx" -c m.cpp -o m.o; echo "rc=$?")
got=$(ruby "$repo/scripts/nfcxx-second-pass.rb" rerun "$stub" /h/syms 4242 -c m.cpp -o m.o; echo "rc=$?")
if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL rerun: bash [$want] ruby [$got]"; fi
echo "driver-second-pass: $pass passed, $fail failed"
[ $fail = 0 ]
