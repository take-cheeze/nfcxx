#!/bin/bash
# Differential test: scripts/setup-cil.rb against the bash it replaced (oracle.sh here). See ../lib.sh.
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=cil

# PRESENT=1: build/cil/ilasm is there already
prep() {
  case " $2 " in
    *" PRESENT=1 "*)
      mkdir -p "$1/root/build/cil"
      echo "ilasm fixture" > "$1/root/build/cil/ilasm"
      chmod +x "$1/root/build/cil/ilasm" ;;
  esac
}

rbm_cases <<'EOF'
fresh|
arm64|RB_STUB_MACHINE=aarch64
unsupported machine|RB_STUB_MACHINE=riscv64
not linux|RB_STUB_SYSTEM=Darwin
already present|PRESENT=1
curl fails|RB_STUB_CURL_FAIL=22
python fails|RB_STUB_PY_FAIL=1
EOF
rbm_finish
