// nfcuop::hir::Graph::merge_onnx / from_onnx: the ONNX ModelProto reader, a hand-written protobuf parser for the few messages
// the writer (nfcuop_hir.cpp) writes and the tools that produce models (onnx, onnxruntime, onnxsim) emit. See nfcuop_hir.hpp.
#include <cstring>

#include "nfcuop_hir.hpp"

namespace nfcuop {
namespace hir {

namespace {

struct Bytes {
  const char* p = nullptr;
  size_t n = 0;
  std::string str() const { return std::string(p, n); }
};

// One message being read: field after field.
class Rd {
 public:
  Rd(const char* p, size_t n) : p_(p), end_(p + n) {}
  explicit Rd(const Bytes& b) : p_(b.p), end_(b.p + b.n) {}
  bool next() {
    if (p_ == end_) return false;
    uint64_t key = varint();
    field = static_cast<int>(key >> 3);
    wire = static_cast<int>(key & 7);
    switch (wire) {
      case 0: num = varint(); break;
      case 1: need(8); std::memcpy(&num, p_, 8); p_ += 8; break;
      case 2: { uint64_t len = varint(); need(len); data = Bytes{p_, static_cast<size_t>(len)}; p_ += len; break; }
      case 5: { need(4); uint32_t v; std::memcpy(&v, p_, 4); num = v; p_ += 4; break; }
      default: throw Error("onnx import: unsupported protobuf wire type " + std::to_string(wire));
    }
    return true;
  }
  int field = 0, wire = 0;
  uint64_t num = 0;  // wire 0, 1 and 5
  Bytes data;        // wire 2
  float as_float() const { uint32_t v = static_cast<uint32_t>(num); float f; std::memcpy(&f, &v, 4); return f; }
  int64_t as_int() const { return static_cast<int64_t>(num); }

