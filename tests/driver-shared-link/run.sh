#!/bin/bash
# scripts/nfcxx-shared-link.rb plan must leave EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS (exported) and ldopts as the bash line of nfcxx does
# (verbatim below), for shared 0 and 1, with ldopts set or not.   bash tests/driver-shared-link/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
for shared in 0 1; do for ldset in unset set; do
  state() { printf 'exp=%s ldopts=[%s] ldset=%s\n' "$(printenv EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS || true)" "${ldopts[*]-}" "${ldopts+set}"; }
  want=$( env -u EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS bash -c "$( [ $ldset = set ] && echo 'ldopts=(-old)'; echo "shared=$shared"; echo '[ $shared = 0 ] || { export EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=-shared; ldopts=(-shared); }'; declare -f state; echo state )" )
  got=$( env -u EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS bash -c "$( [ $ldset = set ] && echo 'ldopts=(-old)'; echo "shared=$shared"; echo "eval \"\$(ruby '$repo/scripts/nfcxx-shared-link.rb' plan shared=\$shared)\""; declare -f state; echo state )" )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL shared=$shared ldset=$ldset"; echo "  bash: $want"; echo "  ruby: $got"; fi
done; done
echo "driver-shared-link: $pass passed, $fail failed"
[ $fail = 0 ]
