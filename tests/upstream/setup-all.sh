#!/usr/bin/env bash
# Prepare all candidate sources; optional native/cross-route smoke invocations.
set -euo pipefail
cd "$(dirname "$0")/../.."
mode=${1:-sources}
case $mode in sources|smoke) ;; *) echo 'usage: setup-all.sh [sources|smoke]' >&2; exit 1 ;; esac
tests/upstream/setup.sh
tests/upstream/setup-cpprefjp.sh
for suite in gcc clang llvm-test-suite microsoft-stl; do tests/upstream/setup-git.sh "$suite"; done
tests/upstream/index-suites.sh
if [ ! -f 3rd/edg/src/cfe.c ]; then git submodule update --init --depth 1 3rd/edg; fi
if [ "$mode" = smoke ]; then
  [ -x build/edg/bin/cpfe ] || scripts/setup-edg.sh
  [ -x build/qbe/qbe ] && [ -x build/cproc/cproc-qbe ] || scripts/setup-qbe.sh
  [ -x build/pathb/cmake/bin/cpfe ] || scripts/setup-pathb.sh
  tests/upstream/self-test.sh
  tests/upstream/run-clang.sh
  tests/upstream/setup-llvm-test-suite.sh
  tests/upstream/edg.sh regressions
  tests/upstream/run-cppreference.sh
  tests/upstream/run-selected.sh
fi
echo 'All candidate snapshots are installed; per-suite logs/results distinguish measured gaps from setup errors.'
