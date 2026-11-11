#!/usr/bin/env bash
# nfcbundle (tools/bundle, docs/notes/bundle.md): shared libraries copied into the executable or shared object that
# needs them. Each case builds a program the usual way, runs it, bundles it, moves the bundled libraries out of
# reach, and runs the bundle: the output must be the same and the bundle must not name the libraries in DT_NEEDED.
#   - C (host gcc): libA (TLS in every model, IFUNC, versions, a weak hook, an interposed symbol, copy relocations)
#     under libB, with threads; linked with GNU ld and lld, PIE and not, RELR, lazy binding; a bundled libB.so
#     dlopen'ed and linked against;
#   - C++ (host g++): libstdc++ and libgcc_s bundled, exceptions thrown and caught across them, a C++ library
#     bundled into a shared object that a C program dlopens;
#   - nfcxx (both backends, when EDG is built) and nfcc: --bundle-libs on the driver.
#   NFCXX_BACKEND=gcc|qbe   (default: both, for the nfcxx cases)
cd "$(dirname "$0")/../.."
root=$PWD
d=tests/bundle
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ninja -C tools/bundle >/dev/null || exit 1
B=$root/build/nfcbundle

ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; [ -z "${2:-}" ] || head -20 <<<"$2"; fail=1; }
# check NAME DIR REF-CMD BUNDLE-CMD [HIDE]: both commands' output (stdout and stderr) must match, and the bundle must
# need none of the libraries in DIR/lib (renamed while the bundle runs; so is the directory HIDE when given).
check() {
  local name=$1 dir=$2 hide=${5:-} ref out
  ref=$(eval "$3" 2>&1); local rc1=$?
  mv "$dir/lib" "$dir/lib.gone"; [ -z "$hide" ] || mv "$hide" "$hide.gone"
  out=$(eval "$4" 2>&1); local rc2=$?
  mv "$dir/lib.gone" "$dir/lib"; [ -z "$hide" ] || mv "$hide.gone" "$hide"
  if [ "$ref" != "$out" ] || [ $rc1 != $rc2 ]; then bad "$name (output differs)" "$(diff <(echo "$ref") <(echo "$out"))"; return; fi
  ok "$name"
}
needs() {  # needs FILE: the DT_NEEDED entries
  readelf -dW "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '
}

# --- C: libA under libB, linker variants -------------------------------------------------------------------------
cvariant() {  # cvariant NAME LIB-LDFLAGS EXE-LDFLAGS
  local name=$1 lf=$2 ef=$3 w; w=$tmp/c-$1; mkdir -p "$w/lib"
  if ! out=$(gcc -shared -fPIC -O1 $d/liba.c -Wl,--version-script=$d/liba.map -Wl,-soname,liba.so $lf -o "$w/lib/liba.so" 2>&1 &&
             gcc -shared -fPIC -O1 $d/libb.c -L"$w/lib" -la -Wl,-soname,libb.so $lf -o "$w/lib/libb.so" 2>&1 &&
             gcc -O1 $d/main.c -L"$w/lib" -lb -la -Wl,-rpath,"$w/lib" $ef -pthread -o "$w/main" 2>&1); then
    bad "C $name (build)" "$out"; return
  fi
  if ! out=$("$B" "$w/main" -o "$w/main.b" 2>&1); then bad "C $name (bundle)" "$out"; return; fi
  case " $(needs "$w/main.b") " in *" liba.so "*|*" libb.so "*) bad "C $name: the bundle still needs $(needs "$w/main.b")"; return ;; esac
  check "C $name" "$w" "'$w/main'" "'$w/main.b'"
}
cvariant "GNU ld PIE" "" ""
cvariant "GNU ld no-PIE" "" "-no-pie -fno-pie"
cvariant "GNU ld RELR" "-Wl,-z,pack-relative-relocs" "-Wl,-z,pack-relative-relocs"
cvariant "GNU ld lazy" "-Wl,-z,lazy" "-Wl,-z,lazy"
if command -v ld.lld >/dev/null; then
  cvariant "lld PIE" "-fuse-ld=lld" "-fuse-ld=lld"
  cvariant "lld no-PIE" "-fuse-ld=lld" "-fuse-ld=lld -no-pie -fno-pie"
