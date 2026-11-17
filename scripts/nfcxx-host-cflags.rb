#!/usr/bin/env ruby
# nfcxx's host-platform cflags (stage B3 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: the additions that
# depend on the backend, freestanding and the host (Darwin, Linux aarch64). Checked against the bash by tests/driver-host/run.sh.
#
#   ruby scripts/nfcxx-host-cflags.rb plan backend=NAME freestanding=0|1 sys=UNAME_S mach=UNAME_M root=ROOT
#       prints the shell statements (cflags+= and files+=) for the driver to eval, in the order the bash appends them.
#
#   - Path B hosted on macOS: lib/pathb/clang_macros.h and lib/pathb/darwin-include (docs/notes/... libc++ on Darwin).
#   - Path B hosted on arm64 macOS: -D_LIBCPP_ABI_ALTERNATE_STRING_LAYOUT (the SDK's libc++ layout; Darwin arm64 only).
#   - Path B hosted on Linux aarch64: lib/pathb/linux-aarch64-include (bits/math-vector.h stands in for GCC's vector types).
#   - Hosted on Linux aarch64, either backend: -D__AARCH64EL__=1 for cflags and files (the multiarch headers need it).

require "shellwords"

module NfcxxHostCflags
  module_function

  def q(s) = Shellwords.escape(s)

  def plan(opts)
    backend = opts.fetch("backend")
    hosted = opts.fetch("freestanding") == "0"
    sys = opts.fetch("sys")
    mach = opts.fetch("mach")
    root = opts.fetch("root")
    pathb = backend == "pathb"
    arm = %w[aarch64 arm64].include?(mach)
    out = []
    out << "cflags+=(#{q("-include")} #{q("#{root}/lib/pathb/clang_macros.h")} #{q("-I")} #{q("#{root}/lib/pathb/darwin-include")})" if pathb && hosted && sys == "Darwin"
    out << "cflags+=(-D_LIBCPP_ABI_ALTERNATE_STRING_LAYOUT)" if pathb && hosted && sys == "Darwin" && mach == "arm64"
    out << "cflags+=(#{q("-I")} #{q("#{root}/lib/pathb/linux-aarch64-include")})" if pathb && hosted && sys == "Linux" && arm
    if hosted && sys == "Linux" && arm
      out << "cflags+=(-D__AARCH64EL__=1); files+=(-D__AARCH64EL__=1)"
    end
    out
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-host-cflags: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  puts NfcxxHostCflags.plan(rest.to_h { |kv| kv.split("=", 2) })
end
