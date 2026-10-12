// The numpy-like API from scripts (lib/uop/nfcuop_poly.hpp, docs/notes/uop-poly.md): Ruby, Lua, Python, JavaScript and Go build
// tensor graphs through nfcpoly. Built by tests/uop/run_poly.sh with -DTEST_RUBY / TEST_LUA / TEST_PYTHON / TEST_JS / TEST_GO for the
// languages that are linked in; every check below runs once per language, with the script written in that language.
//
//   model      the same MLP-with-softmax model (broadcasting, slicing, concatenation, reduction, integer ops, where) is built in each
//              language and in C++: the values are equal bit for bit and the exported ONNX bytes are identical
//   operators  `+ - * / % // < > <= >= == != & | ^ @`, unary minus and scalars on either side, as operators where the language has
//              them and as named methods everywhere: both equal the C++ operators
//   errors     nfcuop::Error as a script error with its message; the same error uncaught comes out of eval as nfcuop::Error
//   dtypes     default_float / default_int configuration and dtype arguments
//   backend    the C backend selected from a script
//   data       nested lists in and out, element kinds, indexing, placeholders and feeds
//   interop    a Tensor made in a script is a C++ np::Tensor, and a C++ tensor is a script value
// argv[1], when given, is a directory: the model's ONNX file (built by the first language) and the C++ values are written there as
// model.onnx / model.json for tests/uop/onnx_check.py.
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iterator>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "nfcpoly.hpp"
#include "nfcuop_np.hpp"
#include "nfcuop_poly.hpp"

using namespace nfcuop;
using nfcpoly::Value;
using np::Axes;
using np::Session;
using np::Tensor;

