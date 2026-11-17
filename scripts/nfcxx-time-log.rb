#!/usr/bin/env ruby
# NFCXX_TIME_LOG (restructure step 3 of docs/notes/driver-body-port.md): the time log's file, as an absolute path, for the scripts
# that log to it. The path is the physical directory of the file's directory plus its basename (the bash abs_path); when that
# directory cannot be entered, the path is kept as given. Checked against the bash by tests/driver-time-log/run.sh.
#
#   ruby scripts/nfcxx-time-log.rb plan time_log=PATH
#       prints the export statement for the driver to eval, or nothing when there is no time log.

require "shellwords"

module NfcxxTimeLog
  module_function

  # abs_path, as the bash function: the physical directory and the basename, or the argument when the directory is not reachable
  def abs_path(arg)
    d = File.dirname(arg)
    b = File.basename(arg)
    return arg unless Dir.exist?(d) && File.executable?(d)
    File.join(File.realpath(d), b)
  end

  def plan(opts)
    log = opts.fetch("time_log", "")
    return "" if log.empty?
    "export NFCXX_TIME_LOG=#{Shellwords.escape(abs_path(log))}"
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-time-log: plan time_log=PATH (got #{cmd.inspect})" unless cmd == "plan"
  out = NfcxxTimeLog.plan(rest.to_h { |kv| kv.split("=", 2) })
  puts out unless out.empty?
end
