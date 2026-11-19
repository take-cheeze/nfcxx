#!/usr/bin/env ruby
# The include directories of nfcxx's --emit-c front end run (the block that prints the generated C): the host's system
# directories (or the freestanding library), then EDG's own include, and the user's -I directories in front of them, each made
# absolute (abs_path: its directory's physical path, then its basename, as the bash had it). The bash built this array with
# abs_path per -I; tests/driver-emit-c/run.sh checks the port against that bash verbatim.
#
#   ruby scripts/nfcxx-emit-c.rb inc BASE ROOT FREESTANDING -- SYS_INC... -- FILES...
#       prints the array's elements, each followed by a NUL byte; FREESTANDING is 1 or 0.

require_relative "trace"

module NfcxxEmitC
  module_function

  # a front end run that failed: its status (cpfe's own messages are on the standard error)
  class Failed < StandardError
    attr_reader :status

    def initialize(status)
      super("")
      @status = status
    end
  end

  # the --emit-c front end run (the bash block that printed the generated C): cpfe runs in the EDG base directory with the
  # include list, the -D and option words, and writes TMP/out.c. Its span (trace_start, trace_end) goes to the pending file
  # when the driver batches its spans (NFCXX_TRACE_PENDING), else is recorded directly; the pid is the driver's (BASH_PID).
  # A failing front end ends the driver with its status, and records no span (as set -e did).
  def run(opts, env = ENV)
    words = ->(k) { opts.fetch(k, "").split("\x1f", -1).reject(&:empty?) }
    base = opts.fetch("base", "")
    inc = inc(base: base, root: opts.fetch("root", ""), freestanding: opts.fetch("freestanding", "0"),
              sys_inc: words["sys_inc"], files: words["files"])
    cpfe = File.join(opts.fetch("edg", ""), "cpfe")
    args = [cpfe, *words["posix_def"], "-D__CHAR_BIT__=8", opts.fetch("std", ""), "--#{opts.fetch("dialect", "")}",
            *words["eh_tls"], *words["gnu_opts"], *words["diag_opts"], *inc,
            "--gen_c_file_name=#{opts.fetch("tmp", "")}/out.c", opts.fetch("file", "")]
    t = NfccxxTrace.start(env)
    ok = Dir.chdir(base) { system(*args) }
    raise Failed.new($?.exitstatus || 127) unless ok

    name = "cpfe --emit-c (front end)"
    unit = opts.fetch("unit", "")
    pid = opts.fetch("bash_pid", Process.pid.to_s).to_i
    return unless NfccxxTrace.enabled?(env)

    pending = env["NFCXX_TRACE_PENDING"].to_s
    if pending.empty?
      NfccxxTrace.span(t, name, "frontend", unit: unit, pid: pid, env: env)
    else
      # trace_end's batched form: start, stop, name, category, pid and unit, each NUL-terminated (scripts/trace.rb flush)
      fields = [t, NfccxxTrace.now_us, name, "frontend", pid, unit]
      File.open(pending, "a") { |f| f.write(fields.map { |x| "#{x}\0" }.join) }
    end
  end

  # abs_path (nfcxx): the directory's physical path, then the basename; a directory that does not exist gives the argument as is
  def abs_path(path)
    dir = File.dirname(path)
    base = File.basename(path)
    return path unless File.directory?(dir)

    "#{File.realpath(dir)}/#{base}"
  rescue SystemCallError
    path
  end

  def inc(base:, root:, freestanding:, sys_inc:, files:)
    inc = freestanding == "1" ? ["-I#{root}/lib"] : sys_inc + ["--sys_include=#{base}/include"]
    files.each do |x|
      next unless x.start_with?("-I") && x.length >= 3   # bash: case $x in -I?*)

      inc.unshift("-I#{abs_path(x.delete_prefix("-I"))}")
    end
    inc
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  if cmd == "run"
    begin
      NfcxxEmitC.run(rest.to_h { |kv| kv.split("=", 2) })
    rescue NfcxxEmitC::Failed => e
      exit e.status
    end
    exit 0
  end
  abort "nfcxx-emit-c: inc BASE ROOT FREESTANDING -- SYS_INC... -- FILES... | run KEY=VALUE... (got #{cmd.inspect})" unless cmd == "inc"
  base, root, freestanding, *tail = rest
  first = tail.index("--")
  second = first && (rel = tail[(first + 1)..].index("--")) && first + 1 + rel
  abort "nfcxx-emit-c: inc needs two -- separators" unless first && second
  sys_inc = tail[(first + 1)...second]
  files = tail[(second + 1)..] || []
  NfcxxEmitC.inc(base: base, root: root, freestanding: freestanding, sys_inc: sys_inc, files: files)
    .each { |x| $stdout.write(x, "\0") }
end
