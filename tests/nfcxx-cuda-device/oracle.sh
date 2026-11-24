#!/usr/bin/env bash
# The oracle of tests/nfcxx-cuda-device/run.sh: the commands nfcxx's CUDA device build runs for one case, as recorded in
# golden/NAME.txt. Line 1 is "status N", the status the build exited with; the rest is the log of the stubbed commands the build
# made. The case's tree is @WORK@, the checkout is @REPO@, and the PID of a cache store's temporary directory is .tmp.PID.
# The golden was recorded from nfcxx's CUDA device build (the bash functions cu_prepare, cu_rewrite, ir_opt_device, cu_amd_build
# and cu_device_build, with the tools stubbed: the rewriter, the emitter, pathb-dump, ptxas, clang and the IR passes log their
# command lines through tool-stub; ensure_tool, cp, mv, mkdir and rm log theirs; the cu_device_build xargs -P is a loop that logs
# JOBS) at the commit this file was last changed in, for every case of cases.txt. The frozen bash copy is in git history.
#   tests/nfcxx-cuda-device/oracle.sh NAME     prints the log of case NAME and exits with its status
here=$(cd "$(dirname "$0")" && pwd)
g=$here/golden/$1.txt
[ -r "$g" ] || { echo "oracle: no golden for case $1" >&2; exit 2; }
st=$(head -n 1 "$g")
case $st in "status "[0-9]*) ;; *) echo "oracle: $g has no status line" >&2; exit 2 ;; esac
tail -n +2 "$g"
exit "${st#status }"
