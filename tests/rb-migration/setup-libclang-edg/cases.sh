# The fixture: an EDG tree (3rd/edg: CMakeLists, src with cp_gen_be.c and folding.c, cmake, bases, include_c++, a hidden entry)
# and be/ (the three nfcxx files). The cmake and ninja stubs print nothing and succeed.
c default "" "" ''
c in-process-0 "LIBCLANG_EDG_IN_PROCESS=0" "" ''
c jobs "LIBCLANG_EDG_JOBS=4" "" ''
c jobs-empty "LIBCLANG_EDG_JOBS=" "" ''
c src-env "LIBCLANG_EDG_SRC=@SB@/root/3rd/edg/" "" ''
c out-env "LIBCLANG_EDG_OUT=@SB@/root/outdir" "" ''
c src-missing-submodule "" "" 'rm -f 3rd/edg/CMakeLists.txt; cat > "$SB/stubs/git" <<"S"
exit 1
S'
c submodule-ok "" "" 'rm -f 3rd/edg/CMakeLists.txt; cat > "$SB/stubs/git" <<"S"
exit 0
S'
c be-missing "" "" 'rm -f be/nfcxx_ast.c'
c patch-fails "" "" 'printf "set(CORE a.c)\n" > 3rd/edg/src/CMakeLists.txt'
c rename-fails "" "" 'printf "int x;\n" > 3rd/edg/src/cp_gen_be.c'
c folding-fails "" "" 'printf "int y;\n" > 3rd/edg/src/folding.c'
c no-bases "" "" 'rm -rf 3rd/edg/bases'
c cmake-fails "" "" 'cat > "$SB/stubs/cmake" <<"S"
echo "CMake Error: no compiler"; exit 1
S'
c ninja-fails "" "" 'cat > "$SB/stubs/ninja" <<"S"
echo "src/x.c: error: boom"; echo "more"; exit 1
S'
c no-src-src "" "" 'rm -rf 3rd/edg/src'
c cp-fails "" "" 'rm -f be/nfcxx_decl.c'
