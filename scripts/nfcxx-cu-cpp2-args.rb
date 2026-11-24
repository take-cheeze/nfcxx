#!/usr/bin/env ruby
# The CUDA, .cpp2 and C++ module refusals that the bash prints before its setup (stage B4 of docs/notes/driver-body-port.md).
# scripts/nfcxx-setup-args.rb calls check(scalars, arrays, env) with the argument loop's state, after its own deferrals. The
# bash's order is: the .cu preparation (cu_prepare), the .cpp2 preparation (cpp2_prepare), the module block, then the setup.
# check returns a refusal to print (a NfcxxSetup::Refusal: the bash's message and status), :setup (the setup check goes on), or
# :oracle (the bash runs the command: a step that rewrites, translates or compiles comes first, or the check cannot tell the
# bash's message).
#
# Only the refusals the bash prints before it compiles or translates anything are here:
#   .cu: a source directory that does not exist (cu_copies' realpath, status 2). A missing input file is the rewriter's own
#        message (cuda-rewrite: cannot read), printed by the rewriter, so it stays in the oracle.
#   .cpp2: cppfront or cpp2util.h not built (status 2); the directory or the file of the first input does not exist (realpath,
#        status 1). A later input is checked after cppfront has translated the first one, and cppfront's own failures are its
#        messages, so both stay in the oracle.
#   modules (a source that declares or imports one): the -std check, the C-source check, the source checks of
#        scripts/nfcxx-modscan.rb (partitions, header units, std imports), and -c with more than one source. A link of modules
#        runs the module build (it compiles), so its setup check is the oracle's.
# The directories the bash makes first (with -c, the .cu and .cpp2 cache directories) are not made here: a refusal does not use
# them. Every command needs build/cuda-rewrite for this check: ensure_tool builds it when it is missing (a compile), so without
# it the oracle runs.

require_relative "nfcxx-setup"
require_relative "nfcxx-modscan"
require_relative "driver-state"

module NfcxxCuCpp2Args
  module_function

  ROOT = File.expand_path("..", __dir__)
  # the C++ standards before C++20 (the bash's case on $std in the module block)
  OLD_STANDARDS = %w[--c++98 --c++03 --c++11 --c++14 --c++17].freeze

  # the check cannot tell the bash's message (a realpath error other than "no such file", or an unreadable source): the oracle
  class Undecided < StandardError; end

  Refusal = NfcxxSetup::Refusal

  def nonempty(v) = (v.nil? || v.empty?) ? nil : v

  # true when PATH resolves (gnu_realpath, as the driver's realpath calls); false when realpath says "No such file or directory";
  # any other failure is Undecided
  def resolves?(path)
    DriverState.gnu_realpath(path)
    true
  rescue Errno::ENOENT
    false
  rescue SystemCallError
    raise Undecided
  end

  # cu_copies: the source directory of each .cu input, in order, before any rewrite (the first one that does not exist)
  def cu_refusal(cu)
    cu.each do |src|
      dir = File.dirname(src)
      return Refusal.new("realpath: #{dir}: No such file or directory", 2) unless resolves?(dir)
    end
    nil
  end

  # cpp2_prepare: cppfront and cpp2util.h first, then the first input's directory and file (before cppfront runs on it)
  def cpp2_refusal(cpp2, env)
    return Refusal.new("nfcxx: cppfront is not built; run scripts/setup-cppfront.sh (docs/notes/cpp2.md)", 2) unless File.executable?(File.join(ROOT, "build", "cppfront"))
    src_dir = nonempty(env["CPPFRONT_SRC"]) || File.join(ROOT, "build", "cppfront-src")
    unless File.file?(File.join(src_dir, "include", "cpp2util.h"))
      return Refusal.new("nfcxx: no cpp2util.h under #{src_dir}; run scripts/setup-cppfront.sh", 2)
    end
    src = cpp2[0]
    dir = File.dirname(src)
    return Refusal.new("realpath: #{dir}: No such file or directory", 1) unless resolves?(dir)
    return Refusal.new("realpath: #{src}: No such file or directory", 1) unless resolves?(src)
    nil
  end

  # the module block (the bash's modules=1 case): the standard, the C sources, each source's check (in order), then -c with one
  # source; a link (not -c) is the module build's, which compiles, so the oracle runs it
  def modules_check(scalars, arrays)
    srcs = arrays.fetch("srcs", [])
    # every source is read (the bash's is-module loop reads them all), so an unreadable one is the oracle's
    flags = srcs.map { |s| NfcxxModscan.module_src?(s) }
    return :setup unless flags.any?

    return Refusal.new("nfcxx: C++ modules need -std=c++20 or later", 2) if OLD_STANDARDS.include?(scalars.fetch("std", ""))
    unless arrays.fetch("cfiles", []).empty?
      return Refusal.new("nfcxx: C sources cannot be built with C++ modules yet (docs/notes/modules.md)", 2)
    end

    srcs.each do |s|
      rc, msg = NfcxxModscan.check_source(s)
      return Refusal.new(msg, rc) unless rc.zero?
    end
    return :oracle unless scalars["compile_only"] == "1"
    return Refusal.new("nfcxx: -c with C++ modules takes one source", 2) unless srcs.size == 1

    :setup
  end

  # the decision for the command: a Refusal, :setup or :oracle (see the header)
  def check(scalars, arrays, env = ENV)
    return :oracle unless File.executable?(File.join(ROOT, "build", "cuda-rewrite"))

    cu = arrays.fetch("cu_inputs", [])
    return (cu_refusal(cu) || :oracle) unless cu.empty?

    cpp2 = arrays.fetch("cpp2_inputs", [])
    return (cpp2_refusal(cpp2, env) || :oracle) unless cpp2.empty?

    modules_check(scalars, arrays)
  rescue Undecided, SystemCallError
    :oracle
  end
end
