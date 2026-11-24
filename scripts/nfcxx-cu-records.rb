#!/usr/bin/env ruby
# The records the frozen body's cu_prepare writes for the .cu rewrite (docs/notes/driver-body-port.md, item 4), in Ruby.
# The body wrote them with state_put (k NAME, then v VALUE for each value, NUL-terminated) in this order: root, tmp, bash_pid,
# compile_only, out, outset, trace_unit, inputs, srcs, files, cflags, obfuscate, ir_opt (a key only when not set), promote_slots,
# unroll, struct_slots, cache_dir, cache_log, preinc, cuda, edg_launch. cuda is empty here: the body sets cuda_opts only from
# cu_prepare's own output. This planner gives the same records from the argument loop's state and the environment defaults.
#
#   ruby scripts/nfcxx-cu-records.rb ROOT TMP BASH_PID -- ARG...   prints the records on standard output
require_relative "nfcxx-loop"

module NfcxxCuRecords
  module_function

  def group(out, name, values = [])
    out << "k#{name}\0"
    values.each { |v| out << "v#{v}\0" }
  end

  # The records for the command ARG... (the loop's state with the environment's defaults, as the body's setup gives it).
  def plan(argv, env, root:, tmp:, bash_pid:)
    state = LoopState.new
    apply_option_environment(state, env)
    run_loop(argv, state, ld_on_path(argv))
    out = +""
    srcs = state.srcs
    trace_unit = srcs.empty? ? state.out : srcs[0]
    trace_unit = env["NFCXX_TRACE_UNIT"].to_s if trace_unit.to_s.empty?
    group(out, "root", [root])
    group(out, "tmp", [tmp])
    group(out, "bash_pid", [bash_pid])
    group(out, "compile_only", [state.compile_only.to_i == 1 ? "1" : "0"])
    group(out, "out", [state.out])
    group(out, "outset", [state.outset.to_s])
    group(out, "trace_unit", [trace_unit])
    group(out, "inputs", state.cu_inputs)
    group(out, "srcs", srcs)
    group(out, "files", state.files)
    group(out, "cflags", state.cflags)
    group(out, "obfuscate", [state.obfuscate.to_i == 1 ? "1" : "0"])
    group(out, "ir_opt", state.ir_opt_set.to_i == 1 ? [state.ir_opt] : [])
    group(out, "promote_slots", [state.promote_slots.to_s])
    group(out, "unroll", [state.unroll.to_s])
    group(out, "struct_slots", [state.struct_slots.to_s])
    group(out, "cache_dir", [state.cache_dir.to_s])
    group(out, "cache_log", [state.cache_log_file.to_s])
    group(out, "preinc", state.preinc)
    group(out, "cuda", [])
    group(out, "cpp2_inputs", state.cpp2_inputs)
    group(out, "edg_launch", [env["NFCXX_CUDA_EDG_LAUNCH"].to_s.empty? ? "1" : env["NFCXX_CUDA_EDG_LAUNCH"]])
    out
  end
end

if __FILE__ == $PROGRAM_NAME
  i = ARGV.index("--")
  abort "usage: nfcxx-cu-records.rb ROOT TMP BASH_PID -- ARG..." unless i == 3
  $stdout.binmode
  $stdout.write(NfcxxCuRecords.plan(ARGV[(i + 1)..], ENV, root: ARGV[0], tmp: ARGV[1], bash_pid: ARGV[2]))
end
