# Case generator for the phase-2 differential (diff-lower-types.sh). Appended after the reference functions. Reads the IR
# files named in ARGV[1..] and prints one case per distinct type form, constant (const TYPE VALUE) and global initializer
# (global NAME TYPE SIZE ... (init ...)) found in them, each case a top-level form the drivers read back.

def walk_forms(x, &blk)
  return unless x.is_a?(Array)
  blk.call(x)
  x.each { |y| walk_forms(y, &blk) }
end

LIMIT_TYPES = 400
LIMIT_CONSTS = 1500
LIMIT_FLOATS = 3000
LIMIT_GLOBALS = 800

types = {}
consts = {}
globals = {}

ARGV.each do |path|
  src = File.open(path, "rb") { |f| f.read }
  forms = parse_forms_chunked(src)
  forms.each do |top|
    walk_forms(top) do |x|
      h = head_of(x)
      if h == "const" || h == "volatile" || h == "ptr" || h == "array" || h == "struct"
        types[form_text(x)] = x
      end
      if h == "scalar" && x.length >= 3 && x[2].is_a?(String)
        types[x[2]] = x[2]
      end
      if h == "const" && x.length == 3 && x[2].is_a?(String)
        consts[form_text(x[1]) + " " + x[2]] = [x[1], x[2]]
      end
      if h == "global" && x.length >= 4
        init = x.find { |y| head_of(y) == "init" }
        globals[form_text(x)] = [x[1], x[2], x[3], init] if init
      end
    end
  end
end

out = []
types.values.first(LIMIT_TYPES).each do |t|
  out << "(parse_type " + form_text(t) + ")"
  %w[type_size reg_class asm_operand_ok asm_class ptx_type mem_type bits_type].each do |fn|
    out << "(" + fn + " " + form_text(t) + ")"
  end
end
# Float constants first (their own limit, so the integer constants cannot crowd them out), then the others.
float_pairs = consts.values.select { |p| form_text(p[0]) == "float" || form_text(p[0]) == "double" }
other_pairs = consts.values.reject { |p| form_text(p[0]) == "float" || form_text(p[0]) == "double" }
(float_pairs.first(LIMIT_FLOATS) + other_pairs.first(LIMIT_CONSTS)).each do |pair|
  ty = form_text(pair[0])
  v = pair[1]
  out << "(float_lit " + v + " " + ty + ")"
  out << "(imm " + ty + " " + v + ")"
  out << "(bool_const_setp p1 " + v + ")"
  # float32_bits is only reached for float-typed constants (byte_const_init); integer text would hit mruby's String#to_f,
  # which is wrong for integers of 19 or more digits (see diff-lower-types.sh).
  out << "(float32_bits " + v + ")" if ty == "float" || ty == "double"
  out << "(as_int " + v + ")"
  out << "(signed64 " + v + ")"
end
globals.values.first(LIMIT_GLOBALS).each do |g|
  name = form_text(g[0])
  ty = form_text(g[1])
  size = form_text(g[2])
  init = form_text(g[3])
  out << "(scalar_const_init " + init + " " + name + " " + size + ")"
  out << "(byte_const_init " + init + " " + name + " " + size + ")"
  out << "(all_zero_init " + init + " " + size + ")"
  out << "(scalar_const_array_init " + ty + " " + init + " " + name + " " + size + ")"
end
$stdout.write(out.join("\n") + "\n")
