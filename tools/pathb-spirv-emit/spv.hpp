// The SPIR-V module builder (scripts/pathb-spirv-emit.rb: class Spv). Ids are handed out in the Ruby's order: a memoized
// type or constant takes its id where the Ruby's memo block does, before or after the ids of its operands as the block
// has it, so the module is the same, word for word.
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

using Inst = std::vector<uint32_t>;

enum : uint32_t {
  OP_NAME_DECORATE = 71,
  OP_MEMBER_DECORATE = 72,
  SC_UNIFORM_CONSTANT = 0,
  SC_INPUT = 1,
  SC_WORKGROUP = 4,
  SC_CROSSWG = 5,
  SC_PRIVATE = 6,
  SC_FUNCTION = 7,
  SC_PUSH_CONSTANT = 9,
  SC_PSB = 5349,
  SCOPE_DEVICE = 1,
  SCOPE_WORKGROUP = 2,
  SCOPE_SUBGROUP = 3,
  SEM_RELAXED = 0,
  SEM_BARRIER = 0x8 | 0x40 | 0x100 | 0x200,
  SEM_BARRIER_KERNEL = 0x8 | 0x100 | 0x200,
  SEM_SG_BARRIER_KERNEL = 0x8 | 0x80 | 0x100 | 0x200,
  SUBGROUP_SIZE = 16,
  BUILTIN_WORKGROUP_ID = 26,
  BUILTIN_LOCAL_INVOCATION_ID = 27,
  BUILTIN_GLOBAL_INVOCATION_ID = 28,
  DEC_BUILTIN = 11,
  DEC_SPEC_ID = 1,
  DEC_BLOCK = 2,
  DEC_OFFSET = 35,
};

// The push block's members (the Ruby's PUSH_MEMBERS): the host writes the same layout.
enum PushMember {
  P_CLOSURE, P_STATICS, P_STACK, P_LOCAL, P_FLAG, P_GX, P_GY, P_GZ, P_NX, P_NY, P_NZ, P_STACK_BYTES, P_LOCAL_STRIDE,
  P_LOCAL_USER, P_OX, P_OY, P_OZ, P_HLO, P_HSIZE, P_DBASE, P_COUNT
};
extern const int PUSH_SIZES[P_COUNT];

class Spv {
 public:
  bool kernel_cl = false;

  uint32_t id() { return bound_++; }
  uint32_t bound() const { return bound_; }
  void cap(uint32_t c);
  void ext(const std::string &name);
  void entry_mode(uint32_t fid, uint32_t mode, uint32_t lit) { modes_.push_back({16, fid, mode, lit}); }
  uint32_t glsl_id();
  uint32_t ext_num(int g);   // the opcode of GLSL instruction g in the module's extended set
  void decl(Inst i) { types_.push_back(std::move(i)); }
  void ann(Inst i) { anns_.push_back(std::move(i)); }
  void func(Inst i) { funcs_.push_back(std::move(i)); }

  uint32_t t_void();
  uint32_t t_bool();
  uint32_t t_int(int bits);
  uint32_t t_float(int bits);
  uint32_t t_vec3();
  uint32_t builtin_vec_t();
  uint32_t t_ptr(uint32_t sc, uint32_t elem);
  uint32_t t_fn(uint32_t ret, const std::vector<uint32_t> &params);
  uint32_t t_push_struct();   // the Ruby's t_struct(members, PUSH_OFFSET, :push)
  uint32_t c_int(int bits, int64_t v);
  uint32_t c_u32(int64_t v) { return c_int(32, v); }
  uint32_t c_u64(int64_t v) { return c_int(64, v); }
  uint32_t c_float(int bits, double v);
  uint32_t c_float_bits(int bits, uint64_t pattern);
  uint32_t c_bool(bool v);
  uint32_t spec_u32(uint32_t spec_id, uint32_t dflt);
  uint32_t workgroup_size(const std::vector<uint32_t> &ids);
  uint32_t var(uint32_t sc, uint32_t ptr_type);
  uint32_t builtin_input(uint32_t builtin);
  uint32_t push_var();
  uint32_t private_var(uint32_t elem);
  uint32_t t_array(uint32_t elem, uint32_t len);
  uint32_t wgs_var(uint32_t words);
  void add_entry(uint32_t model, uint32_t fid, const std::string &name, const std::vector<uint32_t> &iface) {
    entries_.push_back({model, fid, name, iface});
  }
  std::vector<uint32_t> finish(uint32_t version);

 private:
  struct Entry {
    uint32_t model, fid;
    std::string name;
    std::vector<uint32_t> iface;
  };
  uint32_t bound_ = 1;
  std::vector<uint32_t> caps_;
  std::vector<std::string> exts_;
  std::vector<Inst> anns_, types_, funcs_, modes_;
  std::vector<Entry> entries_;
  std::map<std::vector<int64_t>, uint32_t> memo_;
  uint32_t glsl_ = 0;
  // the memo of the Ruby (a key of a tag and integers): the id if the key is known, else 0
  uint32_t *find(const std::vector<int64_t> &k);
  uint32_t put(const std::vector<int64_t> &k, uint32_t v) { return memo_[k] = v; }
};

std::vector<uint32_t> str_words(const std::string &s);
// a double as Ruby packs it into a float ([v].pack("e")): an infinity beyond FLT_MAX
float ruby_float(double d);
