#!/usr/bin/env bash
# The oneAPI runtime helper (scripts/oneapi-env.sh): for the installed oneAPI it exports the compiler, MKL, TBB and UMF library
# directories that exist and OPENCL_INCLUDE; for a missing root it exports nothing and returns 0; an existing LD_LIBRARY_PATH
# entry is kept, and sourcing twice adds nothing. Each case runs in a child shell with the oneAPI variables unset.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
helper=$root/scripts/oneapi-env.sh
fail=0

# probe ENV...: runs the helper in a clean child shell with the given assignments; prints "LD=<LD_LIBRARY_PATH>" and "CL=<OPENCL_INCLUDE>"
probe() {
  env -u LD_LIBRARY_PATH -u OPENCL_INCLUDE -u ONEAPI_ROOT -u ONEAPI_COMPILER_VERSION "$@" bash -c '
    . "$1" || { echo "helper failed"; exit 1; }
    echo "LD=${LD_LIBRARY_PATH-<unset>}"; echo "CL=${OPENCL_INCLUDE-<unset>}"' _ "$helper"
}

# 1. The installed oneAPI: the expected directories are the ones that exist, in this order, and OPENCL_INCLUDE is the compiler's.
oneapi=/opt/intel/oneapi
ver=$(ls -1 "$oneapi/compiler" | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)
want=""
for d in "$oneapi/compiler/$ver/lib" "$oneapi/mkl/latest/lib" "$oneapi/tbb/latest/lib" "$oneapi/umf/latest/lib"; do
  [ -d "$d" ] && want=${want:+$want:}$d
done
got=$(probe) rc=$?
if [ $rc = 0 ] && grep -qx "LD=$want" <<< "$got" && grep -qx "CL=$oneapi/compiler/$ver/include" <<< "$got"; then
  echo "installed: ok (LD_LIBRARY_PATH=$want)"
else
  echo "installed: FAIL (want LD=$want CL=$oneapi/compiler/$ver/include)"; echo "$got"; fail=1
fi
# the directories exist and hold the libraries the runtime needs
for lib in libsycl.so libimf.so libsvml.so libiomp5.so; do
  found=0; for d in ${want//:/ }; do [ -e "$d/$lib" ] && found=1; done
  if [ $found = 1 ]; then echo "lib $lib: found"; else echo "lib $lib: FAIL (not in the exported directories)"; fail=1; fi
done

# 2. A missing root exports nothing and returns 0.
got=$(probe ONEAPI_ROOT=/nonexistent) rc=$?
if [ $rc = 0 ] && grep -qx "LD=<unset>" <<< "$got" && grep -qx "CL=<unset>" <<< "$got"; then
  echo "missing root: ok"
else
  echo "missing root: FAIL"; echo "$got"; fail=1
fi
got=$(probe ONEAPI_ROOT=/nonexistent LD_LIBRARY_PATH=/x/custom) rc=$?
if [ $rc = 0 ] && grep -qx "LD=/x/custom" <<< "$got"; then echo "missing root, LD_LIBRARY_PATH kept: ok"; else echo "missing root, LD_LIBRARY_PATH kept: FAIL"; echo "$got"; fail=1; fi

# 3. An existing LD_LIBRARY_PATH entry is kept, at the end of the list; OPENCL_INCLUDE set by the caller is kept.
got=$(probe LD_LIBRARY_PATH=/x/custom:/y/other OPENCL_INCLUDE=/my/cl) rc=$?
if [ $rc = 0 ] && grep -qx "LD=$want:/x/custom:/y/other" <<< "$got" && grep -qx "CL=/my/cl" <<< "$got"; then
  echo "existing LD_LIBRARY_PATH kept, OPENCL_INCLUDE kept: ok"
else
  echo "existing LD_LIBRARY_PATH kept, OPENCL_INCLUDE kept: FAIL"; echo "$got"; fail=1
fi

# 4. Sourcing twice does not repeat a directory.
got=$(env -u LD_LIBRARY_PATH -u OPENCL_INCLUDE bash -c '. "$1"; . "$1"; echo "LD=$LD_LIBRARY_PATH"' _ "$helper")
if grep -qx "LD=$want" <<< "$got"; then echo "sourced twice: ok"; else echo "sourced twice: FAIL"; echo "$got"; fail=1; fi

exit $fail
