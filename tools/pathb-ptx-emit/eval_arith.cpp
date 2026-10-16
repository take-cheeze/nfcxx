// --eval-arith: runs each case of a file through the arithmetic lowering (FnCtx::arith) and prints what it emits, one line
// per case. A case is (arith DEST_TYPE ((%N PTX_REG TYPE) ...) INSTR): the preset registers, then the instruction form,
// lowered into the destination register %d of DEST_TYPE. diff-arith.sh runs the same cases through the Ruby reference
// (class Fn, copied verbatim) and compares the two outputs.
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#include "ir.hpp"
#include "lower_arith.hpp"
#include "lower_types.hpp"

namespace {

struct BadCase : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// The emitted lines joined by " ~ " (the lines carry their own indentation, as the Ruby's emit writes them). A case is
// (arith DTY PRESETS INSTR), (call DTY PRESETS INSTR) or (asm PRESETS INSTR); see the header comment.
std::string run_case(const Node &c) {
  if (c.kind != Node::List || c.items.empty() || c.items[0].kind != Node::Atom) throw BadCase("case");
  const std::string &kind = c.items[0].text;
  bool is_asm = kind == "asm";
  if (!(kind == "arith" || kind == "call" || is_asm) || c.items.size() != (is_asm ? 3u : 4u)) throw BadCase("case");
  const Node &presets = c.items[is_asm ? 1 : 2];
  if (presets.kind != Node::List) throw BadCase("presets");
  FnCtx ctx;
  for (const Node &p : presets.items) {
    if (p.kind != Node::List || p.items.size() != 3 || p.items[0].kind != Node::Atom || p.items[1].kind != Node::Atom)
      throw BadCase("preset");
    ctx.regs[p.items[0].text] = RegInfo{p.items[1].text, parse_type(&p.items[2])};
  }
  const Node &x = c.items[is_asm ? 2 : 3];
  if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) throw BadCase("instr");
  if (is_asm) {
    if (x.items[0].text != "ptx-asm") throw BadCase("instr");
    ctx.asm_stmt(x);
  } else {
    Ty dty = parse_type(&c.items[1]);
    if (kind == "arith") {
      if (!ctx.arith(x.items[0].text, x, "%d", dty)) return "NOTARITH";
    } else {
      if (x.items[0].text != "call") throw BadCase("instr");
      if (!ctx.call(x, "%d", dty)) return "NOTCALL";
    }
  }
  std::string out;
  for (size_t i = 0; i < ctx.lines.size(); i++) {
    if (i) out += " ~ ";
    out += ctx.lines[i];
  }
  return out;
}

}  // namespace

// Prints one line per case of src. Returns the process status (1 when the file itself does not parse).
int run_eval_arith(const std::string &src) {
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
      line = run_case(c);
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
