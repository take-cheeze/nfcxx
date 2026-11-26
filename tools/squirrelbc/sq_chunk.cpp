// Squirrel 3.2 bytecode stream reader: see sq_chunk.hpp. The field order follows SQClosure::Load and
// SQFunctionProto::Load (squirrel/sqobject.cpp) of the 3.2 stable tree; each check there is a check here.
#include "sq_chunk.hpp"

#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace squirrel {

namespace {

// Tags of the stream structure (sqobject.h). They are written as u32 in the native order.
constexpr std::uint16_t kStreamTag = 0xFAFA;                  // SQ_BYTECODE_STREAM_TAG (squirrel.h)
constexpr std::uint32_t kTagHead = ('S' << 24) | ('Q' << 16) | ('I' << 8) | 'R';
constexpr std::uint32_t kTagPart = ('P' << 24) | ('A' << 16) | ('R' << 8) | 'T';
constexpr std::uint32_t kTagTail = ('T' << 24) | ('A' << 16) | ('I' << 8) | 'L';

class Reader {
 public:
  Reader(const std::uint8_t *data, std::size_t size) : p_(data), end_(data + size) {}

  void bytes(void *dst, std::size_t n) {
    if (static_cast<std::size_t>(end_ - p_) < n) throw std::runtime_error("truncated stream");
    if (n) std::memcpy(dst, p_, n);
    p_ += n;
  }

  // Reads `count` records of `size` bytes each, after checking that they are all left in the stream.
  void need(std::int64_t count, std::size_t size) const {
    if (count < 0) throw std::runtime_error("negative count in stream");
    if (static_cast<std::uint64_t>(count) > static_cast<std::uint64_t>(end_ - p_) / size)
      throw std::runtime_error("truncated stream");
  }

  std::uint32_t u32() {
    std::uint8_t b[4];
    bytes(b, 4);
    return static_cast<std::uint32_t>(b[0]) | (static_cast<std::uint32_t>(b[1]) << 8) |
           (static_cast<std::uint32_t>(b[2]) << 16) | (static_cast<std::uint32_t>(b[3]) << 24);
  }

  std::uint64_t u64() {
    std::uint8_t b[8];
    bytes(b, 8);
    std::uint64_t v = 0;
    for (int i = 7; i >= 0; --i) v = (v << 8) | b[i];
    return v;
  }

  std::int64_t i64() { return static_cast<std::int64_t>(u64()); }

  void expect_tag(std::uint32_t tag) {
    if (u32() != tag) throw std::runtime_error("invalid or corrupted closure stream");
  }

  bool at_end() const { return p_ == end_; }

 private:
  const std::uint8_t *p_;
  const std::uint8_t *end_;
};

Object read_object(Reader &r, const Chunk &hdr) {
  Object o;
  o.type = r.u32();
  switch (o.type) {
    case kOtString: {
      std::int64_t len = r.i64();
      r.need(len, hdr.char_size);
      o.text.resize(static_cast<std::size_t>(len) * hdr.char_size);
      r.bytes(&o.text[0], o.text.size());
      break;
    }
    case kOtBool:
    case kOtInteger:
      o.integer = r.i64();
      break;
    case kOtFloat:
      if (hdr.float_size == 4) {
        float f;
        r.bytes(&f, 4);
        o.floating = f;
      } else {
        r.bytes(&o.floating, 8);
      }
      break;
    case kOtNull:
      break;
    default: {
      char msg[80];
      std::snprintf(msg, sizeof msg, "cannot deserialize object of type 0x%08x", static_cast<unsigned>(o.type));
      throw std::runtime_error(msg);
    }
  }
  return o;
}

Proto read_proto(Reader &r, const Chunk &hdr) {
  Proto p;
  r.expect_tag(kTagPart);
  p.source = read_object(r, hdr);
  p.name = read_object(r, hdr);
  r.expect_tag(kTagPart);
  // SQFunctionProto::Save writes these eight SQInteger counts, in this order.
  std::int64_t nliterals = r.i64(), nparameters = r.i64(), noutervalues = r.i64(), nlocalvarinfos = r.i64();
  std::int64_t nlineinfos = r.i64(), ndefaultparams = r.i64(), ninstructions = r.i64(), nfunctions = r.i64();
  // Each record has a minimum size, so a count that cannot fit in the rest of the stream is rejected before any
  // allocation. An object is at least its u32 type.
  r.need(nliterals, 4);
  r.need(nparameters, 4);
  r.need(noutervalues, 8 + 4 + 4);
  r.need(nlocalvarinfos, 4 + 8 * 3);
  r.need(nlineinfos, 16);
  r.need(ndefaultparams, 8);
  r.need(ninstructions, 8);
  r.need(nfunctions, 4);

  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < nliterals; ++i) p.literals.push_back(read_object(r, hdr));
  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < nparameters; ++i) p.parameters.push_back(read_object(r, hdr));
  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < noutervalues; ++i) {
    OuterVar ov;
    ov.type = r.u64();
    ov.src = read_object(r, hdr);
    ov.name = read_object(r, hdr);
    p.outers.push_back(ov);
  }
  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < nlocalvarinfos; ++i) {
    LocalVarInfo lv;
    lv.name = read_object(r, hdr);
    lv.pos = r.u64();
    lv.start_op = r.u64();
    lv.end_op = r.u64();
    p.localvars.push_back(lv);
  }
  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < nlineinfos; ++i) {
    LineInfo li;
    li.line = r.i64();
    li.op = r.i64();
    p.lines.push_back(li);
  }
  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < ndefaultparams; ++i) p.defaultparams.push_back(r.i64());
  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < ninstructions; ++i) {
    Instruction in;
    std::uint8_t b[8];
    r.bytes(b, 8);
    in.arg1 = static_cast<std::int32_t>(static_cast<std::uint32_t>(b[0]) | (static_cast<std::uint32_t>(b[1]) << 8) |
                                        (static_cast<std::uint32_t>(b[2]) << 16) |
                                        (static_cast<std::uint32_t>(b[3]) << 24));
    in.op = b[4];
    in.arg0 = b[5];
    in.arg2 = b[6];
    in.arg3 = b[7];
    if (in.op >= kNumOpcodes) {
      char msg[80];
      std::snprintf(msg, sizeof msg, "invalid opcode 0x%02x at instruction %lld", in.op,
                    static_cast<long long>(i));
      throw std::runtime_error(msg);
    }
    p.instructions.push_back(in);
  }
  r.expect_tag(kTagPart);
  for (std::int64_t i = 0; i < nfunctions; ++i) p.functions.push_back(read_proto(r, hdr));
  p.stacksize = r.i64();
  std::uint8_t bg;
  r.bytes(&bg, 1);
  if (bg > 1) throw std::runtime_error("invalid bgenerator flag in stream");
  p.bgenerator = bg != 0;
  p.varparams = r.i64();
  return p;
}

}  // namespace

