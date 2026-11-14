#!/bin/bash
# Differential test: scripts/setup-mold.rb against the bash it replaced (oracle.sh here). See ../lib.sh. The pinned commit
# of v3.0.0 is 8de38c35a2df16a25f7ff87ac3ad07156a925beb; the stubbed git reports RB_STUB_GIT_HEAD for rev-parse.
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=mold
PIN=8de38c35a2df16a25f7ff87ac3ad07156a925beb

prep() { :; }

rbm_cases <<EOF
fresh|RB_STUB_GIT_HEAD=$PIN
other commit|RB_STUB_GIT_HEAD=0123456789abcdef
no cargo|RB_OMIT=cargo RB_STUB_GIT_HEAD=$PIN
cargo fails|RB_STUB_GIT_HEAD=$PIN RB_STUB_CARGO_FAIL=101
clone fails|RB_STUB_GIT_FAIL=clone RB_STUB_GIT_HEAD=$PIN
EOF
rbm_finish
