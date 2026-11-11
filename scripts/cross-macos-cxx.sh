#!/bin/sh
# cross-macos-cxx.sh: the C++ compiler for the cross path's preprocess and dependency scan (nfcxx -M). It targets Darwin
# arm64 and drops the host's include directories (-nostdinc, -nostdinc++): the host's /usr/include, with glibc's
# features.h, must not leak into a macOS compile. nfcxx passes the cross include directories itself (NFCXX_SYS_INCLUDES).
exec clang++ --target=arm64-apple-darwin -nostdinc -nostdinc++ -isystem "$(clang -print-resource-dir)/include" "$@"
