#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Checks of the Path B e-graph pass (docs/notes/pathb-egraph.md), run by tests/pathb-egraph/run.sh.
#
#   ruby tests/pathb-egraph/check.rb goldens FILE.ir...   every function is converted to SSA, optimized, and the
#                                                          optimized form is verified and printed/parsed/verified again
#   ruby tests/pathb-egraph/check.rb cases FILE.ir...     every file's `main` is optimized and verified; with a .args
#                                                          file it is also run in the interpreter, original against
#                                                          optimized, on the .args inputs (expected values checked)
#                                                          and on 50 random inputs; a .lets file gives the
#                                                          expected number of lets after optimization
#
# Exit status 1 on any failure.

require 'timeout'
require_relative '../../scripts/pathb-egraph'

# Converted SSA text of every function of an IR file that pathb-ssa.rb converts (a function the converter cannot
# model is skipped). Raises Fail when the converter's own verification fails.
def ssa_texts(path)
  read_forms(File.read(path)).filter_map do |form|
    next unless head(form) == "function"

    begin
      conv = Converter.new(fn_of(form)).run
    rescue Unsupported
      next
    end
    conv.render
  end
end

# Number of condbr and switch terminators in a function.
def branch_count(efn) = efn.blocks.values.count { |b| %w[condbr switch].include?(b[:term][0]) }

# Number of condbr and switch terminators whose operand is still a constant. The pass folds all of them, so none
# may remain in the optimized form.
def constant_branches(efn)
  efn.blocks.values.count do |b|
    %w[condbr switch].include?(b[:term][0]) && %w[const null].include?(b[:term][1][0])
  end
end

# Runs a golden function in the interpreter (when it models it: integer code without calls or pointers) on 5 random
# inputs, original against optimized. A function the interpreter cannot run, or that runs too long, is skipped.
def diff_random(orig, opt, totals, failures, text)
  arity = orig.params[1..].size
  rng = Random.new(7)
  probe = Array.new(arity, 0)
  begin
    Timeout.timeout(2) { PathbEgraph.run(orig, probe) }
  rescue Unsupported, Timeout::Error
    totals[:interp_unsupported] += 1
    return
  end
  totals[:interp_functions] += 1
  5.times do
    args = Array.new(arity) { rng.rand(-20..60) }
    a = interpret_timed(orig, args)
    b = interpret_timed(opt, args)
    totals[:interp_runs] += 1
    failures << "#{text[/\(ssa-function ("[^"]*")/, 1]} #{args}: original #{a}, optimized #{b}" unless a == b
  end
end

def interpret_timed(efn, args)
  Timeout.timeout(2) { PathbEgraph.run(efn, args).to_s }
rescue Unsupported, Timeout::Error => e
  e.class.name
end

def check_goldens(files)
  totals = Hash.new(0)
  failures = []
  files.each do |f|
    ssa_texts(f).each do |text|
      totals[:functions] += 1
      orig = PathbEgraph.parse_fn(read_forms(text).first)
      begin
        out, st = PathbEgraph.optimize_fn(PathbEgraph.parse_fn(read_forms(text).first))
        back = PathbEgraph.parse_fn(read_forms(PathbEgraph.render(out)).first)
        PathbEgraph.verify(back)
        totals[:lets_before] += st[:lets_before]
        totals[:lets_after] += st[:lets_after]
        totals[:pure_before] += st[:pure_before]
        totals[:pure_after] += st[:pure_after]
        totals[:enodes_added] += st[:enodes_added]
        totals[:enodes_input] += st[:enodes_input]
        totals[:iterations] += st[:iterations]
        totals[:saturated] += st[:saturated]
        totals[:cut_iters] += st[:cut_iters]
        totals[:cut_nodes] += st[:cut_nodes]
        %i[condbr_folded switch_folded blocks_removed phis_replaced phis_removed].each { |k| totals[k] += st[k] }
        failures << "#{File.basename(f)}: constant branch left" if constant_branches(out).positive?
        totals[:branches_before] += branch_count(orig)
        totals[:branches_after] += branch_count(out)
        totals[:cse] += st[:cse]
        # The cut-short output (a small budget) is verified too.
        tight, = PathbEgraph.optimize_fn(PathbEgraph.parse_fn(read_forms(text).first), iters: 2, nodes: 20)
        PathbEgraph.verify(tight)
        # Where the interpreter runs the function (integer code), the optimized form returns the same values.
        diff_random(orig, out, totals, failures, text)
      rescue Fail, Unsupported => e
        failures << "#{File.basename(f)} #{text[/\(ssa-function ("[^"]*")/, 1]}: #{e.message}"
      end
    end
  end
  puts "#{failures.empty? ? 'ok  ' : 'FAIL'} goldens: #{totals[:functions]} functions from #{files.size} files verified after optimization, " \
       "lets #{totals[:lets_before]} -> #{totals[:lets_after]} (pure #{totals[:pure_before]} -> #{totals[:pure_after]})"
  puts "     interpreter: #{totals[:interp_functions]} golden functions run (#{totals[:interp_runs]} random " \
       "runs, original against optimized), #{totals[:interp_unsupported]} not modelled"
  puts "     budget: e-nodes #{totals[:enodes_input]} input + #{totals[:enodes_added]} added, " \
       "#{totals[:iterations]} iterations; blocks saturated #{totals[:saturated]}, cut by iterations " \
       "#{totals[:cut_iters]}, cut by nodes #{totals[:cut_nodes]}"
  puts "     control: branches (condbr, switch) #{totals[:branches_before]} -> #{totals[:branches_after]}, folded " \
       "#{totals[:condbr_folded]} condbr and #{totals[:switch_folded]} switch, removed " \
       "#{totals[:blocks_removed]} blocks, #{totals[:phis_replaced]} phis replaced, #{totals[:phis_removed]} dead phis"
  puts "     common subexpressions across blocks merged: #{totals[:cse]}"
  failures.each { |m| puts "FAIL golden #{m}" }
  failures.empty?
