#!/usr/bin/env ruby
# nfcxx's keep_static choice (docs/notes/driver-body-port.md): -fkeep-static-functions keeps EDG's static __tls_init (thread_local
# dynamic initialization), but it is a GCC option, and clang (the C compiler on macOS) rejects it. So the option is passed unless the
# C compiler (NFCXX_GCC, default cc) reports clang on the first line of its --version. The bash was
#   keep_static=(--c_to_obj_option -fkeep-static-functions)
#   "${NFCXX_GCC:-cc}" --version 2>/dev/null | head -1 | grep -qi clang && keep_static=()
# tests/driver-keep-static/run.sh checks the port against that bash verbatim, with stub compilers.
#
#   ruby scripts/nfcxx-keep-static.rb plan      prints the assignment of keep_static (for eval); status 0
module NfcxxKeepStatic
  module_function

  # the first line of the C compiler's --version (empty when it fails or prints nothing), as the bash's head -1 gives it
  def first_version_line(compiler)
    out = IO.popen([compiler, "--version"], err: File::NULL, &:read)
    out.to_s.lines.first.to_s
  rescue SystemCallError
    ""
  end

  def assignment(compiler)
    clang = first_version_line(compiler).match?(/clang/i)
    clang ? "keep_static=()" : "keep_static=(--c_to_obj_option -fkeep-static-functions)"
  end
end

if $PROGRAM_NAME == __FILE__
  abort "nfcxx-keep-static: plan (got #{ARGV.first.inspect})" unless ARGV == ["plan"]
  puts NfcxxKeepStatic.assignment(ENV["NFCXX_GCC"].to_s.empty? ? "cc" : ENV["NFCXX_GCC"])
end
