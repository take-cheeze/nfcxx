// nfcast: a self-specializing AST interpreter for a Lua 5.4 subset (docs/notes/ast.md).
//
// The source is parsed into a tree of nodes that evaluate themselves. A node starts generic, watches the types that reach
// it and rewrites itself into a specialized node (integer addition, a table field with an inline cache, a call of a
// known kind); a guard that fails falls back to a generic node. Values are tagged (nil, boolean, 64-bit integer, double,
// string, table, function, host object); collectable objects live in one heap with a precise mark-and-sweep collector.
//
// This header is what a host needs: values, the heap objects it may create, State, and the error type. The node classes
// are private (nfcast_impl.hpp). Not thread safe: one State is used by one thread at a time.
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

namespace nfcast {

struct State;
struct GCObject;
struct String;
struct Table;
struct Closure;
struct Native;
struct HostObject;
struct Cell;
struct Proto;
struct Frame;
struct Node;

// T_DEAD is a table key whose value was removed and whose object may be gone (never dereferenced); T_CELL is the box of a
// captured local in a frame slot. Neither is ever visible to a script.
enum Tag : std::uint8_t {
  T_NIL = 0,
  T_FALSE = 1,
  T_TRUE = 2,
  T_INT = 3,
  T_FLT = 4,
  T_DEAD = 5,
  T_STR = 6,
  T_TAB = 7,
  T_FUN = 8,
  T_HOST = 9,
  T_CELL = 10
};

enum GCType : std::uint8_t { G_STRING, G_TABLE, G_CLOSURE, G_NATIVE, G_CELL, G_HOST };

struct GCObject {
  GCObject* gcnext;
  GCType gctype;
  std::uint8_t marked;
};

// A value: 16 bytes. Truthiness is `t >= T_TRUE`; the collectable kinds are `t >= T_STR`.
struct Value {
  Tag t;
  union {
    std::int64_t i;
    double d;
    GCObject* o;
  };
  Value() : t(T_NIL), i(0) {}
  static Value boolean(bool b) {
    Value v;
    v.t = b ? T_TRUE : T_FALSE;
    return v;
  }
  static Value integer(std::int64_t n) {
    Value v;
    v.t = T_INT;
    v.i = n;
    return v;
  }
  static Value number(double x) {
    Value v;
    v.t = T_FLT;
    v.d = x;
    return v;
  }
  static Value object(Tag t, GCObject* p) {
    Value v;
    v.t = t;
    v.o = p;
    return v;
  }
  static Value str(String* s) { return object(T_STR, reinterpret_cast<GCObject*>(s)); }
  static Value table(Table* x) { return object(T_TAB, reinterpret_cast<GCObject*>(x)); }
  static Value function(Closure* x) { return object(T_FUN, reinterpret_cast<GCObject*>(x)); }
  static Value function(Native* x) { return object(T_FUN, reinterpret_cast<GCObject*>(x)); }
  static Value host(HostObject* x);  // HostObject has a vtable: the GCObject base is not at offset 0, so it is converted, not cast

  bool is_nil() const { return t == T_NIL; }
  bool truthy() const { return t >= T_TRUE; }
  bool is_gc() const { return t >= T_STR; }
  bool is_number() const { return t == T_INT || t == T_FLT; }
  bool is_bool() const { return t == T_FALSE || t == T_TRUE; }
  String* s() const { return reinterpret_cast<String*>(o); }
  Table* tab() const { return reinterpret_cast<Table*>(o); }
  HostObject* hostobj() const;
  bool is_closure() const;
  bool is_native() const;
  Closure* closure() const { return reinterpret_cast<Closure*>(o); }
  Native* native() const { return reinterpret_cast<Native*>(o); }
};

// ---- strings ----------------------------------------------------------------------------------------------------
// Strings of up to 40 bytes are interned (equal contents, equal pointer); longer ones are compared by content.
struct String : GCObject {
  std::uint32_t hash;
  std::uint32_t len;
  String* hnext;  // the intern table's chain
  bool interned;
  const char* data() const { return reinterpret_cast<const char*>(this + 1); }
  char* mdata() { return reinterpret_cast<char*>(this + 1); }
  std::string_view view() const { return std::string_view(data(), len); }
};

// ---- tables -----------------------------------------------------------------------------------------------------
// An array part for the keys 1..asize and a hash part (open addressing, linear probing; a removed key stays as a dead key
// with a nil value until the next rehash, so that `next` keeps working while a loop clears fields).
struct TNode {
  Value key;
  Value val;
};

struct Table : GCObject {
  Value* arr;
  std::uint32_t asize, acap;
  TNode* nodes;
  std::uint32_t hcap;   // a power of two, or 0
  std::uint32_t hused;  // occupied nodes, dead keys included
  Table* meta;
  std::uint8_t absent;  // bit k set: metamethod k is known to be absent (reset whenever the table is written)

