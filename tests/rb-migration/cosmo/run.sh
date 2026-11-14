#!/bin/bash
# Differential test: scripts/setup-cosmo.rb against the bash it replaced (oracle.sh here). See ../lib.sh.
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=cosmo

# PRESENT=1: build/cosmocc/bin/cosmocc is there already (an executable that prints its version)
prep() {
  case " $2 " in
    *" PRESENT=1 "*)
      mkdir -p "$1/root/build/cosmocc/bin"
      printf '#!/bin/sh\necho "cosmocc 4.0.2 (fixture)"\n' > "$1/root/build/cosmocc/bin/cosmocc"
      chmod +x "$1/root/build/cosmocc/bin/cosmocc" ;;
  esac
}

rbm_cases <<'EOF'
fresh, pinned digest|
fresh, digest differs|RB_STUB_SHA=1
already present|PRESENT=1
url without digest|COSMOCC_URL=https://mirror.test/cosmocc.zip
url with digest|COSMOCC_URL=https://mirror.test/cosmocc.zip COSMOCC_SHA256=abc123
empty url is unset|COSMOCC_URL=
custom dir|COSMOCC_DIR=@SB@/custom
curl fails|RB_STUB_CURL_FAIL=22
EOF
rbm_finish
