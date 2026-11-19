#!/usr/bin/env ruby
# nfcxx's trace unit (stage B3 of docs/notes/driver-body-port.md), ported from the bash in nfcxx: the unit of the time log's
# lines is the first source when there is one, else the output (trace_unit=${srcs[0]-$out}: a first source that is set, even
# empty, is used; an unset one falls back to the output). The plan also exports it as NFCXX_TRACE_UNIT (the back-end scripts it
# runs log under it too). Checked against the bash by tests/driver-trace-unit/run.sh.
#
#   ruby scripts/nfcxx-trace-unit.rb plan srcs0_set=0|1 srcs0=NAME out=NAME
#       prints trace_unit=NAME and export NFCXX_TRACE_UNIT=NAME for the driver to eval.

require "shellwords"

module NfcxxTraceUnit
  module_function

  def plan(opts)
    unit = opts.fetch("srcs0_set", "0") == "1" ? opts.fetch("srcs0", "") : opts.fetch("out", "")
    word = Shellwords.escape(unit)
    "trace_unit=#{word}\nexport NFCXX_TRACE_UNIT=#{word}"
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-trace-unit: plan KEY=VALUE... (got #{cmd.inspect})" unless cmd == "plan"
  puts NfcxxTraceUnit.plan(rest.to_h { |kv| kv.split("=", 2) })
end
