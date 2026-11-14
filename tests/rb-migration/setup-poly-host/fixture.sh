mkdir -p build/poly-host
cat > "$SB/stubs/curl" <<'S'
out=""; prev=""; url=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; url=$a; done
[ -n "$out" ] && : > "$out"
exit 0
S
cat > "$SB/stubs/tar" <<'S'
dir=""; prev=""
for a in "$@"; do [ "$prev" = -C ] && dir=$a; prev=$a; done
mkdir -p "$dir/src" "$dir/include"
for f in lapi ldo lua luac lstate; do : > "$dir/src/$f.c"; done
for h in lua luaconf lauxlib lualib; do : > "$dir/src/$h.h"; done
: > "$dir/include/mruby.h"
S
cat > "$SB/stubs/rake" <<'S'
case "$*" in *--version*) exit 0;; esac
case "$*" in *" all"*) mkdir -p "$SB/root/build/poly-host/mruby-out/host/lib" "$SB/root/build/poly-host/mruby-out/host/include" && : > "$SB/root/build/poly-host/mruby-out/host/lib/libmruby.a";; esac
exit 0
S
