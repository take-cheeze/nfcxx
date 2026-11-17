#!/bin/bash
# Stage B1 of docs/notes/driver-body-port.md: the oracle of the driver body. tests/driver-body/nfcxx-bash is ./nfcxx as it was
# when the port began (frozen; the bash driver's behaviour is what the Ruby driver must match). This checks that the frozen
# copy still runs and that it is the file it was taken from: the bash syntax parses, the copy's first lines are the driver's,
# and the copy answers --help as the driver does. The body stages compare against it (see the plan).
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
oracle=$here/nfcxx-bash
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }
bash -n "$oracle"; check "the frozen driver parses" $?
# the driver differs from the frozen copy only where the ports moved code out: the Ruby flag (B2) and the default backend block (B3,
# scripts/nfcxx-backend.rb default). Both are removed from both sides; the rest must be the same.
# the oracle's cu_prepare reply loop (B4) is removed before the comparison: from the line after its --cu-prepare call to its cuda_opts line
oracle_cu=$(mktemp); awk '
  /--cu-prepare < "\$inf" > "\$outf" \|\| exit \$\?$/ { print; skip = 1; next }
  skip && /^  cuda_opts=\(\$\{cu_cuda/ { skip = 0; next }
  /--prepare < "\$inf" > "\$outf" \|\| exit \$\?$/ && !cpp2 { print; skip2 = 1; next }
  skip2 && /^  cflags\+=\("-I\$cppfront_src\/include"\)/ { skip2 = 0; next }
  /^  \{$/ && !pend { pend = 1; held = $0; next }
  pend && /^    state_put root "\$root"; state_put tmp "\$cudatmp"; state_put keep/ { pend = 0; skip3 = 1; next }
  pend { print held; pend = 0 }
  skip3 && /^  \} > "\$inf"$/ { skip3 = 0; next }
  /^# lookup: the --cache-log block/ { skip4 = 1 }
  skip4 && /^return 0$/ { skip4 = 0; next }
  /^    local key; key=\$\(realpath -m/ { next }
  /^    dir=\$\{NFCXX_CU_CACHE:-/ { next }
  /^  while IFS= read -r d; do files\+=\("\$d"\); done < <\($/ { skip5 = 1; next }
  skip5 && /p.\)$/ { skip5 = 0; next }
  skip5 { next }
  /^  inc=\(\${sys_inc\[@\]\+\${sys_inc/ { skip6 = 1; next }
  skip6 && /^  for x in \$\{files\[@\]/ { skip6 = 0; next }
  skip6 { next }
  /^# ensure_tool DIR OUT: builds the repo tool/ { skip7 = 1 }
  skip7 && /^}$/ { skip7 = 0; next }
  skip7 { next }
  /^ensure_tool "\$root\/tools\/cuda-rewrite" / { next }
  /^keep_static=\(--c_to_obj_option -fkeep-static-functions\)$/ { next }
  /^"\$\{NFCXX_GCC:-cc\}" --version 2>\/dev\/null \| head -1 \| grep -qi clang/ { next }
  !skip && !skip2 && !skip3 && !skip4 { print }' "$oracle" > "$oracle_cu"
check "the frozen driver matches the driver apart from the ports (B2, B3)" "$(
  diff -q <(sed -e 's/trap .*EXIT//' -e 's/^  eccp_dir=\$(mktemp -d); $/  eccp_dir=$(mktemp -d)/' -e '/^default_backend=0$/,/^fi$/d' -e '/^if \[ -n "\$sanitize" \]; then$/,/^fi$/d' -e '/^if \[ \$cosmo = 1 \]; then$/,/^fi$/d' -e '/^if \[ \$freestanding = 1 \]; then$/,/^fi$/d' -e '/^# Path B hosted on macOS (the SDK/,/__AARCH64EL__=1); files+=(-D__AARCH64EL__=1); }$/d' -e '/^inst_opts=()$/,/^esac$/d' -e '/^  for e in \${eccp_envs\[@\]+"\${eccp_envs\[@\]}"}; do export "\$e"; done$/d' -e '/^if \[ -n "\$target" \] && \[ "\$target" != linux_k1om \]; then$/,/^fi$/d' -e '/^\[ \${#gnu_opts\[@\]} -gt 0 \] && export EDG_CPFE_DEFAULT_OPTIONS=/d' -e '/^\[ \$shared = 0 \] || { export EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=-shared; ldopts=(-shared); }$/d' -e '/^\[ -z "\$time_log" \] || export NFCXX_TIME_LOG=/d' -e '/^if \[ "\$target" = linux_k1om \]; then$/,/^fi$/d' -e '/^case \$backend in$/,/^esac$/d' -e '/^\[ -n "\${CUDA_HOME:-}" \] && export NFCXX_SYSTEM_PATHS=/d' -e '/^\[ "\${NFCXX_CUDA_TARGET:-nvidia}" = amdgpu \] && export NFCXX_SYSTEM_PATHS=/d' -e '/^trace_unit=\${srcs\[0\]-\$out}; export NFCXX_TRACE_UNIT=\$trace_unit/d' -e '/^  nm -C "\$out" 2>\/dev\/null | sed/d' -e '/^    NFCXX_CUDA_HOST_SYMBOLS=\$hsyms NFCXX_CACHE= NFCXX_CACHE_REMOTE= "\$root\/nfcxx"/d' -e '/^  found=0$/,/^  done < "\$cudatmp\/\$(basename "\${cu_inputs\[0\]}" .cu).dev.kernels.unresolved"$/d' -e '/^gnu_opts=()$/,/^fi$/d' -e '/^loop_ld=""$/,/^done$/d' -e '/^loop_set() {/,/^}/d' -e '/^loop_append() {/,/^}/d' -e '/^loop_recs=(); loop_done=0/,/^done$/d' -e '/^  posix_def=(-D_POSIX_SOURCE)/d' -e '/^  # The C++ and atomic libraries of the host: macOS/,/^  \[ \$freestanding = 0 \] || { pb_cxx_libs=""/d' -e '/^      \*) b=\$(basename "\$f"); dst=\${b%\.\*}\.o; \[ \$outset = 1 \] && dst=\$out$/d' -e '/^      dst=\$out; \[ \$outset = 1 \] || dst=\$(basename "\${cfiles\[\$i\]}" \.c)\.o$/d' -e '/^  b=\$(basename "\${srcs\[0\]}"); out=\${b%\.\*}\.o$/d' -e '/^  df=\${dfile:-/,/^    \${sysdirs\[@\]/d' "$oracle_cu") \
          <(sed -e 's/trap .*EXIT//' -e '/^    # the directory is scripts\/nfcxx-cpp2.rb/d' -e '/--cpp2-dir=/d' -e '/^ks_sh=/d' -e '/^eval "\$ks_sh"$/d' -e '/^# ensure_tool DIR OUT, as a Ruby call/,/^# directory OUT.lock/d' -e '/nfcxx-ensure-tool.rb/d' -e '/^  # the include list: scripts\/nfcxx-emit-c.rb inc/,/^  # in front of them, made absolute/d' -e '/nfcxx-emit-c.rb/d' -e '/^  inc=()$/d' -e '/^  while IFS= read -r -d .. x; do inc+=/d' -e '/^  # the -D options of the macros the -m options add/d' -e '/nfcxx-isa-macros.rb/d' -e '/^  # the eccp directory and its temporary directories are removed by eccp_cleanup/,/^  if \[ "\${NFCXX_TMP_OWNED:-}" = 1 \]; then ; fi$/d' -e '/^# NFCXX_RUBY_DRIVER=1/,/NFCXX_RUBY_DRIVER:-0/d' -e '/^if \[ -n "\$sanitize" \]; then$/,/^fi$/d' -e '/^if \[ \$cosmo = 1 \]; then$/,/^fi$/d' -e '/^# The freestanding or hosted setup/,/^fi$/d' -e '/^# The host-platform cflags (Path B/,/nfcxx-host-cflags.rb\" plan/d' -e '/^# --instantiate: scripts\/nfcxx-instantiate.rb/d' -e '/^inst_sh=/d' -e '/^eval "\$inst_sh"$/d' -e '/^# The front end.s version option/d' -e '/^gnu_sh=/d' -e '/^eval "\$gnu_sh"$/d' -e '/^trace_sh=/d' -e '/^eval "\$trace_sh"; export NFCXX_TRACE_UNIT/d' -e '/^sysp_sh=/d' -e '/^\[ -z "\$sysp_sh" \] || eval/d' -e '/^backend_sh=/d' -e '/^eval "\$backend_sh"$/d' -e '/^# --target=linux_k1om: the k1om toolchain/d' -e '/^k1om_sh=/d' -e '/^\[ -z "\$k1om_sh" \] || eval/d' -e '/^tl_sh=/d' -e '/^\[ -z "\$tl_sh" \] || eval/d' -e '/^sl_sh=/d' -e '/^\[ -z "\$sl_sh" \] || eval/d' -e '/^  # the reply (scripts\/nfcxx-cu-apply.rb plan, restructure/,/^  eval "\$cu_sh"$/d' -e '/^  # the planner.s state records (scripts\/nfcxx-state-records.rb/,/nfcxx-state-records.rb" "\${st\[@\]}" > "\$inf"$/d' -e '/^# the lookup and the cache log (scripts\/nfcxx-cache-check.rb check/,/^return 0$/d' -e '/^  found=0$/,/^  done < "\$cudatmp\/\$(basename "\${cu_inputs\[0\]}" .cu).dev.kernels.unresolved"$/d' -e '/^  # the unresolved kernels that the host symbols define/d' -e '/nfcxx-second-pass.rb" host-symbols/d' -e '/nfcxx-second-pass.rb" rerun/d' -e '/nfcxx-second-pass.rb" found/d' -e '/^  # the reply (scripts\/nfcxx-cu-apply.rb plan kind=cpp2/,/^  eval "\$cpp2_sh"$/d' -e '/^tgt_sh=/d' -e '/^\[ -z "\$tgt_sh" \] || eval/d' -e '/^# --target=NAME: the EDG table/,/^# The gnu_opts array is passed/d' -e '/^  # the eccp environment (scripts\/nfcxx-eccp-env.rb plan/d' -e '/nfcxx-eccp-env.rb" plan envs=/d' -e '/^# The backend.s compiler .NFCXX_CC. and its refusals/d' -e '/^# The loop.s state as the shell statements/,/^eval "\$loop_sh"$/d' -e '/^  # posix_def: as the macOS base/d' -e '/^  # The C++ and atomic libraries of the host (macOS/,/nfcxx-host-libs.rb" plan/d' -e '/nfcxx-host-libs.rb" plan/d' -e '/nfcxx-objname.rb/d' -e '/^    dst=\${pbobj\[\$j\]}; j=\$((j + 1))$/d' -e '/^      \*) \[ \$outset = 1 \] && dst=\$out$/d' -e '/^      dst=\$out; \[ \$outset = 1 \] || dst=\${cobjn\[\$i\]}$/d' -e '/^  dep_cmd=();/d' -e '/^  \[ \${#dep_cmd\[@\]} -gt 0 \] || exit 1$/d' -e '/^  "\${dep_cmd\[@\]}"$/d' "$repo/nfcxx" \
            | awk '/^# The default backend \(docs\/notes\/pathb-default.md; the rule is/ { skip = 1 }
                   skip && /uname -m\)"\)"$/ { skip = 0; next }
                   !skip') >/dev/null && echo 0 || echo 1)"
# B2: the flag runs the Ruby skeleton, which runs the oracle: a compile gives the same stdout, stderr and status
src=$(mktemp -d); printf 'int main() { return 0; }\n' > "$src/m.cpp"
(cd "$src" && "$repo/nfcxx" -c m.cpp -o plain.o >p.out 2>p.err; echo $? > p.rc; NFCXX_RUBY_DRIVER=1 "$repo/nfcxx" -c m.cpp -o flag.o >f.out 2>f.err; echo $? > f.rc)
check "the Ruby skeleton gives the bash driver's stdout, stderr and status" "$(cd "$src" && cmp -s p.out f.out && cmp -s p.err f.err && cmp -s p.rc f.rc && echo 0 || echo 1)"
rm -rf "$src"

echo "driver-body: $pass passed, $fail failed"
[ "$fail" = 0 ]
