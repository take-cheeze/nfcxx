#!/usr/bin/env ruby
# nfcxx's SYCL pre-pass, ported from the bash in nfcxx (sycl_kernel_headers and the block after it; stage 5 of
# docs/notes/driver-port-plan.md, docs/notes/sycl-kernel-builtins.md). The Ruby driver (scripts/nfcxx.rb) makes these two calls before the body:
#
#   ruby scripts/nfcxx-sycl.rb check ARG...             exit 0: the two passes apply; exit 1: they do not (the bash goes on)
#   ruby scripts/nfcxx-sycl.rb run --root=DIR ARG...    runs the two passes and exits with the status the bash gave: 2 for its
#                                                       messages, else the second pass's status
#
# ARG... is the driver's argument list as given (the bash's args0). The decision reads the arguments the way the bash's loop
# classifies them (scripts/nfcxx-prepass.rb's parse_args): a -c compile of one source, where .cu and .cpp2 are sources, with no
# object, C input, -E or --emit-c, an -I directory that holds sycl/detail/kernel_desc.hpp, and a source that includes <sycl/...>.
# NFCXX_SYCL_PASS set (the second pass, or a run inside one) means no pre-pass.
# Pass 1 runs the driver with NFCXX_SYCL_PASS and NFCXX_SYCL_DUMP (its log is kept, and its status ignored); a dump with no
# record is the bash's refusal; scripts/sycl-integration-header.rb makes the integration header; the wrapper includes sycl.hpp,
# that header and the source; pass 2 compiles the wrapper with __SYCL_UNNAMED_LAMBDA__=1. The temporary directory is removed
# on every exit (the bash's pass 2 failure left it: its set -e exited before the removal).
# Tests: tests/nfcxx-sycl/run.sh (the bash block, verbatim, is tests/nfcxx-sycl/oracle.sh).

require "fileutils"
require "tmpdir"
require_relative "nfcxx-prepass"

module NfcxxSycl
  module_function

  # the loop's classification of ARG..., or nil when the planner's loop refuses the arguments (the bash refuses them too,
  # before this point, so the bash goes on and refuses them itself)
  def state(argv)
    parse_args(argv)
  rescue Stop, Unported
    nil
  end

  # sycl_kernel_headers ARG...: a -I directory of the arguments (-IDIR, or the word after -I) holds sycl/detail/kernel_desc.hpp
  def headers?(argv)
    prev = nil
    argv.each do |a|
      d = nil
      d = a[2..] if a.start_with?("-I") && a.length > 2
      d = a if prev == "-I"
      prev = a
      next if d.nil? || d.empty?
      return true if File.file?("#{d}/sycl/detail/kernel_desc.hpp")
    end
    false
  end

  # the decision of the bash's SYCL block
  def applies?(argv)
    return false unless ENV["NFCXX_SYCL_PASS"].to_s.empty?
    st = state(argv)
    return false if st.nil? || st[:emit_hip]
    # a .cu input is not in the two passes: its device pre-pass is the CUDA plan (the bash ran the passes for it before)
    st[:compile_only] && st[:ncpp] == 1 && st[:nobj].zero? && st[:ncfiles].zero? && !st[:preprocess] && !st[:emit_c] &&
      st[:cu].empty? && headers?(argv) && !st[:srcs].empty? && sycl_include?(st[:srcs][0])
  end

  # a command with NAME=VALUE environment entries; its status (127 when it cannot start, as the shell's)
  def spawn_wait(env, *cmd, **opts)
    pid = Process.spawn(env, *cmd, **opts)
    Process.wait(pid)
    $?.exitstatus || (128 + $?.termsig)
  rescue SystemCallError
    127
  end

  # the two passes: the status the bash gives
  def run(argv, root)
    st = state(argv)
    raise ArgumentError, "run: the arguments are not a SYCL build" if st.nil? || st[:srcs].empty?
    src = st[:srcs][0]
    driver = File.join(root, "nfcxx")
    tmp = Dir.mktmpdir("nfcxx-sycl")
    begin
      sy_src = File.realpath(src)
      dump = File.join(tmp, "dump")
      log = File.join(tmp, "pass1.log")
      # Pass 1: the front end records the kernels (the compile fails at the header's size check; the record is what matters)
      spawn_wait({ "NFCXX_SYCL_PASS" => "1", "NFCXX_SYCL_DUMP" => dump }, driver, *argv, out: log, err: log)
      unless File.size?(dump)
        system("cat", log, out: $stderr)
        $stderr.puts "nfcxx: the SYCL pre-pass recorded no kernels"
        return 2
      end
      hdr = File.join(tmp, "integration.hpp")
      return 2 unless system(File.join(root, "scripts", "sycl-integration-header.rb"), dump, out: hdr)
      wrapper = File.join(tmp, "wrapper.cpp")
      File.write(wrapper, "#include <sycl/sycl.hpp>\n#include \"#{hdr}\"\n#include \"#{sy_src}\"\n")
      sy_args = argv.map { |a| a == src ? wrapper : a }
      sy_args += ["-o", "#{File.basename(strip_ext(sy_src))}.o"] unless st[:outset]
      # Pass 2: the wrapper, with the macro that selects the integration-header path (and __make_integer_seq)
      spawn_wait({ "NFCXX_SYCL_PASS" => "1" }, driver, "-D__SYCL_UNNAMED_LAMBDA__=1", *sy_args)
    ensure
      FileUtils.rm_rf(tmp)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  case cmd
  when "check"
    exit(NfcxxSycl.applies?(rest) ? 0 : 1)
  when "run"
    root = rest.first.to_s.delete_prefix("--root=")
    abort "nfcxx-sycl: run takes --root=DIR first" unless rest.first.to_s.start_with?("--root=")
    exit NfcxxSycl.run(rest[1..], root)
  else
    abort "nfcxx-sycl: check or run (got #{cmd.inspect})"
  end
end
