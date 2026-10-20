#!/usr/bin/env bash
# libclang-edg: build a cpfe whose back end is be/nfcxx_decl.c (it lists the declarations of the primary file)
# instead of EDG's C++-generating back end. Same view-of-the-submodule approach as scripts/setup-pathb.sh: 3rd/edg
# is not modified; build/libclang-edg/tree links to it and replaces only the files below.
#   src/CMakeLists.txt                 nfcxx_decl.c added to CORE_FRONT_END_SOURCE_FILES; cp_gen_be.c's back_end renamed
#   cmake/macro-conf/nfcxx-libclang/   EDG's C++ back-end configuration (BACK_END_IS_CP_GEN_BE=1, no IL lowering).
#                                      That configuration keeps the source sequence lists (declarations in source
#                                      order, with their scopes) and the per-class member lists, which the back end
#                                      reads. EDG rejects those lists together with IL lowering.
# Result: build/libclang-edg/cmake/bin/cpfe. scripts/libclang-cursors runs it; lib/libclang-edg uses that.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=${LIBCLANG_EDG_SRC:-$root/3rd/edg}   # an EDG checkout elsewhere (worktrees with an empty 3rd/)
out=${LIBCLANG_EDG_OUT:-$root/build/libclang-edg}
tree=$out/tree

if [ ! -f "$src/CMakeLists.txt" ]; then
  git -C "$root" submodule update --init --depth 1 3rd/edg
fi

rm -rf "$tree"; mkdir -p "$tree/src" "$tree/cmake/macro-conf/nfcxx-libclang"  # keep $out/cmake: incremental rebuilds

link_all() { # link_all <from-dir> <to-dir> <exclude-name>...
  local from=$1 to=$2; shift 2
  for e in "$from"/* "$from"/.[!.]*; do
    [ -e "$e" ] || continue
    local n; n=$(basename "$e")
    for x in "$@"; do [ "$n" = "$x" ] && continue 2; done
    ln -s "$e" "$to/$n"
  done
}
link_all "$src" "$tree" src cmake
link_all "$src/src" "$tree/src" CMakeLists.txt
link_all "$src/cmake" "$tree/cmake" macro-conf
link_all "$src/cmake/macro-conf" "$tree/cmake/macro-conf" nfcxx-libclang

# 1. Back end: nfcxx_decl.c joins the CORE list. cp_gen_be.c stays (the front end uses its helpers, such as
#    expr_has_comma_operation), but its back_end() is renamed in the tree copy, so the C++ generator never runs.
sed 's/ cp_gen_be\.c / cp_gen_be.c nfcxx_decl.c /' "$src/src/CMakeLists.txt" > "$tree/src/CMakeLists.txt"
grep -q ' cp_gen_be.c nfcxx_decl.c ' "$tree/src/CMakeLists.txt" || { echo "setup-libclang-edg: CORE list patch failed" >&2; exit 1; }
cp "$root/be/nfcxx_decl.c" "$tree/src/"
rm -f "$tree/src/cp_gen_be.c"  # a symlink into the submodule: write a copy, never through the link
sed 's/^void back_end(void)/void nfcxx_cp_gen_back_end_unused(void)/' "$src/src/cp_gen_be.c" > "$tree/src/cp_gen_be.c"
grep -q 'nfcxx_cp_gen_back_end_unused(void)' "$tree/src/cp_gen_be.c" || { echo "setup-libclang-edg: cp_gen_be.c rename failed" >&2; exit 1; }
# folding.c calls mangled_typeinfo_string, which lower_name.h declares only with IL lowering on. The C++ configuration
# has lowering off, so the tree's folding.c gets the prototype (the function itself is still built from lower_name.c).
rm -f "$tree/src/folding.c"  # a symlink into the submodule: write a copy, never through the link
python3 - "$src/src/folding.c" "$tree/src/folding.c" <<'PY'
import sys
lines = open(sys.argv[1]).read().split('\n')
anchor = next(i for i, l in enumerate(lines) if 'Conditionally open the "edg" namespace' in l)
lines.insert(anchor, 'namespace edg { extern char *mangled_typeinfo_string(a_type *type); }  /* nfcxx: see setup-libclang-edg.sh */')
open(sys.argv[2], 'w').write('\n'.join(lines))
PY

# 2. Macro config: EDG's C++ back-end configuration (default/cpfe-cp), with the Linux and release options.
cat > "$tree/cmake/macro-conf/nfcxx-libclang/base.cmakedef" <<'CFG'
import <linux-gcc-release/base>
CFG
cat > "$tree/cmake/macro-conf/nfcxx-libclang/cpfe.cmakedef" <<'CFG'
# libclang-edg: the C++-generating back end's configuration; nfcxx_decl.c defines back_end() in its place.
import <linux-gcc-release/cpfe-cp>
# The per-class list of member declarations in source order (class_type_supp(t)->member_declarations). Off by
# default in host_envir.h; nfcxx_decl.c reads it.
MAINTAIN_CLASS_MEMBER_LIST=1
# No IL lowering: the source sequence lists conflict with it (host_envir.h). The Itanium C++ ABI is what Linux
# sets in support/platform/linux/base; folding.c needs its mangled_typeinfo_string, declared only with IA64_ABI.
DO_IL_LOWERING=0
IA64_ABI=1
CFG
cat > "$tree/cmake/macro-conf/nfcxx-libclang/cpfe-cp.cmakedef" <<'CFG'
import <linux-gcc-release/cpfe-cp>
CFG
cat > "$tree/cmake/macro-conf/nfcxx-libclang/cdisp.cmakedef" <<'CFG'
import <linux-gcc-release/cdisp>
CFG

# 3. Base dir (predefined macros, EDG's own headers), as setup-pathb.sh does.
base=$out/edg-base
rm -rf "$base"; cp -r "$src/bases/docker/dev-env/gcc" "$base"
rm -rf "$base/include"; ln -s "$src/include_c++" "$base/include"

cd "$tree"
EDG_BASE=$base cmake -G Ninja -S "$tree" -B "$out/cmake" -DCMAKE_BUILD_TYPE=Release \
  -DEDG_MACRO_CONF=nfcxx-libclang -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ >"$out/configure.log" 2>&1 \
  || { tail -30 "$out/configure.log" >&2; exit 1; }
cd "$out/cmake"
ninja ${LIBCLANG_EDG_JOBS:+-j$LIBCLANG_EDG_JOBS} bin/cpfe >"$out/build.log" 2>&1 || { grep -m20 -B2 -A8 'error' "$out/build.log" >&2; exit 1; }
echo "libclang-edg cpfe built: $out/cmake/bin/cpfe (base dir: $base)"
