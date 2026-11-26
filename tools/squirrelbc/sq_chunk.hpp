// Squirrel 3.2 bytecode stream reader (tools/squirrelbc). It reads what sq_writeclosure writes (squirrel/sqapi.cpp,
// squirrel/sqobject.cpp: SQClosure::Save and SQFunctionProto::Save) and nothing else.
//
// The stream is the 2-byte tag SQ_BYTECODE_STREAM_TAG (0xFAFA), then the closure header (HEAD, then the sizes of SQChar,
// SQInteger and SQFloat that the writer was built with), then the function prototype tree, then TAIL. The format has no
// version field: the 3.2 identity is the tags, the field order and the opcode set of sqopcodes.h (61 opcodes, 0x00-0x3C).
// Every integer is written in the writer's native byte order; this reader is little-endian, as x86-64 and arm64 are.
#ifndef NFCXX_SQUIRREL_CHUNK_HPP
#define NFCXX_SQUIRREL_CHUNK_HPP

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace squirrel {

// SQObjectType values as WriteObject stores them (sq_type, the full type word with its flag bits).
constexpr std::uint32_t kOtNull = 0x01000001u;
constexpr std::uint32_t kOtInteger = 0x05000002u;
constexpr std::uint32_t kOtFloat = 0x05000004u;
constexpr std::uint32_t kOtBool = 0x01000008u;
constexpr std::uint32_t kOtString = 0x08000010u;

constexpr std::uint8_t kNumOpcodes = 0x3D;  // sqopcodes.h: _OP_LINE (0x00) to _OP_CLOSE (0x3C)

// One literal, parameter, outer name or local name. Only the field for `type` is set.
struct Object {
  std::uint32_t type = kOtNull;
  std::int64_t integer = 0;  // kOtInteger, and kOtBool (0 or 1)
  double floating = 0.0;     // kOtFloat (read at the writer's SQFloat width)
  std::string text;          // kOtString, the bytes of the string
};

// SQInstruction: 8 bytes, arg1 first (SQInt32), then op, arg0, arg2, arg3.
struct Instruction {
  std::int32_t arg1 = 0;
  std::uint8_t op = 0;
  std::uint8_t arg0 = 0;
  std::uint8_t arg2 = 0;
  std::uint8_t arg3 = 0;
};

struct LineInfo {
  std::int64_t line = 0;
  std::int64_t op = 0;
};

struct LocalVarInfo {
  Object name;
  std::uint64_t pos = 0;
  std::uint64_t start_op = 0;
  std::uint64_t end_op = 0;  // UINT_MINUS_ONE while the local is captured as an outer
};

struct OuterVar {
  std::uint64_t type = 0;  // SQOuterType: otLOCAL or otOUTER
  Object src;
  Object name;
};

struct Proto {
  Object source;
  Object name;
  std::int64_t stacksize = 0;
  bool bgenerator = false;
  std::int64_t varparams = 0;
  std::vector<LocalVarInfo> localvars;
  std::vector<LineInfo> lines;
  std::vector<Object> literals;
  std::vector<Object> parameters;
  std::vector<OuterVar> outers;
  std::vector<std::int64_t> defaultparams;
  std::vector<Instruction> instructions;
  std::vector<Proto> functions;
};

// The stream header, and the main prototype.
struct Chunk {
  std::uint32_t char_size = 0;     // sizeof(SQChar), 1 in the default build
  std::uint32_t integer_size = 0;  // sizeof(SQInteger), 8 on LP64
  std::uint32_t float_size = 0;    // sizeof(SQFloat), 4 (float) or 8 (double)
  Proto main;
};

// Parses a whole stream. Throws std::runtime_error with the reason when the stream is not a 3.2 bytecode stream of a
// layout this reader knows (SQChar 1 byte, SQInteger 8 bytes, SQFloat 4 or 8 bytes), when it is truncated, or when
// bytes are left over after TAIL. Nothing is returned for an invalid stream.
Chunk load(const std::uint8_t *data, std::size_t size);

// The opcode's name as sqopcodes.h spells it ("_OP_LOADINT"), or nullptr when op is not an opcode.
const char *op_name(std::uint8_t op);

}  // namespace squirrel

#endif  // NFCXX_SQUIRREL_CHUNK_HPP
