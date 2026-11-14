#!/bin/bash
# Differential test: scripts/setup-emsdk.rb against the bash it replaced (oracle.sh here). See ../lib.sh.
# INSTALLED=1: build/emsdk holds emsdk at the pinned version; OLD=1: at an older one (the emsdk fixture logs its calls).
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=emsdk

prep() {
  local dir="$1/root/build/emsdk" version=
  case " $2 " in
    *" INSTALLED=1 "*) version=6.0.13 ;;
    *" OLD=1 "*) version=5.0.0 ;;
  esac
  if [ -n "$version" ]; then
    mkdir -p "$dir"
    cat > "$dir/emsdk" <<'EOF'
#!/bin/bash
echo "emsdk $*" >> "$RB_STUB_LOG"
EOF
    chmod +x "$dir/emsdk"
    echo "$version" > "$dir/.nfcxx-version"
  fi
}

rbm_cases <<'EOF'
fresh|
installed|INSTALLED=1
stale version|OLD=1
version from EMSDK_VERSION|EMSDK_VERSION=6.1.0
clone fails|RB_STUB_GIT_FAIL=clone
EOF
rbm_finish
