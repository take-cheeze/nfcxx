#!/usr/bin/env ruby
# nfcxx, the CRuby driver: the entry point that replaces the bash driver (nfcxx) one step at a time. The Ruby port
# (scripts/nfcxx-loop.rb) first decides whether it has a plan for the arguments: the pre-loop re-runs it models
# (-fsyntax-only, --bundle-*) print RUN and EXEC lines, and the runner (scripts/nfcxx-run.rb) runs them. Anything else (the
# port's loop state, its refusals, the steps it does not port) goes to the bash driver with the same arguments, so the
# behaviour is the bash's for every argument list the port does not plan.
#
#   ruby scripts/nfcxx.rb ARG...   the driver; NFCXX_DRIVER_TRACE=1 prints "nfcxx: driver: plan" or "nfcxx: driver: bash" to stderr
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
LOOP = File.join(ROOT, "scripts", "nfcxx-loop.rb")
RUNNER = File.join(ROOT, "scripts", "nfcxx-run.rb")
PLAN_KINDS = %w[RUN EXEC CP CAT LN].freeze

# true when the port plans these arguments: its output is a plan (its first line is a plan command) and it ran to its end
def planned?(args)
  out = IO.popen([RbConfig.ruby, LOOP, *args], err: File::NULL, &:read)
  return false unless $?.success?

  first = out.lines.first
  !first.nil? && PLAN_KINDS.include?(first.split(" ", 2).first)
end

def trace(kind)
  $stderr.write("nfcxx: driver: #{kind}\n") if ENV["NFCXX_DRIVER_TRACE"] == "1"
end

if planned?(ARGV)
  trace("plan")
  exec(RbConfig.ruby, RUNNER, "--root=#{ROOT}", "--", *ARGV)
else
  trace("bash")
  exec("bash", File.join(ROOT, "nfcxx"), *ARGV)
end