static int checks = 0, failed = 0;
static std::string g_lang = "C++";
#define CHECK(cond)                                                                                              \
  do {                                                                                                           \
    checks++;                                                                                                    \
    if (!(cond)) { failed++; std::printf("FAIL [%s] %s:%d: %s\n", g_lang.c_str(), __FILE__, __LINE__, #cond); } \
  } while (0)
#define CHECK_EQ(got, want)                                                                                      \
  do {                                                                                                           \
    checks++;                                                                                                    \
    auto got_ = (got);                                                                                           \
    auto want_ = (want);                                                                                         \
    if (!(got_ == want_)) {                                                                                      \
      failed++;                                                                                                  \
      std::printf("FAIL [%s] %s:%d: %s\n", g_lang.c_str(), __FILE__, __LINE__, #got);                            \
      std::printf("  got:  %s\n  want: %s\n", show(got_).c_str(), show(want_).c_str());                         \
    }                                                                                                            \
  } while (0)

static std::string show(const std::string& s) { return "\"" + s + "\""; }
static std::string show(bool b) { return b ? "true" : "false"; }
static std::string show(long long v) { return std::to_string(v); }
template <class T>
static std::string show(const std::vector<T>& v) {
  std::string o = "[";
  for (size_t k = 0; k < v.size(); k++) o += (k ? ", " : "") + show(v[k]);
  return o + "]";
}

// ---- the languages that are linked in ---------------------------------------------------------------------------------
enum class L { Ruby, Lua, Python, Js, Go };
struct Lang {
  L l;
  const char* id;     // the name eval() takes
  const char* title;
};
static std::vector<Lang> g_langs;
static void collect_languages() {
#ifdef TEST_RUBY
  g_langs.push_back({L::Ruby, "ruby", "Ruby (mruby)"});
#endif
#ifdef TEST_LUA
  g_langs.push_back({L::Lua, "lua", "Lua"});
#endif
#ifdef TEST_PYTHON
  g_langs.push_back({L::Python, "python", "Python"});
#endif
#ifdef TEST_JS
  g_langs.push_back({L::Js, "js", "JavaScript (QuickJS-NG)"});
#endif
#ifdef TEST_GO
  g_langs.push_back({L::Go, "go", "Go (yaegi)"});
#endif
}

// ---- writing scripts in five syntaxes -------------------------------------------------------------------------------
static std::string camel(const std::string& s) {  // the Go name of a method: to_onnx -> ToOnnx
  std::string o;
  bool up = true;
  for (char c : s) {
    if (c == '_') { up = true; continue; }
    o.push_back(up && c >= 'a' && c <= 'z' ? static_cast<char>(c - 'a' + 'A') : c);
    up = false;
  }
  return o;
}
static std::string join(const std::vector<std::string>& v, const char* sep = ", ") {
  std::string o;
  for (size_t k = 0; k < v.size(); k++) o += (k ? sep : "") + v[k];
  return o;
}
static std::string num(double v) {
  char b[40];
  std::snprintf(b, sizeof b, "%.17g", v);
  std::string s = b;
  if (s.find_first_of(".en") == std::string::npos) s += ".0";
  return s;
}
static std::string q(const std::string& s) { return "\"" + s + "\""; }

using Rows = std::vector<std::vector<double>>;
struct Syn {
  L l;
  std::string list1(const std::vector<double>& v) const {
    std::vector<std::string> e;
    for (double d : v) e.push_back(num(d));
    return (l == L::Go ? "[]float64{" : l == L::Lua ? "{" : "[") + join(e) + (l == L::Go || l == L::Lua ? "}" : "]");
  }
  std::string list2(const Rows& r) const {
    std::vector<std::string> e;
    for (const auto& row : r) {
      std::vector<std::string> c;
      for (double d : row) c.push_back(num(d));
      e.push_back((l == L::Lua || l == L::Go ? "{" : "[") + join(c) + (l == L::Lua || l == L::Go ? "}" : "]"));
    }
    return (l == L::Go ? "[][]float64{" : l == L::Lua ? "{" : "[") + join(e) + (l == L::Go || l == L::Lua ? "}" : "]");
  }
  std::string ints(const std::vector<int>& v) const {  // a shape
    std::vector<std::string> e;
    for (int d : v) e.push_back(std::to_string(d));
    return (l == L::Go ? "[]int{" : l == L::Lua ? "{" : "[") + join(e) + (l == L::Go || l == L::Lua ? "}" : "]");
  }
  std::string any_list(const std::vector<std::string>& items) const {  // a list of script values
    return (l == L::Go ? "[]any{" : l == L::Lua ? "{" : "[") + join(items) + (l == L::Go || l == L::Lua ? "}" : "]");
  }
  std::string nil() const { return l == L::Python ? "None" : l == L::Js ? "null" : "nil"; }
  std::string yes() const { return l == L::Python ? "True" : "true"; }
  // obj.fn(args): Lua passes the object with a colon, Go capitalizes
  std::string call(const std::string& obj, const std::string& fn, const std::vector<std::string>& args = {}) const {
    return obj + (l == L::Lua ? ":" : ".") + (l == L::Go ? camel(fn) : fn) + "(" + join(args) + ")";
  }
  std::string prop(const std::string& obj, const std::string& name) const {
    return obj + "." + (l == L::Go ? camel(name) + "()" : name);
  }
  std::string assign(const std::string& var, const std::string& expr) const {
    switch (l) {
      case L::Lua: return "local " + var + " = " + expr + "\n";
      case L::Js: return "const " + var + " = " + expr + ";\n";
      case L::Go: return var + " := " + expr + "\n";
      default: return var + " = " + expr + "\n";
    }
  }
  std::string set_prop(const std::string& obj, const std::string& name, const std::string& value) const {
    if (l == L::Go) return obj + ".Set" + camel(name) + "(" + value + ")\n";
    return obj + "." + name + " = " + value + (l == L::Js ? ";\n" : "\n");
  }
  // the script's value: a list of [values, dtype] for the tensors in `exprs`
  std::string values_and_dtypes(const std::vector<std::string>& exprs) const {
    std::string s;
    switch (l) {
      case L::Python: return "res = [" + join(exprs) + "]\n[[t.values(), t.dtype] for t in res]\n";
      case L::Ruby: return "res = [" + join(exprs) + "]\nres.map { |t| [t.values, t.dtype] }\n";
      case L::Lua:
        return "local res = {" + join(exprs) + "}\nlocal out = {}\nfor i, t in ipairs(res) do out[i] = {t:values(), t.dtype} end\nreturn out\n";
      case L::Js: return "const res = [" + join(exprs) + "];\nres.map(t => [t.values(), t.dtype])\n";
      case L::Go:
        return "res := []*Tensor{" + join(exprs) + "}\nout := []any{}\nfor _, t := range res { out = append(out, any([]any{t.Values(), t.Dtype()})) }\nout\n";
    }
    return s;
  }
  // the dtype names of `exprs`, then the values of the property expressions `extra` (strings)
  std::string dtype_strings(const std::vector<std::string>& exprs, const std::vector<std::string>& extra) const {
    switch (l) {
      case L::Python: return "[t.dtype for t in [" + join(exprs) + "]] + [" + join(extra) + "]\n";
      case L::Ruby: return "[" + join(exprs) + "].map { |t| t.dtype } + [" + join(extra) + "]\n";
      case L::Lua:
        return "local out = {}\nfor i, t in ipairs({" + join(exprs) + "}) do out[i] = t.dtype end\nfor _, e in ipairs({" + join(extra) +
               "}) do out[#out + 1] = e end\nreturn out\n";
      case L::Js: return "[" + join(exprs) + "].map(t => t.dtype).concat([" + join(extra) + "])\n";
      case L::Go:
        return "out := []any{}\nfor _, t := range []*Tensor{" + join(exprs) + "} { out = append(out, t.Dtype()) }\nout = append(out, " + join(extra) + ")\nout\n";
    }
    return "";
  }
  std::string result(const std::string& expr) const { return (l == L::Lua ? "return " : "") + expr + "\n"; }
  // a script whose value is the message of the error that STMT raises ("no error" when it does not)
  std::string catch_message(const std::string& setup, const std::string& stmt, bool is_expr = true) const {
    switch (l) {
      case L::Python:
        return setup + "try:\n    " + stmt + "\n    msg = 'no error'\nexcept Exception as e:\n    msg = str(e)\nmsg\n";
      case L::Ruby: return setup + "begin\n  " + stmt + "\n  'no error'\nrescue => e\n  e.message\nend\n";
      case L::Lua:
        return setup + "local ok, e = pcall(function() " + (is_expr ? "return " : "") + stmt + " end)\nif ok then return 'no error' end\nreturn e.message\n";
      case L::Js: return setup + "(function () { try { " + stmt + "; return 'no error'; } catch (e) { return e.message; } })()\n";
      case L::Go:
        return setup + "func catchMsg() (msg string) {\n  defer func() { if r := recover(); r != nil { msg = nfc.ErrMessage(r) } }()\n  " + stmt +
               "\n  return \"no error\"\n}\ncatchMsg()\n";
    }
    return "";
  }
};

// ---- values coming back --------------------------------------------------------------------------------------------
struct Flat {
  std::vector<double> v;
  std::string kinds;  // b, i, f per element
};
static void flatten(const Value& x, Flat& out) {
  if (x.is_array()) {
    for (const Value& e : x.as<std::vector<Value>>()) flatten(e, out);
  } else if (x.is_bool()) {
    out.v.push_back(x.as<bool>() ? 1 : 0);
    out.kinds += 'b';
  } else if (x.is_int()) {
    out.v.push_back(static_cast<double>(x.as<long long>()));
    out.kinds += 'i';
  } else if (x.is_float()) {
    out.v.push_back(x.as<double>());
    out.kinds += 'f';
  } else {
    out.v.push_back(-12345);
    out.kinds += '?';
    CHECK(false && "a nested list holds numbers");
  }
}
static Flat flat_of(const Value& x) {
  Flat f;
  flatten(x, f);
  return f;
}
static Flat flat_of(const Array& a) {
  Flat f;
  for (const Scalar& s : a.data) {
    f.v.push_back(s.as_double());
    f.kinds += a.dtype == DType::Bool ? 'b' : is_int(a.dtype) ? 'i' : 'f';
  }
  return f;
}
static bool same(const Flat& a, const Flat& b, bool kinds) { return a.v == b.v && (!kinds || a.kinds == b.kinds); }

static std::string read_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}
static std::string tmp_dir() {
  const char* t = std::getenv("TMPDIR");
  return t && *t ? t : "/tmp";
}

// A fresh Session and Context with the numpy API bound; scripts get `onnx_path`.
struct Env {
  Session s;
  nfcpoly::Context ctx;
  explicit Env(const std::string& onnx_path = "") {
    poly::bind_numpy(ctx, s);
    ctx.set("onnx_path", onnx_path);
  }
  Value run(const Lang& lg, const std::string& code) { return ctx.eval_value(lg.id, code); }
};

// ============================================================================================================================
// model: the same graph in every language and in C++
// ============================================================================================================================
static const Rows W1 = {{0.5, -1.0, 0.25, 1.5, -0.75}, {0.125, 2.0, 0.0, -0.5, 1.0}, {0.25, -1.25, 0.75, 0.5, 1.0}};
static const std::vector<double> B1 = {0.1, -0.2, 0.3, 0.0, 0.05};
static const Rows W2 = {{0.5, -0.5}, {1.0, 0.25}, {-0.75, 0.75}, {0.125, -1.0}, {0.3, 0.6}};
static const std::vector<double> B2 = {0.25, -0.25};
static const Rows X = {{1, 2, 3}, {-1, 0.5, 2}, {0, 0, 1}, {3, -2, 0.25}};
static const std::vector<std::string> kOutNames = {"p", "z", "r", "m", "k", "t"};

static std::vector<double> flat_rows(const Rows& r) {
  std::vector<double> f;
  for (const auto& row : r) f.insert(f.end(), row.begin(), row.end());
  return f;
}

struct Model {
  Tensor x;
  std::vector<std::pair<std::string, Tensor>> outs;
  std::map<std::string, Array> feeds;
};
static Model build_model(Session& s) {
  Model m;
  m.x = s.placeholder("x", {4, 3});
  Tensor w1 = s.array(flat_rows(W1), {3, 5}), b1 = s.array(B1), w2 = s.array(flat_rows(W2), {5, 2}), b2 = s.array(B2);
  Tensor h = np::relu(np::matmul(m.x, w1) + b1);
  Tensor logits = np::matmul(h, w2) + b2;
  Tensor p = np::softmax(logits);                                         // the MLP with softmax
  Tensor z = np::concatenate({p.slice(1, 0, 1), logits * 0.5 - 1}, 1);    // slicing, concatenation, scalars
  Tensor r = p.sum(0);                                                    // a reduction
  Tensor mm = (m.x - m.x.mean(1, true)) * 2 + 1;                          // broadcasting arithmetic
  Tensor i = s.arange(4);
  Tensor big = i > 1, neg = -i;                                           // (the order of evaluation of arguments is not the scripts')
  Tensor k = np::where(big, i, neg);                                      // integers, a comparison, where
  Tensor t = m.x.T();
  m.outs = {{"p", p}, {"z", z}, {"r", r}, {"m", mm}, {"k", k}, {"t", t}};
  m.feeds["x"] = Array::from_doubles(DType::Float32, {4, 3}, flat_rows(X));
  return m;
}

// The literals of the data in language L.
static std::string fill(std::string script, const Syn& sy) {
  auto rep = [&](const std::string& tok, const std::string& val) {
    for (size_t p; (p = script.find(tok)) != std::string::npos;) script.replace(p, tok.size(), val);
  };
  rep("@W1@", sy.list2(W1));
  rep("@B1@", sy.list1(B1));
  rep("@W2@", sy.list2(W2));
  rep("@B2@", sy.list1(B2));
  rep("@X@", sy.list2(X));
  return script;
}

// One script per language. Python and Lua use operators (Lua has no `@`, so matmul is a method there), Ruby operators and
// methods, JavaScript and Go methods only. Every script makes the calls of build_model() in the same order.
static std::string model_script(L l) {
  switch (l) {
    case L::Python:
      return R"(x = np.placeholder('x', [4, 3])
w1 = np.array(@W1@); b1 = np.array(@B1@); w2 = np.array(@W2@); b2 = np.array(@B2@)
h = np.relu(x @ w1 + b1)
logits = h @ w2 + b2
prob = np.softmax(logits)
cat = np.concatenate([prob[:, 0:1], logits * 0.5 - 1], 1)
red = prob.sum(0)
cen = (x - x.mean(1, True)) * 2 + 1
i = np.arange(4)
sel = np.where(i > 1, i, -i)
tr = x.T
outs = [prob, cat, red, cen, sel, tr]
np.save_onnx(onnx_path, [['p', prob], ['z', cat], ['r', red], ['m', cen], ['k', sel], ['t', tr]])
res = np.eval_all(outs, [['x', @X@]])
[res, [o.dtype for o in outs], [o.shape for o in outs], [o.ndim for o in outs], [o.size for o in outs]]
)";
    case L::Ruby:
      return R"(x = np.placeholder('x', [4, 3])
w1 = np.array(@W1@); b1 = np.array(@B1@); w2 = np.array(@W2@); b2 = np.array(@B2@)
h = np.relu(x.matmul(w1) + b1)
logits = h.matmul(w2) + b2
prob = np.softmax(logits)
cat = np.concatenate([prob[nil, 0...1], logits * 0.5 - 1], 1)
red = prob.sum(0)
cen = (x - x.mean(1, true)) * 2 + 1
i = np.arange(4)
sel = np.where(i > 1, i, -i)
tr = x.T
outs = [prob, cat, red, cen, sel, tr]
np.save_onnx(onnx_path, [['p', prob], ['z', cat], ['r', red], ['m', cen], ['k', sel], ['t', tr]])
res = np.eval_all(outs, [['x', @X@]])
[res, outs.map { |o| o.dtype }, outs.map { |o| o.shape }, outs.map { |o| o.ndim }, outs.map { |o| o.size }]
)";
    case L::Lua:
      return R"(local x = np:placeholder('x', {4, 3})
local w1 = np:array(@W1@); local b1 = np:array(@B1@); local w2 = np:array(@W2@); local b2 = np:array(@B2@)
local h = np:relu(x:matmul(w1) + b1)
local logits = h:matmul(w2) + b2
local prob = np:softmax(logits)
local cat = np:concatenate({prob:index(nil, '0:1'), logits * 0.5 - 1}, 1)
local red = prob:sum(0)
local cen = (x - x:mean(1, true)) * 2 + 1
local i = np:arange(4)
local sel = np:where(i:gt(1), i, -i)
local tr = x.T
local outs = {prob, cat, red, cen, sel, tr}
np:save_onnx(onnx_path, {{'p', prob}, {'z', cat}, {'r', red}, {'m', cen}, {'k', sel}, {'t', tr}})
local res = np:eval_all(outs, {{'x', @X@}})
local dts, shs, nds, szs = {}, {}, {}, {}
for n, o in ipairs(outs) do dts[n] = o.dtype; shs[n] = o.shape; nds[n] = o.ndim; szs[n] = o.size end
return {res, dts, shs, nds, szs}
)";
    case L::Js:
      return R"(const x = np.placeholder('x', [4, 3]);
const w1 = np.array(@W1@), b1 = np.array(@B1@), w2 = np.array(@W2@), b2 = np.array(@B2@);
const h = np.relu(x.matmul(w1).add(b1));
const logits = h.matmul(w2).add(b2);
const prob = np.softmax(logits);
const cat = np.concatenate([prob.index(null, '0:1'), logits.mul(0.5).sub(1)], 1);
const red = prob.sum(0);
const cen = x.sub(x.mean(1, true)).mul(2).add(1);
const i = np.arange(4);
const sel = np.where(i.gt(1), i, i.neg());
const tr = x.T;
const outs = [prob, cat, red, cen, sel, tr];
np.save_onnx(onnx_path, [['p', prob], ['z', cat], ['r', red], ['m', cen], ['k', sel], ['t', tr]]);
const res = np.eval_all(outs, [['x', @X@]]);
[res, outs.map(o => o.dtype), outs.map(o => o.shape), outs.map(o => o.ndim), outs.map(o => o.size)]
)";
    case L::Go:
      return R"(x := np.Placeholder("x", []int{4, 3})
