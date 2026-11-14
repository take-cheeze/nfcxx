#!/bin/bash
# Stub for the external commands the setup scripts run. lib.sh links this file under each command's name in the sandbox's
# bin directory. Each call is logged to $RB_STUB_LOG as the name and its arguments. The fixtures the scripts expect are made
# in place; nothing is downloaded, cloned or built.
#   curl, unzip, tar, python3, cargo, git, rake, ninja, c++, cxxfail, rtcc, sha256sum: fakes, below
#   mkdir rm install ln mv: logged, then the real command
#   uname: logged; -m is RB_STUB_MACHINE (default x86_64), -s is RB_STUB_SYSTEM (default Linux)
#   mktemp: logged; the directory $RB_SB/tmp/mktemp, created and printed
# RB_STUB_* variables set a failure (a status) or a value per case; see each run.sh.
name=$(basename "$0")
log() { printf '%s\n' "$*" >> "$RB_STUB_LOG"; }
# option WANT ARGS...: the argument after the first WANT in ARGS
option() {
  local want=$1 prev= a
  shift
  for a; do
    if [ "$prev" = "$want" ]; then echo "$a"; return; fi
    prev=$a
  done
}

case $name in
  mkdir|rm|install|ln|mv)
    log "$name" "$@"
    exec "/usr/bin/$name" "$@" ;;
  uname)
    log uname "$@"
    case $1 in
      -m) echo "${RB_STUB_MACHINE:-x86_64}" ;;
      -s) echo "${RB_STUB_SYSTEM:-Linux}" ;;
      *) exec /usr/bin/uname "$@" ;;
    esac ;;
  mktemp)
    log mktemp "$@"
    d=$RB_SB/tmp/mktemp
    mkdir -p "$d"
    echo "$d" ;;
  curl)
    log curl "$@"
    [ -z "${RB_STUB_CURL_FAIL:-}" ] || exit "$RB_STUB_CURL_FAIL"
    o=$(option -o "$@")
    if [ -n "$o" ]; then mkdir -p "$(dirname "$o")"; echo "download fixture" > "$o"; fi
    exit 0 ;;
  unzip)
    log unzip "$@"
    d=$(option -d "$@")
    mkdir -p "$d/bin"
    printf '#!/bin/sh\necho "cosmocc 4.0.2 (fixture)"\n' > "$d/bin/cosmocc"
    exit 0 ;;
  tar)
    log tar "$@"
    d=$(option -C "$@")
    mkdir -p "$d/tinygo/bin"
    printf '#!/bin/sh\necho "tinygo fixture"\n' > "$d/tinygo/bin/tinygo"
    chmod +x "$d/tinygo/bin/tinygo"
    exit 0 ;;
  python3)
    log python3 "$@"
    [ -z "${RB_STUB_PY_FAIL:-}" ] || exit "$RB_STUB_PY_FAIL"
    rid=$(printf '%s\n' "$2" | sed -n 's#.*runtimes/\([^/]*\)/native/ilasm.*#\1#p')
    mkdir -p "$4/runtimes/$rid/native"
    echo "ilasm fixture" > "$4/runtimes/$rid/native/ilasm"
    exit 0 ;;
  cargo)
    log cargo "$@"
    if [ -n "${RB_STUB_CARGO_FAIL:-}" ]; then echo "error: fixture" >&2; exit "$RB_STUB_CARGO_FAIL"; fi
    mkdir -p target/release
    printf '#!/bin/sh\necho "mold 3.0.0"\n' > target/release/mold
    chmod +x target/release/mold
    exit 0 ;;
  git)
    log git "$@"
    dir=$PWD
    if [ "$1" = -C ]; then dir=$2; shift 2; fi
    sub=$1
    [ "${RB_STUB_GIT_FAIL:-}" != "$sub" ] || exit 128
    case $sub in
      clone)
        dest=${*: -1}
        mkdir -p "$dest/.git"
        case $dest in
          *emsdk)
            cat > "$dest/emsdk" <<'EOF'
#!/bin/bash
echo "emsdk $*" >> "$RB_STUB_LOG"
EOF
            chmod +x "$dest/emsdk" ;;
        esac ;;
      init)
        d=$dir
        if [ -n "${3:-}" ]; then d=$3; fi
        mkdir -p "$d/.git" ;;
      rev-parse) echo "${RB_STUB_GIT_HEAD:-}" ;;
      fetch)
        if [ -n "${RB_STUB_FETCH_SRC:-}" ]; then
          mkdir -p "$dir/source"
          echo "int main() {}" > "$dir/source/cppfront.cpp"
          echo 'const char* version = "v0.8.2";' > "$dir/source/version.info"
        fi ;;
      submodule) mkdir -p "$dir/3rd/mruby" ;;
    esac
    exit 0 ;;
  rake)
    log rake "$@"
    log "ENV LD=${LD-unset} BC2CPP_WORLD_ROOT=${BC2CPP_WORLD_ROOT-unset} BC2CPP_RUNNER_CXX=${BC2CPP_RUNNER_CXX-unset} BC2CPP_RUNNER_OPT=${BC2CPP_RUNNER_OPT-unset} MRUBY_CONFIG=${MRUBY_CONFIG-unset} MRUBY_BUILD_DIR=${MRUBY_BUILD_DIR-unset} NFCXX_BACKEND=${NFCXX_BACKEND-unset}"
    log "CWD $(pwd -P)"
    if [ -n "${RB_STUB_RAKE_FAIL:-}" ]; then echo "rake: fixture failure"; exit "$RB_STUB_RAKE_FAIL"; fi
    exit 0 ;;
  ninja)
    log ninja "$@"
    if [ "${1:-}" = -t ]; then cat "$RB_SB/ninja-cmds"; fi
    exit 0 ;;
  c++)
    log c++ "$@"
    o=$(option -o "$@")
    if [ -n "$o" ]; then mkdir -p "$(dirname "$o")"; : > "$o"; fi
    exit 0 ;;
  cxxfail)
    log cxxfail "$@"
    exit 3 ;;
  rtcc)
    log "RTCC NFCXX_GCC=${NFCXX_GCC-unset} NFCXX_CC=${NFCXX_CC-unset} NFCXX_AS=${NFCXX_AS-unset} NFCXX_K1OM_ROOT=${NFCXX_K1OM_ROOT-unset} NFCXX_CCACHE=${NFCXX_CCACHE-unset} $*"
    for a; do
      case $a in *.o) mkdir -p "$(dirname "$a")"; : > "$a" ;; esac
    done
    if [ -n "${RB_STUB_RTCC_FAIL:-}" ]; then echo "error: rtcc fixture"; exit 1; fi
    exit 0 ;;
  sha256sum)
    log sha256sum "$@"
    if [ "${1:-}" = -c ]; then
      while IFS= read -r l; do log "SHA256 INPUT $l"; done
      if [ -n "${RB_STUB_SHA:-}" ]; then echo "sha256sum: fixture: FAILED" >&2; exit 1; fi
      exit 0
    fi
    echo "0000000000000000000000000000000000000000000000000000000000000000  $1" ;;
  *)
    log "$name" "$@"
    echo "stub: unknown command $name" >&2
    exit 127 ;;
esac
