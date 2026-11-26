// mrbbc_dump: prints a RITE file's ireps, pools, symbols and instructions (tools/mrbbc/mrb_rite.hpp).
//
//   mrbbc_dump file.rite > listing.txt
//
// Exit status: 0 when the file reads and every instruction decodes; 1 with a message on stderr otherwise; 2 for usage.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "mrb_rite.hpp"

namespace {

std::string quote(const std::string &s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x20 || c >= 0x7f) {
      char buf[8];
      std::snprintf(buf, sizeof buf, "\\x%02x", c);
      out += buf;
    } else {
      out += static_cast<char>(c);
    }
  }
  return out + "\"";
}

void dump_irep(const mrb::Irep &irep, int index, int depth, std::size_t &ninsn, std::string &out) {
  std::string pad(static_cast<std::size_t>(depth) * 2, ' ');
  std::vector<mrb::Insn> insns = mrb::decode_iseq(irep);  // throws ReadError on a bad instruction
  out += pad + "irep " + std::to_string(index) + ": nlocals " + std::to_string(irep.nlocals) + " nregs " +
         std::to_string(irep.nregs) + " children " + std::to_string(irep.reps.size()) + " ilen " +
         std::to_string(irep.iseq.size()) + " catches " + std::to_string(irep.catches.size()) + " pool " +
         std::to_string(irep.pool.size()) + " syms " + std::to_string(irep.syms.size()) + "\n";
  if (irep.has_lv) {
    out += pad + "  locals:";
    for (std::size_t i = 0; i < irep.lv.size(); ++i) {
      out += " R" + std::to_string(i + 1) + "=" + (irep.lv[i].empty() ? std::string("-") : irep.lv[i]);
    }
    out += "\n";
  }
  for (std::size_t i = 0; i < irep.pool.size(); ++i) {
    const mrb::Pool &p = irep.pool[i];
    out += pad + "  pool[" + std::to_string(i) + "] ";
    switch (p.kind) {
      case mrb::Pool::Kind::Int: out += "int " + std::to_string(p.i); break;
      case mrb::Pool::Kind::Float: {
        char buf[64];
        std::snprintf(buf, sizeof buf, "float %.17g", p.f);
        out += buf;
        break;
      }
      case mrb::Pool::Kind::Str: out += "str " + quote(p.s); break;
      case mrb::Pool::Kind::BigInt: out += "bigint (" + std::to_string(p.s.size()) + " bytes)"; break;
    }
    out += "\n";
  }
  for (std::size_t i = 0; i < irep.syms.size(); ++i) {
    out += pad + "  sym[" + std::to_string(i) + "] " + (irep.sym_null[i] ? std::string("null") : quote(irep.syms[i])) + "\n";
  }
  for (const mrb::Catch &c : irep.catches) {
    out += pad + "  catch type " + std::to_string(c.type) + " [" + std::to_string(c.begin) + ", " +
           std::to_string(c.end) + ") -> " + std::to_string(c.target) + "\n";
  }
  for (const mrb::Insn &in : insns) {
    char head[32];
    std::snprintf(head, sizeof head, "%04zx ", in.pc);
    out += pad + "  " + head + in.name;
    if (in.ext != 0) out += "(EXT" + std::to_string(in.ext) + ")";
    for (std::uint32_t a : in.args) out += " " + std::to_string(a);
    out += "\n";
    ++ninsn;
  }
  for (std::size_t i = 0; i < irep.reps.size(); ++i) {
    dump_irep(irep.reps[i], static_cast<int>(i), depth + 1, ninsn, out);
  }
}

}  // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s file.rite\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    mrb::Module m = mrb::read_module(bytes.data(), bytes.size());
    std::string out = "RITE 04.00, " + std::to_string(m.binary_size) + " bytes, compiler " + m.compiler + " " +
                      m.compiler_version + "\n";
    std::size_t ninsn = 0;
    dump_irep(m.root, 0, 0, ninsn, out);
    out += "decoded " + std::to_string(ninsn) + " instructions\n";
    std::fwrite(out.data(), 1, out.size(), stdout);
  } catch (const mrb::ReadError &e) {
    std::fprintf(stderr, "%s: %s\n", argv[1], e.what());
    return 1;
  }
  return 0;
}
