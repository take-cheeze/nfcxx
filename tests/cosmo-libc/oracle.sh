#!/usr/bin/env bash
# EDG's C++ runtime (libC.a) for the --cosmo links (docs/notes/cosmo.md): the members of the host build's libC.a, compiled
# from 3rd/edg/lib_src with cosmo's C compiler and headers. Prints the directory of libC.a, building it first when it is
# missing or older than the host archive. Two members of the host archive are left out: decode.o defines __cxa_demangle
# for EDG's prelinker, and eh_util.o defines std::terminate, std::unexpected and the handler setters, which cosmo's
# libc++abi (libcosmo.a) already has.
# Needs build/edg (scripts/setup-edg.sh) for the member list and the eccp driver, and cosmocc (NFCXX_COSMOCC, or
# build/cosmocc/bin/cosmocc from scripts/setup-cosmo.sh). COSMO_LIBC_OUT: another output directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
edg=${EDG_BUILD:-$root/build/edg}
cosmocc=${NFCXX_COSMOCC:-$root/build/cosmocc/bin/cosmocc}
cosmo_root=$(cd "$(dirname "$cosmocc")/.." && pwd)
out=${COSMO_LIBC_OUT:-$root/build/cosmo-libc}
host=$edg/lib/libC.a
[ -f "$host" ] || { echo "cosmo-libc: $host is missing; run scripts/setup-edg.sh" >&2; exit 2; }
[ -x "$cosmocc" ] || { echo "cosmo-libc: $cosmocc is not installed; run scripts/setup-cosmo.sh" >&2; exit 2; }
lib=$out/libC.a
if [ ! -f "$lib" ] || [ "$host" -nt "$lib" ] || [ "$root/scripts/cosmo-libc.sh" -nt "$lib" ]; then
  mkdir -p "$out/obj"
  # the C compile of eccp's output: cosmo's gcc with cosmo's include path and predefines (cosmocc's own wrapper flags).
  # cosmocc itself refuses the -S that gcc-cc runs for its weak symbols.
  cat > "$out/cosmo-cc" <<CC
#!/bin/sh
exec "$cosmo_root/bin/x86_64-linux-cosmo-gcc" -U__k8 -U__k8__ -U__amd64 -U__amd64__ -U__x86_64 -U__x86_64__ -U__linux -U__linux__ -mno-red-zone -mlong-double-64 -D__COSMOPOLITAN__ -D__COSMOCC__ -D__FATCOSMOCC__ -isystem "$cosmo_root/include" -fno-pie -nostdinc -isystem "$cosmo_root/include" "\$@"
CC
  chmod +x "$out/cosmo-cc"
  # the host archive's members, minus decode.o
  members=$(ar t "$host" | grep -v '^decode\.o$')
  rm -f "$out/obj"/*.o
  for o in $members; do
    src=$root/3rd/edg/lib_src/${o%.o}.c
    [ -f "$src" ] || { echo "cosmo-libc: no source for $o in 3rd/edg/lib_src" >&2; exit 2; }
    NFCXX_GCC=$out/cosmo-cc NFCXX_CC=$root/scripts/gcc-cc NFCXX_CCACHE=0 "$edg/bin/eccp" --building_runtime --c++23 -g \
      -DCHECKING=1 -DDEBUG=1 -DUSE_STDINT_HEADER -DSYSTEM_RUNTIME_HAS_IA64_THREAD_ATEXIT=0 -D__COSMOPOLITAN__ -D__COSMOCC__ \
      -D__FATCOSMOCC__ --preinclude "$cosmo_root/include/libc/integral/normalize.inc" --no_standard_includes \
      --sys_include="$root/3rd/edg/include_c++" --sys_include="$root/3rd/edg/include_c99" --sys_include="$cosmo_root/include" \
      --g++ --nfcxx_eh_thread_local -DNFCXX_EH_TLS=1 --c_to_obj_option -fPIC -o "$out/obj/$o" -c "$src"
  done
  objcopy -W _ZSt9terminatev -W _ZSt13get_terminatev -W _ZSt13set_terminatePFvvE -W _ZSt14set_unexpectedPFvvE \
    -W _ZSt10unexpectedv "$out/obj/eh_util.o"
  rm -f "$lib"; ar rcs "$lib" "$out"/obj/*.o
fi
echo "$out"
