// --eval-cases: runs each case of a file through the phase-2 helpers and prints the canonical result, one line per case.
// A case is one top-level form (fn ARG...); each ARG is an IR form, read as the Ruby reader reads it. diff-lower-types.sh
// runs the same cases through the Ruby reference (the same functions, copied verbatim) and compares the two outputs.
#include <cstdio>
#include <string>
#include <vector>

#include "ir.hpp"
#include "lower_types.hpp"

namespace {

struct Val {
  enum Kind { Nil, Bool, Int, Str, Arr } kind = Nil;
  bool b = false;
  i128 i = 0;
  std::string s;
  std::vector<Val> a;
};

Val nil() { return Val{}; }
Val boolean(bool b) {
  Val v;
  v.kind = Val::Bool;
  v.b = b;
  return v;
}
Val integer(i128 i) {
  Val v;
  v.kind = Val::Int;
  v.i = i;
  return v;
}
Val str(const std::string &s) {
  Val v;
  v.kind = Val::Str;
  v.s = s;
  return v;
}
Val arr(std::vector<Val> items) {
  Val v;
  v.kind = Val::Arr;
  v.a = std::move(items);
  return v;
}

// The Ruby value of an IR type: ["int", size, signed, bool], ["float", size], ["ptr", nil], ["void"].
Val type_val(const Ty &t) {
  if (t.kind == "int") return arr({str("int"), integer(t.size), boolean(t.is_signed), boolean(t.is_bool)});
  if (t.kind == "float") return arr({str("float"), integer(t.size)});
  if (t.kind == "ptr") return arr({str("ptr"), nil()});
  return arr({str("void")});
}

// The canonical text of a value: nil, true/false, integers in decimal, strings quoted, arrays in brackets.
std::string canon(const Val &v) {
  switch (v.kind) {
    case Val::Nil: return "nil";
    case Val::Bool: return v.b ? "true" : "false";
    case Val::Int: return i128_text(v.i);
    case Val::Str: return "\"" + v.s + "\"";
    case Val::Arr: {
      std::string out = "[";
      for (size_t k = 0; k < v.a.size(); k++) {
        if (k) out += " ";
        out += canon(v.a[k]);
      }
      return out + "]";
    }
  }
  return "nil";
}

// The text of an argument, as Ruby's to_s on the atom or string.
std::string text_of(const Node &n) { return n.kind == Node::Atom || n.kind == Node::Str ? n.text : ""; }

// Evaluates one case. An argument count that does not match the function throws BadCase.
struct BadCase {};

Val eval_case(const Node &f) {
  if (f.kind != Node::List || f.items.empty() || f.items[0].kind != Node::Atom) throw BadCase{};
  const std::string &fn = f.items[0].text;
  const std::vector<Node> &a = f.items;
  auto need = [&](size_t n) {
    if (a.size() != n + 1) throw BadCase{};
  };
  auto arg = [&](size_t k) -> const Node * { return &a[k + 1]; };

  if (fn == "parse_type") { need(1); return type_val(parse_type(arg(0))); }
  if (fn == "type_size") { need(1); return integer(type_size(parse_type(arg(0)))); }
  if (fn == "reg_class") { need(1); return str(reg_class(parse_type(arg(0)))); }
  if (fn == "asm_operand_ok") { need(1); return boolean(asm_operand_ok(parse_type(arg(0)))); }
  if (fn == "asm_class") { need(1); return str(asm_class(parse_type(arg(0)))); }
  if (fn == "ptx_type") { need(1); return str(ptx_type(parse_type(arg(0)))); }
  if (fn == "mem_type") { need(1); return str(mem_type(parse_type(arg(0)))); }
  if (fn == "bits_type") { need(1); return str(bits_type(parse_type(arg(0)))); }
  if (fn == "ptx_sym") { need(1); return str(ptx_sym(text_of(*arg(0)))); }
  if (fn == "float_lit") { need(2); return str(float_lit(text_of(*arg(0)), parse_type(arg(1)))); }
  if (fn == "bool_const_setp") { need(2); return str(bool_const_setp(text_of(*arg(0)), text_of(*arg(1)))); }
  if (fn == "float32_bits") {
    need(1);
    auto bits = float32_bits(text_of(*arg(0)));
    return bits ? integer(static_cast<i128>(*bits)) : nil();
  }
  if (fn == "as_int") { need(1); return integer(as_int(arg(0))); }
  if (fn == "signed64") { need(1); return integer(signed64(as_int(arg(0)))); }
  if (fn == "imm") { need(2); return str(imm(parse_type(arg(0)), as_int(arg(1)))); }
  if (fn == "scalar_const_init") {
    need(3);
    auto r = scalar_const_init(arg(0), text_of(*arg(1)), as_int(arg(2)));
    if (!r) return nil();
    return arr({str((*r)[0]), str((*r)[1])});
  }
  if (fn == "scalar_const_array_init") {
    need(4);
    auto r = scalar_const_array_init(arg(0), arg(1), text_of(*arg(2)), as_int(arg(3)));
    if (!r) return nil();
    return arr({str(r->ptype), str(r->body), integer(r->count)});
  }
  if (fn == "byte_const_init") {
    need(3);
    auto r = byte_const_init(arg(0), text_of(*arg(1)), as_int(arg(2)));
    if (!r) return nil();
    return arr({str(r->ptype), str(r->body), integer(r->size)});
  }
  if (fn == "all_zero_init") { need(2); return boolean(all_zero_init(arg(0), as_int(arg(1)))); }
  throw BadCase{};
}

}  // namespace

// Prints one line per case of src. Returns the process status (1 when the file itself does not parse).
int run_eval_cases(const std::string &src) {
  std::vector<Node> cases;
  try {
    cases = parse_forms_chunked(src);
  } catch (const BadIR &) {
    std::fputs("BADIR-PARSE\n", stdout);
    return 1;
  }
  for (const Node &c : cases) {
    std::string line;
    try {
      line = canon(eval_case(c));
    } catch (const Refused &) {
      line = "REFUSED";
    } catch (const BadIR &) {
      line = "BADIR";
    } catch (const BadCase &) {
      line = "BADCASE";
    }
    line += "\n";
    std::fwrite(line.data(), 1, line.size(), stdout);
  }
  return 0;
}
