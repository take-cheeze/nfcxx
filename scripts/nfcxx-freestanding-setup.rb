#!/usr/bin/env ruby
# nfcxx's freestanding or hosted setup (stage B3 of docs/notes/driver-body-port.md), ported from the bash in nfcxx. Freestanding:
# headers come only from lib/ (extra), and --gnu-version defaults to 130000. Hosted: the host's C++ include directories
# (scripts/host-sys.rb host_sys_includes), libm (and libc++ on Darwin) for the link, and the host's GNU version when none was given.
# Checked against the bash by tests/driver-freestanding/run.sh.
#
#   ruby scripts/nfcxx-freestanding-setup.rb plan freestanding=0|1 gnu=VERSION sys=UNAME_S root=ROOT
#       prints the shell statements for the driver to eval (the trace spans stay in the driver around the call).

require "shellwords"

module NfcxxFreestanding
  module_function

  def q(s) = Shellwords.escape(s)

  def host_sys(root, command)
    ruby = ENV["RUBY"] || "ruby"
    out = IO.popen([ruby, File.join(root, "scripts", "host-sys.rb"), command], err: File::NULL, &:read)
    out.to_s
  end

  def plan(opts)
    freestanding = opts.fetch("freestanding") == "1"
    gnu = opts.fetch("gnu", "")
    sys = opts.fetch("sys")
    root = opts.fetch("root")
    lines = []
    if freestanding
      lines << "extra=(--no_standard_includes #{q("-I#{root}/lib")})"
      lines << "gnu=130000" if gnu.empty?
    else
      # the host's include directories: one per line, empty lines skipped (the bash read loop)
      host_sys(root, "host_sys_includes").each_line do |d|
        d = d.chomp
        lines << "sys_inc+=(#{q("--sys_include=#{d}")})" unless d.empty?
      end
      lines << "hosted_libs=(--c_to_obj_lib=m)"
      lines << "hosted_libs+=(--c_to_obj_lib=c++)" if sys == "Darwin"
      if gnu.empty?
        version = host_sys(root, "host_gnu_version").sub(/\n+\z/, "")
        lines << "gnu=#{q(version)}"
      end
    end
    lines
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-freestanding: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  puts NfcxxFreestanding.plan(rest.to_h { |kv| kv.split("=", 2) })
end