end

# Result of running fn on args: the value, "trap", or :unsupported when the interpreter does not model it.
def interpret(efn, args)
  PathbEgraph.run(efn, args).to_s
rescue Unsupported
  :unsupported
end

def check_case(f)
  main = ssa_texts(f).find { |t| t.start_with?('(ssa-function "main"') }
  raise Fail, "no converted main" unless main

  orig = PathbEgraph.parse_fn(read_forms(main).first)
  opt, = PathbEgraph.optimize_fn(orig)
  # The same function under a tight budget (cut short by iterations and by nodes): still correct.
  tight, = PathbEgraph.optimize_fn(orig, iters: 1, nodes: 4)
  before = PathbEgraph.let_counts(orig)
  after = PathbEgraph.let_counts(opt)
  errors = []
  args_file = f.sub(/\.ir\z/, ".args")
  runs = 0
  unsupported = 0
  if File.exist?(args_file)
    rng = Random.new(20_261_102)
    arity = orig.params[1..].size
    cases = File.readlines(args_file).map(&:strip).reject(&:empty?).map do |line|
      inp, want = line.split("=>").map(&:strip)
      [inp.split.map { |s| Integer(s, 10) }, want]
    end
    cases += Array.new(50) { [Array.new(arity) { rng.rand(-20..60) }, nil] }
    cases.each do |args, want|
      a = interpret(orig, args)
      b = interpret(opt, args)
      c = interpret(tight, args)
      if a == :unsupported || b == :unsupported || c == :unsupported
        unsupported += 1
        errors << "#{args} is unsupported in one form only" unless a == b && a == c
        next
      end
      runs += 1
      errors << "#{args}: original #{a}, optimized #{b}" unless a == b
      errors << "#{args}: original #{a}, tight budget #{c}" unless a == c
      errors << "#{args}: want #{want}, got #{a}" if want && a != want
    end
  end
  errors << "lets grew from #{before[0]} to #{after[0]}" if after[0] > before[0]
  errors << "a constant branch is left" if constant_branches(opt).positive?
  errors << "no let removed (the redundancy case must shrink)" if File.basename(f) == "redundant.ir" && after[0] >= before[0]
  # A `.lets` file holds the hand-derived number of lets after optimization.
  lets_file = f.sub(/\.ir\z/, ".lets")
  if File.exist?(lets_file)
    want_lets = Integer(File.read(lets_file).strip, 10)
    errors << "lets after optimization: want #{want_lets}, got #{after[0]}" unless after[0] == want_lets
  end
  status = errors.empty? ? "ok  " : "FAIL"
  puts "#{status} cases #{File.basename(f)}: lets #{before[0]} -> #{after[0]} (pure #{before[1]} -> #{after[1]}), " \
       "#{runs} interpreted runs equal, #{unsupported} unsupported"
  errors.each { |m| puts "     #{m}" }
  errors.empty?
end

def check_cases(files)
  files.map { |f| check_case(f) }.all?
end

mode, *files = ARGV
abort "usage: check.rb goldens|cases FILE.ir..." unless %w[goldens cases].include?(mode) && !files.empty?

ok = mode == "goldens" ? check_goldens(files) : check_cases(files)
exit(ok ? 0 : 1)
