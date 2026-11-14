#!/bin/bash
# Differential test: scripts/setup-tinygo.rb against the bash it replaced (oracle.sh here). See ../lib.sh.
# INSTALLED=1: build/tinygo has the pinned version; OLD=1: it has an older one.
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=tinygo

prep() {
  local dir="$1/root/build/tinygo" version=
  case " $2 " in
    *" INSTALLED=1 "*) version=0.39.0 ;;
    *" OLD=1 "*) version=0.38.0 ;;
  esac
  if [ -n "$version" ]; then
    mkdir -p "$dir/bin"
    printf '#!/bin/sh\n' > "$dir/bin/tinygo"
    chmod +x "$dir/bin/tinygo"
    echo "$version" > "$dir/.version"
  fi
}

rbm_cases <<'EOF'
fresh|
installed|INSTALLED=1
old version|OLD=1
forced|INSTALLED=1 FORCE=1
other architecture|RB_STUB_MACHINE=aarch64
other system|RB_STUB_SYSTEM=Darwin
download fails|RB_STUB_CURL_FAIL=22
checksum fails|RB_STUB_SHA=1
EOF
rbm_finish
