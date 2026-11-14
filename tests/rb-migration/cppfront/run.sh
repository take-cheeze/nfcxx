#!/bin/bash
# Differential test: scripts/setup-cppfront.rb against the bash it replaced (oracle.sh here). See ../lib.sh.
# CPP2=1 makes the checkout in @SB@/cpp (CPPFRONT_SRC names it); NOINFO=1 leaves out its version.info. A clone runs the
# git stub; RB_STUB_FETCH_SRC=1 makes its fetch produce the source.
here=$(cd "$(dirname "$0")" && pwd -P)
. "$here/../lib.sh"
NAME=cppfront

prep() {
  case " $2 " in
    *" CPP2=1 "*)
      mkdir -p "$1/cpp/source"
      echo "void f();" > "$1/cpp/source/cppfront.cpp"
      case " $2 " in
        *" NOINFO=1 "*) ;;
        *) echo 'const char* version = "v0.8.2";' > "$1/cpp/source/version.info" ;;
      esac ;;
  esac
}

rbm_cases <<'EOF'
checkout given|CPPFRONT_SRC=@SB@/cpp CPP2=1
checkout without version info|CPPFRONT_SRC=@SB@/cpp CPP2=1 NOINFO=1
checkout missing|CPPFRONT_SRC=@SB@/cpp
clone|RB_STUB_FETCH_SRC=1
clone from another remote|RB_STUB_FETCH_SRC=1 CPPFRONT_REPO=https://mirror.test/cppfront
clone without source|
fetch fails|RB_STUB_GIT_FAIL=fetch
compiler fails|CPPFRONT_SRC=@SB@/cpp CPP2=1 CXX=cxxfail
compiler named by CXX|CPPFRONT_SRC=@SB@/cpp CPP2=1 CXX=c++
EOF
rbm_finish
