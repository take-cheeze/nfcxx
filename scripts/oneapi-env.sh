# oneAPI runtime environment for the scripts that build or run SYCL and oneAPI programs. Sourced, not executed:
#
#   . "$root/scripts/oneapi-env.sh"
#
# Prepends the oneAPI library directories that exist (compiler, MKL, TBB, UMF) to LD_LIBRARY_PATH and sets OPENCL_INCLUDE
# to the compiler's include directory when it is unset or empty. A directory already in LD_LIBRARY_PATH is not added again,
# so sourcing it twice, or over a caller's own setting, changes nothing that is already there.
# ONEAPI_ROOT (default /opt/intel/oneapi) is the install root; ONEAPI_COMPILER_VERSION picks the compiler version directory
# (default: the latest one). Without an install under the root nothing is exported. This does not source setvars.sh: the
# variables are computed here. Sets only __oneapi_* names and unsets them again; it changes no shell options.

__oneapi_root=${ONEAPI_ROOT:-/opt/intel/oneapi}
__oneapi_ver=${ONEAPI_COMPILER_VERSION:-}
if [ -z "$__oneapi_ver" ] && [ -d "$__oneapi_root/compiler" ]; then
  __oneapi_ver=$(ls -1 "$__oneapi_root/compiler" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1 || true)
fi
if [ -n "$__oneapi_ver" ] && [ -d "$__oneapi_root/compiler/$__oneapi_ver" ]; then
  __oneapi_new=""
  for __oneapi_d in "$__oneapi_root/compiler/$__oneapi_ver/lib" "$__oneapi_root/mkl/latest/lib" \
                    "$__oneapi_root/tbb/latest/lib" "$__oneapi_root/umf/latest/lib"; do
    [ -d "$__oneapi_d" ] || continue
    case ":${LD_LIBRARY_PATH:-}:" in *":$__oneapi_d:"*) continue ;; esac
    __oneapi_new=${__oneapi_new:+$__oneapi_new:}$__oneapi_d
  done
  if [ -n "$__oneapi_new" ]; then
    export LD_LIBRARY_PATH="$__oneapi_new${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  if [ -z "${OPENCL_INCLUDE:-}" ] && [ -d "$__oneapi_root/compiler/$__oneapi_ver/include" ]; then
    export OPENCL_INCLUDE="$__oneapi_root/compiler/$__oneapi_ver/include"
  fi
fi
unset __oneapi_root __oneapi_ver __oneapi_new __oneapi_d
