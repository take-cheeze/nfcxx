# The bash block of nfcxx's SYCL pre-pass as it was on main (70f19b04), verbatim: sycl_kernel_headers and the if that runs the
# two passes. Sourced by tests/nfcxx-sycl/run.sh in a copy of the driver (the cut after this block); scripts/nfcxx-sycl.rb is the port.
sycl_kernel_headers() {  # sycl_kernel_headers ARG...: TRUE when a -I directory of the arguments has the oneAPI kernel header
  local prev="" a d=""
  for a in "$@"; do
    d=""
    case $a in -I?*) d=${a#-I} ;; esac
    [ "$prev" = -I ] && d=$a
    prev=$a
    if [ -n "$d" ] && [ -f "$d/sycl/detail/kernel_desc.hpp" ]; then return 0; fi
  done
  return 1
}
if [ $compile_only = 1 ] && [ $ncpp = 1 ] && [ $nobj = 0 ] && [ ${#cfiles[@]} = 0 ] && [ $preprocess = 0 ] \
   && [ $emit_c = 0 ] && [ -z "${NFCXX_SYCL_PASS:-}" ] && sycl_kernel_headers "${args0[@]}" \
   && grep -Eq '#[[:space:]]*include[[:space:]]*[<"]sycl/' "${srcs[0]}"; then
  sy_tmp=$(mktemp -d)
  sy_src=$(realpath "${srcs[0]}")
  # Pass 1: the front end records the kernels (the compile fails at the header's size check; the record is what matters).
  NFCXX_SYCL_PASS=1 NFCXX_SYCL_DUMP="$sy_tmp/dump" "$root/nfcxx" "${args0[@]}" > "$sy_tmp/pass1.log" 2>&1 || true
  if [ ! -s "$sy_tmp/dump" ]; then
    cat "$sy_tmp/pass1.log" >&2; rm -rf "$sy_tmp"
    echo "nfcxx: the SYCL pre-pass recorded no kernels" >&2; exit 2
  fi
  "$root/scripts/sycl-integration-header.rb" "$sy_tmp/dump" > "$sy_tmp/integration.hpp" || { rm -rf "$sy_tmp"; exit 2; }
  printf '#include <sycl/sycl.hpp>\n#include "%s"\n#include "%s"\n' "$sy_tmp/integration.hpp" "$sy_src" > "$sy_tmp/wrapper.cpp"
  sy_args=()
  for a in "${args0[@]}"; do
    if [ "$a" = "${srcs[0]}" ]; then sy_args+=("$sy_tmp/wrapper.cpp"); else sy_args+=("$a"); fi
  done
  [ $outset = 1 ] || sy_args+=(-o "$(basename "${sy_src%.*}").o")
  # Pass 2: the wrapper, with the macro that selects the integration-header path (and __make_integer_seq).
  NFCXX_SYCL_PASS=1 "$root/nfcxx" -D__SYCL_UNNAMED_LAMBDA__=1 "${sy_args[@]}"; sy_rc=$?
  rm -rf "$sy_tmp"
  exit $sy_rc
fi
