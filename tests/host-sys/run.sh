#!/bin/bash
# Differential test of scripts/host-sys.rb (the Ruby port of the host probes) against tests/host-sys/oracle.sh (the bash
# original). Each case runs one function both ways with the same environment and the same fake host compiler, and the
# two must print the same stdout and exit with the same status. The fake compilers answer the probes the way GCC, Apple
# clang and a clang past EDG's table limit do, and a missing compiler. Lines of the form "CASE | FUNCTION ARGS".
#
#   bash tests/host-sys/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
oracle=$here/oracle.sh
ruby_cli=$repo/scripts/host-sys.rb
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/dir"

# the fake compilers: --version, -dumpfullversion and the search list of "-E -x LANG -v -"
cat > "$work/bin/gnu" <<'EOF'
#!/bin/bash
case " $* " in
  *" --version "*) echo "g++ (GCC) 13.3.0"; echo "Copyright (C) 2023" ;;
  *" -dumpfullversion "*) echo 13.3.0 ;;
  *" -E "*) { echo '#include <...> search starts here:'; echo ' /fake/c++/13'; echo ' /fake/include';
              echo ' /fake/framework (framework directory)'; echo 'End of search list.'; } >&2 ;;
esac
EOF
cat > "$work/bin/clang21" <<'EOF'
#!/bin/bash
case " $* " in
  *" --version "*) echo "Apple clang version 21.0.0 (clang-2100.0.123.5)" ;;
  *" -dumpfullversion "*) echo "clang: error: no input files" >&2; exit 1 ;;
  *" -E "*) { echo '#include <...> search starts here:'; echo ' /fake/libcxx'; echo 'End of search list.'; } >&2 ;;
esac
EOF
cat > "$work/bin/clang22" <<'EOF'
#!/bin/bash
case " $* " in
  *" --version "*) echo "clang version 22.1.2" ;;
  *" -dumpfullversion "*) echo 22.1.2 ;;
esac
EOF
cat > "$work/bin/clang_nodump" <<'EOF'
#!/bin/bash
case " $* " in
  *" --version "*) echo "clang version 19.1.0" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work"/bin/*

cases=(
  "gnu | host_dialect"
  "gnu | host_clang_version"
  "gnu | host_gnu_version"
  "gnu | host_sys_includes"
  "gnu | host_sys_includes c"
  "clang21 | host_dialect"
  "clang21 | host_clang_version"
  "clang21 | host_gnu_version"
  "clang21 | host_sys_includes"
  "clang22 | host_clang_version"
  "clang22 | host_gnu_version"
  "clang_nodump | host_clang_version"
  "clang_nodump | host_gnu_version"
  "missing | host_dialect"
  "missing | host_clang_version"
  "missing | host_gnu_version"
  "missing | host_sys_includes"
  "override | host_sys_includes"
  "override | host_sys_includes c"
  "none | host_qbe_target"
  "none | abs_path scripts/no-such-file.rb"
  "none | abs_path nodir/x"
  "none | abs_path $repo/tests/host-sys/../host-sys/oracle.sh"
)

# the environment of a case, as shell assignments
env_of() {
  case $1 in
    gnu) echo "NFCXX_CXX=$work/bin/gnu NFCXX_CC=$work/bin/gnu" ;;
    clang21) echo "NFCXX_CXX=$work/bin/clang21 NFCXX_CC=$work/bin/clang21" ;;
    clang22) echo "NFCXX_CXX=$work/bin/clang22 NFCXX_CC=$work/bin/clang22" ;;
    clang_nodump) echo "NFCXX_CXX=$work/bin/clang_nodump NFCXX_CC=$work/bin/clang_nodump" ;;
    missing) echo "NFCXX_CXX=$work/bin/absent NFCXX_CC=$work/bin/absent" ;;
    override) echo "NFCXX_CXX=$work/bin/gnu NFCXX_SYS_INCLUDES=/x/one:/x/two:" ;;
    none) echo "NFCXX_CXX=$work/bin/gnu" ;;
  esac
}

pass=0; fail=0
for c in "${cases[@]}"; do
  name=${c%%|*}; name=${name// /}
  fn=${c#*|}; fn=${fn# }
  envs=$(env_of "$name")
  # shellcheck disable=SC2086
  a=$(cd "$repo" && env -i PATH="$work/bin:/usr/bin:/bin:$(dirname "$(command -v ruby)")" HOME="$work" $envs \
        bash -c 'source "$1"; shift; "$@"' bash "$oracle" $fn 2>/dev/null); sa=$?
  # shellcheck disable=SC2086
  b=$(cd "$repo" && env -i PATH="$work/bin:/usr/bin:/bin:$(dirname "$(command -v ruby)")" HOME="$work" $envs \
        ruby "$ruby_cli" $fn 2>/dev/null); sb=$?
  if [ "$a" = "$b" ] && [ "$sa" = "$sb" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [$name] $fn"
    echo "  bash ($sa): $(printf '%s' "$a" | tr '\n' '|')"
    echo "  ruby ($sb): $(printf '%s' "$b" | tr '\n' '|')"
  fi
done
echo "host-sys: $pass passed, $fail failed"
[ $fail = 0 ]
