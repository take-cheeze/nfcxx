#!/usr/bin/env ruby
# The second pass's decision (restructure step 2 / B7 of docs/notes/driver-body-port.md), ported from the bash loop in nfcxx: the
# second pass runs when a kernel the device side left unresolved appears in the host symbols as NAME< (after the
# _INTERNAL_..:: scopes are removed). The driver keeps nm and the re-run; this decides.
#
#   ruby scripts/nfcxx-second-pass.rb found HOSTSYMS UNRESOLVED
#       prints 1 when some non-empty line of UNRESOLVED is NAME with a line of HOSTSYMS matching (^|[ :])NAME<, else 0.
#       Missing files count as empty. Checked against the bash loop by tests/driver-second-pass/run.sh.

module NfcxxSecondPass
  module_function

  def found?(hostsyms, unresolved)
    syms = File.file?(hostsyms) ? File.read(hostsyms) : ""
    names = File.file?(unresolved) ? File.read(unresolved).each_line.map(&:chomp) : []
    names.any? do |k|
      !k.empty? && syms.each_line.any? { |line| line.match?(/(^|[ :])#{Regexp.escape(k)}</) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, hostsyms, unresolved = ARGV
  abort "nfcxx-second-pass: found HOSTSYMS UNRESOLVED (got #{cmd.inspect})" unless cmd == "found" && unresolved
  puts(NfcxxSecondPass.found?(hostsyms, unresolved) ? 1 : 0)
end