w1 := np.Array(@W1@)
b1 := np.Array(@B1@)
w2 := np.Array(@W2@)
b2 := np.Array(@B2@)
h := np.Relu(x.Matmul(w1).Add(b1))
logits := h.Matmul(w2).Add(b2)
prob := np.Softmax(logits)
cat := np.Concatenate([]any{prob.Index(nil, "0:1"), logits.Mul(0.5).Sub(1)}, 1)
red := prob.Sum(0)
cen := x.Sub(x.Mean(1, true)).Mul(2).Add(1)
i := np.Arange(4)
sel := np.Where(i.Gt(1), i, i.Neg())
tr := x.T()
outs := []*Tensor{prob, cat, red, cen, sel, tr}
np.SaveOnnx(onnx_path, []any{[]any{"p", prob}, []any{"z", cat}, []any{"r", red}, []any{"m", cen}, []any{"k", sel}, []any{"t", tr}})
res := np.EvalAll([]any{prob, cat, red, cen, sel, tr}, []any{[]any{"x", @X@}})
dts, shs, nds, szs := []any{}, []any{}, []any{}, []any{}
for _, o := range outs { dts = append(dts, o.Dtype()); shs = append(shs, o.Shape()); nds = append(nds, o.Ndim()); szs = append(szs, o.Size()) }
[]any{res, dts, shs, nds, szs}
)";
  }
  return "";
}

static std::string g_first_onnx;  // the bytes the first language wrote

static void test_model(const Lang& lg, const std::string& out_dir) {
  Session ref;
  Model m = build_model(ref);
  std::vector<Tensor> ts;
  for (auto& o : m.outs) ts.push_back(o.second);
  std::string want_onnx = ref.to_onnx(m.outs);  // before eval, as in the scripts: exporting adds the output nodes to the graph
  std::vector<Array> want = ref.eval_all(ts, m.feeds);

  std::string path = tmp_dir() + "/nfcuop_poly_" + lg.id + ".onnx";
  std::remove(path.c_str());
  Env env(path);
  Value r = env.run(lg, fill(model_script(lg.l), Syn{lg.l}));
  std::vector<Value> top = r.as<std::vector<Value>>();
  CHECK(top.size() == 5);
  if (top.size() != 5) return;
  std::vector<Value> res = top[0].as<std::vector<Value>>();
  std::vector<std::string> dts = top[1].as<std::vector<std::string>>();
  CHECK(res.size() == want.size() && dts.size() == want.size());
  for (size_t k = 0; k < want.size() && k < res.size(); k++) {
    g_lang = std::string(lg.id) + ":" + kOutNames[k];
    // (a) the values equal the C++ API's, bit for bit (the kind of every element too, except in JavaScript, which has one number type)
    CHECK(same(flat_of(res[k]), flat_of(want[k]), lg.l != L::Js));
    CHECK_EQ(dts[k], std::string(name(want[k].dtype)));
    CHECK_EQ(top[2].as<std::vector<std::vector<long long>>>()[k], std::vector<long long>(want[k].shape.begin(), want[k].shape.end()));
    CHECK_EQ(top[3].as<std::vector<long long>>()[k], static_cast<long long>(want[k].shape.size()));
    CHECK_EQ(top[4].as<std::vector<long long>>()[k], static_cast<long long>(numel(want[k].shape)));
  }
  g_lang = lg.id;
  // (b) the exported ONNX bytes are those of the C++-built model
  std::string got_onnx = read_file(path);
  CHECK(!got_onnx.empty());
  CHECK(got_onnx == want_onnx);
  if (g_first_onnx.empty()) g_first_onnx = got_onnx;
  CHECK(got_onnx == g_first_onnx);  // and so identical across the languages
  if (!out_dir.empty() && g_langs.front().id == std::string(lg.id)) {
    std::ofstream(out_dir + "/model.onnx", std::ios::binary) << got_onnx;
    std::string j = "{\"inputs\":{\"x\":{\"dtype\":\"float32\",\"shape\":[4,3],\"data\":[";
    std::vector<double> xs = flat_rows(X);
    for (size_t k = 0; k < xs.size(); k++) j += (k ? "," : "") + num(xs[k]);
    j += "]}},\"outputs\":{";
    for (size_t k = 0; k < want.size(); k++) {
      const Array& a = want[k];
      j += (k ? "," : "") + q(kOutNames[k]) + ":{\"dtype\":\"" + name(a.dtype) + "\",\"shape\":[";
      for (size_t d = 0; d < a.shape.size(); d++) j += (d ? "," : "") + std::to_string(a.shape[d]);
      j += "],\"data\":[";
      for (size_t e = 0; e < a.data.size(); e++) {
        char b[64];
        if (is_float(a.dtype)) std::snprintf(b, sizeof b, "%.17g", a.data[e].f);
        else std::snprintf(b, sizeof b, "%lld", static_cast<long long>(a.data[e].i));
        j += std::string(e ? "," : "") + b;
      }
      j += "]}";
    }
    std::ofstream(out_dir + "/model.json") << j << "}}";
  }
  std::remove(path.c_str());
}

// ============================================================================================================================
// operators and named methods
// ============================================================================================================================
struct OpCase {
  const char* name;
  std::function<Tensor(const Tensor& a, const Tensor& b, const Tensor& ia, const Tensor& ib)> cpp;
  // the named form: receiver, method, arguments (the same in every language); empty receiver: no named form
  const char* recv;
  const char* method;
  std::vector<const char*> args;
  // the operator form in Python, Ruby and Lua; empty: the language has no such operator
  const char* py;
  const char* rb;
  const char* lua;
};

