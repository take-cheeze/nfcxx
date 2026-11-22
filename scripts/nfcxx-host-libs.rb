#!/usr/bin/env ruby
# nfcxx's host-dependent choices for the front end's defines and the Path B link libraries (stage B3 of
# docs/notes/driver-body-port.md), ported from the bash in nfcxx. Checked against the bash by tests/driver-host-libs/run.sh.
#
#   ruby scripts/nfcxx-host-libs.rb plan sys=UNAME_S freestanding=0|1
#       prints shell statements: posix_def (the front end's POSIX define, as the macOS base), pb_cxx_libs and pb_atomic_lib
#       (the host's C++ and atomic libraries; for a freestanding program none but libc++ on macOS, for the exception tables' personality).

require "shellwords"

module NfcxxHostLibs
  module_function

  def q(s) = Shellwords.escape(s)

  def plan(opts)
    sys = opts.fetch("sys")
    freestanding = opts.fetch("freestanding", "0") == "1"
    darwin = sys == "Darwin"
    posix_def = darwin ? ["-D_DARWIN_C_SOURCE", "-U__BLOCKS__"] : ["-D_POSIX_SOURCE"]
    cxx, atomic = darwin ? ["-lc++", ""] : ["-lstdc++ -lgcc_s", "-latomic"]
    # a freestanding program has no C++ library, but on macOS its exception tables (a landing pad that calls std::terminate
    # is enough) name libc++abi's personality, __gxx_personality_v0: libc++ is named for that. Linux takes it from libstdc++,
    # which pathb-ldrt.rb's link script names.
    cxx = darwin ? "-lc++" : "" if freestanding
    atomic = "" if freestanding
    [
      "posix_def=(#{posix_def.map { |w| q(w) }.join(" ")})",
      "pb_cxx_libs=#{q(cxx)}",
      "pb_atomic_lib=#{q(atomic)}",
    ]
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-host-libs: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  puts NfcxxHostLibs.plan(rest.to_h { |kv| kv.split("=", 2) })
end