  Value get(const Value& k) const;
  Value get_int(std::int64_t k) const {
    if (static_cast<std::uint64_t>(k) - 1u < asize) return arr[k - 1];
    return get_int_hash(k);
  }
  Value get_int_hash(std::int64_t k) const;
  Value get_str(const String* k) const;
  // The index of the node whose key is the string K, or -1.
  long find_str(const String* k) const;
  // Raw writes. The key must not be nil or NaN (the caller checks); a float key with an integer value is normalized.
  void set(State& S, const Value& k, const Value& v);
  void set_int(State& S, std::int64_t k, const Value& v);
  void set_str(State& S, String* k, const Value& v);
  // A border (`#t` without metamethods).
  std::int64_t length() const;
  // Iteration: the entry after KEY (nil: the first). Returns false at the end. KEY not in the table throws an error.
  bool next(State& S, Value& key, Value& val) const;
  void reserve_array(State& S, std::uint32_t n);
  // Moves the keys asize+1, asize+2, ... that wait in the hash part into the array part.
  void absorb(State& S);
};

// ---- functions --------------------------------------------------------------------------------------------------
struct Cell : GCObject {  // a local variable that a closure captured
  Value v;
};

struct Closure : GCObject {
  Proto* proto;
  std::uint32_t nup;
  Cell** up;
};

// The arguments of a native function, and where its results go.
struct Args {
  Value* v;
  int n;
  Value operator[](int k) const { return k < n ? v[k] : Value(); }
};

struct Rets {
  Value* p;
  int n, cap;
  alignas(Value) unsigned char buf[3 * sizeof(Value)];
  Rets() : p(reinterpret_cast<Value*>(buf)), n(0), cap(3) {}
  ~Rets() {
    if (p != reinterpret_cast<Value*>(buf)) std::free(p);
  }
  Rets(const Rets&) = delete;
  Rets& operator=(const Rets&) = delete;
  void push(const Value& v) {
    if (n == cap) grow();
    p[n++] = v;
  }
  Value first() const { return n ? p[0] : Value(); }
  void grow();
};

typedef void (*NativeFn)(State& S, Args a, Rets& r, Native& self);

struct Native : GCObject {
  NativeFn fn;
  const char* name;
  void* data;  // for the host's use
  Value up;    // one upvalue (a bound receiver, say); marked by the collector
};

// A host object: a value the script can index, assign to, call methods on and compare, whose behavior the host
// implements. Allocate with State::new_host; the collector deletes it when it is unreachable (release() first).
struct HostMember {
  virtual ~HostMember() {}
  bool is_method = false;
  virtual Value get(State& S, HostObject* self) = 0;               // a property read; for a method, the bound function
  virtual void set(State& S, HostObject* self, const Value& v) = 0;  // a property write (throws if read-only)
  virtual void call(State& S, HostObject* self, Args a, Rets& r) = 0;  // obj:method(args); A excludes the receiver
};

struct HostObject : GCObject {
  virtual ~HostObject() {}
  // Objects of one class return the same key: the inline caches of the nodes are keyed by it.
  virtual const void* type_key() const = 0;
  // The member NAME of this object's class, or null. The member must outlive the State (nodes cache it).
  virtual HostMember* member(State& S, String* name) = 0;
  virtual std::string describe() const { return "userdata"; }
  virtual bool same_as(const HostObject* other) const { return this == other; }  // for ==
};

// ---- errors -----------------------------------------------------------------------------------------------------
// A script error in flight: the C++ exception that unwinds the evaluator (and runs the destructors of the host frames
// it crosses). V is the error value; TRACE the call stack where it was raised, filled in when no pcall is active.
struct Thrown {
  Value v;
  std::vector<std::string> trace;
};

struct Stats {
  std::uint64_t rewrites = 0;       // nodes that replaced themselves with a specialized or a generic node
  std::uint64_t deopts = 0;         // of those, rewrites away from a specialized node after a guard failed
  std::uint64_t generic_ops = 0;    // operations that took a slow path (arithmetic, comparison, index, call, concat)
  std::uint64_t gc_cycles = 0;
};

// ---- the interpreter ----------------------------------------------------------------------------------------------
struct State {
  State();
  ~State();
  State(const State&) = delete;
  State& operator=(const State&) = delete;