static std::vector<OpCase> op_cases() {
  using T = const Tensor&;
  return {
      {"add", [](T a, T b, T, T) { return a + b; }, "a", "add", {"b"}, "a + b", "a + b", "a + b"},
      {"sub", [](T a, T b, T, T) { return a - b; }, "a", "sub", {"b"}, "a - b", "a - b", "a - b"},
      {"mul", [](T a, T b, T, T) { return a * b; }, "a", "mul", {"b"}, "a * b", "a * b", "a * b"},
      {"div", [](T a, T b, T, T) { return a / b; }, "a", "div", {"b"}, "a / b", "a / b", "a / b"},
      {"mod", [](T, T, T ia, T ib) { return ia % ib; }, "ia", "mod", {"ib"}, "ia % ib", "ia % ib", "ia % ib"},
      {"floordiv", [](T, T, T ia, T ib) { return np::floor_divide(ia, ib); }, "ia", "floor_divide", {"ib"}, "ia // ib", "", "ia // ib"},
      {"matmul", [](T a, T b, T, T) { return np::matmul(a, b); }, "a", "matmul", {"b"}, "a @ b", "", ""},
      {"lt", [](T a, T b, T, T) { return a < b; }, "a", "lt", {"b"}, "a < b", "a < b", ""},
      {"gt", [](T a, T b, T, T) { return a > b; }, "a", "gt", {"b"}, "a > b", "a > b", ""},
      {"le", [](T a, T b, T, T) { return a <= b; }, "a", "le", {"b"}, "a <= b", "a <= b", ""},
      {"ge", [](T a, T b, T, T) { return a >= b; }, "a", "ge", {"b"}, "a >= b", "a >= b", ""},
      {"eq", [](T a, T b, T, T) { return a == b; }, "a", "eq", {"b"}, "a == b", "a == b", ""},
      {"ne", [](T a, T b, T, T) { return a != b; }, "a", "ne", {"b"}, "a != b", "a != b", ""},
      {"and", [](T, T, T ia, T ib) { return ia & ib; }, "ia", "and_", {"ib"}, "ia & ib", "ia & ib", "ia & ib"},
      {"or", [](T, T, T ia, T ib) { return ia | ib; }, "ia", "or_", {"ib"}, "ia | ib", "ia | ib", "ia | ib"},
      {"xor", [](T, T, T ia, T ib) { return ia ^ ib; }, "ia", "xor", {"ib"}, "ia ^ ib", "ia ^ ib", "ia ~ ib"},
      {"neg", [](T a, T, T, T) { return -a; }, "a", "neg", {}, "-a", "-a", "-a"},
      // numbers on the right: weak scalars, like the C++ overloads
      {"add_s", [](T a, T, T, T) { return a + 2; }, "a", "add", {"2"}, "a + 2", "a + 2", "a + 2"},
      {"add_f", [](T a, T, T, T) { return a + 0.5; }, "a", "add", {"0.5"}, "a + 0.5", "a + 0.5", "a + 0.5"},
      {"sub_s", [](T a, T, T, T) { return a - 1; }, "a", "sub", {"1"}, "a - 1", "a - 1", "a - 1"},
      {"mul_s", [](T a, T, T, T) { return a * 3; }, "a", "mul", {"3"}, "a * 3", "a * 3", "a * 3"},
      {"div_s", [](T a, T, T, T) { return a / 4; }, "a", "div", {"4"}, "a / 4", "a / 4", "a / 4"},
      {"mod_s", [](T, T, T ia, T) { return ia % 3; }, "ia", "mod", {"3"}, "ia % 3", "ia % 3", "ia % 3"},
      {"iadd_f", [](T, T, T ia, T) { return ia + 1.5; }, "ia", "add", {"1.5"}, "ia + 1.5", "ia + 1.5", "ia + 1.5"},
      {"idiv_s", [](T, T, T ia, T) { return ia / 2; }, "ia", "div", {"2"}, "ia / 2", "ia / 2", "ia / 2"},
      {"gt_s", [](T a, T, T, T) { return a > 2; }, "a", "gt", {"2"}, "a > 2", "a > 2", ""},
      {"le_f", [](T a, T, T, T) { return a <= 2.5; }, "a", "le", {"2.5"}, "a <= 2.5", "a <= 2.5", ""},
      {"eq_s", [](T a, T, T, T) { return a == 4; }, "a", "eq", {"4"}, "a == 4", "a == 4", ""},
      // numbers on the left (Python and Lua only: Ruby's Integer does not ask the other operand, JavaScript and Go have no operators)
      {"radd", [](T a, T, T, T) { return 2 + a; }, "", "", {}, "2 + a", "", "2 + a"},
      {"rsub", [](T a, T, T, T) { return 1.5 - a; }, "", "", {}, "1.5 - a", "", "1.5 - a"},
      {"rmul", [](T a, T, T, T) { return 3 * a; }, "", "", {}, "3 * a", "", "3 * a"},
      {"rdiv", [](T a, T, T, T) { return 1 / a; }, "", "", {}, "1 / a", "", "1 / a"},
      {"rmod", [](T, T, T ia, T) { return 7 % ia; }, "", "", {}, "7 % ia", "", "7 % ia"},
      {"rfloordiv", [](T, T, T ia, T) { return np::floor_divide(np::detail::lift(ia, 10, true), ia); }, "", "", {}, "10 // ia", "", "10 // ia"},
      {"rlt", [](T a, T, T, T) { return 3 < a; }, "", "", {}, "3 < a", "", ""},
      {"rge", [](T a, T, T, T) { return 3 >= a; }, "", "", {}, "3 >= a", "", ""},
      {"radd_t", [](T a, T b, T, T) { return b + a; }, "", "", {}, "b + a", "b + a", "b + a"},
  };
}

static std::string ops_setup(const Syn& sy) {
  std::string s;
  s += sy.assign("a", sy.call("np", "array", {sy.list2({{1, 2}, {3, 4}})}));
  s += sy.assign("b", sy.call("np", "array", {sy.list2({{0.5, 2}, {1, 8}})}));
  s += sy.assign("ia", sy.call("np", "array", {sy.list2({{7, -7}, {3, -3}}), q("int32")}));
  s += sy.assign("ib", sy.call("np", "array", {sy.list2({{2, 2}, {-3, 2}}), q("int32")}));
  return s;
}

static void check_ops(const Lang& lg, bool operators) {
  Session ref;
  Tensor a = ref.array({1, 2, 3, 4}, {2, 2}), b = ref.array({0.5, 2, 1, 8}, {2, 2});
  Tensor ia = ref.array({7, -7, 3, -3}, {2, 2}, DType::Int32), ib = ref.array({2, 2, -3, 2}, {2, 2}, DType::Int32);
  Syn sy{lg.l};
  std::vector<std::string> exprs;
  std::vector<const OpCase*> used;
  std::vector<OpCase> cases = op_cases();
  for (const OpCase& c : cases) {
    std::string e;
    if (operators) {
      e = lg.l == L::Python ? c.py : lg.l == L::Ruby ? c.rb : lg.l == L::Lua ? c.lua : "";
    } else if (*c.recv) {
      std::vector<std::string> args(c.args.begin(), c.args.end());
      e = sy.call(c.recv, c.method, args);
    }
    if (e.empty()) continue;
    exprs.push_back(e);
    used.push_back(&c);
  }
  CHECK(exprs.size() >= (operators ? 20u : 25u));
  Env env;
  Value r = env.run(lg, ops_setup(sy) + sy.values_and_dtypes(exprs));
  std::vector<Value> items = r.as<std::vector<Value>>();
  CHECK(items.size() == used.size());
  for (size_t k = 0; k < used.size() && k < items.size(); k++) {
    g_lang = std::string(lg.id) + (operators ? " operator " : " method ") + used[k]->name;
    Array want = ref.eval(used[k]->cpp(a, b, ia, ib));
    std::vector<Value> pair = items[k].as<std::vector<Value>>();
    CHECK(same(flat_of(pair[0]), flat_of(want), lg.l != L::Js));
    CHECK_EQ(pair[1].as<std::string>(), std::string(name(want.dtype)));
  }
  g_lang = lg.id;
}

// ============================================================================================================================
// errors
// ============================================================================================================================
static std::string cpp_message(const std::function<void()>& f) {
  try {
    f();
  } catch (const Error& e) {
    return e.what();
  }
  return "no error";
}

static void check_errors(const Lang& lg) {
  Syn sy{lg.l};
  int li = static_cast<int>(lg.l);
  // the failing statements, per language: reshape to a size that does not fit; an unknown dtype; a ragged list; an unfed
  // placeholder; a feed for a placeholder that does not exist; integer-only operators on floats
  struct Case {
    std::string name;
    std::string stmt[5];  // Ruby, Lua, Python, JavaScript, Go
    std::string want;     // the message
    bool exact;
  };
  std::string rs = cpp_message([] { Session s; s.zeros({2, 2}).reshape({5}); });
  std::string unfed = cpp_message([] { Session s; Tensor x = s.placeholder("x", {2}); s.eval(x + 1); });
  std::string modf = cpp_message([] { Session s; Tensor a = s.zeros({2}); (void)(a % 2); });
  std::vector<Case> cases = {
      {"reshape", {"np.zeros([2, 2]).reshape(5)", "np:zeros({2, 2}):reshape(5)", "np.zeros([2, 2]).reshape(5)", "np.zeros([2, 2]).reshape(5)",
                   "np.Zeros([]int{2, 2}).Reshape(5)"}, rs, true},
      {"dtype", {"np.array([1, 2], 'float16')", "np:array({1, 2}, 'float16')", "np.array([1, 2], 'float16')", "np.array([1, 2], 'float16')",
                 "np.Array([]float64{1, 2}, \"float16\")"},
       "np: unknown dtype 'float16' (bool, int32, int64, float32, float64)", true},
      {"ragged", {"np.array([[1, 2], [3]])", "np:array({{1, 2}, {3}})", "np.array([[1, 2], [3]])", "np.array([[1, 2], [3]])",
                  "np.Array([][]float64{{1, 2}, {3}})"}, "np: ragged nested list", true},
      {"unfed", {"y = np.placeholder('x', [2]); np.eval(y + 1)", "local y = np:placeholder('x', {2}); np:eval(y + 1)",
                 "y = np.placeholder('x', [2]); np.eval(y + 1)", "const y = np.placeholder('x', [2]); np.eval(y.add(1))",
                 "y := np.Placeholder(\"x\", []int{2}); np.Eval(y.Add(1))"}, unfed, true},
      {"nofeed", {"y = np.placeholder('x', [2]); np.eval(y, [['q', [1, 2]]])", "local y = np:placeholder('x', {2}); np:eval(y, {{'q', {1, 2}}})",
                  "y = np.placeholder('x', [2]); np.eval(y, [['q', [1, 2]]])", "const y = np.placeholder('x', [2]); np.eval(y, [['q', [1, 2]]])",
                  "y := np.Placeholder(\"x\", []int{2}); np.Eval(y, []any{[]any{\"q\", []float64{1, 2}}})"},
       "np: no placeholder named 'q'", true},
      {"floatmod", {"np.zeros([2]).mod(2)", "np:zeros({2}):mod(2)", "np.zeros([2]).mod(2)", "np.zeros([2]).mod(2)", "np.Zeros([]int{2}).Mod(2)"}, modf, true},
      {"arity", {"np.zeros([2]).sum(1, true, 7)", "np:zeros({2}):sum(1, true, 7)", "np.zeros([2]).sum(1, True, 7)", "np.zeros([2]).sum(1, true, 7)",
                 "np.Zeros([]int{2}).Sum(1, true, 7)"}, "wrong number of arguments", false},
      {"operand", {"np.zeros([2]) + 'x'", "np:zeros({2}) + 'x'", "np.zeros([2]) + 'x'", "np.zeros([2]).add('x')", "np.Zeros([]int{2}).Add(\"x\")"},
       "np: unsupported operand", false},
      {"badaxis", {"np.zeros([2]).sum(3)", "np:zeros({2}):sum(3)", "np.zeros([2]).sum(3)", "np.zeros([2]).sum(3)", "np.Zeros([]int{2}).Sum(3)"},
       cpp_message([] { Session s; s.zeros({2}).sum(3); }), true},
  };
  for (const Case& c : cases) {
    g_lang = std::string(lg.id) + " error " + c.name;
    Env env;
    std::string stmt = c.stmt[li];
    // the statement may have a leading `y = ...;` part: it goes into the setup so that only the last one is inside the try
    size_t semi = stmt.find("; ");
    std::string setup, last = stmt;
    if (semi != std::string::npos) {
      setup = stmt.substr(0, semi) + (lg.l == L::Js ? ";" : "") + "\n";
      last = stmt.substr(semi + 2);
    }
    std::string msg = env.run(lg, sy.catch_message(setup, last)).as<std::string>();
    if (c.exact) CHECK_EQ(msg, c.want);
    else CHECK(msg.find(c.want) != std::string::npos);
    if (!c.exact || msg.empty()) continue;
    // uncaught, the same error leaves eval() as the C++ exception itself
    Env env2;
    bool threw = false;
    try {
      env2.run(lg, setup + last + "\n");
    } catch (const Error& e) {
      threw = true;
      CHECK_EQ(std::string(e.what()), c.want);
    } catch (const std::exception& e) {
      std::printf("  unexpected exception type: %s\n", e.what());
    }
    CHECK(threw);
  }
  g_lang = lg.id;
}

