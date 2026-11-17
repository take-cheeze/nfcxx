#!/usr/bin/env ruby
# The shared-link options (restructure step 3 of docs/notes/driver-body-port.md), ported from the bash line in nfcxx: a shared
# object (-shared) replaces eccp's link options with -shared, through EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS and the driver's ldopts.
# Checked against the bash by tests/driver-shared-link/run.sh.
#
#   ruby scripts/nfcxx-shared-link.rb plan shared=0|1
#       prints the statements for the driver to eval: the export and ldopts=(-shared) when shared is 1; nothing otherwise.

module NfcxxSharedLink
  module_function

  def plan(opts)
    opts.fetch("shared", "0") == "1" ? ["export EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS=-shared", "ldopts=(-shared)"].join("\n") : ""
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *rest = ARGV
  abort "nfcxx-shared-link: plan shared=0|1 (got #{cmd.inspect})" unless cmd == "plan"
  out = NfcxxSharedLink.plan(rest.to_h { |kv| kv.split("=", 2) })
  puts out unless out.empty?
end