  // Compiles CODE as a chunk (a vararg function); null with *ERR set ("chunk:line: message near ...") on a syntax error.
  Closure* load(std::string_view code, const std::string& chunkname, std::string* err);
  // Calls FN with N arguments, appending its results to OUT. Throws Thrown.
  void call(const Value& fn, const Value* args, int n, Rets& out);

  // ---- creating values ----
  String* str(std::string_view s);
  Value strv(std::string_view s) { return Value::str(str(s)); }
  Table* new_table(std::uint32_t narr = 0, std::uint32_t nhash = 0);
  Native* new_native(NativeFn fn, const char* name, void* data = nullptr, const Value& up = Value());
  template <class T, class... A>
  T* new_host(A&&... a) {
    T* h = new T(static_cast<A&&>(a)...);
    link_host(h);
    return h;
  }
  void link_host(HostObject* h);

  // ---- globals and the standard library ----
  Table* globals = nullptr;
  Table* string_meta = nullptr;  // the metatable of every string; its __index is the string library
  void open_libs();               // base, string, table, math

  // ---- values that must survive collections: pins, and the stack ----
  int pin(const Value& v);
  void unpin(int id);
  Value pinned(int id) const { return pins[static_cast<std::size_t>(id)]; }

  // ---- collection ----
  void collect();
  std::size_t gc_bytes() const { return bytes; }
  std::size_t gc_threshold = 1 << 20;
  bool gc_stress = false;  // collect at every safe point (a function entry, a loop iteration), for tests; NFCAST_GC_STRESS=1

  // ---- errors ----
  [[noreturn]] void error(const Value& v);                // raise V as is
  [[noreturn]] void rt_error(const std::string& msg);       // "chunk:line: msg" of the running script frame
  [[noreturn]] void arg_error(int argn, const char* fname, const std::string& msg);  // "bad argument #n to 'f' (msg)"
  std::vector<std::string> traceback() const;
  const char* keep_name(const std::string& s);  // a string that lives as long as the State (native function names)

  // ---- operations as the script does them (metamethods included) ----
  Value index(const Value& obj, const Value& key);
  void setindex(const Value& obj, const Value& key, const Value& val);

  // ---- conversions ----
  std::string tostring(const Value& v);  // honors __tostring
  static const char* type_name(const Value& v);
  Table* metatable_of(const Value& v) const;
  Value metamethod(const Value& v, const char* event);  // nil when none

  Stats stats;
  void* userdata = nullptr;  // for the host's use (the nfcpoly backend keeps its Lang here)

  // ---- internal ----
  struct Impl;
  Impl* impl;
  std::size_t bytes = 0;
  Value* stack = nullptr;
  Value* stack_end = nullptr;
  Value* top = nullptr;
  Frame* cur = nullptr;
  int depth = 0;
  int max_depth = 1500;  // nested script calls; the evaluator recurses on the C++ stack (about 1 KB per level)
  int pcall_depth = 0;
  // The native function being run and how it was called: from a node (CALL_WHERE names the callee there, for "bad argument #1
  // to 'rep'") or from another native (NFN: errors get no position and use the qualified name, as Lua does).
  Node* call_where = nullptr;
  Native* cur_native = nullptr;
  bool nfn = false;
  std::vector<Value> pins;
  std::vector<int> free_pins;
  std::vector<Value> extra_roots;  // temporaries held by native code across a call into the script
  Value pending;                    // the error value in flight
  Native* next_fn = nullptr;        // the `next` function (for-in recognizes it)
  Native* ipairs_iter = nullptr;
  GCObject* all = nullptr;
};

inline Value Value::host(HostObject* x) { return object(T_HOST, static_cast<GCObject*>(x)); }
inline HostObject* Value::hostobj() const { return static_cast<HostObject*>(o); }
inline bool Value::is_closure() const { return t == T_FUN && o->gctype == G_CLOSURE; }
inline bool Value::is_native() const { return t == T_FUN && o->gctype == G_NATIVE; }

// Number formatting and parsing exactly as Lua does it ("%.14g", integral floats print with ".0").
std::string number_to_string(const Value& v);
// A string as a number (decimal, hex, exponent, surrounding spaces); false when it is not one.
bool string_to_number(std::string_view s, Value* out);
// A float with an exact integer value as that integer.
bool float_to_integer(double d, std::int64_t* out);

}  // namespace nfcast
