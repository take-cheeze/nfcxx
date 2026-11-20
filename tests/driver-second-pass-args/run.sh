#!/bin/bash
# Stage B7 of docs/notes/driver-body-port.md: the second pass from the Ruby driver (scripts/nfcxx.rb). The oracle (tests/driver-body/
# nfcxx-bash, frozen) runs its second pass as "$root/nfcxx" with NFCXX_CUDA_HOST_SYMBOLS; the Ruby driver makes that line run
# scripts/nfcxx-second-pass.rb run, which starts scripts/nfcxx.rb with the same environment and arguments. Checked here, without a
# CUDA toolkit: the substituted line runs the Ruby driver with the bash's environment (host symbols, cache emptied, TMPDIR and the
# driver's own variables inherited), arguments and status (also a signal), and records no span of its own (the oracle's trace
# span is kept). The substitution changes only that line. The refusals the Ruby driver prints before its oracle come first, as
# before, with the second pass's environment set. What needs a CUDA toolkit, and is not run here: a whole .cu compile that reaches
# the second pass (the gate needs the device rewrite's .dev.kernels.unresolved), and the temporary-directory cleanup of that run.
#   bash tests/driver-second-pass-args/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int main(){return 0;}\n' > m.cpp
printf 'export module mm;\nexport int f(){return 1;}\n' > mod.cc
printf 'export module mm:part;\n' > part.cc
mkdir -p tmp

# the stub roots: a bash ./nfcxx (the bash's second run) and scripts/nfcxx.rb (the Ruby driver's), each printing its environment,
# arguments and status. The Ruby stub's root also holds the real second-pass helper (the substituted line calls it there).
bash_stub="$work/bash-root"; ruby_stub="$work/ruby-root"
mkdir -p "$bash_stub" "$ruby_stub/scripts"
cat > "$bash_stub/nfcxx" <<'STUB'
#!/bin/bash
printf 'hs=%s cache=%s remote=%s tmp=%s owned=%s args=' "$NFCXX_CUDA_HOST_SYMBOLS" "$NFCXX_CACHE" "$NFCXX_CACHE_REMOTE" "$TMPDIR" "$NFCXX_TMP_OWNED"
printf '[%s]' "$@"; echo
if [ "${STUB_MODE:-}" = signal ]; then kill -TERM $$; fi
exit "${STUB_STATUS:-7}"
STUB
chmod +x "$bash_stub/nfcxx"
cat > "$ruby_stub/scripts/nfcxx.rb" <<'STUB'
#!/usr/bin/env ruby
puts "hs=#{ENV["NFCXX_CUDA_HOST_SYMBOLS"]} cache=#{ENV["NFCXX_CACHE"]} remote=#{ENV["NFCXX_CACHE_REMOTE"]} tmp=#{ENV["TMPDIR"]} owned=#{ENV["NFCXX_TMP_OWNED"]} args=" + ARGV.map { |a| "[#{a}]" }.join
Process.kill("TERM", Process.pid) if ENV["STUB_MODE"] == "signal"
exit Integer(ENV.fetch("STUB_STATUS", "7"))
STUB
for f in nfcxx-second-pass.rb trace.rb host-sys.rb; do ln -s "$repo/scripts/$f" "$ruby_stub/scripts/$f"; done

