#!/usr/bin/env ruby
# cu_prepare and cpp2_prepare of the frozen body (docs/notes/driver-body-port.md, item 4), in Ruby. The body keeps its
# temporary directory and its EXIT trap (the body's own cleanup, and the body reads cudatmp after the prepare). It writes the
# state the step needs as records (state_put: k NAME, then v VALUE for each), and this script does the rest: the directory of
# the copies (with -c, the per-user cache; otherwise the temporary directory), the rewrite of each .cu input
# (scripts/nfcxx-cuda-device.rb: cu_prepare_run), the translation of each .cpp2 input (scripts/nfcxx-cpp2.rb: NfcxxCpp2.run,
# cppfront in a scratch directory), and the array edits (scripts/nfcxx-cu-apply.rb: srcs, files, cflags, cuda_opts, preinc).
# Standard output is the statements the body evals. The rewriter's own output is discarded here (the body sent it to its
# reply file before, so it was never shown). A failed step prints its message on standard error and ends with its status.
#
#   ruby scripts/nfcxx-cu-cpp2-prepare.rb cu   < RECORDS   the .cu inputs (cu_prepare)
#   ruby scripts/nfcxx-cu-cpp2-prepare.rb cpp2 < RECORDS   the .cpp2 inputs (cpp2_prepare; the arrays are the .cu step's)
#
# RECORDS are driver-state groups. Both: root, tmp (the body's temporary directory), compile_only, out, outset, inputs, srcs,
# files, cflags. cu also: bash_pid, trace_unit, obfuscate, ir_opt (only when set), promote_slots, unroll, struct_slots,
# cache_dir, cache_log, preinc, cuda, edg_launch (the groups cu_prepare_run reads). A scalar is its first value.

require "fileutils"
require "stringio"
require_relative "driver-state"
require_relative "nfcxx-cu-apply"
require_relative "nfcxx-cpp2"
require_relative "nfcxx-cuda-device"

module NfcxxCuCpp2Prepare
  module_function

  SEP = "\x1f"

  # a step that failed: its message (empty when the step printed its own) and status
  class Failed < StandardError
    attr_reader :status

    def initialize(message, status)
      super(message)
      @status = status
    end
  end

  def str(groups, name) = (groups[name] || []).first.to_s
  def list(groups, name) = groups[name] || []
  def joined(groups, name) = list(groups, name).join(SEP)
  def compile_only?(groups) = str(groups, "compile_only") == "1"

  # the object a -c compile of this command writes: -o, or the first input's name with .o (the bash's rule for both steps)
  def object_of(groups, ext)
    return str(groups, "out") if str(groups, "outset") == "1"

    "#{File.basename(list(groups, "inputs")[0].to_s, ext)}.o"
  end

  # cu_prepare: each .cu input is rewritten, its copy takes the input's place in srcs and files, and the -I of its directory
  # goes into cflags and files. The copies go to the per-user cache for a -c compile (the object's key), else to the temporary
  # directory. Returns the statements the body evals.
  def cu(groups, env = ENV) = cu_result(groups, env)[0]

  # cu's statements and the arrays they set (srcs, files, cflags), for cpp2 to continue from
  def cu_result(groups, env = ENV)
    dir = str(groups, "tmp")
    keep = ""
    if compile_only?(groups)
      keep = cu_dir(object_of(groups, ".cu"), env)
      FileUtils.mkdir_p(keep)
      dir = keep
    end
    state = groups.merge("dir" => [dir], "keep" => [keep])
    result, status = cu_prepare_run(state)
    raise Failed.new("", status) unless status == 0

    reply = StringIO.new
    DriverState.write_groups(reply, result)
    DriverState.write_end(reply)
    applied = NfcxxCuApply.arrays(arrays(groups, "cu"), reply.string)
    [NfcxxCuApply.plan(arrays(groups, "cu"), reply.string), applied]
  rescue CuCopiesFailed => e
    raise Failed.new(e.message, 2)
  rescue CudaRefused => e
    raise Failed.new("nfcxx: #{e.message}", 2)
  rescue CudaUnported => e
    raise Failed.new("unported: #{e.message}", 3)
  end

  # cpp2_prepare: the checks, the directory and the translations are NfcxxCpp2.run's (cppfront must be built, the directory
  # of the translations is the per-user cache for a -c compile). Returns the statements the body evals.
  def cpp2(groups, env = ENV)
    root = str(groups, "root")
    cppfront_src = env["CPPFRONT_SRC"].to_s.empty? ? "#{root}/build/cppfront-src" : env["CPPFRONT_SRC"]
    opts = arrays(groups, "cpp2").merge(
      "root" => root, "cppfront_src" => cppfront_src, "cudatmp" => str(groups, "tmp"),
      "compile_only" => str(groups, "compile_only"), "out" => str(groups, "out"), "outset" => str(groups, "outset")
    )
    NfcxxCpp2.run(opts, env)
  rescue NfcxxCpp2::Failed => e
    raise Failed.new(e.message, e.status)
  end

  # both: the .cu inputs (cu_prepare), then the .cpp2 inputs (cpp2_prepare) in the same process, so cpp2 continues from the arrays
  # cu set. The records' "cpp2_inputs" group is the .cpp2 list (the "inputs" group is the .cu list). Returns the statements the body evals.
  def both(groups, env = ENV)
    statements = []
    g = groups
    unless list(groups, "inputs").empty?
      text, applied = cu_result(groups, env)
      statements << text
      g = g.merge("srcs" => applied["srcs"], "files" => applied["files"], "cflags" => applied["cflags"])
    end
    unless list(groups, "cpp2_inputs").empty?
      statements << cpp2(g.merge("inputs" => list(groups, "cpp2_inputs")), env)
    end
    statements.join("\n")
  end

  # the options NfcxxCuApply.plan and NfcxxCpp2.run take: the input list and the arrays, joined
  def arrays(groups, kind)
    { "kind" => kind, "inputs" => joined(groups, "inputs"), "srcs" => joined(groups, "srcs"),
      "files" => joined(groups, "files"), "cflags" => joined(groups, "cflags") }
  end

  def joined(groups, name) = list(groups, name).join(SEP)
end

if $PROGRAM_NAME == __FILE__
  kind = ARGV[0]
  abort "nfcxx-cu-cpp2-prepare: cu, cpp2 or both (records on standard input)" unless ARGV.size == 1 && %w[cu cpp2 both].include?(kind)

  begin
    groups = DriverState.read_groups($stdin.binmode.read)
  rescue ArgumentError => e
    warn "nfcxx-cu-cpp2-prepare: #{e.message}"
    exit 2
  end

  saved = $stdout.dup
  statements = nil
  failure = nil
  begin
    $stdout.reopen(File::NULL)
    statements = case kind
                 when "cu" then NfcxxCuCpp2Prepare.cu(groups)
                 when "cpp2" then NfcxxCuCpp2Prepare.cpp2(groups)
                 else NfcxxCuCpp2Prepare.both(groups)
                 end
  rescue NfcxxCuCpp2Prepare::Failed => e
    failure = e
  ensure
    $stdout.reopen(saved)
  end

  if failure
    warn failure.message unless failure.message.empty?
    exit failure.status
  end
  puts statements
end
