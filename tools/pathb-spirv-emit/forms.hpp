// The IR types, the passes on function forms and the static region (scripts/pathb-spirv-emit.rb: parse_type, collect_calls,
// expand_cxa_vec_ctor, fold_fnptr_slots, scan_slots, wgs_layout, kernel_key, class Mod).
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "ir.hpp"

// An IR scalar type: the Ruby's ["int", size, signed, bool], ["float", size], ["ptr"], ["void"].
struct Ty {
  enum K : uint8_t { Void, Int, Float, Ptr };
  K k = Void;
  int size = 0;
  bool sign = false;
  bool boolean = false;
  bool operator==(const Ty &o) const { return k == o.k && size == o.size && sign == o.sign && boolean == o.boolean; }
  bool operator!=(const Ty &o) const { return !(*this == o); }
  const char *kind_name() const {
    switch (k) {
      case Int: return "int";
      case Float: return "float";
      case Ptr: return "ptr";
      default: return "void";
    }
  }
};

inline Ty ty_int(int size, bool sign, bool boolean = false) { return Ty{Ty::Int, size, sign, boolean}; }
inline Ty ty_float(int size) { return Ty{Ty::Float, size, false, false}; }
inline Ty ty_ptr() { return Ty{Ty::Ptr, 0, false, false}; }
inline Ty ty_void() { return Ty{}; }
inline const Ty U32 = ty_int(4, false);
inline const Ty U8 = ty_int(1, false);
inline const Ty BOOL4 = ty_int(4, false, true);   // the Ruby's ["int", 4, false, true]: a comparison's value

Ty parse_type(const Node &x);
std::optional<Ty> parse_type_safe(const Node &x);
bool scalar_form(const Node &x);
inline bool int_ty(const Ty &t) { return t.k == Ty::Int && !t.boolean; }
inline bool bool_ty(const Ty &t) { return t.k == Ty::Int && t.boolean; }

// Insertion-ordered map (the Ruby's Hash): re-setting a key keeps its place.
template <class V> struct OMap {
  std::vector<std::string> keys;
  std::unordered_map<std::string, V> map;
  bool has(const std::string &k) const { return map.count(k) != 0; }
  V &set(const std::string &k, V v) {
    auto it = map.find(k);
    if (it == map.end()) {
      keys.push_back(k);
      return map.emplace(k, std::move(v)).first->second;
    }
    it->second = std::move(v);
    return it->second;
  }
  V *get(const std::string &k) {
    auto it = map.find(k);
    return it == map.end() ? nullptr : &it->second;
  }
  const V *get(const std::string &k) const {
    auto it = map.find(k);
    return it == map.end() ? nullptr : &it->second;
  }
  size_t size() const { return keys.size(); }
};

// the callees a form calls directly (&"name" in the callee position), in the order met
void collect_calls(const Node &x, std::vector<std::string> &acc);
// the functions a form names by address (calls, and the addresses it stores or passes)
void collect_fn_refs(const Node &x, std::vector<std::string> &acc);
// unrolls the __cxa_vec_ctor calls of a function form (in place)
void expand_cxa_vec_ctor(Node &body);
// folds the constexpr function-pointer slots of a body (the function's statements: pointers into its form)
void fold_fnptr_slots(std::vector<Node *> &body, const std::vector<const Node *> &slots);
// the slots a body loads and stores directly (with the access types) and the slots whose address escapes
void scan_slots(const Node &x, std::unordered_map<std::string, std::vector<std::optional<Ty>>> &direct,
                std::unordered_set<std::string> &escaped);
bool mentions_wgs(const Node &t);
// the closure type a kernel entry casts __nfcxx_sycl_closure() to: [manifest key, struct name], or false
bool kernel_key(const Node &form, std::string &key, std::string &found);

// the IR text of a float to its value, as Ruby's String#to_f reads it
double ruby_to_f(const std::string &text);

// The unit's definitions and the static region (the Ruby's class Mod).
struct Mod {
  OMap<Node *> defs;      // IR name => function form
  OMap<Node *> globals;   // IR name => global form
  OMap<Node *> datas;     // IR name => data form (string literals)
  std::unordered_set<std::string> empty_types;
  OMap<int64_t> statics;  // name => byte offset in the static region (the objects a kernel uses)
  std::vector<std::string> static_order;
  int64_t static_size = 0;

  int64_t static_offset(const std::string &name);
  std::vector<uint8_t> static_bytes(const Node &d) const;
  void static_image(std::vector<uint8_t> &bytes, std::vector<std::pair<int64_t, int64_t>> &relocs);
};

extern const char *const EH_RUNTIME_STATE[4];
extern const char *const GLIBCXX_ASSERT_FAIL;
