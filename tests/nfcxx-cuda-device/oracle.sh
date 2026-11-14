#!/usr/bin/env bash
# The oracle of scripts/nfcxx-cuda-device.rb: nfcxx's CUDA device build run on one .cu input, with the tools stubbed. The
# functions are nfcxx's own, copied from nfcxx with awk: cu_prepare, cu_rewrite, ir_opt_device, cu_amd_build, cu_device_build.
# In cu_device_build the xargs -P that assembles the groups is replaced (sed) by a loop that logs the job count (JOBS) and
# runs ptxas once per group in glob order: the parallel run is scheduling, the count is the decision.
# The stubs: the tools (the rewriter, the emitter, pathb-dump, ptxas, clang, the IR passes through ruby) run tool-stub, which
# logs its command line; ensure_tool builds a missing tool (a copy of tool-stub); mktemp is CU_TEST_TMP; the trace, the cache
# log and the device key (CU_TEST_KEY) are no-ops. cp, mv, mkdir and rm log their lines and run. The log is printed at the end.
#   tests/nfcxx-cuda-device/oracle.sh ROOT SRC [--cflag=ARG | --compile | --out=PATH | --ir-opt=V | --cache-dir=DIR | --cache-key=KEY]...
# run.sh gives the environment (CU_TEST_*, and the NFCXX_* and CUDA_HOME variables of the case).
here=$(cd "$(dirname "$0")" && pwd)
nfcxx=$here/../../nfcxx

extract() {  # extract NAME: nfcxx's function NAME, from its header line to the closing brace at column 0
  awk -v f="$1" 'index($0, f "() {") == 1 { p = 1 } p { print } p && $0 == "}" { p = 0 }' "$nfcxx"
}
text=$({ extract cu_prepare; extract cu_rewrite; extract ir_opt_device; extract cu_amd_build; extract cu_device_build; } |
  sed -e 's#^    ls "\$groups"/g\*\.ptx | xargs -P .*$#    _out JOBS "${NFCXX_PTXAS_JOBS:-4}"; for f in "$groups"/g*.ptx; do "$ptxas" -arch=sm_$sm "$f" -o "${f%.ptx}.cubin" || exit $?; done#')
[ "$(printf '%s\n' "$text" | grep -c 'xargs')" = 0 ] || { echo "oracle: the xargs line of cu_device_build was not replaced" >&2; exit 2; }
[ "$(printf '%s\n' "$text" | grep -c '^cu_[a-z_]*() {\|^ir_opt_device() {')" = 5 ] || { echo "oracle: the functions were not all extracted" >&2; exit 2; }
eval "$text"

# The stubs (after the functions, so they replace any of their commands).
_out() { local s=$1 x; shift; for x in "$@"; do s+=" $x"; done; printf '%s\n' "$s" >> "$CU_TEST_LOG"; }
ensure_tool() { if [ ! -e "$2" ]; then _out RUN ensure_tool "$1" "$2"; command cp "$here/tool-stub" "$2"; fi; return 0; }
cp() { _out CP "$@"; command cp "$@"; }
mv() { _out RUN mv "$@"; command mv "$@"; }
mkdir() { _out RUN mkdir "$@"; command mkdir "$@"; }
rm() { _out RUN rm "$@"; command rm "$@"; }
ruby() { _out RUN ruby "$@"; }
mktemp() { printf '%s\n' "$CU_TEST_TMP"; }
trace_start() { :; }
trace_end() { :; }
trace_finish() { :; }
cache_log() { :; }
cu_device_key() { printf '%s\n' "${CU_TEST_KEY-}"; }

root=$1; src=$2; shift 2
rewriter=("$root/build/cuda-rewrite")
cflags=(); files=(); srcs=(); preinc=(); cu_inputs=("$src"); cu_keep=""; cudatmp=""
compile_only=0; out=""; outset=0; cache_dir=""; ir_opt=""; ir_opt_set=0
promote_slots=${NFCXX_PROMOTE_SLOTS:-1}; unroll=${NFCXX_UNROLL:-1}; struct_slots=${NFCXX_STRUCT_SLOTS:-1}
obfuscate=0; case ${NFCXX_OBFUSCATE_KERNELS:-0} in 0|"") ;; *) obfuscate=1 ;; esac
for a in "$@"; do
  case $a in
    --cflag=*) cflags+=("${a#--cflag=}") ;;
    --compile) compile_only=1 ;;
    --out=*) out=${a#--out=}; outset=1 ;;
    --ir-opt=*) ir_opt=${a#--ir-opt=}; ir_opt_set=1 ;;
    --cache-dir=*) cache_dir=${a#--cache-dir=} ;;
    --cache-key=*) CU_TEST_KEY=${a#--cache-key=} ;;
    *) echo "oracle: unknown argument $a" >&2; exit 2 ;;
  esac
done

cu_prepare
trap - EXIT   # the exit cleanup of the temporary directory is not a command of the build
cat "$CU_TEST_LOG" 2>/dev/null