// ============================================================================================================================
// to_onnx returns the bytes
// ============================================================================================================================
static void check_to_onnx(const Lang& lg) {
  Session ref;
  Tensor rx = ref.placeholder("x", {2});
  std::string want = ref.to_onnx({{"y", rx + 1}}, "tiny");
  Syn sy{lg.l};
  auto script = [&](bool as_array) {
    std::string call = sy.call("np", "to_onnx", {sy.any_list({sy.any_list({q("y"), "y"})}), q("tiny")});
    return sy.assign("x", sy.call("np", "placeholder", {q("x"), sy.ints({2})})) + sy.assign("y", sy.call("x", "add", {"1"})) +
           sy.result(as_array ? "Array.from(" + call + ")" : call);
  };
  Env env;
  Value v = env.run(lg, script(false));
  std::string got;
  try {
    got = v.as<std::string>();
  } catch (const nfcpoly::ConversionError&) {  // JavaScript: bytes that are not text are a Uint8Array, which Array.from turns into a list
    Env env2;
    for (long long b : env2.run(lg, script(true)).as<std::vector<long long>>()) got.push_back(static_cast<char>(b));
  }
  CHECK(got == want);
  CHECK(want.size() > 20);
}

// ============================================================================================================================
// dtype configuration
// ============================================================================================================================
static std::vector<std::string> dtype_reference(Session& s) {
  std::vector<std::string> d;
  auto add = [&](const Tensor& t) { d.push_back(name(t.dtype())); };
  add(s.array({1, 2}));
  add(s.array({1, 2}, DType::Int32));
  add(s.arange(3));
  add(s.arange(0.5, 3));
  add(s.zeros({1}));
  add(s.full({1}, 3));
  add(s.full({1}, 2.5));
  add(s.full({1}, 3, DType::Float32));
  add(s.linspace(0, 1, 3));
  add(s.eye(2));
  add(s.scalar(1));
  add(s.placeholder("q", {1}));
  Tensor ia = s.array({1, 2}, DType::Int32);
  add(ia / 2);
  add(ia + 1);
  add(s.array({1, 2}, DType::Bool) + 1);
  add(ia.sum());
  add(ia.astype(DType::Float32));
  d.push_back(name(s.default_float));
  d.push_back(name(s.default_int));
  return d;
}

static void check_dtypes(const Lang& lg) {
  Syn sy{lg.l};
  auto arr_i32 = [&] { return sy.call("np", "array", {sy.list1({1, 2}), q("int32")}); };
  std::vector<std::string> exprs = {
      sy.call("np", "array", {sy.list1({1, 2})}),
      arr_i32(),
      sy.call("np", "arange", {"3"}),
      sy.call("np", "arange", {"0.5", "3"}),
      sy.call("np", "zeros", {sy.ints({1})}),
      sy.call("np", "full", {sy.ints({1}), "3"}),
      sy.call("np", "full", {sy.ints({1}), "2.5"}),
      sy.call("np", "full", {sy.ints({1}), "3", q("float32")}),
      sy.call("np", "linspace", {"0", "1", "3"}),
      sy.call("np", "eye", {"2"}),
      sy.call("np", "scalar", {"1"}),
      sy.call("np", "placeholder", {q("q"), sy.ints({1})}),
      sy.call(arr_i32(), "div", {"2"}),
      sy.call(arr_i32(), "add", {"1"}),
      sy.call(sy.call("np", "array", {sy.list1({1, 2}), q("bool")}), "add", {"1"}),
      sy.call(arr_i32(), "sum"),
      sy.call(arr_i32(), "astype", {q("float32")}),
  };
  std::vector<std::string> extra = {sy.prop("np", "default_float"), sy.prop("np", "default_int")};
  for (int wide = 0; wide < 2; wide++) {
    g_lang = std::string(lg.id) + (wide ? " float64/int64 defaults" : " default dtypes");
    Session ref;
    if (wide) {
      ref.default_float = DType::Float64;
      ref.default_int = DType::Int64;
    }
    Env env;
    std::string code;
    if (wide) code += sy.set_prop("np", "default_float", q("float64")) + sy.set_prop("np", "default_int", q("int64"));
    code += sy.dtype_strings(exprs, extra);
    CHECK_EQ(env.run(lg, code).as<std::vector<std::string>>(), dtype_reference(ref));
    // the Session in C++ saw the change
    CHECK(env.s.default_float == ref.default_float && env.s.default_int == ref.default_int);
  }
  // a bad configuration is an error
  g_lang = std::string(lg.id) + " dtype config errors";
  {
    Env env;
    std::string stmt = lg.l == L::Go ? "np.SetDefaultFloat(\"int32\")" : "np.default_float = \"int32\"";
    std::string m = env.run(lg, sy.catch_message("", stmt, false)).as<std::string>();
    CHECK_EQ(m, std::string("np: default_float must be float32 or float64"));
  }
  g_lang = lg.id;
}

// ============================================================================================================================
// the C backend
// ============================================================================================================================
static bool have_cc() {
  const char* cc = std::getenv("NFCUOP_CC");
  std::string cmd = std::string(cc && *cc ? cc : "cc") + " --version >/dev/null 2>&1";
  return std::system(cmd.c_str()) == 0;
}

static void check_backend(const Lang& lg) {
  Syn sy{lg.l};
  Session ref;
  Tensor a = ref.array({1, -2, 3, 4, 5, 6}, {2, 3}), w = ref.array({0.5, -1, 0.25, 2, 1, -0.5}, {3, 2});
  Array want = ref.eval(np::softmax(np::matmul(a, w) + 1).sum(0, true));
  std::string code = sy.assign("a", sy.call("np", "array", {sy.list2({{1, -2, 3}, {4, 5, 6}})})) +
                     sy.assign("w", sy.call("np", "array", {sy.list2({{0.5, -1}, {0.25, 2}, {1, -0.5}})})) +
                     sy.assign("y", sy.call(sy.call("np", "softmax", {sy.call(sy.call("a", "matmul", {"w"}), "add", {"1"})}), "sum", {"0", sy.yes()})) +
                     sy.set_prop("np", "backend", q("c")) +
                     sy.assign("r", sy.call("np", "eval", {"y"})) +
                     sy.result(sy.any_list({"r", sy.prop("np", "backend")}));
  Env env;
  Value v = env.run(lg, code);
  std::vector<Value> items = v.as<std::vector<Value>>();
  CHECK(items.size() == 2);
  if (items.size() != 2) return;
  CHECK(same(flat_of(items[0]), flat_of(want), false));  // the C backend computes what the interpreter does, bit for bit
  CHECK_EQ(items[1].as<std::string>(), std::string("c"));
  CHECK(env.s.backend == ut::Session::Backend::C);
  // and back
  Value back = env.run(lg, sy.set_prop("np", "backend", q("interpreter")) + sy.result(sy.prop("np", "backend")));
  CHECK_EQ(back.as<std::string>(), std::string("interpreter"));
  std::string bad = env.run(lg, sy.catch_message("", lg.l == L::Go ? "np.SetBackend(\"gpu\")" : "np.backend = \"gpu\"", false)).as<std::string>();
  CHECK(bad.find("backend is \"interpreter\" or \"c\"") != std::string::npos);
}

