#!/bin/bash
# The --emit-c front end run (scripts/nfcxx-emit-c.rb run) against a stub cpfe: it runs in the EDG base directory with the
# driver's words, writes the generated C to the file named by --gen_c_file_name, and its span is in the time log. A failing
# front end ends the driver with its status and writes no span.   bash tests/driver-emit-c-run/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/edg/bin" "$work/base"
printf '#!/bin/sh\nexit 1\n' > "$work/edg/bin/eccp"; chmod +x "$work/edg/bin/eccp"
cat > "$work/edg/bin/cpfe" <<'STUB'
#!/bin/sh
# stub front end: records its directory and words, writes the file named by --gen_c_file_name, exits with CPFE_STATUS
pwd > "$CPFE_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$CPFE_LOG"; case $a in --gen_c_file_name=*) printf 'int emitted(void);\n' > "${a#--gen_c_file_name=}" ;; esac; done
exit "${CPFE_STATUS:-0}"
STUB
chmod +x "$work/edg/bin/cpfe"
cd "$work" || exit 1
printf 'int main() { return 0; }\n' > main.cpp

run() {  # run STATUS: the driver with --emit-c; the output, the status and the time log are in $work
  rm -f "$work/log" "$work/cpfe.log"
  (env -i PATH="$PATH" HOME="$HOME" RUBY="$(command -v ruby)" EDG_BUILD="$work/edg" EDG_BASE="$work/base" \
     NFCXX_TIME_LOG="$work/log" CPFE_LOG="$work/cpfe.log" CPFE_STATUS="$1" \
     "$repo/nfcxx" --emit-c main.cpp) > "$work/out" 2> "$work/err"; st=$?
}

run 0
if [ $st = 0 ] && grep -qx 'int emitted(void);' "$work/out"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL --emit-c prints the generated C (status $st)"; fi
if [ "$(sed -n 1p "$work/cpfe.log")" = "$work/base" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL the front end runs in the EDG base directory"; fi
if grep -q -- '^--c++23$' "$work/cpfe.log" && grep -q -- '^--gen_c_file_name=' "$work/cpfe.log" && grep -qx "$work/main.cpp" "$work/cpfe.log"; then
  pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL the front end gets the standard, the output name and the source"; fi
if grep -qP '^\d+\.\d{6}\tfrontend\tcpfe --emit-c \(front end\)\t' "$work/log" 2>/dev/null; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL the time log has the front end span"; fi

run 3
if [ $st = 3 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL a failing front end ends the driver with its status (status $st)"; fi
if ! grep -q 'frontend' "$work/log" 2>/dev/null; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL a failing front end writes no span"; fi

# under --trace the driver batches its spans (NFCXX_TRACE_PENDING): the front end's span is written with them, in the time log too
rm -f "$work/log" "$work/t.json"
(env -i PATH="$PATH" HOME="$HOME" RUBY="$(command -v ruby)" EDG_BUILD="$work/edg" EDG_BASE="$work/base" \
   NFCXX_TIME_LOG="$work/log" CPFE_LOG="$work/cpfe.log" CPFE_STATUS=0 \
   "$repo/nfcxx" --emit-c --trace="$work/t.json" main.cpp) > /dev/null 2>&1; st=$?
if [ $st = 0 ] && [ "$(grep -c 'cpfe --emit-c (front end)' "$work/log")" = 1 ] && grep -q 'cpfe --emit-c (front end)' "$work/t.json"; then
  pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL the batched front end span is in the time log and the trace (status $st)"; fi

echo "driver-emit-c-run: $pass passed, $fail failed"
[ $fail = 0 ]