fi

# A shared object as the input: libB with libA in it, dlopen'ed, then linked against (section headers) and loaded
# under its soname.
w=$tmp/so; mkdir -p "$w/lib" "$w/bundled"
if out=$(gcc -shared -fPIC -O1 $d/liba.c -Wl,--version-script=$d/liba.map -Wl,-soname,liba.so -o "$w/lib/liba.so" 2>&1 &&
         gcc -shared -fPIC -O1 $d/libb.c -L"$w/lib" -la -Wl,-soname,libb.so -Wl,-rpath,"$w/lib" -o "$w/lib/libb.so" 2>&1 &&
         gcc -O1 $d/dl.c -rdynamic -o "$w/dl" -ldl 2>&1 &&
         "$B" "$w/lib/libb.so" -o "$w/bundled/libb.so" 2>&1 &&
         "$B" --export=main "$w/lib/libb.so" -o "$w/bundled/libb-main.so" 2>&1); then
  check "C shared object, dlopen" "$w" "'$w/dl' '$w/lib/libb.so'" "'$w/dl' '$w/bundled/libb.so'"
  out=$("$w/dl" "$w/bundled/libb-main.so" 2>&1)
  case $out in *"a_get hidden"*) ok "C shared object, --export=main" ;; *) bad "C shared object, --export=main" "$out" ;; esac
  if out=$(gcc -O1 $d/main.c -L"$w/bundled" -lb -Wl,-rpath,"$w/bundled" -pthread -o "$w/main.b" 2>&1) &&
     out2=$(gcc -O1 $d/main.c -L"$w/lib" -lb -la -Wl,-rpath,"$w/lib" -pthread -o "$w/main" 2>&1); then
    check "C linked against a bundled shared object" "$w" "'$w/main'" "'$w/main.b'"
    # ... and that program bundled in turn: the bundled libB is an input library like any other.
    if out=$("$B" "$w/main.b" -o "$w/main.bb" 2>&1); then
      check "C program needing a bundled shared object, bundled" "$w" "'$w/main'" "'$w/main.bb'" "$w/bundled"
    else bad "C program needing a bundled shared object (bundle)" "$out"; fi
  else bad "C linked against a bundled shared object (build)" "$out$out2"; fi
else
  bad "C shared object (build or bundle)" "$out"
fi

# --stubs: a plugin that names the bundled libA and libB in DT_NEEDED (and has a DT_RUNPATH to the real ones, like a
# ruby extension) is dlopen'ed by the bundled program. With the stubs it shares the program's libA; the real libraries
# are out of reach while the bundle runs, so without the stubs the dlopen fails.
w=$tmp/stubs; mkdir -p "$w/lib" "$w/dist"
if out=$(gcc -shared -fPIC -O1 $d/liba.c -Wl,--version-script=$d/liba.map -Wl,-soname,liba.so -o "$w/lib/liba.so" 2>&1 &&
         gcc -shared -fPIC -O1 $d/libb.c -L"$w/lib" -la -Wl,-soname,libb.so -o "$w/lib/libb.so" 2>&1 &&
         gcc -shared -fPIC -O1 $d/plugin.c -L"$w/lib" -lb -la -Wl,-rpath,"$w/lib" -o "$w/plugin.so" 2>&1 &&
         gcc -O1 $d/pl.c -L"$w/lib" -lb -la -Wl,-rpath,"$w/lib" -o "$w/pl" -ldl 2>&1 &&
         "$B" "$w/pl" --stubs "$w/dist/stubs" -o "$w/dist/pl" 2>&1); then
  n=" $(needs "$w/dist/pl") "
  case $n in *" liba.so "*) case $n in *" libb.so "*) n="" ;; esac ;; esac
  [ -z "$n" ] || bad "C --stubs: the bundle does not need its stubs:$n"
  check "C --stubs: a plugin needing bundled libraries" "$w" "'$w/pl' '$w/plugin.so'" "'$w/dist/pl' '$w/plugin.so'"
  out=$("$w/dist/pl" "$w/plugin.so" 2>&1)
  case $out in *"one libA"*) ok "C --stubs: the plugin uses the bundled libA" ;; *) bad "C --stubs: one libA" "$out" ;; esac
