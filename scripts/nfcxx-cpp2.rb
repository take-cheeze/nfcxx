#!/usr/bin/env ruby
# nfcxx's cpp2_prepare loop (slice 6 of docs/notes/driver-state-design.md): for each .cpp2 input, the directory of its source
# (realpath of its dirname, as the -I that quoted includes need) and its translation, DIR/<name without .cpp2>.cpp, made by
# cppfront in the scratch directory (cd SCRATCH; cppfront -q -o COPY ABS). The bash keeps the array edits and the checks
# that cppfront is built. tests/nfcxx-cpp2-prepare/run.sh checks the port against the bash with a stub cppfront.
#
#   ruby scripts/nfcxx-cpp2.rb --cpp2-dir=OBJ     prints the directory of the translations of a -c compile of OBJ (cpp2_prepare)
#   ruby scripts/nfcxx-cpp2.rb --prepare < RECORDS
#       RECORDS are driver-state groups: root, dir, scratch, cppfront (the program) and inputs (one value per .cpp2 input).
#       The reply is the groups sdirs and copies (one value per input), then z. A failing step ends with its status and
#       message: realpath's for a missing source directory (status 1), cppfront's status otherwise.

require "digest"
require "fileutils"
require "stringio"
require "tmpdir"
require_relative "driver-state"
require_relative "nfcxx-cu-apply"

module NfcxxCpp2
  module_function

  # a step that failed: its message (empty when the step printed its own) and status
  class Failed < StandardError
    attr_reader :status

    def initialize(message, status)
      super(message)
      @status = status
    end
  end

  # cpp2_prepare's directory of the translations of a -c compile of OBJ: the per-user cache, keyed by the SHA-1 of realpath -m OBJ
  # (as the bash had it with realpath -m and sha1sum; Ruby does both on every platform, macOS included)
  def cpp2_dir(obj, env = ENV)
    key = Digest::SHA1.hexdigest("#{DriverState.realpath_m(obj)}\n")[0, 16]
    cache = nonempty(env["NFCXX_CU_CACHE"]) ||
            "#{nonempty(env["XDG_CACHE_HOME"]) || "#{nonempty(env["HOME"]) || "/tmp"}/.cache"}/nfcxx"
    "#{cache}/cpp2/#{key}"
  end

  def nonempty(v) = (v.nil? || v.empty?) ? nil : v

  # cpp2_prepare, the whole step (the bash's checks, directory, scratch directory, translations and array edits): the statements
  # the driver evals (nfcxx-cu-apply.rb's plan of the reply). OPTS: root, cppfront_src, cudatmp (the driver's temporary
  # directory, which the driver removes on exit), compile_only, out, outset, inputs, srcs, files, cflags (the arrays joined by
  # ASCII 31). A failed check or step ends with its message and status.
  def run(opts, env = ENV)
    root = opts.fetch("root", "")
    cppfront = "#{root}/build/cppfront"
    cppfront_src = opts.fetch("cppfront_src", "")
    inputs = opts.fetch("inputs", "").split("\x1f", -1).reject(&:empty?)
    raise Failed.new("nfcxx: cppfront is not built; run scripts/setup-cppfront.sh (docs/notes/cpp2.md)", 2) unless File.executable?(cppfront)
    unless File.file?(File.join(cppfront_src, "include", "cpp2util.h"))
      raise Failed.new("nfcxx: no cpp2util.h under #{cppfront_src}; run scripts/setup-cppfront.sh", 2)
    end
    cudatmp = opts.fetch("cudatmp", "")
    dir = cudatmp
    if opts.fetch("compile_only", "0") == "1"
      obj = opts.fetch("out", "")
      obj = "#{File.basename(inputs[0].to_s, ".cpp2")}.o" if opts.fetch("outset", "0") != "1"
      dir = cpp2_dir(obj, env)
      FileUtils.mkdir_p(dir)
    end
    scratch = Dir.mktmpdir("tmp.", cudatmp)
    sdirs, copies = prepare(dir: dir, scratch: scratch, cppfront: cppfront, inputs: inputs)
    reply = StringIO.new
    DriverState.write_groups(reply, [["sdirs", sdirs], ["copies", copies]])
    DriverState.write_end(reply)
    NfcxxCuApply.plan({
      "kind" => "cpp2", "cppfront" => cppfront_src, "inputs" => opts.fetch("inputs", ""),
      "srcs" => opts.fetch("srcs", ""), "files" => opts.fetch("files", ""), "cflags" => opts.fetch("cflags", ""),
    }, reply.string)
  end

  # [sdirs, copies] for INPUTS; each translation is made in SCRATCH (cppfront's -o is relative to it, as the bash has it)
  def prepare(dir:, scratch:, cppfront:, inputs:)
    sdirs = []
    copies = []
    inputs.each do |src|
      begin
        sdirs << DriverState.gnu_realpath(File.dirname(src))
      rescue SystemCallError
        raise Failed.new("realpath: #{File.dirname(src)}: No such file or directory", 1)
      end
      copy = File.join(dir, "#{File.basename(src, ".cpp2")}.cpp")
      copies << copy
      begin
        abs = DriverState.gnu_realpath(src)
      rescue SystemCallError
        raise Failed.new("realpath: #{src}: No such file or directory", 1)
      end
      ok = Dir.chdir(scratch) { system(cppfront, "-q", "-o", copy, abs) }
      raise Failed.new("", $?.exitstatus || 1) unless ok
    end
    [sdirs, copies]
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.size == 1 && ARGV[0].start_with?("--cpp2-dir=")
    puts NfcxxCpp2.cpp2_dir(ARGV[0].delete_prefix("--cpp2-dir="))
    exit 0
  end
  if ARGV.first == "run"
    begin
      puts NfcxxCpp2.run(ARGV.drop(1).to_h { |kv| kv.split("=", 2) })
    rescue NfcxxCpp2::Failed => e
      $stderr.puts e.message unless e.message.empty?
      exit e.status
    end
    exit 0
  end
  abort "nfcxx-cpp2: --prepare (records on standard input) or --cpp2-dir=OBJ or run KEY=VALUE..." unless ARGV == ["--prepare"]
  begin
    groups = DriverState.read_groups($stdin.binmode.read)
    sdirs, copies = NfcxxCpp2.prepare(dir: DriverState.scalar(groups, "dir"), scratch: DriverState.scalar(groups, "scratch"),
                                      cppfront: DriverState.scalar(groups, "cppfront"), inputs: groups.fetch("inputs", []))
  rescue NfcxxCpp2::Failed => e
    $stderr.puts e.message unless e.message.empty?
    exit e.status
  rescue ArgumentError => e
    $stderr.puts "nfcxx-cpp2: #{e.message}"
    exit 2
  end
  $stdout.binmode
  DriverState.write_groups($stdout, [["sdirs", sdirs], ["copies", copies]])
  DriverState.write_end($stdout)
end
