// --eval-arith: runs each case of a file through the lowering (FnCtx::arith, call, asm_stmt, memory, store_stmt) and prints
// what it emits, one line per case. A case is (arith DEST_TYPE ((%N PTX_REG TYPE) ...) INSTR), (call DEST_TYPE PRESETS
// INSTR), (asm PRESETS INSTR), (mem DEST_TYPE PRESETS SYMBOLS INSTR) or (stmt PRESETS SYMBOLS STMT): the preset registers,
// the module symbols and frame slots, then the form. diff-arith.sh runs the same cases through the Ruby reference (class Fn,
// copied verbatim) and compares the two outputs.
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#include "ir.hpp"
#include "lower_arith.hpp"
#include "lower_types.hpp"
#include "module_decls.hpp"

namespace {

struct BadCase : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// The emitted lines joined by " ~ " (the lines carry their own indentation, as the Ruby's emit writes them).
std::string joined(const FnCtx &ctx) {
  std::string out;
  for (size_t i = 0; i < ctx.lines.size(); i++) {
    if (i) out += " ~ ";
    out += ctx.lines[i];
  }
  return out;
}

// The preset registers of a case: each is (%N PTX_REG TYPE).
void presets_into(FnCtx &ctx, const Node &presets) {
  if (presets.kind != Node::List) throw BadCase("presets");
  for (const Node &p : presets.items) {
    if (p.kind != Node::List || p.items.size() != 3 || p.items[0].kind != Node::Atom || p.items[1].kind != Node::Atom)
      throw BadCase("preset");
    ctx.regs[p.items[0].text] = RegInfo{p.items[1].text, parse_type(&p.items[2])};
  }
}

// The module symbols and frame slots of a case: each is (shared NAME), (global NAME), (const NAME), (extern NAME),
// (string NAME) or (slot NAME OFFSET).
void symbols_into(FnCtx &ctx, ModuleSymbols &syms, const Node &list) {
  if (list.kind != Node::List) throw BadCase("symbols");
  for (const Node &e : list.items) {
    if (e.kind != Node::List || e.items.size() < 2 || e.items[0].kind != Node::Atom || e.items[1].kind != Node::Atom)
      throw BadCase("symbol");
    const std::string &kind = e.items[0].text;
    const std::string &name = e.items[1].text;
    if (kind == "shared") syms.shared.insert(name);
    else if (kind == "global") syms.globals.insert(name);
    else if (kind == "const") syms.consts.insert(name);
    else if (kind == "extern") syms.externs.insert(name);
    else if (kind == "string") syms.strings.insert(name);
    else if (kind == "slot" && e.items.size() == 3 && e.items[2].kind == Node::Atom)
      ctx.slots[name] = static_cast<int>(as_int(&e.items[2]));
    else throw BadCase("symbol");
  }
  ctx.mod = &syms;
}

// Runs one case: (arith DEST PRESETS INSTR), (call DEST PRESETS INSTR), (asm PRESETS INSTR), (mem DEST PRESETS SYMBOLS INSTR)
// or (stmt PRESETS SYMBOLS STMT).
std::string run_case(const Node &c) {
  if (c.kind != Node::List || c.items.empty() || c.items[0].kind != Node::Atom) throw BadCase("case");
  const std::string &kind = c.items[0].text;
  FnCtx ctx;
  ModuleSymbols syms;
  if (kind == "arith" || kind == "call") {
    if (c.items.size() != 4) throw BadCase("case");
    presets_into(ctx, c.items[2]);
    Ty dty = parse_type(&c.items[1]);
    const Node &x = c.items[3];
    if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) throw BadCase("instr");
    if (kind == "arith") {
      if (!ctx.arith(x.items[0].text, x, "%d", dty)) return "NOTARITH";
    } else {
      if (x.items[0].text != "call") throw BadCase("instr");
      if (!ctx.call(x, "%d", dty)) return "NOTCALL";
    }
    return joined(ctx);
  }
  if (kind == "asm") {
    if (c.items.size() != 3) throw BadCase("case");
    presets_into(ctx, c.items[1]);
    const Node &x = c.items[2];
    if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom || x.items[0].text != "ptx-asm")
      throw BadCase("instr");
    ctx.asm_stmt(x);
    return joined(ctx);
  }
  if (kind == "mem") {
    if (c.items.size() != 5) throw BadCase("case");
    presets_into(ctx, c.items[2]);
    symbols_into(ctx, syms, c.items[3]);
    Ty dty = parse_type(&c.items[1]);
    const Node &x = c.items[4];
    if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) throw BadCase("instr");
    if (!ctx.memory(x.items[0].text, x, "%d", dty)) return "NOTMEM";
    return joined(ctx);
  }
  if (kind == "stmt") {
    if (c.items.size() != 4) throw BadCase("case");
    presets_into(ctx, c.items[1]);
    symbols_into(ctx, syms, c.items[2]);
    const Node &x = c.items[3];
    if (x.kind != Node::List || x.items.empty() || x.items[0].kind != Node::Atom) throw BadCase("stmt");
    if (!ctx.store_stmt(x.items[0].text, x)) return "NOTSTMT";
    return joined(ctx);
  }
  throw BadCase("case");
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
