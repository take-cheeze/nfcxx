# Driver for the arithmetic differential (diff-arith.sh). Appended after the reference functions copied from
# scripts/pathb-ptx-emit.rb (class Fn among them); it runs each case (arith DEST PRESETS INSTR) through Fn#rval and
# prints the emitted lines joined by " ~ ", the same text the C++ --eval-arith prints. Keep the head list in step with
# FnCtx::arith in lower_arith.cpp.

class BadCase < StandardError; end

# The harness's view of a Fn: the register map it is given, and the lines it emitted.
class Fn
  def set_regs(r)
    @regs = r
  end

  def lines_out
    @lines
  end
end

# The instruction heads of the rval branches this port covers (wadd..cf2i and the comparisons).
ARITH_HEADS = %w[
  wadd wsub wmul wneg cdiv crem cshl cshr and or xor not fadd fsub fmul fdiv fneg iconv fconv i2f u2f cf2i
  lt le gt ge eq ne lt.s le.s gt.s ge.s eq.s ne.s lt.u le.u gt.u ge.u eq.u ne.u lt.f le.f gt.f ge.f eq.f ne.f
]

def ev_arith(c)
  raise BadCase, "case" unless c.is_a?(Array) && c.length == 4 && c[0] == "arith"
  presets = c[2]
  raise BadCase, "presets" unless presets.is_a?(Array)
  fn = Fn.new(["fn", "t"], 0)
  regs = {}
  presets.each do |p|
    raise BadCase, "preset" unless p.is_a?(Array) && p.length == 3 && p[0].is_a?(String) && p[1].is_a?(String)
    regs[p[0]] = [p[1], parse_type(p[2])]
  end
  fn.set_regs(regs)
  dty = parse_type(c[1])
  x = c[3]
  raise BadCase, "instr" unless x.is_a?(Array) && !x.empty? && x[0].is_a?(String)
  return "NOTARITH" unless ARITH_HEADS.include?(x[0])
  fn.rval(x, "%d", dty)
  fn.lines_out.map { |l| l.to_s }.join(" ~ ")
end

def run_arith(src)
  forms = nil
  begin
    forms = parse_forms_chunked(src)
  rescue BadIR
    $stdout.write("BADIR-PARSE\n")
    return 1
  end
  forms.each do |f|
    line = nil
    begin
      line = ev_arith(f)
    rescue Refused
      line = "REFUSED"
    rescue BadIR
      line = "BADIR"
    rescue BadCase
      line = "BADCASE"
    end
    $stdout.write(line + "\n")
  end
  0
end

case_src = File.open(ARGV[0], "rb") { |f| f.read }
exit(run_arith(case_src))
