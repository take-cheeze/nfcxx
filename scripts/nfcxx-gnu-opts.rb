#!/usr/bin/env ruby
# nfcxx's front-end version option (stage B3 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: the clang dialect
# takes the host's clang version (scripts/host-sys.rb host_clang_version, when it has one); otherwise a GNU version, when one
# was given, is the front end's --gnu_version. Checked against the bash by tests/driver-gnu-opts/run.sh.
#
#   ruby scripts/nfcxx-gnu-opts.rb plan dialect=NAME gnu=VERSION root=ROOT
#       prints gnu_opts=(...) for the driver to eval.

require "shellwords"

module NfcxxGnuOpts
  module_function

  def plan(opts)
    dialect = opts.fetch("dialect", "")
    gnu = opts.fetch("gnu", "")
    root = opts.fetch("root")
    words =
      if dialect == "clang"
        cv = IO.popen([ENV["RUBY"] || "ruby", File.join(root, "scripts", "host-sys.rb"), "host_clang_version"], err: File::NULL, &:read).to_s
        cv = cv.sub(/\n+\z/, "")
        cv.empty? ? [] : ["--clang_version=#{cv}"]
      elsif !gnu.empty?
        ["--gnu_version=#{gnu}"]
      else
        []
      end
    "gnu_opts=(#{words.map { |w| Shellwords.escape(w) }.join(" ")})"
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-gnu-opts: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  puts NfcxxGnuOpts.plan(rest.to_h { |kv| kv.split("=", 2) })
end
