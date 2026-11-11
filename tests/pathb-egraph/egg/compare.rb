# Compares our e-graph pass with egg on the same programs: time of our pass alone, the size of its output (lets that
# compute an operation) against egg's extracted DAG (operations only), and whether each extracted program computes what
# the original computes, on the same random inputs.
#   ruby compare.rb PROGRAMS.ssa EGG_EXTRACTED.txt
$LOAD_PATH.unshift File.expand_path("../../../scripts", __dir__)
require "pathb-egraph"

ssa_file, egg_file = ARGV
forms = read_forms(File.read(ssa_file)).select { |f| head(f) == "ssa-function" }

# egg's extracted DAG per program: [nodes, root]; a node is [op, args] with op "num" (value), "sym" (name) or an operator
egg = {}
lines = File.readlines(egg_file, chomp: true)
until lines.empty?
  name, n = lines.shift.split
  nodes = Array.new(n.to_i) { lines.shift.split }
  egg[name] = nodes
end

def wrap32(x) = ((x & 0xffffffff) ^ 0x80000000) - 0x80000000

def eval_egg(nodes, inputs)
  vals = []
  nodes.each do |op, *args|
    vals << case op
            when "num" then wrap32(args[0].to_i)
            when "sym" then inputs["abcd".index(args[0])]
            when "+" then wrap32(vals[args[0].to_i] + vals[args[1].to_i])
            when "*" then wrap32(vals[args[0].to_i] * vals[args[1].to_i])
            when "-" then wrap32(vals[args[0].to_i] - vals[args[1].to_i])
            else raise "op #{op}"
            end
  end
  vals.last
end

rng = Random.new(12_345)
inputs_for = ->(k) { [[0, 0, 0, 0], [1, 2, 3, 4], [-1, -2, 3, 7]] + Array.new(k) { Array.new(4) { rng.rand(-20..60) } } }

ours_time = 0.0
ours_ops = 0
egg_ops = 0
egg_total = 0
checked = 0
mismatches = []
forms.each do |form|
  name = form[1].raw[1..-2]
  orig_efn = PathbEgraph.parse_fn(form)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, = PathbEgraph.optimize_fn(PathbEgraph.parse_fn(form))
  ours_time += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  # our output's operations: the lets whose right-hand side computes something (not a constant, not a copy)
  ops = out.blocks.values.sum { |b| b[:instrs].count { |i| head(i) == "let" && head(i[3]).is_a?(String) && !%w[const null].include?(head(i[3])) } }
  ours_ops += ops

  nodes = egg.fetch(name) { raise "no egg program #{name}" }
  egg_ops += nodes.count { |op, *| !%w[num sym].include?(op) }
  egg_total += nodes.size

  inputs_for.call(10).each do |args|
    want = PathbEgraph.run(orig_efn, args)
    got = PathbEgraph.run(out, args)
    egg_got = eval_egg(nodes, args)
    checked += 1
    mismatches << [name, args, want, got] unless want == got
    mismatches << [name, args, want, "egg #{egg_got}"] unless egg_got == want
  end
end

n = forms.size
puts "functions: #{n}"
puts format("ours: %.3f ms per function (the pass alone), %.1f operations per function in the output", 1000 * ours_time / n, ours_ops.to_f / n)
puts format("egg: %.1f operations per extracted DAG (%.1f nodes with leaves)", egg_ops.to_f / n, egg_total.to_f / n)
puts "checks: #{checked} input vectors"
puts mismatches.empty? ? "all equal" : "MISMATCHES: #{mismatches.size}"
mismatches.first(5).each { |m| p m }
