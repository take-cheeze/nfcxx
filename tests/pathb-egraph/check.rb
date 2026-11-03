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
    # The whole module's functions and globals: a call in one function reaches the others.
    module_forms = ssa_texts(f).flat_map { |t| read_forms(t) } + read_forms(File.read(f)).select { |g| head(g) == "global" }
    ssa_texts(f).each do |text|
      totals[:functions] += 1
      install_module(module_forms)
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
        totals[:loads_merged] += st[:loads_merged]
        totals[:stores_forwarded] += st[:stores_forwarded]
        totals[:stores_removed] += st[:stores_removed]
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
  puts "     memory: loads merged #{totals[:loads_merged]}, stores forwarded #{totals[:stores_forwarded]}, " \
       "dead stores removed #{totals[:stores_removed]}"
  failures.each { |m| puts "FAIL golden #{m}" }
  failures.empty?
end

# The interpreter of pathb-ssa.rb does not model a call or a volatile access. The cases that test memory use them, so
# this subclass models them for the cases only: `&"observe"` reads and writes nothing, `&"clobber"` writes 77 into the
# slot whose address its pointer argument is, and `load.v` and `store.v` act as `load` and `store`. Addresses and
# memory are the base interpreter's (slots are objects at addresses; see layout_slots).
class CaseMachine < PathbEgraph::CheckedMachine
  private

  def exec(s)
    case head(s)
    when "store.v" then super(["store", *s[1..]])
    when "eval" then call(s[1])
    else super
    end
  end

  def eval_rv(f)
    case head(f)
    when "load.v" then super(["load", *f[1..]])
    when "call" then call(f)
    else super
    end
  end

  def call(f)
    raise Unsupported, "call of #{sx(f[2])}" unless f[2].is_a?(Ref) && f[2].sigil == "&"

    case f[2].raw
    when '"observe"' then 0
    when '"clobber"'
      a = addr_of(f[3])
      key = slot_at(a) or raise Unsupported, "clobber of an address that is not a slot"
      store_cell(@slot_type[key], a, canon(77, @slot_type[key]))
      0
    else call_fn(f)
    end
  end
end

# Result of running fn on args: the value, "trap", or :unsupported when the interpreter does not model it.
def interpret(efn, args)
  fn = Fn.new(efn.name, efn.ret, efn.params, efn.header, [])
  CaseMachine.new(fn, args).run_ssa(efn.blocks).to_s
rescue Trap
  "trap"
rescue Unsupported => e
  warn "unsupported: #{e.message}" if ENV["CHECK_DEBUG"]
  :unsupported
end

# Number of nodes with each operator head in the statements and let right-hand sides of a function.
def count_heads(x, seen)
  return unless x.is_a?(Array)

  seen[head(x)] += 1 if head(x)
  x.each { |y| count_heads(y, seen) }
  seen
end

def check_case(f)
  main = ssa_texts(f).find { |t| t.start_with?('(ssa-function "main"') }
  raise Fail, "no converted main" unless main

  globals = read_forms(File.read(f)).select { |g| head(g) == "global" }
  install_module(ssa_texts(f).flat_map { |t| read_forms(t) } + globals)
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
  errors << "no let removed (the redundancy case must shrink)" if f.end_with?("pathb-egraph/cases/redundant.ir") &&
                                                                  after[0] >= before[0]
  # A `.lets` file holds the hand-derived number of lets after optimization.
  lets_file = f.sub(/\.ir\z/, ".lets")
  if File.exist?(lets_file)
    want_lets = Integer(File.read(lets_file).strip, 10)
    errors << "lets after optimization: want #{want_lets}, got #{after[0]}" unless after[0] == want_lets
  end
  # Hand-derived counts of the optimized `main`: "HEAD N" lines in FILE.counts (for example `load 2`).
  counts_file = f.sub(/\.ir\z/, ".counts")
  if File.exist?(counts_file)
    seen = Hash.new(0)
    opt.blocks.each_value { |blk| blk[:instrs].each { |i| count_heads(i, seen) } }
    File.readlines(counts_file).map(&:split).reject(&:empty?).each do |op, n|
      errors << "#{op}: expected #{n} in the optimized main, got #{seen[op]}" unless seen[op] == Integer(n, 10)
    end
  end
  status = errors.empty? ? "ok  " : "FAIL"
  puts "#{status} cases #{File.basename(f)}: lets #{before[0]} -> #{after[0]} (pure #{before[1]} -> #{after[1]}), " \
       "#{runs} interpreted runs equal, #{unsupported} unsupported"
  errors.each { |m| puts "     #{m}" }
  errors.empty?
end

def check_cases(files)
  files.map do |f|
    check_case(f)
  rescue Fail, Unsupported => e
    puts "FAIL cases #{File.basename(f)}: #{e.message}"
    false
  end.all?
end

if $PROGRAM_NAME == __FILE__
  mode, *files = ARGV
  abort "usage: check.rb goldens|cases FILE.ir..." unless %w[goldens cases].include?(mode) && !files.empty?

  ok = mode == "goldens" ? check_goldens(files) : check_cases(files)
  exit(ok ? 0 : 1)
end
