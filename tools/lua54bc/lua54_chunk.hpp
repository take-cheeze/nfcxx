// Lua 5.4 binary chunk reader: the data model and the decoder for the instruction words.
//
// Reads a chunk as lundump.c of Lua 5.4.9 (the pin in scripts/setup-poly-lua.sh) does, and decodes every instruction
// by the formats of lopcodes.h. Plain C++17, no dependencies, so nfcxx can build it. Only the reader lives here: the
// Path B IR producer is a later step (docs/notes/pathb-stage2.md, section 1).
#ifndef NFCXX_LUA54_CHUNK_HPP
#define NFCXX_LUA54_CHUNK_HPP

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace lua54 {

// Instruction formats (lopcodes.h, enum OpMode).
enum class Fmt : std::uint8_t { ABC, ABx, AsBx, Ax, sJ };

// Opcodes in the order of lopcodes.h (enum OpCode). The format of each is the one lopcodes.c gives.
enum Op : std::uint8_t {
  MOVE, LOADI, LOADF, LOADK, LOADKX, LOADFALSE, LFALSESKIP, LOADTRUE, LOADNIL, GETUPVAL,
  SETUPVAL, GETTABUP, GETTABLE, GETI, GETFIELD, SETTABUP, SETTABLE, SETI, SETFIELD, NEWTABLE,
  SELF, ADDI, ADDK, SUBK, MULK, MODK, POWK, DIVK, IDIVK, BANDK,
  BORK, BXORK, SHRI, SHLI, ADD, SUB, MUL, MOD, POW, DIV,
  IDIV, BAND, BOR, BXOR, SHL, SHR, MMBIN, MMBINI, MMBINK, UNM,
  BNOT, NOT, LEN, CONCAT, CLOSE, TBC, JMP, EQ, LT, LE,
  EQK, EQI, LTI, LEI, GTI, GEI, TEST, TESTSET, CALL, TAILCALL,
  RETURN, RETURN0, RETURN1, FORLOOP, FORPREP, TFORPREP, TFORCALL, TFORLOOP, SETLIST, CLOSURE,
  VARARG, VARARGPREP, EXTRAARG,
  NUM_OPCODES
};

static_assert(NUM_OPCODES == 83, "Lua 5.4.9 has 83 opcodes");

const char *op_name(std::uint8_t op);
Fmt op_format(std::uint8_t op);

// One 32-bit instruction word (Instruction in lopcodes.h). Accessors follow the GETARG_* macros.
struct Insn {
  std::uint32_t raw = 0;

  std::uint8_t op() const { return raw & 0x7f; }
  unsigned A() const { return (raw >> 7) & 0xff; }
  unsigned k() const { return (raw >> 15) & 1; }
  unsigned B() const { return (raw >> 16) & 0xff; }
  unsigned C() const { return (raw >> 24) & 0xff; }
  unsigned Bx() const { return (raw >> 15) & 0x1ffff; }
  int sBx() const { return static_cast<int>(Bx()) - 65535; }   // OFFSET_sBx
  unsigned Ax() const { return raw >> 7; }
  int sJ() const { return static_cast<int>(raw >> 7) - 16777215; }  // OFFSET_sJ
  int sC() const { return static_cast<int>(C()) - 127; }      // OFFSET_sC
};

// A constant (lobject.h tags: nil, false, true, integer, float, short and long string).
struct Constant {
  enum class Kind : std::uint8_t { Nil, False, True, Integer, Float, String };
  Kind kind = Kind::Nil;
  std::int64_t i = 0;
  double f = 0;
  std::string s;   // Kind::String
};

struct UpvalDesc {
  std::uint8_t instack = 0;
  std::uint8_t idx = 0;
  std::uint8_t kind = 0;
  std::optional<std::string> name;   // present only if the chunk keeps debug information
};

struct LocVar {
  std::optional<std::string> name;
  int startpc = 0;
  int endpc = 0;
};

struct AbsLineInfo {
  int pc = 0;
  int line = 0;
};

struct Proto {
  std::optional<std::string> source;   // absent when stripped and inherited from the parent
  int linedefined = 0;
  int lastlinedefined = 0;
  std::uint8_t numparams = 0;
  bool is_vararg = false;
  std::uint8_t maxstacksize = 0;
  std::vector<Insn> code;
  std::vector<Constant> k;
  std::vector<UpvalDesc> upvalues;
  std::vector<std::unique_ptr<Proto>> p;
  std::vector<std::uint8_t> lineinfo;       // relative line deltas (ldebug.c)
  std::vector<AbsLineInfo> abslineinfo;
  std::vector<LocVar> locvars;
};

struct Chunk {
  std::uint8_t upvalue_count = 0;   // of the main function
  std::unique_ptr<Proto> main;
};

// Parses a binary chunk. Throws std::runtime_error with lundump.c's messages, e.g. "truncated chunk" or
// "version mismatch", on bad input. A big-endian chunk is refused by the LUAC_INT check, as lundump.c does.
Chunk load(const std::uint8_t *data, std::size_t size, const std::string &name);

}  // namespace lua54

#endif  // NFCXX_LUA54_CHUNK_HPP
