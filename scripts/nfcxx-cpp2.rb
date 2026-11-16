#!/usr/bin/env ruby
# nfcxx's cpp2_prepare loop (slice 6 of docs/notes/driver-state-design.md): for each .cpp2 input, the directory of its source
# (realpath of its dirname, as the -I that quoted includes need) and its translation, DIR/<name without .cpp2>.cpp, made by
# cppfront in the scratch directory (cd SCRATCH; cppfront -q -o COPY ABS). The bash keeps the array edits and the checks
# that cppfront is built. tests/nfcxx-cpp2-prepare/run.sh checks the port against the bash with a stub cppfront.
#
#   ruby scripts/nfcxx-cpp2.rb --prepare < RECORDS
#       RECORDS are driver-state groups: root, dir, scratch, cppfront (the program) and inputs (one value per .cpp2 input).
#       The reply is the groups sdirs and copies (one value per input), then z. A failing step ends with its status and
#       message: realpath's for a missing source directory (status 1), cppfront's status otherwise.

require_relative "driver-state"

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
  abort "nfcxx-cpp2: --prepare (records on standard input)" unless ARGV == ["--prepare"]
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
