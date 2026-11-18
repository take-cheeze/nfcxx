#!/usr/bin/env ruby
# nfcxx's argument refusals (docs/notes/driver-body-port.md), ported from the bash in nfcxx that follows the argument
# loop and the -E branch: a source on stdin needs -E, the -x language is C++ (or none), and -MD/-MMD need -c. The first refusal wins,
# in that order, as in the bash. Each refusal is the bash message, byte for byte, on standard error with status 2. A check that
# passes prints nothing. The EDG, dialect and C++ module checks stay in nfcxx: the EDG check is a file test that comes between these
# and the dialect check, so moving these alone would change which refusal wins.
# Checked against the bash by tests/driver-argchecks/run.sh.
#
#   ruby scripts/nfcxx-argchecks.rb check stdin_src=0|1 xlang=LANG depmode=FLAG compile_only=0|1

module NfcxxArgChecks
  module_function

  # Returns the refusal message for the state, or nil when every check passes.
  def refusal(state)
    if state.fetch("stdin_src") == "1"
      return "nfcxx: a source on stdin is supported only with -E"
    end
    case state.fetch("xlang")
    when "", "c++", "none"
    else
      return "nfcxx: -x #{state.fetch("xlang")}: only C++ sources (use nfcc for C)"
    end
    depmode = state.fetch("depmode")
    if depmode != "" && state.fetch("compile_only") == "0"
      return "nfcxx: #{depmode} needs -c (dependency files are written for a compile only)"
    end
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-argchecks: check KEY=VALUE... (got #{cmd.inspect})" unless cmd == "check"
  state = rest.to_h { |kv| kv.split("=", 2) }
  %w[stdin_src xlang depmode compile_only].each do |k|
    abort "nfcxx-argchecks: missing #{k}=" unless state.key?(k)
  end
  msg = NfcxxArgChecks.refusal(state)
  if msg
    warn msg
    exit 2
  end
end
