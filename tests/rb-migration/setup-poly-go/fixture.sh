mkdir -p lib/poly/go build/poly-go
printf 'module nfcgo\n\nrequire github.com/traefik/yaegi v0.16.1\n' > lib/poly/go/go.mod
: > lib/poly/go/go.sum
printf 'int nfcgo_init(void);\n' > lib/poly/go/nfcgo.h
: > lib/poly/go/main.go
touch -d '2000-01-01' lib/poly/go/go.mod lib/poly/go/go.sum lib/poly/go/nfcgo.h lib/poly/go/main.go
cat > "$SB/stubs/go" <<'S'
case "$1" in
  env) echo "${GO_VERSION_OUT:-go1.24.3}" ;;
  build) out=""; prev=""; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
         : > "$out"; printf 'int nfcgo_init(void);\n' > "${out%.so}.h" ;;
esac
S