 private:
  void need(uint64_t k) const { if (static_cast<uint64_t>(end_ - p_) < k) throw Error("onnx import: truncated protobuf message"); }
  uint64_t varint() {
    uint64_t v = 0;
    for (int shift = 0; shift < 64; shift += 7) {
      need(1);
      uint8_t b = static_cast<uint8_t>(*p_++);
      v |= static_cast<uint64_t>(b & 0x7f) << shift;
      if (!(b & 0x80)) return v;
    }
    throw Error("onnx import: bad varint");
  }
  const char* p_;
  const char* end_;
};

// repeated int64 fields come unpacked (one varint per field) or packed (one length-delimited blob of varints)
void read_ints(const Rd& r, std::vector<int64_t>& out) {
  if (r.wire == 0) { out.push_back(r.as_int()); return; }
  if (r.wire != 2) throw Error("onnx import: bad repeated integer field");
  Bytes b = r.data;
  const char* p = b.p;
  const char* end = b.p + b.n;
  while (p < end) {
    uint64_t v = 0;
    int shift = 0;
    for (;;) {
      if (p == end || shift > 63) throw Error("onnx import: bad packed integers");
      uint8_t c = static_cast<uint8_t>(*p++);
      v |= static_cast<uint64_t>(c & 0x7f) << shift;
      shift += 7;
      if (!(c & 0x80)) break;
    }
    out.push_back(static_cast<int64_t>(v));
  }
}
template <class T>
void read_fixed(const Rd& r, std::vector<T>& out) {  // float_data (fixed32) and double_data (fixed64)
  if (r.wire == 2) {
    if (r.data.n % sizeof(T)) throw Error("onnx import: bad packed floats");
    for (size_t k = 0; k < r.data.n; k += sizeof(T)) { T v; std::memcpy(&v, r.data.p + k, sizeof(T)); out.push_back(v); }
  } else if (r.wire == (sizeof(T) == 4 ? 5 : 1)) {
    T v;
    std::memcpy(&v, &r.num, sizeof(T));
    out.push_back(v);
  } else {
    throw Error("onnx import: bad repeated float field");
  }
}

bool dtype_of(int64_t t, DType& d) {
  switch (t) {
    case 1: d = DType::Float32; return true;
    case 6: d = DType::Int32; return true;
    case 7: d = DType::Int64; return true;
    case 9: d = DType::Bool; return true;
    case 11: d = DType::Float64; return true;
  }
  return false;
}
std::string onnx_type_name(int64_t t) {
  static const char* names[] = {"UNDEFINED", "FLOAT", "UINT8", "INT8", "UINT16", "INT16", "INT32", "INT64", "STRING", "BOOL", "FLOAT16", "DOUBLE", "UINT32", "UINT64", "COMPLEX64", "COMPLEX128", "BFLOAT16"};
  return t >= 0 && t < 17 ? names[t] : "type " + std::to_string(t);
}
DType need_dtype(int64_t t, const std::string& what) {
  DType d;
  if (!dtype_of(t, d)) throw Error("onnx import: " + what + " has element type " + onnx_type_name(t) + "; only FLOAT, DOUBLE, INT32, INT64 and BOOL are supported");
  return d;
}

struct TensorMsg {
  std::string name;
  Array a;
};

TensorMsg read_tensor(const Bytes& b) {
  TensorMsg t;
  Shape dims;
  int64_t dt = 0;
  std::string raw;
  bool has_raw = false;
  std::vector<float> fd;
  std::vector<double> dd;
  std::vector<int64_t> i32, i64;
  for (Rd r(b); r.next();) {
    switch (r.field) {
      case 1: read_ints(r, dims); break;
      case 2: dt = r.as_int(); break;
      case 4: read_fixed(r, fd); break;
      case 5: read_ints(r, i32); break;
      case 7: read_ints(r, i64); break;
      case 8: t.name = r.data.str(); break;
      case 9: raw = r.data.str(); has_raw = true; break;
      case 10: read_fixed(r, dd); break;
      case 13: throw Error("onnx import: tensor " + t.name + " uses external data");
      case 14: if (r.as_int() != 0) throw Error("onnx import: tensor " + t.name + " uses external data");
               break;
      case 3: case 6: case 11: if (r.field == 3) throw Error("onnx import: segmented tensors are not supported");
               break;
      default: break;
    }
  }
  const std::string what = "tensor " + (t.name.empty() ? std::string("(unnamed)") : t.name);
  DType d = need_dtype(dt, what);
  int64_t n = 1;
  for (int64_t k : dims) {
    if (k < 0) throw Error("onnx import: " + what + " has a negative dimension");
    n *= k;
  }
  std::vector<Scalar> v;
  v.reserve(static_cast<size_t>(n));
  if (has_raw) {
    const size_t w = d == DType::Bool ? 1 : d == DType::Int32 || d == DType::Float32 ? 4 : 8;
    if (raw.size() != static_cast<size_t>(n) * w) throw Error("onnx import: " + what + " has " + std::to_string(raw.size()) + " bytes of raw_data, expected " + std::to_string(n * static_cast<int64_t>(w)));
    for (int64_t k = 0; k < n; k++) {
      const char* p = raw.data() + static_cast<size_t>(k) * w;
      switch (d) {
        case DType::Bool: v.push_back(Scalar::from_int(d, p[0] != 0)); break;
        case DType::Int32: { int32_t x; std::memcpy(&x, p, 4); v.push_back(Scalar::from_int(d, x)); break; }
        case DType::Int64: { int64_t x; std::memcpy(&x, p, 8); v.push_back(Scalar::from_int(d, x)); break; }
        case DType::Float32: { float x; std::memcpy(&x, p, 4); v.push_back(Scalar::from_double(d, x)); break; }
        case DType::Float64: { double x; std::memcpy(&x, p, 8); v.push_back(Scalar::from_double(d, x)); break; }
      }
    }
  } else {
    size_t have = d == DType::Float32 ? fd.size() : d == DType::Float64 ? dd.size() : d == DType::Int64 ? i64.size() : i32.size();
    if (have != static_cast<size_t>(n)) throw Error("onnx import: " + what + " has " + std::to_string(have) + " values, expected " + std::to_string(n));
    for (int64_t k = 0; k < n; k++) {
      size_t q = static_cast<size_t>(k);
      switch (d) {
        case DType::Float32: v.push_back(Scalar::from_double(d, fd[q])); break;
        case DType::Float64: v.push_back(Scalar::from_double(d, dd[q])); break;
        case DType::Int64: v.push_back(Scalar::from_int(d, i64[q])); break;
        default: v.push_back(Scalar::from_int(d, i32[q])); break;  // Int32 and Bool are in int32_data
      }
    }
  }
  t.a = Array(d, dims, std::move(v));
  return t;
}

struct InfoMsg {
  std::string name;
  bool has_type = false;
  DType dtype = DType::Float32;
  Dims shape;  // integers (dim_value) and symbols (dim_param)
};

// The polynomial text of each dim_param the exporter renamed ("poly0" -> "4*N"), from the model's metadata_props.
using DimExprs = std::map<std::string, std::string>;

InfoMsg read_value_info(const Bytes& b, const DimExprs& exprs) {
  InfoMsg vi;
  int64_t elem = 0;
  bool dynamic = false;
  for (Rd r(b); r.next();) {
    if (r.field == 1) vi.name = r.data.str();
    else if (r.field == 2) {                       // TypeProto
      for (Rd t(r.data); t.next();) {
        if (t.field != 1) continue;                // tensor_type
        vi.has_type = true;
        for (Rd tt(t.data); tt.next();) {
          if (tt.field == 1) elem = tt.as_int();
          else if (tt.field == 2) {                // TensorShapeProto
            for (Rd sh(tt.data); sh.next();) {
              if (sh.field != 1) continue;         // Dimension: one of dim_value, dim_param
              bool has_value = false, has_param = false;
              int64_t dv = 0;
              std::string param;
              for (Rd dim(sh.data); dim.next();) {
                if (dim.field == 1) { has_value = true; dv = dim.as_int(); }
                else if (dim.field == 2) { has_param = true; param = dim.data.str(); }
              }
              if (has_value) vi.shape.push_back(Dim(dv));
              else if (has_param && !param.empty()) {
                auto e = exprs.find(param);   // a polynomial written under a fresh name: its text is the dimension's symbol here
                vi.shape.push_back(Dim::symbol(e == exprs.end() ? param : e->second));
              }
              else dynamic = true;
            }
          }
        }
      }
    }
  }
  if (vi.has_type) {
    if (dynamic) throw Error("onnx import: " + vi.name + " has a dynamic dimension (neither dim_value nor dim_param)");
    vi.dtype = need_dtype(elem, "value " + vi.name);
  }
  return vi;
}

Attribute read_attribute(const Bytes& b, const std::string& op) {
  std::string name, s;
  int64_t type = 0, i = 0;
  float f = 0;
  std::vector<int64_t> ints;
  std::vector<float> floats;
  bool has_t = false;
  TensorMsg t;
  for (Rd r(b); r.next();) {
    switch (r.field) {
      case 1: name = r.data.str(); break;
      case 2: f = r.as_float(); break;
      case 3: i = r.as_int(); break;
      case 4: s = r.data.str(); break;
      case 5: t = read_tensor(r.data); has_t = true; break;
      case 7: read_fixed(r, floats); break;
      case 8: read_ints(r, ints); break;
      case 20: type = r.as_int(); break;
      case 21: throw Error("onnx import: " + op + ": attribute references (ref_attr_name) are not supported");
      default: break;
    }
  }
  switch (type) {
    case 1: return Attribute::Float(name, f);
    case 2: return Attribute::Int(name, i);
    case 3: return Attribute::String(name, s);
    case 4: if (!has_t) throw Error("onnx import: " + op + ": attribute " + name + " has no tensor"); return Attribute::Tensor(name, t.a);
    case 6: return Attribute::Floats(name, std::vector<double>(floats.begin(), floats.end()));
    case 7: return Attribute::Ints(name, ints);
    default: throw Error("onnx import: " + op + ": attribute " + name + " has unsupported type " + std::to_string(type) + " (INT, INTS, FLOAT, FLOATS, STRING and TENSOR are supported)");
  }
}

struct NodeMsg {
  std::string op, name, domain;
  std::vector<std::string> in, out;
  std::vector<Attribute> attrs;
};

NodeMsg read_node(const Bytes& b) {
  NodeMsg n;
  std::vector<Bytes> attrs;
  for (Rd r(b); r.next();) {
    switch (r.field) {
      case 1: n.in.push_back(r.data.str()); break;
      case 2: n.out.push_back(r.data.str()); break;
      case 3: n.name = r.data.str(); break;
      case 4: n.op = r.data.str(); break;
      case 5: attrs.push_back(r.data); break;
      case 7: n.domain = r.data.str(); break;
      default: break;
    }
  }
  for (const Bytes& a : attrs) n.attrs.push_back(read_attribute(a, n.op));
  return n;
}

bool same_array(const Array& a, const Array& b) {
  if (a.dtype != b.dtype || a.shape != b.shape) return false;
  for (size_t k = 0; k < a.data.size(); k++) if (a.data[k] != b.data[k]) return false;
  return true;
}

}  // namespace

std::vector<int> Graph::merge_onnx(const std::string& bytes) {
  std::vector<Bytes> nodes, inits, inputs, outputs;
  int64_t opset = 0;
  bool has_graph = false;
  DimExprs exprs;
  for (Rd m(bytes.data(), bytes.size()); m.next();) {
    if (m.field == 8) {
      std::string domain;
      int64_t ver = 0;
      for (Rd o(m.data); o.next();) { if (o.field == 1) domain = o.data.str(); else if (o.field == 2) ver = o.as_int(); }
      if (domain.empty() || domain == "ai.onnx") opset = ver;
    } else if (m.field == 14) {  // metadata_props: StringStringEntryProto
      std::string key, value;
      for (Rd e(m.data); e.next();) { if (e.field == 1) key = e.data.str(); else if (e.field == 2) value = e.data.str(); }
      const std::string prefix = "nfcuop.dim_expr.";
      if (key.compare(0, prefix.size(), prefix) == 0) exprs[key.substr(prefix.size())] = value;
    } else if (m.field == 7) {
      has_graph = true;
      for (Rd g(m.data); g.next();) {
        if (g.field == 1) nodes.push_back(g.data);
        else if (g.field == 5) inits.push_back(g.data);
        else if (g.field == 11) inputs.push_back(g.data);
        else if (g.field == 12) outputs.push_back(g.data);
      }
    }
  }
  if (!has_graph) throw Error("onnx import: the model has no graph");
  if (opset < 13) throw Error("onnx import: the default-domain opset is " + std::to_string(opset) + "; opset 13 or newer is needed");

  std::map<std::string, int> local;  // name in the model -> value id here
  auto check_existing = [&](int id, DType d, const Dims& shape, const std::string& name) {
    const Value& v = value(id);
    // compared as text: a polynomial written as dim_param "4*N" is read back as a symbol of that name, which is the same size
    if (v.dtype != d || to_string(dims(id)) != to_string(shape))
      throw Error("onnx import: value " + name + " is " + std::string(nfcuop::name(d)) + to_string(shape) + " in the model but " + nfcuop::name(v.dtype) + to_string(dims(id)) + " in the graph (name collision)");
  };

  // initializers first: an input of the same name is the initializer
  std::map<std::string, int> init_names;
  for (const Bytes& b : inits) {
    TensorMsg t = read_tensor(b);
    if (t.name.empty()) throw Error("onnx import: an initializer has no name");
    init_names[t.name] = 1;
    int id = find_value(t.name);
    if (id >= 0) {
      const Array* have = initializer(id);
      if (!have || !same_array(*have, t.a)) throw Error("onnx import: initializer " + t.name + " differs from the value of that name in the graph (name collision)");
      local[t.name] = id;
    } else {
      local[t.name] = add_initializer(t.name, t.a);
    }
  }
  for (const Bytes& b : inputs) {
    InfoMsg vi = read_value_info(b, exprs);
    if (init_names.count(vi.name)) continue;
    if (!vi.has_type) throw Error("onnx import: input " + vi.name + " has no tensor type");
    int id = find_value(vi.name);
    if (id >= 0) {
      if (initializer(id) || producer(id) >= 0) throw Error("onnx import: " + vi.name + " is an input of the model but an initializer or a node output in the graph (name collision)");
      check_existing(id, vi.dtype, vi.shape, vi.name);
      local[vi.name] = id;
    } else {
      local[vi.name] = add_symbolic_input(vi.name, vi.dtype, vi.shape);
    }
  }

  auto resolve = [&](const std::string& n, const std::string& op) -> int {
    if (n.empty()) return -1;
    auto it = local.find(n);
    if (it == local.end()) throw Error("onnx import: " + op + " reads " + n + ", which no input, initializer or earlier node defines");
    return it->second;
  };
  for (const Bytes& b : nodes) {
    NodeMsg n = read_node(b);
    if (!n.domain.empty() && n.domain != "ai.onnx") throw Error("onnx import: operator " + n.op + " is in the domain " + n.domain + ", which is not supported");
    if (n.op == "Constant") {
      if (n.out.size() != 1 || n.attrs.size() != 1) throw Error("onnx import: Constant needs one output and exactly one value attribute");
      const Attribute& a = n.attrs[0];
      Array arr;
      if (a.name == "value" && a.kind == AttrKind::Tensor) arr = a.t;
      else if (a.name == "value_float" && a.kind == AttrKind::Float) arr = Array::from_doubles(DType::Float32, {}, {a.f});
      else if (a.name == "value_int" && a.kind == AttrKind::Int) arr = Array::from_doubles(DType::Int64, {}, {static_cast<double>(a.i)});
      else if (a.name == "value_floats" && a.kind == AttrKind::Floats) arr = Array::from_doubles(DType::Float32, {static_cast<int64_t>(a.floats.size())}, a.floats);
      else if (a.name == "value_ints" && a.kind == AttrKind::Ints) {
        std::vector<Scalar> v;
        for (int64_t x : a.ints) v.push_back(Scalar::from_int(DType::Int64, x));
        arr = Array(DType::Int64, {static_cast<int64_t>(a.ints.size())}, std::move(v));
      } else throw Error("onnx import: Constant attribute " + a.name + " is not supported");
      int id = find_value(n.out[0]);
      if (id >= 0) {
        const Array* have = initializer(id);
        if (!have || !same_array(*have, arr)) throw Error("onnx import: Constant " + n.out[0] + " differs from the value of that name in the graph (name collision)");
        local[n.out[0]] = id;
      } else {
        local[n.out[0]] = add_initializer(n.out[0], arr);
      }
      continue;
    }
    if (n.out.empty() || n.out[0].empty()) throw Error("onnx import: " + n.op + " has no output name");
    for (size_t k = 1; k < n.out.size(); k++)
      if (!n.out[k].empty()) throw Error("onnx import: " + n.op + " has several outputs; only single-output operators are supported");
    int have = find_value(n.out[0]);
    if (have >= 0) {  // a node of this graph that the model carries along: reuse it
      int p = producer(have);
      if (p < 0 || nodes_[static_cast<size_t>(p)].op != n.op) throw Error("onnx import: " + n.op + " produces " + n.out[0] + ", a different kind of value in the graph (name collision)");
      local[n.out[0]] = have;
      continue;
    }
    std::vector<int> ins;
    for (const std::string& s : n.in) ins.push_back(resolve(s, n.op));
    // opset 13..17: ReduceMean/ReduceMax/ReduceMin take `axes` as an attribute (ReduceSum has the input since 13, ReduceProd since 18)
    std::vector<Attribute> attrs;
    for (const Attribute& a : n.attrs) {
      if ((n.op == "ReduceMean" || n.op == "ReduceMax" || n.op == "ReduceMin" || n.op == "ReduceProd") && a.name == "axes" && a.kind == AttrKind::Ints) {
        if (ins.size() > 1) throw Error("onnx import: " + n.op + " has axes as an attribute and as an input");
        std::vector<Scalar> v;
        for (int64_t x : a.ints) v.push_back(Scalar::from_int(DType::Int64, x));
        std::string nm = n.out[0] + "_axes";
        while (find_value(nm) >= 0) nm += "_";
        ins.push_back(add_initializer(nm, Array(DType::Int64, {static_cast<int64_t>(a.ints.size())}, std::move(v))));
      } else {
        attrs.push_back(a);
      }
    }
    if (!is_onnx_operator(n.op)) throw Error("onnx import: " + n.op + " is not an ONNX operator");
    int out = add_node_named(n.op, ins, attrs, n.out[0], n.name);
    local[n.out[0]] = out;
  }

  std::vector<int> result;
  for (const Bytes& b : outputs) {
    InfoMsg vi = read_value_info(b, exprs);
    auto it = local.find(vi.name);
    if (it == local.end()) throw Error("onnx import: graph output " + vi.name + " is not defined");
    if (vi.has_type) check_existing(it->second, vi.dtype, vi.shape, vi.name);
    result.push_back(it->second);
  }
  return result;
}

Graph Graph::from_onnx(const std::string& bytes, std::vector<int>* outputs) {
  Graph g;
  std::vector<int> o = g.merge_onnx(bytes);
  if (outputs) *outputs = o;
  return g;
}

}  // namespace hir
}  // namespace nfcuop