# the oracle's second-run line (the bash's), and the same line as the Ruby driver makes it (scripts/nfcxx.rb's oracle text)
want_line=$(grep -F 'NFCXX_CUDA_HOST_SYMBOLS=$hsyms NFCXX_CACHE= NFCXX_CACHE_REMOTE=' "$repo/tests/driver-body/nfcxx-bash" | head -1 | sed 's/^ *//')
got_line=$(ruby -I "$repo/scripts" -e 'require "nfcxx-second-pass"; text = NfcxxSecondPass.oracle_text(File.read(ARGV[0])); abort "no line" unless text
  puts text.lines.grep(/nfcxx-second-pass\.rb" run /).map { |l| l.sub(/^ */, "") }' "$repo/tests/driver-body/nfcxx-bash")
if [ -n "$want_line" ] && [ -n "$got_line" ] && [ "$(echo "$got_line" | wc -l)" = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL the substituted line: [$got_line]"; fi

# the substitution changes that one line of the oracle, and nothing else
if ruby -I "$repo/scripts" -e 'require "nfcxx-second-pass"; t = File.read(ARGV[0]); o = NfcxxSecondPass.oracle_text(t)
  exit(1) unless o && t.lines.size == o.lines.size && t.lines.zip(o.lines).count { |a, b| a != b } == 1
  exit(1) unless NfcxxSecondPass.oracle_text("no such line\n").nil?' "$repo/tests/driver-body/nfcxx-bash"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL the oracle text: the substitution changes more than the second-run line, or does not apply"
fi

# eval-line.sh ROOT HSYMS LINE ARG...: the oracle's second-run line evaluated as the oracle evaluates it (root, hsyms and args2 set)
cat > "$work/eval-line.sh" <<'EVAL'
root=$1; hsyms=$2; line=$3; shift 3; args2=("$@"); eval "$line"
EVAL

# run_both LABEL [ENV=VALUE...] -- ARG...: the bash's second-run line with the bash stub, and the substituted line with the Ruby stub,
# in the same environment; the output and the status of each must match
run_both() {
  local label=$1; shift
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  local got want gst wst
  got=$(env "${envs[@]}" bash "$work/eval-line.sh" "$ruby_stub" /h/host.syms "$got_line" "$@" 2>&1); gst=$?
  want=$(env "${envs[@]}" bash "$work/eval-line.sh" "$bash_stub" /h/host.syms "$want_line" "$@" 2>&1); wst=$?
  if [ "$got" = "$want" ] && [ "$gst" = "$wst" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $label: ruby [$got] $gst, bash [$want] $wst"; fi
}
# the bash's second run: the stub's output, the status, the environment it was given
run_both "spawn, status 7" -- -c m.cpp -o m.o
run_both "status 0" STUB_STATUS=0 -- -c m.cpp -o m.o
run_both "status 3, arguments with spaces and quotes" STUB_STATUS=3 -- -c "my file.cpp" -o "o'x.o" -DA=1
run_both "cache left out (NFCXX_CACHE and NFCXX_CACHE_REMOTE emptied)" NFCXX_CACHE=/c NFCXX_CACHE_REMOTE=/r -- -c m.cpp -o m.o
run_both "TMPDIR and NFCXX_TMP_OWNED inherited" TMPDIR="$work/tmp" NFCXX_TMP_OWNED=1 -- -c m.cpp -o m.o
run_both "the run ends by a signal (128 + its number)" STUB_MODE=signal -- -c m.cpp -o m.o

# no span of its own: the oracle's trace_end records the second pass, so the run adds no time-log line
log="$work/time.log"; : > "$log"
NFCXX_TIME_LOG="$log" bash "$work/eval-line.sh" "$ruby_stub" /h/host.syms "$got_line" -c m.cpp -o m.o >/dev/null 2>&1
if [ ! -s "$log" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL the run records a span: $(cat "$log")"; fi

# the refusals come first: the Ruby driver prints the refusal the bash prints, with the second pass's environment set (the host symbols
# and the cache emptied), and the bash's status. A second-pass change must not alter which refusal prints first.
check_same() {  # check_same ARG...: the Ruby driver and the bash driver give the same output (stderr and stdout) and status
  local got want
  got=$(NFCXX_CUDA_HOST_SYMBOLS=/h/host.syms ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1; echo "status=$?")
  want=$(NFCXX_CUDA_HOST_SYMBOLS=/h/host.syms bash "$repo/nfcxx" "$@" 2>&1; echo "status=$?")
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $*"; echo "  driver: $got"; echo "  bash:   $want"; fi
}
refused() {  # refused MESSAGE ARG...: the message on stderr, status 2, as the bash
  local want_msg=$1; shift
  local got status
  got=$(NFCXX_CUDA_HOST_SYMBOLS=/h/host.syms ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1 >/dev/null); status=$?
  if [ "$got" = "$want_msg" ] && [ "$status" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL refused $*: status $status"; echo "  driver: $got"; echo "  want:   $want_msg"; fi
  check_same "$@"
}
refused "nfcxx: unknown backend 'bogus'" --backend=bogus -c m.cpp -o m.o
refused "nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got bogus)" --instantiate=bogus -c m.cpp -o m.o
refused "nfcxx: part.cc: module partitions are not supported yet (docs/notes/modules.md)" -c part.cc m.cpp -o y.o
refused "realpath: /nonexistent/a: No such file or directory" -c /nonexistent/a/x.cu -o x.o
refused "realpath: /nonexistent/a: No such file or directory" --backend=bogus -c /nonexistent/a/x.cu -o x.o
check_same -c mod.cc -o m.o
check_same -c m.cpp -o m.o
check_same -fsyntax-only m.cpp
check_same -E m.cpp

echo "driver-second-pass-args: $pass passed, $fail failed"
[ $fail = 0 ]
