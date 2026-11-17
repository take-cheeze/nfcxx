#!/usr/bin/env ruby
# The environment of the eccp command (restructure step 3 of docs/notes/driver-body-port.md), ported from the bash loop in nfcxx that
# exports each eccp_envs element (NAME=VALUE, or a bare NAME) into the eccp subshell. The elements come joined by ASCII 31.
# Checked against the bash by tests/driver-eccp-env/run.sh.
#
#   ruby scripts/nfcxx-eccp-env.rb plan envs=ELEM<US>ELEM...
#       prints one export statement per element, for the driver to eval in the subshell.

require "shellwords"

module NfcxxEccpEnv
  module_function

  def plan(envs)
    envs.split("\x1f", -1).reject(&:empty?).map { |e| "export #{Shellwords.escape(e)}" }.join("\n")
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-eccp-env: plan envs=... (got #{cmd.inspect})" unless cmd == "plan"
  opts = rest.to_h { |kv| kv.split("=", 2) }
  out = NfcxxEccpEnv.plan(opts.fetch("envs", ""))
  puts out unless out.empty?
end
