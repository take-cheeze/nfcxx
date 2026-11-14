mkdir -p build/poly-lua/src/.git
for f in lapi ldo lua luac linit lstate lmathlib lvm; do : > build/poly-lua/src/$f.c; done
for h in lua luaconf lauxlib lualib; do : > build/poly-lua/src/$h.h; done