Chunk load(const std::uint8_t *data, std::size_t size) {
  Reader r(data, size);
  std::uint16_t tag;
  std::uint8_t t[2];
  r.bytes(t, 2);
  tag = static_cast<std::uint16_t>(t[0] | (t[1] << 8));
  if (tag != kStreamTag) throw std::runtime_error("invalid stream");

  Chunk c;
  r.expect_tag(kTagHead);
  c.char_size = r.u32();
  c.integer_size = r.u32();
  c.float_size = r.u32();
  if (c.char_size != 1) throw std::runtime_error("unsupported SQChar size (the reader takes 1-byte characters)");
  if (c.integer_size != 8) throw std::runtime_error("unsupported SQInteger size (the reader takes 8-byte integers)");
  if (c.float_size != 4 && c.float_size != 8) throw std::runtime_error("unsupported SQFloat size");

  c.main = read_proto(r, c);
  r.expect_tag(kTagTail);
  if (!r.at_end()) throw std::runtime_error("bytes left after the end of the stream");
  return c;
}

const char *op_name(std::uint8_t op) {
  // sqopcodes.h, in value order. A test checks this table against the header of the reference tree.
  static const char *const kNames[kNumOpcodes] = {
      "_OP_LINE",       "_OP_LOAD",        "_OP_LOADINT",     "_OP_LOADFLOAT",   "_OP_DLOAD",
      "_OP_TAILCALL",   "_OP_CALL",        "_OP_PREPCALL",    "_OP_PREPCALLK",   "_OP_GETK",
      "_OP_MOVE",       "_OP_NEWSLOT",     "_OP_DELETE",      "_OP_SET",         "_OP_GET",
      "_OP_EQ",         "_OP_NE",          "_OP_ADD",         "_OP_SUB",         "_OP_MUL",
      "_OP_DIV",        "_OP_MOD",         "_OP_BITW",        "_OP_RETURN",      "_OP_LOADNULLS",
      "_OP_LOADROOT",   "_OP_LOADBOOL",    "_OP_DMOVE",       "_OP_JMP",         "_OP_JCMP",
      "_OP_JZ",         "_OP_SETOUTER",    "_OP_GETOUTER",    "_OP_NEWOBJ",      "_OP_APPENDARRAY",
      "_OP_COMPARITH",  "_OP_INC",         "_OP_INCL",        "_OP_PINC",        "_OP_PINCL",
      "_OP_CMP",        "_OP_EXISTS",      "_OP_INSTANCEOF",  "_OP_AND",         "_OP_OR",
      "_OP_NEG",        "_OP_NOT",         "_OP_BWNOT",       "_OP_CLOSURE",     "_OP_YIELD",
      "_OP_RESUME",     "_OP_FOREACH",     "_OP_POSTFOREACH", "_OP_CLONE",       "_OP_TYPEOF",
      "_OP_PUSHTRAP",   "_OP_POPTRAP",     "_OP_THROW",       "_OP_NEWSLOTA",    "_OP_GETBASE",
      "_OP_CLOSE",
  };
  return op < kNumOpcodes ? kNames[op] : nullptr;
}

}  // namespace squirrel
