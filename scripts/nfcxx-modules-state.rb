#!/usr/bin/env ruby
# The records the frozen body's modules_plan_input wrote with state_put for scripts/nfcxx-modules-plan.rb (its header lists the
# groups): root, out, moddir, std, emit_c, compile_only, cfiles, srcs, argv. Written here, from the arguments the body passes:
#
#   ruby scripts/nfcxx-modules-state.rb ROOT OUT MODDIR STD EMIT_C COMPILE_ONLY NCFILES CFILE... NSRCS SRC... -- ARG...
#
# The format is state_put's: k NAME, then v VALUE for each value (an empty array gives the key only; empty values are kept), NUL-terminated.
# srcs are the sources after the .cu and .cpp2 steps (the body's array at this point), so they are passed in, not planned here.
module NfcxxModulesState
  module_function

  def records(root:, out:, moddir:, std:, emit_c:, compile_only:, cfiles:, srcs:, argv:)
    groups = [["root", [root]], ["out", [out]], ["moddir", [moddir]], ["std", [std]], ["emit_c", [emit_c]],
              ["compile_only", [compile_only]], ["cfiles", cfiles], ["srcs", srcs], ["argv", argv]]
    groups.map { |name, values| "k#{name}\0" + values.map { |v| "v#{v}\0" }.join }.join
  end
end

if $PROGRAM_NAME == __FILE__
  a = ARGV.dup
  scalars = a.shift(6)
  n = Integer(a.shift)
  cfiles = a.shift(n)
  m = Integer(a.shift)
  srcs = a.shift(m)
  abort "nfcxx-modules-state: -- before the arguments" unless a.shift == "--"
  $stdout.binmode
  $stdout.write(NfcxxModulesState.records(root: scalars[0], out: scalars[1], moddir: scalars[2], std: scalars[3],
                                          emit_c: scalars[4], compile_only: scalars[5], cfiles: cfiles, srcs: srcs, argv: a))
end
