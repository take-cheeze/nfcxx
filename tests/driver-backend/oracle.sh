#!/bin/bash
# The bash backend decision of nfcxx (copied verbatim from nfcxx's setup: default_backend, pb_fs_host, the NFCXX_PATH=b override
# and the case on $backend). Reads cases on stdin: one line of KEY=VALUE words per case; prints "backend default pb_fs" or
# "REFUSED message" per case. uname is stubbed by the case's host (SYS, MACH).
uname() { if [ "$1" = -s ]; then echo "$SYS"; else echo "$MACH"; fi; }
decide() {
  local backend=$backend backend_explicit=$backend_explicit path_b=$path_b freestanding=$freestanding cosmo=$cosmo emit_c=$emit_c \
        target=$target preprocess=$preprocess depmode=$depmode shared=$shared default_backend=0 pb_fs_host=0
  case $(uname -s) in
    Linux) case $(uname -m) in x86_64|aarch64|arm64) pb_fs_host=1 ;; esac ;;
    Darwin) [ "$(uname -m)" = arm64 ] && pb_fs_host=1 ;;
  esac
  if [ -z "$backend" ]; then
    backend=gcc
    fs_ok=1; [ $freestanding = 0 ] || [ $pb_fs_host = 1 ] || fs_ok=0
    if [ $backend_explicit = 0 ] && [ $fs_ok = 1 ] && [ $cosmo = 0 ] \
       && [ $emit_c = 0 ] && [ -z "$target" ] && [ $preprocess = 0 ] && [ -z "$depmode" ] && [ $shared = 0 ]; then
      backend=pathb; default_backend=1
    fi
  fi
  [ $path_b = 0 ] || { backend=pathb; default_backend=0; }
  case $backend in
    pathb) [ $freestanding = 0 ] || [ $pb_fs_host = 1 ] ||
             { echo "REFUSED nfcxx: Path B (--backend=pathb) compiles freestanding programs on x86-64 and aarch64 Linux and arm64 macOS only"; return; } ;;
    gcc) ;;
    *) echo "REFUSED nfcxx: unknown backend '$backend'"; return ;;
  esac
  echo "$backend $default_backend $pb_fs_host"
}
while IFS= read -r line; do
  [ -n "$line" ] || continue
  ( for kv in $line; do export "$kv"; done; decide )
done
