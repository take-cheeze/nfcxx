# Driver for the phase-2 differential (diff-lower-types.sh). Appended after the reference functions copied from
# scripts/pathb-ptx-emit.rb; it runs each case (one top-level form: fn ARG...) and prints the canonical result, the
# same text the C++ --eval-cases prints. Keep the case list in step with eval_case in eval_cases.cpp.

class BadCase < StandardError; end

# The canonical text of a value (nil, true/false, decimal integers, quoted strings, bracketed arrays).
def canon(v)
  if v.nil?
    "nil"
  elsif v == true
    "true"
  elsif v == false
    "false"
  elsif v.is_a?(Integer)
    v.to_s
  elsif v.is_a?(String)
    "\"" + v + "\""
  elsif v.is_a?(Array)
    "[" + v.map { |x| canon(x) }.join(" ") + "]"
  else
    raise BadCase, "canon"
  end
end

# The text of an argument: an atom's or a string's bytes; anything else is "" (as the C++ text_of).
def tx(x)
  (x.is_a?(String) || x.is_a?(IRStr)) ? x.to_s : ""
end

def nargs(a, n)
  raise BadCase, "args" unless a.length == n
end

def ev_case(f)
  raise BadCase, "form" unless f.is_a?(Array) && !f.empty? && f[0].is_a?(String)
  fn = f[0]
  a = f[1..-1]
  if fn == "parse_type"
    nargs(a, 1); parse_type(a[0])
  elsif fn == "type_size"
    nargs(a, 1); type_size(parse_type(a[0]))
  elsif fn == "reg_class"
    nargs(a, 1); reg_class(parse_type(a[0]))
  elsif fn == "asm_operand_ok"
    nargs(a, 1); asm_operand_ok(parse_type(a[0]))
  elsif fn == "asm_class"
    nargs(a, 1); asm_class(parse_type(a[0]))
  elsif fn == "ptx_type"
    nargs(a, 1); ptx_type(parse_type(a[0]))
  elsif fn == "mem_type"
    nargs(a, 1); mem_type(parse_type(a[0]))
  elsif fn == "bits_type"
    nargs(a, 1); bits_type(parse_type(a[0]))
  elsif fn == "ptx_sym"
    nargs(a, 1); ptx_sym(tx(a[0]))
  elsif fn == "float_lit"
    nargs(a, 2); float_lit(tx(a[0]), parse_type(a[1]))
  elsif fn == "bool_const_setp"
    nargs(a, 2); bool_const_setp(tx(a[0]), tx(a[1]))
  elsif fn == "float32_bits"
    nargs(a, 1); float32_bits(tx(a[0]))
  elsif fn == "as_int"
    nargs(a, 1); as_int(a[0])
  elsif fn == "signed64"
    nargs(a, 1); signed64(as_int(a[0]))
  elsif fn == "imm"
    nargs(a, 2); imm(parse_type(a[0]), as_int(a[1]))
  elsif fn == "scalar_const_init"
    nargs(a, 3); scalar_const_init(a[0], tx(a[1]), as_int(a[2]))
  elsif fn == "scalar_const_array_init"
    nargs(a, 4); scalar_const_array_init(a[0], a[1], tx(a[2]), as_int(a[3]))
  elsif fn == "byte_const_init"
    nargs(a, 3); byte_const_init(a[0], tx(a[1]), as_int(a[2]))
  elsif fn == "all_zero_init"
    nargs(a, 2); all_zero_init?(a[0], as_int(a[1]))
  else
    raise BadCase, "unknown case #{fn}"
  end
end

def run_cases(src)
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
      line = canon(ev_case(f))
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
exit(run_cases(case_src))