// ============================================================================================================================
// data in and out: nested lists, kinds, shapes, slices, reductions
// ============================================================================================================================
struct DataCase {
  const char* name;
  std::function<std::string(const Syn&)> expr;  // a script expression whose value is a number or nested list
  std::function<Array(Session&)> cpp;
};

static std::vector<DataCase> data_cases() {
  using S = const Syn&;
  auto np_ = [](S s, const char* fn, std::vector<std::string> a) { return s.call("np", fn, a); };
  auto m = [](S s, const std::string& o, const char* fn, std::vector<std::string> a = {}) { return s.call(o, fn, a); };
  auto ar = [=](S s, const char* n) { return np_(s, "arange", {n}); };
  auto cube = [=](S s) { return m(s, ar(s, "24"), "reshape", {"2", "3", "4"}); };
  return {
      {"int list", [=](S s) { return m(s, np_(s, "array", {s.list2({{1, 2, 3}, {4, 5, 6}}), q("int32")}), "tolist"); },
       [](Session& s) { return s.eval(s.array({1, 2, 3, 4, 5, 6}, {2, 3}, DType::Int32)); }},
      {"bool list", [=](S s) { return m(s, np_(s, "array", {s.list2({{1, 0}, {0, 1}}), q("bool")}), "tolist"); },
       [](Session& s) { return s.eval(s.array({1, 0, 0, 1}, {2, 2}, DType::Bool)); }},
      {"float64 list", [=](S s) { return m(s, np_(s, "array", {s.list1({0.1, 2.5}), q("float64")}), "tolist"); },
       [](Session& s) { return s.eval(s.array({0.1, 2.5}, DType::Float64)); }},
      {"0-d", [=](S s) { return m(s, np_(s, "array", {"3.5"}), "tolist"); }, [](Session& s) { return s.eval(s.scalar(3.5)); }},
      {"item int", [=](S s) { return m(s, np_(s, "array", {"7", q("int64")}), "item"); }, [](Session& s) { return s.eval(s.scalar(7, DType::Int64)); }},
      {"reshape ints", [=](S s) { return m(s, ar(s, "6"), "reshape", {"2", "3"}); }, [](Session& s) { return s.eval(s.arange(6).reshape({2, 3})); }},
      {"reshape -1", [=](S s) { return m(s, ar(s, "6"), "reshape", {s.ints({-1, 2})}); }, [](Session& s) { return s.eval(s.arange(6).reshape({-1, 2})); }},
      {"transpose", [=](S s) { return m(s, m(s, ar(s, "6"), "reshape", {"2", "3"}), "transpose", {"1", "0"}); },
       [](Session& s) { return s.eval(s.arange(6).reshape({2, 3}).transpose({1, 0})); }},
      {"T of cube", [=](S s) { return s.prop(cube(s), "T"); }, [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).T()); }},
      {"arange start stop step", [=](S s) { return np_(s, "arange", {"1", "10", "3"}); }, [](Session& s) { return s.eval(s.arange(1, 10, 3)); }},
      {"arange float step", [=](S s) { return np_(s, "arange", {"2.0", "0.0", "-0.5"}); }, [](Session& s) { return s.eval(s.arange(2.0, 0.0, -0.5)); }},
      {"arange dtype", [=](S s) { return np_(s, "arange", {"5", q("int64")}); }, [](Session& s) { return s.eval(s.arange(5, DType::Int64)); }},
      {"linspace", [=](S s) { return np_(s, "linspace", {"0", "1", "5"}); }, [](Session& s) { return s.eval(s.linspace(0, 1, 5)); }},
      {"eye", [=](S s) { return np_(s, "eye", {"2", q("int32")}); }, [](Session& s) { return s.eval(s.eye(2, DType::Int32)); }},
      {"full", [=](S s) { return np_(s, "full", {s.ints({2, 2}), "7"}); }, [](Session& s) { return s.eval(s.full({2, 2}, 7)); }},
      {"ones int", [=](S s) { return np_(s, "ones", {s.ints({2}), q("int32")}); }, [](Session& s) { return s.eval(s.ones({2}, DType::Int32)); }},
      {"zeros int shape", [=](S s) { return np_(s, "zeros", {"3"}); }, [](Session& s) { return s.eval(s.zeros({3})); }},
      {"slice", [=](S s) { return m(s, ar(s, "10"), "slice", {"0", "2", "8", "3"}); }, [](Session& s) { return s.eval(s.arange(10).slice(0, 2, 8, 3)); }},
      {"slice nil bounds", [=](S s) { return m(s, ar(s, "5"), "slice", {"0", s.nil(), s.nil(), "-1"}); },
       [](Session& s) { return s.eval(s.arange(5).slice(0, np::None, np::None, -1)); }},
      {"slice negative", [=](S s) { return m(s, ar(s, "5"), "slice", {"0", "-3", s.nil()}); }, [](Session& s) { return s.eval(s.arange(5).slice(0, -3, np::None)); }},
      {"at", [=](S s) { return m(s, m(s, ar(s, "6"), "reshape", {"2", "3"}), "at", {"1", "1"}); },
       [](Session& s) { return s.eval(s.arange(6).reshape({2, 3}).at(1, 1)); }},
      {"at negative", [=](S s) { return m(s, cube(s), "at", {"-1"}); }, [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).at(-1)); }},
      {"flip", [=](S s) { return m(s, m(s, ar(s, "6"), "reshape", {"2", "3"}), "flip", {"1"}); }, [](Session& s) { return s.eval(s.arange(6).reshape({2, 3}).flip(1)); }},
      {"index", [=](S s) { return m(s, cube(s), "index", {"1", q("1:"), q(":2")}); },
       [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).at(1).slice(0, 1, np::None).slice(1, np::None, 2)); }},
      {"index step", [=](S s) { return m(s, cube(s), "index", {s.nil(), q("::-1"), q("1:4:2")}); },
       [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).slice(1, np::None, np::None, -1).slice(2, 1, 4, 2)); }},
      {"sum axes", [=](S s) { return m(s, cube(s), "sum", {s.ints({0, 2})}); }, [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).sum(Axes{0, 2})); }},
      {"sum keepdims", [=](S s) { return m(s, cube(s), "sum", {"1", s.yes()}); }, [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).sum(1, true)); }},
      {"sum all", [=](S s) { return m(s, cube(s), "sum"); }, [](Session& s) { return s.eval(s.arange(24).sum()); }},
      {"mean", [=](S s) { return m(s, cube(s), "mean", {"-1"}); }, [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).mean(-1)); }},
      {"max min", [=](S s) { return m(s, np_(s, "maximum", {m(s, cube(s), "max", {"0"}), m(s, cube(s), "min", {"0"})}), "tolist"); },
       [](Session& s) {
         Tensor c = s.arange(24).reshape({2, 3, 4});
         return s.eval(np::maximum(c.max(0), c.min(0)));
       }},
      {"var std", [=](S s) { return np_(s, "stack", {s.any_list({m(s, cube(s), "var", {"2"}), m(s, cube(s), "std", {"2"})}), "1"}); },
       [](Session& s) {
         Tensor c = s.arange(24).reshape({2, 3, 4});
         return s.eval(np::stack({c.var(Axes{2}), c.stddev(Axes{2})}, 1));
       }},
      {"concatenate", [=](S s) { return np_(s, "concatenate", {s.any_list({ar(s, "3"), np_(s, "arange", {"10", "12"})})}); },
       [](Session& s) { return s.eval(np::concatenate({s.arange(3), s.arange(10, 12)})); }},
      {"squeeze expand", [=](S s) { return m(s, m(s, ar(s, "3"), "expand_dims", {"0"}), "squeeze"); }, [](Session& s) { return s.eval(s.arange(3).expand_dims(0).squeeze()); }},
      {"broadcast_to", [=](S s) { return m(s, ar(s, "3"), "broadcast_to", {s.ints({2, 3})}); }, [](Session& s) { return s.eval(s.arange(3).broadcast_to({2, 3})); }},
      {"swapaxes ravel", [=](S s) { return m(s, m(s, cube(s), "swapaxes", {"0", "2"}), "ravel"); }, [](Session& s) { return s.eval(s.arange(24).reshape({2, 3, 4}).swapaxes(0, 2).ravel()); }},
      {"astype", [=](S s) { return m(s, m(s, np_(s, "linspace", {"-2", "2", "5"}), "astype", {q("int32")}), "tolist"); },
       [](Session& s) { return s.eval(s.linspace(-2, 2, 5).astype(DType::Int32)); }},
      {"math", [=](S s) {
         Syn t = s;
         auto x = np_(s, "linspace", {"-2", "2", "5"});
         return np_(s, "stack", {s.any_list({m(t, x, "exp"), m(t, x, "sigmoid"), m(t, x, "tanh"), m(t, x, "sin"), m(t, x, "cos"), m(t, x, "relu"),
                                              m(t, x, "square"), m(t, m(t, x, "abs"), "sqrt"), m(t, x, "clip", {"-1", "1"}), m(t, x, "log_softmax")}), "0"});
       },
       [](Session& s) {
         Tensor x = s.linspace(-2, 2, 5);
         return s.eval(np::stack({x.exp(), x.sigmoid(), x.tanh(), x.sin(), x.cos(), x.relu(), x.square(), x.abs().sqrt(), x.clip(-1, 1), x.log_softmax()}, 0));
       }},
      {"reciprocal log", [=](S s) {
         auto x = np_(s, "arange", {"1", "5"});
         return np_(s, "stack", {s.any_list({m(s, m(s, x, "astype", {q("float32")}), "reciprocal"), m(s, m(s, x, "astype", {q("float32")}), "log")}), "0"});
       },
       [](Session& s) {
         Tensor x = s.arange(1, 5).astype(DType::Float32);
         return s.eval(np::stack({x.reciprocal(), x.log()}, 0));
       }},
      {"np.where scalars", [=](S s) { return np_(s, "where", {m(s, ar(s, "5"), "gt", {"2"}), ar(s, "5"), "-1"}); },
       [](Session& s) { Tensor i = s.arange(5); return s.eval(np::where(i > 2, i, np::detail::lift(i, -1, true))); }},
      {"np.maximum scalar", [=](S s) { return np_(s, "maximum", {np_(s, "linspace", {"0", "4", "5"}), "1.5"}); },
       [](Session& s) { Tensor x = s.linspace(0, 4, 5); return s.eval(np::maximum(x, np::detail::lift(x, 1.5, false))); }},
      {"np functions", [=](S s) {
         auto x = np_(s, "linspace", {"0", "3", "4"});
         return np_(s, "stack", {s.any_list({np_(s, "exp", {x}), np_(s, "softmax", {x}), np_(s, "relu", {np_(s, "minimum", {x, "1"})}), np_(s, "sqrt", {x}),
                                              np_(s, "reshape", {np_(s, "reshape", {x, s.ints({2, 2})}), s.ints({4})})}), "0"});
       },
       [](Session& s) {
         Tensor x = s.linspace(0, 3, 4);
         return s.eval(np::stack({x.exp(), np::softmax(x), np::relu(np::minimum(x, np::detail::lift(x, 1, true))), x.sqrt(), x.reshape({2, 2}).reshape({4})}, 0));
       }},
      {"np.sum mean", [=](S s) {
         auto x = np_(s, "reshape", {np_(s, "linspace", {"0", "3", "4"}), s.ints({2, 2})});
         return np_(s, "stack", {s.any_list({np_(s, "sum", {x, "1", s.yes()}), np_(s, "mean", {x, "1", s.yes()}), np_(s, "max", {x, "1", s.yes()}),
                                              np_(s, "min", {x, "1", s.yes()}), np_(s, "var", {x, "1", s.yes()}), np_(s, "std", {x, "1", s.yes()})}), "0"});
       },
       [](Session& s) {
         Tensor x = s.linspace(0, 3, 4).reshape({2, 2});
         return s.eval(np::stack({x.sum(1, true), x.mean(1, true), x.max(1, true), x.min(1, true), x.var(Axes{1}, true), x.stddev(Axes{1}, true)}, 0));
       }},
      {"np.sum all", [=](S s) { return np_(s, "sum", {np_(s, "linspace", {"0", "3", "4"})}); }, [](Session& s) { return s.eval(s.linspace(0, 3, 4).sum()); }},
      {"list operand", [=](S s) { return np_(s, "matmul", {s.list2({{1, 2}, {3, 4}}), s.list2({{1, 0}, {0, 1}})}); },
       [](Session& s) { return s.eval(np::matmul(s.array({1, 2, 3, 4}, {2, 2}), s.array({1, 0, 0, 1}, {2, 2}))); }},
      {"bool and logical_not", [=](S s) { return np_(s, "logical_not", {m(s, ar(s, "4"), "gt", {"1"})}); },
       [](Session& s) { return s.eval(np::logical_not(s.arange(4) > 1)); }},
  };
}

