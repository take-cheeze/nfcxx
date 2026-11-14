mkdir -p 3rd/edg/src 3rd/edg/cmake/macro-conf/x 3rd/edg/bases/docker/dev-env/gcc 3rd/edg/include_c++ be
: > 3rd/edg/CMakeLists.txt
: > 3rd/edg/.hidden
printf 'set(CORE_FRONT_END_SOURCE_FILES a.c cp_gen_be.c b.c)\n' > 3rd/edg/src/CMakeLists.txt
printf 'int x;\nvoid back_end(void)\n{\n}\n' > 3rd/edg/src/cp_gen_be.c
printf 'int y;\n/* Conditionally open the "edg" namespace here */\nint z;\n' > 3rd/edg/src/folding.c
: > 3rd/edg/src/a.c; : > 3rd/edg/src/b.c
: > 3rd/edg/cmake/CMakeLists.txt
: > 3rd/edg/cmake/macro-conf/x/m.cmakedef
: > 3rd/edg/bases/docker/dev-env/gcc/defs.h
: > 3rd/edg/include_c++/stdio.h
printf 'decl\n' > be/nfcxx_decl.c; printf 'ast\n' > be/nfcxx_ast.c; printf 'entry\n' > be/nfcxx_edg_entry.c
cat > "$SB/stubs/cmake" <<'S'
b=""; prev=""
for a in "$@"; do [ "$prev" = -B ] && b=$a; prev=$a; done
mkdir -p "$b"
S
