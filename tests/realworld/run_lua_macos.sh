#!/usr/bin/env bash
# Lua 5.4 for macOS arm64: the shared harness, cross_macos.sh lua (see there for the expected results).
exec "$(dirname "$0")/cross_macos.sh" lua
