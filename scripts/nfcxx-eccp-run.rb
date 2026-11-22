#!/usr/bin/env ruby
# The eccp call of the driver body (docs/notes/driver-body-port.md, item 7): runs the planned EDG command and records its span.
#
#   ruby scripts/nfcxx-eccp-run.rb [--cd=DIR] [--env=NAME=VALUE]... -- ARG...
#
#   --cd=DIR         the directory the command runs in (the plan's eccp_cd; absent when the call stays in the user's directory)
#   --env=NAME=VALUE a variable the command gets (the plan's eccp_envs, exported for the command only)
#   ARG...           the command as the plan gives it (the first is the EDG driver's path)
#
# The body runs this under set -euo pipefail, so its status ends the body as the bash subshell's did: a failed command
# ends the run with its status, writes no span (the span is recorded only when the command succeeds, as the bash did), and
# the body's EXIT trap and the cache store are not reached. The span is the bash's trace_end for "eccp (front end, C compile,
# link)" in category eccp: appended to the pending file (NFCXX_TRACE_PENDING) when there is one, or written by trace.rb
# otherwise, with the same clock (microseconds since the epoch) and the same record fields.

require "rbconfig"

TRACE_RB = File.join(__dir__, "trace.rb")
SPAN_NAME = "eccp (front end, C compile, link)"
SPAN_CATEGORY = "eccp"

def trace_on?
  !ENV["NFCXX_TRACE"].to_s.empty? || !ENV["NFCXX_TIME_LOG"].to_s.empty?
end

def trace_now
  Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
end

def ruby_bin
  ENV["RUBY"] || RbConfig.ruby
end

# trace_end: the span from start to now, with the fields the bash writes (its trace_end)
def trace_span(start)
  stop = trace_now
  unit = ENV["NFCXX_TRACE_UNIT"].to_s
  pending = ENV["NFCXX_TRACE_PENDING"].to_s
  if !pending.empty?
    File.open(pending, "ab") do |f|
      f.write([start.to_s, stop.to_s, SPAN_NAME, SPAN_CATEGORY, Process.pid.to_s, unit].map { |s| s + "\0" }.join)
    end
  else
    system(ruby_bin, TRACE_RB, "span", start.to_s, SPAN_NAME, SPAN_CATEGORY, Process.pid.to_s, unit)
  end
end

cd = nil
envs = {}
argv = nil
rest = ARGV.dup
while (arg = rest.shift)
  case arg
  when "--" then argv = rest; break
  when /\A--cd=(.*)\z/m then cd = Regexp.last_match(1)
  when /\A--env=(.*)\z/m
    name, eq, value = Regexp.last_match(1).partition("=")
    envs[name] = value if eq == "="
  else
    warn "nfcxx: scripts/nfcxx-eccp-run.rb: unknown option #{arg}"
    exit 2
  end
end
abort "nfcxx: scripts/nfcxx-eccp-run.rb: no command" if argv.nil? || argv.empty?

start = trace_on? ? trace_now : 0
opts = {}
if cd && !cd.empty?
  unless Dir.exist?(cd)
    warn "cd: #{cd}: No such file or directory"
    exit 1
  end
  opts[:chdir] = cd
end
begin
  pid = Process.spawn(envs, [argv[0], argv[0]], *argv[1..], **opts)
rescue Errno::ENOENT
  warn "#{argv[0]}: No such file or directory"
  exit 127
rescue Errno::EACCES
  warn "#{argv[0]}: Permission denied"
  exit 126
end
Process.wait(pid)
status = $?.exitstatus || 128 + $?.termsig
exit status unless status == 0
trace_span(start) if trace_on?
exit 0
