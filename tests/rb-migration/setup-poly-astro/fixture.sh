mkdir -p build/poly-astro/src/.git build/poly-astro/src/lib build/poly-astro/src/runtime build/poly-astro/src/sample/luastro lib/poly
printf 'module ASTroGen\n%s\nit.foo #{it}\n' 'build_allocator_decl}.join(";\n")' > build/poly-astro/src/lib/astrogen.rb
printf 'x = it.bar #{it}\n' > build/poly-astro/src/sample/luastro/lua_gen.rb
: > build/poly-astro/src/runtime/rt.h
: > build/poly-astro/src/sample/luastro/node.c
: > lib/poly/nfcpoly_astro_shim.c; : > lib/poly/nfcpoly_astro_shim.h
touch -d '2000-01-01' lib/poly/nfcpoly_astro_shim.c lib/poly/nfcpoly_astro_shim.h
cat > "$SB/stubs/ruby" <<'S'
case "$*" in *ASTroGen*) : > node_head.h;; esac
exit 0
S
cat > "$SB/stubs/nm" <<'S'
echo "0000000000000000 T lua_newstate"
echo "0000000000000010 T luaL_checknumber"
echo "0000000000000020 T other_fn"
echo "                 U lua_undefined"
echo "0000000000000030 T lua_arith"
S