else bad "C --stubs (build or bundle)" "$out"; fi

# --- C++ with the host compiler: libstdc++ and libgcc_s ----------------------------------------------------------
w=$tmp/cxx; mkdir -p "$w/lib"
if out=$(g++ -O1 $d/cxx.cpp -o "$w/cxx" 2>&1 && "$B" "$w/cxx" -o "$w/cxx.b" 2>&1); then
  case " $(needs "$w/cxx.b") " in
    *" libstdc++.so.6 "*|*" libgcc_s.so.1 "*) bad "C++ g++: the bundle still needs $(needs "$w/cxx.b")" ;;
    *) check "C++ g++ (libstdc++, libgcc_s)" "$w" "'$w/cxx'" "'$w/cxx.b'" ;;
  esac
else bad "C++ g++ (build or bundle)" "$out"; fi
# A C++ shared object (with libstdc++ in it) dlopen'ed by a C program, which itself has no C++ runtime.
if out=$(g++ -shared -fPIC -O1 $d/cxxlib.cpp -o "$w/lib/libcxxlib.so" 2>&1 &&
         gcc -O1 $d/cxxdl.c -o "$w/cxxdl" -ldl 2>&1 &&
         "$B" "$w/lib/libcxxlib.so" -o "$w/libcxxlib.b.so" 2>&1); then
  check "C++ shared object dlopen'ed from C" "$w" "'$w/cxxdl' '$w/lib/libcxxlib.so'" "'$w/cxxdl' '$w/libcxxlib.b.so'"
else bad "C++ shared object (build or bundle)" "$out"; fi

# --- the drivers ---------------------------------------------------------------------------------------------------
if [ -x "${EDG_BUILD:-build/edg}/bin/eccp" ]; then
  for be in $backends; do
    w=$tmp/nfcxx-$be; mkdir -p "$w/lib"
    export NFCXX_BACKEND=$be
    if out=$(./nfcxx $d/cxx.cpp -o "$w/cxx" 2>&1 && ./nfcxx --bundle-libs $d/cxx.cpp -o "$w/cxx.b" 2>&1); then
      case " $(needs "$w/cxx.b") " in
        *" libstdc++.so.6 "*) bad "nfcxx $be --bundle-libs: the bundle still needs $(needs "$w/cxx.b")" ;;
        *) check "nfcxx $be --bundle-libs" "$w" "'$w/cxx'" "'$w/cxx.b'" ;;
      esac
    else bad "nfcxx $be --bundle-libs (build)" "$out"; fi
    # --bundle-exclude keeps a library external.
    if out=$(./nfcxx --bundle-libs --bundle-exclude=libgcc_s $d/cxx.cpp -o "$w/cxx.x" 2>&1); then
      n=" $(needs "$w/cxx.x") "
      case $n in
        *" libstdc++.so.6 "*|*" libgcc_s.so.1 "*" libgcc_s.so.1 "*) bad "nfcxx $be --bundle-exclude: needs$n" ;;
        *" libgcc_s.so.1 "*) ok "nfcxx $be --bundle-exclude=libgcc_s" ;;
        *) bad "nfcxx $be --bundle-exclude: libgcc_s.so.1 not kept: needs$n" ;;
      esac
    else bad "nfcxx $be --bundle-exclude (build)" "$out"; fi
    # -shared: a C++ shared object with libstdc++ in it, dlopen'ed by a C program. (-shared links no EH shim, so the
    # library's own throws are left out: NO_LIBRARY_THROW.)
    if out=$(./nfcxx -DNO_LIBRARY_THROW -shared $d/cxxlib.cpp -o "$w/lib/libcxxlib.so" 2>&1 &&
             ./nfcxx -DNO_LIBRARY_THROW -shared --bundle-libs $d/cxxlib.cpp -o "$w/libcxxlib.b.so" 2>&1 &&
             gcc -O1 $d/cxxdl.c -o "$w/cxxdl" -ldl 2>&1); then
      check "nfcxx $be -shared --bundle-libs" "$w" "'$w/cxxdl' '$w/lib/libcxxlib.so'" "'$w/cxxdl' '$w/libcxxlib.b.so'"
    else bad "nfcxx $be -shared --bundle-libs (build)" "$out"; fi
    # --bundle-stubs: the stubs directory, found through $ORIGIN.
    if out=$(./nfcxx --bundle-libs --bundle-stubs="$w/st" $d/cxx.cpp -o "$w/cxx.s" 2>&1) && [ -f "$w/st/libstdc++.so.6" ] &&
       readelf -dW "$w/cxx.s" | grep -q 'RUNPATH.*\$ORIGIN/st' && [ "$("$w/cxx.s" 2>&1)" = "$("$w/cxx" 2>&1)" ]; then
      ok "nfcxx $be --bundle-stubs"
    else bad "nfcxx $be --bundle-stubs" "$out$(readelf -dW "$w/cxx.s" 2>&1 | grep -E 'NEEDED|PATH')"; fi
    # -c ignores the option (no link), as gcc ignores link options with -c.
    if out=$(./nfcxx --bundle-libs -c $d/cxx.cpp -o "$w/cxx.o" 2>&1) && [ -f "$w/cxx.o" ]; then ok "nfcxx $be --bundle-libs -c"
    else bad "nfcxx $be --bundle-libs -c" "$out"; fi
  done
  unset NFCXX_BACKEND
