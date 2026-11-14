# The fixture: lib/poly/go (go.mod naming yaegi, go.sum, nfcgo.h, main.go), and a go stub that writes the library and the
# header cgo writes (build/poly-go/ is empty: the library is built).
c default "" "" ''
c go-env "GO=@SB@/root/gobin/go" "" 'mkdir -p "$SB/root/gobin" && ln -s "$SB/bin/go" "$SB/root/gobin/go"'
c go-bad "GO=/nonexistent/go" "" ''
c go-old "GO_VERSION_OUT=go1.22.4" "" ''
c go-unknown "GO_VERSION_OUT=" "" ''
c go-old-prefix "GO_VERSION_OUT=go1.30.1" "" ''
c go-no-go "" "" 'rm -f "$SB/bin/go"'
c no-cc "" "" 'rm -f "$SB/bin/gcc"'
c cc-env "CC=/nonexistent/cc" "" ''
c cc-env-ok "CC=@SB@/root/nfcc" "" ''
c fresh "" "" 'mkdir -p build/poly-go && : > build/poly-go/libnfcgo.so && : > build/poly-go/libnfcgo.h && touch -d "2100-01-01" build/poly-go/libnfcgo.so build/poly-go/libnfcgo.h'
c fresh-force "FORCE=1" "" 'mkdir -p build/poly-go && : > build/poly-go/libnfcgo.so && : > build/poly-go/libnfcgo.h && touch -d "2100-01-01" build/poly-go/libnfcgo.so build/poly-go/libnfcgo.h'
c fresh-newer-go "" "" 'mkdir -p build/poly-go && : > build/poly-go/libnfcgo.so && : > build/poly-go/libnfcgo.h && touch -d "2100-01-01" build/poly-go/libnfcgo.so build/poly-go/libnfcgo.h && : > lib/poly/go/x.go && touch -d "2200-01-01" lib/poly/go/x.go'
c fresh-no-header "" "" 'mkdir -p build/poly-go && : > build/poly-go/libnfcgo.so && touch -d "2100-01-01" build/poly-go/libnfcgo.so'
c poly-go-dir "POLY_GO_DIR=@SB@/root/elsewhere" "" ''
c home-empty "HOME=" "" ''
c build-fails "" "" 'cat > "$SB/stubs/go" <<"S"
case "$1" in env) echo go1.24.3;; build) echo "x.go: type error"; exit 1;; esac
S'
c build-proxy "" "" 'cat > "$SB/stubs/go" <<"S"
case "$1" in env) echo go1.24.3;; build) echo "dial tcp: lookup proxy.golang.org: no such host"; exit 1;; esac
S'
c build-no-header "" "" 'cat > "$SB/stubs/go" <<"S"
case "$1" in env) echo go1.24.3;; build) out=""; prev=""; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done; : > "$out";; esac
S'
c header-mismatch "" "" 'cat > "$SB/stubs/go" <<"S"
case "$1" in env) echo go1.24.3;; build) out=""; prev=""; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done; : > "$out"; printf "int nfcgo_other(void);\n" > "${out%.so}.h";; esac
S'
c no-nfcgo-h "" "" 'rm -f lib/poly/go/nfcgo.h'
c go-gcc-logs "" "" ''