static void check_data(const Lang& lg) {
  Syn sy{lg.l};
  std::vector<DataCase> cases = data_cases();
  Session ref;
  std::vector<std::string> exprs;
  for (const DataCase& c : cases) exprs.push_back(c.expr(sy));
  // each expression is evaluated by itself: a failure names the case
  for (size_t k = 0; k < cases.size(); k++) {
    g_lang = std::string(lg.id) + " data " + cases[k].name;
    Env env;
    std::string code;
    std::string e = exprs[k];
    bool tensor_valued;
    {
      // tensor results are realized with tolist(); numbers and lists (from tolist/item) are returned as they are
      std::string t = e;
      tensor_valued = t.find("tolist") == std::string::npos && t.find("Tolist") == std::string::npos && t.find("item") == std::string::npos &&
                      t.find("Item") == std::string::npos;
    }
    code = sy.result(tensor_valued ? sy.call(e, "tolist") : e);
    Value v;
    try {
      v = env.run(lg, code);
    } catch (const std::exception& ex) {
      CHECK(false && "the script ran");
      std::printf("  %s\n  script: %s\n", ex.what(), code.c_str());
      continue;
    }
    Array want = cases[k].cpp(ref);
    CHECK(same(flat_of(v), flat_of(want), lg.l != L::Js));
    // the shape comes back as the nesting of the list
    if (want.shape.size() >= 1 && v.is_array()) CHECK(static_cast<int64_t>(v.as<std::vector<Value>>().size()) == want.shape[0]);
    if (want.shape.empty()) CHECK(!v.is_array());
  }
  g_lang = lg.id;
}

// ============================================================================================================================
// placeholders and feeds, str, properties
// ============================================================================================================================
static void check_misc(const Lang& lg) {
  Syn sy{lg.l};
  Session ref;
  {  // feeds: nested lists, a Tensor as data, several outputs at once
    g_lang = std::string(lg.id) + " feeds";
    Tensor x = ref.placeholder("x", {2, 2}), y = ref.placeholder("y", {2}, DType::Int32);
    Tensor f = x.sum(1) + y;
    Array want = ref.eval(f, {{"x", Array::from_doubles(DType::Float32, {2, 2}, {1, 2, 3, 4})}, {"y", Array::from_doubles(DType::Int32, {2}, {10, 20})}});
    std::string code = sy.assign("x", sy.call("np", "placeholder", {q("x"), sy.ints({2, 2})})) +
                       sy.assign("y", sy.call("np", "placeholder", {q("y"), sy.ints({2}), q("int32")})) +
                       sy.assign("f", sy.call(sy.call("x", "sum", {"1"}), "add", {"y"})) +
                       sy.result(sy.call("np", "eval", {"f", sy.any_list({sy.any_list({q("x"), sy.list2({{1, 2}, {3, 4}})}),
                                                                           sy.any_list({q("y"), sy.call("np", "array", {sy.list1({10, 20}), q("int32")})})})}));
    Env env;
    CHECK(same(flat_of(env.run(lg, code)), flat_of(want), false));
    // eval_all: several tensors, one lowering
    std::string code2 = sy.assign("x", sy.call("np", "placeholder", {q("x"), sy.ints({2})})) +
                        sy.assign("a", sy.call("x", "add", {"1"})) + sy.assign("b", sy.call("x", "mul", {"2"})) +
                        sy.result(sy.call("np", "eval_all", {sy.any_list({"a", "b"}), sy.any_list({sy.any_list({q("x"), sy.list1({5, 6})})})}));
    Env env2;
    std::vector<Value> r = env2.run(lg, code2).as<std::vector<Value>>();
    CHECK(r.size() == 2);
    if (r.size() == 2) {
      CHECK(flat_of(r[0]).v == (std::vector<double>{6, 7}));
      CHECK(flat_of(r[1]).v == (std::vector<double>{10, 12}));
    }
  }
  {  // str / printing
    g_lang = std::string(lg.id) + " str";
    std::string arr = sy.call("np", "array", {sy.list2({{1, 2}, {3, 4}})});
    std::string str = lg.l == L::Python ? "str(" + arr + ")" : lg.l == L::Ruby ? arr + ".to_s" : lg.l == L::Lua ? "tostring(" + arr + ")" :
                      lg.l == L::Js ? "String(" + arr + ")" : arr + ".Str()";
    Env env;
    CHECK_EQ(env.run(lg, sy.result(str)).as<std::string>(), std::string("[[1., 2.], [3., 4.]]"));
    std::string via_method = sy.call(arr, "str");
    Env env2;
    CHECK_EQ(env2.run(lg, sy.result(via_method)).as<std::string>(), std::string("[[1., 2.], [3., 4.]]"));
  }
  {  // a Tensor is a C++ np::Tensor, and a C++ tensor is a script value
    g_lang = std::string(lg.id) + " interop";
    Env env;
    Value t = env.run(lg, sy.result(sy.call(sy.call("np", "arange", {"4"}), "mul", {"2"})));
    np::Tensor c = t.as<np::Tensor>();
    CHECK(env.s.eval(c).data[3].as_double() == 6);
    CHECK(&c.session() == &env.s);
    Value total = t.call("sum");  // a method called from C++
    CHECK(total.as<np::Tensor>().item() == 12);
    env.ctx.set("shared", c);
    Value r = env.run(lg, sy.result(sy.call(sy.call("shared", "add", {"1"}), "values")));
    CHECK(flat_of(r).v == (std::vector<double>{1, 3, 5, 7}));
    // a C++ error from a call made by C++ comes out as the C++ exception
    bool threw = false;
    try {
      t.call("reshape", 5);
    } catch (const Error& e) {
      threw = std::string(e.what()).find("cannot reshape") != std::string::npos;
    }
    CHECK(threw);
  }
  {  // a loop that makes thousands of tensors (the collectors of the interpreters release them)
    g_lang = std::string(lg.id) + " many tensors";
    std::string loop;
    switch (lg.l) {
      case L::Python: loop = "x = np.zeros([1])\nfor _ in range(1000):\n    x = x.add(1)\nx.item()\n"; break;
      case L::Ruby: loop = "x = np.zeros([1])\n1000.times { x = x.add(1) }\nx.item\n"; break;
      case L::Lua: loop = "local x = np:zeros({1})\nfor _ = 1, 1000 do x = x:add(1) end\nreturn x:item()\n"; break;
      case L::Js: loop = "let x = np.zeros([1]); for (let i = 0; i < 1000; i++) { x = x.add(1); } x.item()\n"; break;
      case L::Go: loop = "x := np.Zeros([]int{1})\nfor i := 0; i < 1000; i++ { x = x.Add(1) }\nx.Item()\n"; break;
    }
    Env env;
    CHECK(flat_of(env.run(lg, loop)).v == (std::vector<double>{1000}));
  }
}

