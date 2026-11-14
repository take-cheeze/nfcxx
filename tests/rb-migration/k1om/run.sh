#!/bin/bash
# Differential test: scripts/setup-k1om.rb against the bash it replaced (oracle.sh here). See ../lib.sh. The sandbox has a
# k1om toolchain (k1om/bin: gcc, ar), the EDG build script (a logging stub) and ninja's compile commands (ninja-cmds).
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=k1om

# NOGCC=1: no k1om gcc; BUILT=1: libC.a is there; NOCMDS=1: ninja lists no runtime commands
prep() {
  local sb=$1 words=" $2 " k="$1/k1om" root="$1/root"
  mkdir -p "$root/build/edg-k1om/lib_src/edg-cpp-rt-cache" "$k/bin"
  case $words in
    *" NOGCC=1 "*) ;;
    *) printf '#!/bin/sh\n' > "$k/bin/k1om-mpss-linux-gcc"; chmod +x "$k/bin/k1om-mpss-linux-gcc" ;;
  esac
  cat > "$k/bin/k1om-mpss-linux-ar" <<'EOF'
#!/bin/bash
echo "AR $*" >> "$RB_STUB_LOG"
: > "$2"
EOF
  chmod +x "$k/bin/k1om-mpss-linux-ar"
  cat > "$root/scripts/setup-edg.sh" <<'EOF'
#!/bin/bash
echo "EDG EDG_BUILD=${EDG_BUILD-unset} EDG_BASE=${EDG_BASE-unset} NFCXX_GCC=${NFCXX_GCC-unset} NFCXX_CC=${NFCXX_CC-unset} NFCXX_AS=${NFCXX_AS-unset}" >> "$RB_STUB_LOG"
[ -z "${RB_STUB_EDG_FAIL:-}" ] || exit 1
EOF
  chmod +x "$root/scripts/setup-edg.sh"
  case $words in
    *" NOCMDS=1 "*) : > "$1/ninja-cmds" ;;
    *)
      cat > "$1/ninja-cmds" <<'EOF'
rtcc lib_src/edg-cpp-rt-cache/a.o
echo unrelated
rtcc lib_src/edg-cpp-rt-cache/c99_complex.o
rtcc lib_src/edg-cpp-rt-cache/b.o
ar qc lib/libC.a lib_src/edg-cpp-rt-cache/a.o
EOF
      ;;
  esac
  case $words in
    *" BUILT=1 "*) mkdir -p "$root/build/k1om"; : > "$root/build/k1om/libC.a" ;;
  esac
}

rbm_cases <<'EOF'
fresh|NFCXX_K1OM_ROOT=@SB@/k1om
already built|NFCXX_K1OM_ROOT=@SB@/k1om BUILT=1
no k1om gcc|NFCXX_K1OM_ROOT=@SB@/k1om NOGCC=1
edg build fails|NFCXX_K1OM_ROOT=@SB@/k1om RB_STUB_EDG_FAIL=1
no runtime commands|NFCXX_K1OM_ROOT=@SB@/k1om NOCMDS=1
runtime compile fails|NFCXX_K1OM_ROOT=@SB@/k1om RB_STUB_RTCC_FAIL=1
preset compiler variables|NFCXX_K1OM_ROOT=@SB@/k1om NFCXX_GCC=x NFCXX_CC=y NFCXX_AS=z NFCXX_CCACHE=1
EOF
rbm_finish
