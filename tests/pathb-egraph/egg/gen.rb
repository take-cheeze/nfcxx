# Writes K random straight-line integer functions of N operations, as SSA (for scripts/pathb-egraph.rb) and as a program
# file (for the egg benchmark). Operands are indices into a value vector: 0..3 parameters, 4..8 constants, then each op.
K, N, seed, out = ARGV[0].to_i, ARGV[1].to_i, ARGV[2].to_i, ARGV[3]
rng = Random.new(seed)
CONSTS = [0, 1, 2, -1, 3]
OPS = %w[+ * -]
ssa = +"(ir-module \"bench.cpp\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))\n"
prog = +""
K.times do |f|
  vals = 4 + CONSTS.size
  lines = []
  N.times do
    pick = ->{ r = rng.rand; r < 0.5 ? rng.rand(vals - [vals - 12, 0].max) + [vals - 12, 0].max : rng.rand(vals) }
    a = pick.call; b = pick.call
    op = OPS[rng.rand(3)]
    lines << [op, a, b]
    vals += 1
  end
  last = vals - 1
  name = "f#{f}"
  ssa << "(ssa-function \"#{name}\"\n  (ret int)\n  (params (param %0 \"a\" int) (param %1 \"b\" int) (param %2 \"c\" int) (param %3 \"d\" int))\n  (bb 0\n"
  # SSA register numbering: index i (>= 4) is %i; constants are (const int v)
  ref = ->(i) { i < 4 ? "%#{i}" : i < 4 + CONSTS.size ? "(const int #{CONSTS[i - 4]})" : "%#{i}" }
  lines.each_with_index do |(op, a, b), k|
    idx = 4 + CONSTS.size + k
    name_op = { "+" => "wadd", "*" => "wmul", "-" => "wsub" }[op]
    ssa << "    (let %#{idx} int (#{name_op} int #{ref.call(a)} #{ref.call(b)}))\n"
  end
  ssa << "    (ret %#{last})))\n"
  prog << "#{f} #{N}\n" + lines.map { |op, a, b| "#{op} #{a} #{b}" }.join("\n") + "\n"
end
ssa << "\n" if false
File.write("#{out}.ssa", ssa + "")
File.write("#{out}.prog", prog)
puts "wrote #{out}.ssa and #{out}.prog"