// ============================================================================================================================
// language-specific syntax: Python's indexing and operators, Ruby's ranges
// ============================================================================================================================
static void check_python() {
  Lang lg{L::Python, "python", "Python"};
  g_lang = "python only";
  Session ref;
  Tensor c = ref.arange(24).reshape({2, 3, 4});
  struct P {
    const char* expr;
    Array want;
  };
  std::vector<P> cases = {
      {"a[1]", ref.eval(c.at(1))},
      {"a[-1, -1]", ref.eval(c.at(-1).at(-1))},
      {"a[:, 1]", ref.eval(c.at(1, 1))},
      {"a[0, 1:3, ::2]", ref.eval(c.at(0).slice(0, 1, 3).slice(1, np::None, np::None, 2))},
      {"a[1:, ::-1, 2]", ref.eval(c.slice(0, 1, np::None).slice(1, np::None, np::None, -1).at(2, 2))},
      {"a[:, :, -1]", ref.eval(c.at(-1, 2))},
      {"a[0][1][2]", ref.eval(c.at(0).at(1).at(2))},
      {"a[::2]", ref.eval(c.slice(0, np::None, np::None, 2))},
      {"a[:, 1:2]", ref.eval(c.slice(1, 1, 2))},
      {"a[:-1, -2:]", ref.eval(c.slice(0, np::None, -1).slice(1, -2, np::None))},
      {"abs(a - 5)", ref.eval((c - 5).abs())},
      {"-a + a", ref.eval(-c + c)},
      {"(a + 1)[0, 0]", ref.eval((c + 1).at(0).at(0))},
      {"a.reshape((6, 4)).T @ a.reshape((6, 4))", ref.eval(np::matmul(c.reshape({6, 4}).T(), c.reshape({6, 4})))},
  };
  Env env;
  env.run(lg, "a = np.arange(24).reshape(2, 3, 4)\n");
  for (const P& p : cases) {
    g_lang = std::string("python ") + p.expr;
    Value v = env.run(lg, std::string("(") + p.expr + ").tolist()");
    CHECK(same(flat_of(v), flat_of(p.want), true));
  }
  g_lang = "python only";
  // repr, hash and comparisons keep Python's protocol
  CHECK_EQ(env.run(lg, "repr(np.array([1, 2]))").as<std::string>(), std::string("[1., 2.]"));
  CHECK_EQ(env.run(lg, "isinstance(hash(a), int)").as<bool>(), true);
  CHECK_EQ(env.run(lg, "a is a").as<bool>(), true);
  // keyword arguments are not supported by bound functions: a clear error
  std::string kw = env.run(lg, Syn{L::Python}.catch_message("", "np.array([1], dtype='int32')")).as<std::string>();
  CHECK(kw.find("keyword") != std::string::npos);
  // the wrong-typed operand of an operator is an error from the library
  std::string bad = env.run(lg, Syn{L::Python}.catch_message("", "a + 'x'")).as<std::string>();
  CHECK(bad.find("np: unsupported operand") != std::string::npos);
  // a tuple of ints for a shape, tuples of pairs for feeds
  CHECK(flat_of(env.run(lg, "np.eval(np.placeholder('q', (2,)) + 1, (('q', (1, 2)),))")).v == (std::vector<double>{2, 3}));
  // 2 ** a is not an operator of the API
  std::string pw = env.run(lg, Syn{L::Python}.catch_message("", "a ** 2")).as<std::string>();
  CHECK(pw.find("unsupported operand") != std::string::npos);
}

static void check_ruby() {
  Lang lg{L::Ruby, "ruby", "Ruby"};
  g_lang = "ruby only";
  Session ref;
  Tensor c = ref.arange(24).reshape({2, 3, 4});
  struct P {
    const char* expr;
    Array want;
  };
  std::vector<P> cases = {
      {"a[1]", ref.eval(c.at(1))},
      {"a[-1, -1]", ref.eval(c.at(-1).at(-1))},
      {"a[nil, 1]", ref.eval(c.at(1, 1))},
      {"a[0, 1..2]", ref.eval(c.at(0).slice(0, 1, 3))},
      {"a[0, 1...2]", ref.eval(c.at(0).slice(0, 1, 2))},
      {"a[1..-1, nil, 2]", ref.eval(c.slice(0, 1, np::None).at(2, 2))},
      {"a[0..-1]", ref.eval(c)},
      {"a[0, -2..-1]", ref.eval(c.at(0).slice(0, -2, np::None))},
      {"a[0, '::2']", ref.eval(c.at(0).slice(0, np::None, np::None, 2))},
      {"(a + 1)[0, 0]", ref.eval((c + 1).at(0).at(0))},
      {"-a + a", ref.eval(-c + c)},
  };
  Env env;
  env.run(lg, "a = np.arange(24).reshape(2, 3, 4)\n");
  for (const P& p : cases) {
    g_lang = std::string("ruby ") + p.expr;
    Value v = env.run(lg, std::string("(") + p.expr + ").tolist");
    CHECK(same(flat_of(v), flat_of(p.want), true));
  }
  g_lang = "ruby only";
  CHECK_EQ(env.run(lg, "np.array([1, 2]).inspect").as<std::string>(), std::string("[1., 2.]"));
  // 2 - a is not supported by mruby's Integer: a TypeError, not a wrong answer
  CHECK_EQ(env.run(lg, Syn{L::Ruby}.catch_message("", "2 - a")).as<std::string>().empty(), false);
  CHECK(env.run(lg, "(a == a.reshape(2, 3, 4)).class.to_s").as<std::string>() == "Tensor");
  CHECK_EQ(env.run(lg, "[a.respond_to?(:+), a.respond_to?(:-@), a.respond_to?(:[]), a.respond_to?(:matmul)].all?").as<bool>(), true);
}

static int run_all(int argc, char** argv);

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  try {
    return run_all(argc, argv);
  } catch (const std::exception& e) {  // a script or conversion error nothing expected: say where
    std::printf("FAIL [%s] uncaught %s\n", g_lang.c_str(), e.what());
    return 1;
  }
}

static int run_all(int argc, char** argv) {
  collect_languages();
  std::string out_dir = argc > 1 ? argv[1] : "";
  if (g_langs.empty()) {
    std::printf("SKIP uop/test_poly: no script language linked in (-DTEST_RUBY, -DTEST_LUA, -DTEST_PYTHON, -DTEST_JS, -DTEST_GO)\n");
    return 0;
  }
  for (const Lang& lg : g_langs) {
    g_lang = lg.id;
    std::printf("-- %s\n", lg.title);
    int before = failed, checks_before = checks;
    test_model(lg, out_dir);
    check_ops(lg, false);
    if (lg.l == L::Python || lg.l == L::Ruby || lg.l == L::Lua) check_ops(lg, true);
    check_errors(lg);
    check_dtypes(lg);
    check_data(lg);
    check_misc(lg);
    check_to_onnx(lg);
    if (have_cc()) check_backend(lg);
    else std::printf("   SKIP the C backend (no C compiler: $NFCUOP_CC or cc)\n");
    if (lg.l == L::Python) check_python();
    if (lg.l == L::Ruby) check_ruby();
    std::printf("   %s: %s (%d checks)\n", lg.id, failed == before ? "ok" : "FAILED", checks - checks_before);
  }
  std::printf("%s: %d checks, %d failed\n", failed ? "FAIL" : "all passed", checks, failed);
  return failed ? 1 : 0;
}
