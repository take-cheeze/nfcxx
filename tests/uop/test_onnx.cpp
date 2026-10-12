// The ONNX reader (hir::Graph::from_onnx / merge_onnx, lib/uop/nfcuop_onnx_import.cpp): round trips with the writer (bytes equal),
// models made by the onnx package and computed by onnxruntime (written by tests/uop/onnx_import_gen.py into argv[1]), merging a
// model into the graph it was exported from, name collisions, errors, and the Pad operator. Needs no Python (the models of
// argv[1] are skipped when the directory is missing or empty).
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "nfcuop_np.hpp"

using namespace nfcuop;
using namespace nfcuop::np;

static int checks = 0, failed = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond)) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
// the statement must throw an Error whose message contains `frag`
#define CHECK_ERR(expr, frag)                                              \
  do {                                                                     \
    checks++;                                                              \
    std::string msg_;                                                      \
    bool threw_ = false;                                                   \
    try { (void)(expr); } catch (const Error& e) { threw_ = true; msg_ = e.what(); } \
    if (!threw_ || msg_.find(frag) == std::string::npos) { failed++; std::printf("FAIL %s:%d: %s: error \"%s\" lacks \"%s\"\n", __FILE__, __LINE__, #expr, msg_.c_str(), frag); } \
  } while (0)

using V = std::vector<double>;
static const DType f32 = DType::Float32, f64 = DType::Float64, i32 = DType::Int32, i64 = DType::Int64;
static Array arr(DType d, const Shape& s, const V& v) { return Array::from_doubles(d, s, v); }
static V vals(const Array& a) { V v; for (const Scalar& s : a.data) v.push_back(s.as_double()); return v; }
static bool near(const V& a, const V& b, double tol) {
  if (a.size() != b.size()) return false;
  for (size_t k = 0; k < a.size(); k++) {
    if (std::isnan(a[k]) && std::isnan(b[k])) continue;
    if (!(std::fabs(a[k] - b[k]) <= tol * (1 + std::fabs(b[k])))) return false;
  }
  return true;
}
static V rand_vec(int64_t n, unsigned seed) {
  V v;
  uint64_t s = 0x9E3779B97F4A7C15ull * (seed + 1);
  for (int64_t k = 0; k < n; k++) {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    v.push_back(static_cast<double>(s >> 11) / 9007199254740992.0 * 2 - 1);
  }
  return v;
}
static Array ints(const std::vector<int64_t>& v) {
  Array a(i64, {static_cast<int64_t>(v.size())}, {});
  for (int64_t q : v) a.data.push_back(Scalar::from_int(i64, q));
  return a;
}

// ---- (a) export -> import -> export gives the same bytes, and the same results ----

static void round_trips() {
  Session s;
  s.default_float = f64;
  Tensor x = s.placeholder("x", {2, 3, 4}), w = s.placeholder("w", {4, 3});
  Tensor t = s.array(rand_vec(12, 3), {3, 4});
  Tensor h = (matmul(x, w).tanh() + 1.0).softmax(1);
  Tensor c = concatenate({h, h * 2.0}, 2).slice(2, 1, None, 2).transpose({1, 0, 2});
  Tensor m = where(x > 0.0, x * t, x.abs()).max(2, true).sum(1).reshape({2, 1}).expand_dims(0).squeeze(0);
  Tensor ints_ = s.array({1, 2, 3, 4}, {4}, i32);
  Tensor out = c.sum(2).sum(0) + m.mean() + (ints_.astype(f64) * 0.5).sum() + (x.astype(DType::Float32).sum()).astype(f64) + s.arange(3).astype(f64).sum();
  Tensor flag = (out > 0.0) | (out < -1.0);
  Tensor padded = x.slice(0, 0, 1).reshape({3, 4}) + 0.0;
  std::string bytes = s.to_onnx({{"out", out}, {"flag", flag}, {"c", c}, {"padded", padded}});
  std::vector<int> outs;
  hir::Graph g2 = hir::Graph::from_onnx(bytes, &outs);
  CHECK(outs.size() == 4);
  CHECK(g2.to_onnx(outs) == bytes);
  // the same results
  std::map<std::string, Array> feeds{{"x", arr(f64, {2, 3, 4}, rand_vec(24, 1))}, {"w", arr(f64, {4, 3}, rand_vec(12, 2))}};
  std::vector<Array> want = s.eval_all({out, flag, c, padded}, feeds);
  ut::Session u;
  hir::Lowerer low(g2, u);
  for (size_t k = 0; k < outs.size(); k++) {
    Array got = u.eval(low.get(outs[k]), feeds);
    CHECK(got.dtype == want[k].dtype && got.shape == want[k].shape && near(vals(got), vals(want[k]), 0));
  }
  // importing twice and exporting again is stable
  std::vector<int> outs3;
  hir::Graph g3 = hir::Graph::from_onnx(g2.to_onnx(outs), &outs3);
  CHECK(g3.to_onnx(outs3) == bytes);
}

// attributes of every kind survive a round trip
static void attributes() {
  using hir::Attribute;
  hir::Graph g;
  int x = g.add_input("x", f32, {2});
  Array t = arr(f64, {2}, V{1.5, -2});
  int y = g.add_node("Identity", {x}, {Attribute::Float("alpha", 0.25), Attribute::Floats("coeffs", {1, 2.5, -3}), Attribute::Tensor("value", t), Attribute::String("note", "hi"),
                                      Attribute::Int("k", -7), Attribute::Ints("axes", {0, -1})});
  std::string bytes = g.to_onnx({y});
  std::vector<int> outs;
  hir::Graph g2 = hir::Graph::from_onnx(bytes, &outs);
  CHECK(g2.to_onnx(outs) == bytes);
  const hir::Node& n = g2.nodes()[0];
  CHECK(n.attr("alpha") && n.attr("alpha")->kind == hir::AttrKind::Float && n.attr("alpha")->f == 0.25);
  CHECK(n.attr("coeffs") && n.attr("coeffs")->floats == (V{1, 2.5, -3}));
  CHECK(n.attr("value") && n.attr("value")->t.dtype == f64 && vals(n.attr("value")->t) == (V{1.5, -2}));
  CHECK(n.attr("note") && n.attr("note")->s == "hi" && n.attr_int("k", 0) == -7 && n.attr("axes")->ints == (std::vector<int64_t>{0, -1}));
  CHECK(g2.str().find("alpha=") != std::string::npos);
}

// ---- (b) models made by the onnx package, computed by onnxruntime ----

static std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

// a tiny JSON reader for {"inputs": {name: {dtype, shape, data}}, "outputs": {...}} (the layout of onnx_check.py)
struct Json {
  const std::string& s;
  size_t p = 0;
  explicit Json(const std::string& str) : s(str) {}
  void ws() { while (p < s.size() && std::isspace(static_cast<unsigned char>(s[p]))) p++; }
  std::string str() { ws(); p++; std::string o; while (s[p] != '"') o += s[p++]; p++; return o; }
  bool eat(char c) { ws(); if (s[p] == c) { p++; return true; } return false; }
  double num() {
    ws();
    if (s.compare(p, 4, "null") == 0) { p += 4; return std::nan(""); }
    if (s.compare(p, 4, "true") == 0) { p += 4; return 1; }
    if (s.compare(p, 5, "false") == 0) { p += 5; return 0; }
    size_t q = p;
    double d = std::strtod(s.c_str() + p, nullptr);
    while (q < s.size() && (std::isalnum(static_cast<unsigned char>(s[q])) || s[q] == '.' || s[q] == '-' || s[q] == '+')) q++;
    p = q;
    return d;
  }
  Array array() {
    std::string dt;
    Shape shape;
    V data;
    eat('{');
    while (!eat('}')) {
      std::string k = str();
      eat(':');
      if (k == "dtype") dt = str();
      else if (k == "shape") { eat('['); while (!eat(']')) { shape.push_back(static_cast<int64_t>(num())); eat(','); } }
      else { eat('['); while (!eat(']')) { data.push_back(num()); eat(','); } }
      eat(',');
    }
    DType d = dt == "bool" ? DType::Bool : dt == "int32" ? i32 : dt == "int64" ? i64 : dt == "float32" ? f32 : f64;
    return arr(d, shape, data);
  }
  std::map<std::string, Array> object() {
    std::map<std::string, Array> m;
    eat('{');
    while (!eat('}')) { std::string k = str(); eat(':'); m[k] = array(); eat(','); }
    return m;
  }
};

static int imported_models = 0;
static void python_models(const std::string& dir, const std::vector<std::string>& names) {
  for (const std::string& name : names) {
    std::string model = slurp(dir + "/" + name + ".onnx"), js = slurp(dir + "/" + name + ".json");
    if (model.empty() || js.empty()) continue;
    std::map<std::string, Array> ins, want;
    {
      Json j(js);
      j.eat('{');
      while (!j.eat('}')) {
        std::string k = j.str();
        j.eat(':');
        (k == "inputs" ? ins : want) = j.object();
        j.eat(',');
      }
    }
    std::vector<int> outs;
    try {
      hir::Graph g = hir::Graph::from_onnx(model, &outs);
      ut::Session u;
      hir::Lowerer low(g, u);
      std::map<std::string, Array> feeds;
      for (const auto& kv : ins) if (g.find_value(kv.first) >= 0 && g.producer(g.find_value(kv.first)) < 0 && !g.initializer(g.find_value(kv.first))) feeds[kv.first] = kv.second;
      size_t k = 0;
      bool ok = outs.size() == want.size();
      for (const auto& kv : want) {   // the outputs are named like the model's outputs; std::map orders them by name
        int id = g.find_value(kv.first);
        ok = ok && id >= 0;
        if (id < 0) break;
        Array got = u.eval(low.get(id), feeds);
        bool eq = got.dtype == kv.second.dtype && got.shape == kv.second.shape && near(vals(got), vals(kv.second), 1e-5);
        if (!eq) std::printf("  %s/%s differs from onnxruntime\n", name.c_str(), kv.first.c_str());
        ok = ok && eq;
        k++;
      }
      CHECK(ok);
      // export, import, export is stable for what came from outside too
      std::string again = g.to_onnx(outs);
      std::vector<int> o2;
      hir::Graph g2 = hir::Graph::from_onnx(again, &o2);
      CHECK(g2.to_onnx(o2) == again);
      imported_models++;
    } catch (const Error& e) {
      CHECK(false);
      std::printf("  %s: %s\n", name.c_str(), e.what());
    }
  }
}

// ---- (c) merging a model into the graph it was exported from ----

static void merging() {
  using hir::Attribute;
  auto build = [](bool big, int* loss, int* mm) {
    auto g = std::unique_ptr<hir::Graph>(new hir::Graph);
    int x = g->add_input("x", f64, {2, 3});
    int w = g->add_input("w", f64, {3, 2});
    *mm = g->add_node("MatMul", {x, w}, {}, "mm");
    *loss = -1;
    if (big) {
      int r = g->add_node("Relu", {*mm}, {}, "r");
      *loss = g->add_node("ReduceSum", {r}, {Attribute::Int("keepdims", 0)}, "loss");
    }
    return g;
  };
  int loss = 0, mm = 0, tmp = 0;
  auto big = build(true, &loss, &mm);
  auto small = build(false, &tmp, &mm);
  std::string bytes = big->to_onnx({loss});
  size_t before = small->num_values();
  std::vector<int> out = small->merge_onnx(bytes);
  CHECK(out.size() == 1 && small->value(out[0]).name == "loss" && small->value(out[0]).shape.empty());
  CHECK(small->nodes().size() == 3 && small->value(mm).name == "mm" && small->producer(mm) == 0);   // x and w, mm: the existing ones
  CHECK(small->num_values() == before + 2);                                                           // r and loss (ReduceSum without axes has no axes initializer)
  CHECK(small->inputs().size() == 2);
  // again: nothing new
  size_t nodes_now = small->nodes().size(), values_now = small->num_values();
  std::vector<int> out2 = small->merge_onnx(bytes);
  CHECK(out2 == out && small->nodes().size() == nodes_now && small->num_values() == values_now);
  // the merged graph computes the same as the original
  ut::Session u1, u2;
  hir::Lowerer l1(*big, u1), l2(*small, u2);
  std::map<std::string, Array> feeds{{"x", arr(f64, {2, 3}, rand_vec(6, 5))}, {"w", arr(f64, {3, 2}, rand_vec(6, 6))}};
  CHECK(near(vals(u1.eval(l1.get(loss), feeds)), vals(u2.eval(l2.get(out[0]), feeds)), 0));
  // the new values can be built on
  int more = small->add_node("Neg", {out[0]});
  CHECK(small->value(more).shape.empty());

  // collisions: a value of the same name that is not the same
  {
    hir::Graph a;
    a.add_input("x", f64, {2, 3});
    a.add_input("w", f64, {4, 2});   // another shape than in the model
    CHECK_ERR(a.merge_onnx(bytes), "name collision");
  }
  {
    hir::Graph a;
    int x = a.add_input("x", f64, {2, 3});
    int w = a.add_input("w", f64, {3, 2});
    a.add_node("Neg", {x}, {}, "mm");   // "mm" is a Neg here, a MatMul there
    (void)w;
    CHECK_ERR(a.merge_onnx(bytes), "name collision");
  }
  {
    hir::Graph a;
    a.add_input("x", f64, {2, 3});
    a.add_initializer("w", arr(f64, {3, 2}, V(6, 1.0)));   // an initializer where the model has an input
    CHECK_ERR(a.merge_onnx(bytes), "name collision");
  }
  {  // an initializer with the same name and another content
    hir::Graph a;
    int x = a.add_input("x", f64, {2});
    int c = a.add_initializer("c", arr(f64, {2}, V{1, 2}));
    int y = a.add_node("Add", {x, c}, {}, "y");
    std::string m = a.to_onnx({y});
    hir::Graph b;
    b.add_input("x", f64, {2});
    b.add_initializer("c", arr(f64, {2}, V{1, 3}));
    CHECK_ERR(b.merge_onnx(m), "name collision");
    hir::Graph ok;
    ok.add_input("x", f64, {2});
    int c2 = ok.add_initializer("c", arr(f64, {2}, V{1, 2}));
    std::vector<int> o = ok.merge_onnx(m);
    CHECK(ok.producer(o[0]) == 0 && ok.nodes()[0].inputs[1] == c2);
  }
  // automatic names never collide with names that came in: a model with a value called v3 in a graph that numbers its values from 0
  {
    hir::Graph a;
    int x = a.add_input("x", f64, {2});
    int y = a.add_node("Neg", {x}, {}, "v3");
    std::string m = a.to_onnx({y});
    hir::Graph b;
    std::vector<int> o = b.merge_onnx(m);
    int p = b.add_node("Neg", {o[0]}), q = b.add_node("Neg", {p}), r = b.add_node("Neg", {q});
    std::set<std::string> names;
    for (int id : {0, 1, o[0], p, q, r}) names.insert(b.value(id).name);
    CHECK(names.size() == 5 || names.size() == 6);
    for (size_t k = 0; k < b.num_values(); k++) CHECK(b.find_value(b.value(static_cast<int>(k)).name) == static_cast<int>(k));
  }
}

// ---- (d) a tiny hand-made ModelProto, for the errors ----

namespace {
struct W {
  std::string b;
  void varint(uint64_t v) { while (v >= 0x80) { b.push_back(static_cast<char>(v | 0x80)); v >>= 7; } b.push_back(static_cast<char>(v)); }
  void i(int f, int64_t v) { varint(static_cast<uint64_t>(f) << 3); varint(static_cast<uint64_t>(v)); }
  void s(int f, const std::string& v) { varint(static_cast<uint64_t>(f) << 3 | 2); varint(v.size()); b += v; }
  void m(int f, const W& w) { s(f, w.b); }
};
W value_info(const std::string& name, int dt, const std::vector<int64_t>& dims, bool dynamic = false) {
  W shape;
  for (int64_t d : dims) { W dim; if (dynamic) dim.s(2, "N"); else dim.i(1, d); shape.m(1, dim); }
  W tensor; tensor.i(1, dt); tensor.m(2, shape);
  W type; type.m(1, tensor);
  W vi; vi.s(1, name); vi.m(2, type);
  return vi;
}
W node(const std::string& op, const std::vector<std::string>& in, const std::vector<std::string>& out) {
  W n;
  for (const auto& i : in) n.s(1, i);
  for (const auto& o : out) n.s(2, o);
  n.s(4, op);
  return n;
}
std::string model(const std::vector<W>& nodes, const std::vector<W>& inputs, const std::vector<W>& outputs, int64_t opset = 18, const std::vector<W>& inits = {}) {
  W g;
  for (const W& n : nodes) g.m(1, n);
  g.s(2, "t");
  for (const W& t : inits) g.m(5, t);
  for (const W& i : inputs) g.m(11, i);
  for (const W& o : outputs) g.m(12, o);
  W os; os.s(1, ""); os.i(2, opset);
  W m; m.i(1, 8); m.m(7, g); m.m(8, os);
  return m.b;
}
}  // namespace

static void errors() {
  W ok_in = value_info("x", 1, {2}), ok_out = value_info("y", 1, {2});
  std::string good = model({node("Neg", {"x"}, {"y"})}, {ok_in}, {ok_out});
  { hir::Graph g; std::vector<int> o = g.merge_onnx(good); CHECK(o.size() == 1 && g.value(o[0]).shape == (Shape{2})); }
  CHECK_ERR(hir::Graph::from_onnx(good.substr(0, good.size() - 5)), "onnx import");           // truncated
  CHECK_ERR(hir::Graph::from_onnx(std::string("\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff", 11)), "onnx import");
  CHECK_ERR(hir::Graph::from_onnx(""), "no graph");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Foo", {"x"}, {"y"})}, {ok_in}, {ok_out})), "Foo");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y"})}, {ok_in}, {ok_out}, 12)), "opset");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y"})}, {value_info("x", 1, {2}, true)}, {ok_out})), "dynamic");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y"})}, {value_info("x", 10, {2})}, {ok_out})), "FLOAT16");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"nope"}, {"y"})}, {ok_in}, {ok_out})), "nope");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y"})}, {ok_in}, {value_info("z", 1, {2})})), "z");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y"})}, {ok_in}, {value_info("y", 1, {3})})), "name collision");   // declared shape differs from the inferred one
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y", "y2"})}, {ok_in}, {ok_out})), "several outputs");
  CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x", "x"}, {"y"})}, {ok_in}, {ok_out})), "Neg");                             // shape inference's own message
  {  // an initializer of an unsupported type
    W t; t.i(1, 2); t.i(2, 5); t.s(8, "c"); t.s(9, std::string(4, '\0'));   // INT16
    CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y"})}, {ok_in}, {ok_out}, 18, {t})), "INT16");
  }
  {  // raw_data of the wrong size
    W t; t.i(1, 2); t.i(2, 1); t.s(8, "c"); t.s(9, std::string(7, '\0'));
    CHECK_ERR(hir::Graph::from_onnx(model({node("Neg", {"x"}, {"y"})}, {ok_in}, {ok_out}, 18, {t})), "raw_data");
  }
  {  // a node in a domain of its own
    W n = node("Neg", {"x"}, {"y"});
    n.s(7, "com.example");
    CHECK_ERR(hir::Graph::from_onnx(model({n}, {ok_in}, {ok_out})), "domain");
  }
}

