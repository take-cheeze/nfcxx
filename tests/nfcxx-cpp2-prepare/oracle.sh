# The bash cpp2_prepare of nfcxx before the port (slice 6 of docs/notes/driver-state-design.md), verbatim. run.sh runs it
# against the port (scripts/nfcxx-cpp2.rb) with a stub cppfront.
cpp2_prepare() {  # cpp2_prepare: translates every .cpp2 input and puts its translation in srcs and files in place of the source
  [ ${#cpp2_inputs[@]} -gt 0 ] || return 0
  local cppfront_src=${CPPFRONT_SRC:-$root/build/cppfront-src}
  [ -x "$root/build/cppfront" ] || { echo "nfcxx: cppfront is not built; run scripts/setup-cppfront.sh (docs/notes/cpp2.md)" >&2; exit 2; }
  [ -f "$cppfront_src/include/cpp2util.h" ] || { echo "nfcxx: no cpp2util.h under $cppfront_src; run scripts/setup-cppfront.sh" >&2; exit 2; }
  if [ -z "${cudatmp:-}" ]; then cudatmp=$(mktemp -d); trap 'rm -rf "$cudatmp"' EXIT; fi
  local dir=$cudatmp
  if [ $compile_only = 1 ]; then
    # As for .cu inputs (cu_prepare): the translation outlives the compile, because the prelinker re-reads it at link time.
    local obj=$out; [ $outset = 1 ] || obj=$(basename "${cpp2_inputs[0]}" .cpp2).o
    local key; key=$(realpath -m "$obj" | sha1sum | cut -c1-16)
    dir=${NFCXX_CU_CACHE:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/nfcxx}/cpp2/$key
    mkdir -p "$dir"
  fi
  local scratch; scratch=$(mktemp -d -p "$cudatmp")
  local src sdir copy i
  for src in "${cpp2_inputs[@]}"; do
    # The translation is not next to the source, so quoted includes relative to the source are found through its directory.
    sdir=$(realpath -- "$(dirname -- "$src")")
    cflags+=("-I$sdir"); files+=("-I$sdir")
    copy=$dir/$(basename "$src" .cpp2).cpp
    local abs; abs=$(realpath -- "$src")   # before the cd: a relative source is relative to the caller's directory
    (cd "$scratch" && "$root/build/cppfront" -q -o "$copy" "$abs") || exit $?
    for i in "${!srcs[@]}"; do if [ "${srcs[$i]}" = "$src" ]; then srcs[$i]=$copy; fi; done
    for i in "${!files[@]}"; do if [ "${files[$i]}" = "$src" ]; then files[$i]=$copy; fi; done
  done
  cflags+=("-I$cppfront_src/include"); files+=("-I$cppfront_src/include")
}