else
  echo "skip nfcxx --bundle-libs (EDG not built: scripts/setup-edg.sh)"
fi
w=$tmp/nfcc; mkdir -p "$w/lib"
if [ -x build/qbe/qbe ] || [ "${NFCXX_BACKEND:-}" = gcc ]; then
  # The libraries by gcc (QBE code has local-exec TLS only, which a shared object cannot use), the program by nfcc.
  # The bundle is linked through -L only: it needs no run-time path to the libraries.
  if out=$(gcc -shared -fPIC -O1 $d/liba.c -Wl,--version-script=$d/liba.map -Wl,-soname,liba.so -o "$w/lib/liba.so" 2>&1 &&
           gcc -shared -fPIC -O1 $d/libb.c -L"$w/lib" -la -Wl,-soname,libb.so -o "$w/lib/libb.so" 2>&1 &&
           ./nfcc $d/main.c -L"$w/lib" -lb -la -Wl,-rpath,"$w/lib" -pthread -o "$w/main" 2>&1 &&
           ./nfcc --bundle-libs $d/main.c -L"$w/lib" -lb -la -pthread -o "$w/main.b" 2>&1); then
    check "nfcc --bundle-libs" "$w" "'$w/main'" "'$w/main.b'"
  else bad "nfcc --bundle-libs (build)" "$out"; fi
else
  echo "skip nfcc --bundle-libs (QBE not built: scripts/setup-qbe.sh)"
fi

# --- refusals ------------------------------------------------------------------------------------------------------
out=$("$B" /bin/sh -o "$tmp/x" 2>&1; echo "rc=$?")
case $out in *"rc=0"*) ok "a program with only glibc libraries bundles to itself" ;; *) bad "glibc-only program" "$out" ;; esac
echo 'int main(void){return 0;}' > "$tmp/st.c"
if gcc -static "$tmp/st.c" -o "$tmp/st" 2>/dev/null; then
  out=$("$B" "$tmp/st" -o "$tmp/st.b" 2>&1; echo "rc=$?")
  case $out in *"no PT_DYNAMIC"*"rc=1"*) ok "a static executable is refused" ;; *) bad "static executable" "$out" ;; esac
fi

exit $fail