// ---- (e) Pad ----

static void pad() {
  using hir::Attribute;
  hir::Graph g;
  int x = g.add_input("x", f64, {2, 3});
  auto pads = [&](const std::vector<int64_t>& v) { return g.add_initializer("", ints(v)); };
  int cv = g.add_initializer("", arr(f64, {}, V{5}));
  int p0 = g.add_node("Pad", {x, pads({1, 0, 0, 2})});
  int p1 = g.add_node("Pad", {x, pads({1, 0, 0, 2}), cv});
  CHECK(g.value(p0).shape == (Shape{3, 5}) && g.value(p1).shape == (Shape{3, 5}));
  ut::Session u;
  hir::Lowerer low(g, u);
  std::map<std::string, Array> feeds{{"x", arr(f64, {2, 3}, V{1, 2, 3, 4, 5, 6})}};
  CHECK(near(vals(u.eval(low.get(p0), feeds)), V{0, 0, 0, 0, 0, 1, 2, 3, 0, 0, 4, 5, 6, 0, 0}, 0));
  CHECK(near(vals(u.eval(low.get(p1), feeds)), V{5, 5, 5, 5, 5, 1, 2, 3, 5, 5, 4, 5, 6, 5, 5}, 0));
  CHECK_ERR(g.add_node("Pad", {x, pads({1, 0, 0})}), "2 * rank");
  CHECK_ERR(g.add_node("Pad", {x, pads({-1, 0, 0, 0})}), "negative");
  CHECK_ERR(g.add_node("Pad", {x, pads({1, 0, 0, 0})}, {Attribute::String("mode", "reflect")}), "constant");
  CHECK(g.value(g.add_node("Pad", {x, pads({0, 0, 0, 0})}, {Attribute::String("mode", "constant")})).shape == (Shape{2, 3}));
  CHECK_ERR(g.add_node("Pad", {x, pads({1, 0, 0, 0}), g.add_input("cvi", f64, {})}), "initializer");
  CHECK_ERR(g.add_node("Pad", {x, pads({1, 0, 0, 0}), g.add_initializer("", arr(f32, {}, V{0}))}), "dtypes differ");
  // a round trip with Pad in it
  std::string bytes = g.to_onnx({p1});
  std::vector<int> outs;
  hir::Graph g2 = hir::Graph::from_onnx(bytes, &outs);
  CHECK(g2.to_onnx(outs) == bytes);
}

int main(int argc, char** argv) {
  round_trips();
  attributes();
  merging();
  errors();
  pad();
  if (argc > 1) python_models(argv[1], {"imp_typed", "imp_attrs", "imp_f64", "imp_slices"});
  if (imported_models == 0) std::printf("SKIP importing models made by the onnx package: no models in the directory (python3, onnx or onnxruntime missing)\n");
  std::printf("%d models made by the onnx package imported and equal to onnxruntime\n", imported_models);
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
