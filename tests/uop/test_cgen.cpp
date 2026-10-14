// nfcuop C rendering (nfcuop_cgen.hpp): what gets fused, and that the generated C computes exactly what the interpreter
// computes: on hand-written graphs, on random scalar, integer-tensor and float-tensor graphs (each batch is one compiled
// program), on every dtype, and through the numpy-like API. Compiles C with $NFCUOP_CC or cc.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <limits>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_arena.hpp"
#include "nfcuop_np.hpp"

using namespace nfcuop;

static int checks = 0, failed = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond)) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
#define CHECK_THROWS(expr)                                                 \
  do {                                                                     \
    checks++;                                                              \
    bool threw_ = false;                                                   \
    try { (void)(expr); } catch (const Error&) { threw_ = true; }          \
    if (!threw_) { failed++; std::printf("FAIL %s:%d: no Error from %s\n", __FILE__, __LINE__, #expr); } \
  } while (0)

static const DType f32 = DType::Float32, f64 = DType::Float64, i32 = DType::Int32, i64 = DType::Int64, bl = DType::Bool;

// equal bit for bit, except that every NaN equals every NaN
static bool same(const Scalar& a, const Scalar& b) {
  if (is_float(a.dtype) && is_float(b.dtype) && std::isnan(a.f) && std::isnan(b.f)) return a.dtype == b.dtype;
  return a == b;
}
static bool same(const Array& a, const Array& b) {
  if (a.dtype != b.dtype || a.shape != b.shape || a.data.size() != b.data.size()) return false;
  for (size_t k = 0; k < a.data.size(); k++) if (!same(a.data[k], b.data[k])) return false;
  return true;
}

using Env = std::map<std::string, Array>;

// The program for `roots`, compiled once, run on every env, compared with the interpreter.
static void compare_run(const std::vector<const UOp*>& roots, const std::vector<Env>& envs, const char* label,
                        const RenderOptions& options = RenderOptions()) {
  CProgram p = render_c(roots, options);
  std::shared_ptr<CModule> m = CModule::compile(p);
  int bad = 0;
  for (const Env& env : envs) {
    std::vector<Array> got = m->run(env);
    for (size_t k = 0; k < roots.size(); k++) {
      Array want = evaluate_array(roots[k], env);
      checks++;
      if (!same(want, got[k])) {
        if (bad++ < 3) std::printf("FAIL %s: output %zu differs\n%s", label, k, dump(roots[k]).c_str());
        failed++;
      }
    }
  }
}

static void structure() {
  Graph g;
  const UOp* x = g.var("x", f32, {2, 3});
  const UOp* y = g.var("y", f32, {2, 3});
  auto prog = [&](std::vector<const UOp*> u) { return render_c(u); };
  // elementwise chains and movement ops fuse into one loop nest with no temporary
  CProgram p = prog({g.mul(g.add(x, y), g.neg(x))});
  CHECK(p.kernels == 1 && p.temporaries == 0 && p.inputs.size() == 2 && p.inputs[0].name == "x" && p.inputs[1].name == "y");
  CHECK(p.source.find("malloc(") == std::string::npos && p.source.find("nfcuop_run") != std::string::npos);
  p = prog({g.add(g.permute(x, {1, 0}), g.reshape(g.expand(g.reshape(g.var("z", f32, {3}), {3, 1}), {3, 2}), {3, 2}))});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  p = prog({g.pad(g.shrink(g.flip(x, {1}), {0, 1}, {2, 3}), {1, 0}, {0, 2})});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  // a reduction is a loop nest of its own, with its producer fused inside it
  p = prog({g.reduce_sum(g.mul(x, y), {1})});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  // softmax: max, shifted exp (used twice), sum, divide
  const UOp* mx = g.expand(g.reduce_max(x, {1}), {2, 3});
  const UOp* e = g.exp2(g.sub(x, mx));
  const UOp* sm = g.fdiv(e, g.expand(g.reduce_sum(e, {1}), {2, 3}));
  p = prog({sm});
  CHECK(p.kernels == 4 && p.temporaries == 3);
  // a node used twice is computed once if it is real work, and not at all if it is only an index change
  const UOp* s = g.add(x, y);
  p = prog({g.mul(s, s)});
  CHECK(p.kernels == 2 && p.temporaries == 1);
  const UOp* t = g.permute(x, {1, 0});
  p = prog({g.mul(t, t)});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  // sharing cannot blow the code up: 40 levels of a + a are 40 loop nests, not 2^40 terms
  const UOp* a = x;
  for (int k = 0; k < 40; k++) a = g.add(a, a);
  p = prog({a});
  CHECK(p.kernels == 40 && p.source.size() < 200000);
  // several outputs share their common subgraph; an output given twice, and outputs that are leaves
  p = prog({s, g.mul(s, x)});
  CHECK(p.kernels == 2 && p.temporaries == 0 && p.outputs.size() == 2);
  p = prog({s, s});
  CHECK(p.kernels == 1 && p.outputs.size() == 2);
  p = prog({x, g.fconst(f32, 2.5, {2}), g.fconst(f32, 1.5)});
  CHECK(p.kernels == 3);
  compare_run({s, s, x, g.fconst(f32, 2.5, {2}), g.fconst(f32, 1.5), g.mul(s, x)},
              {Env{{"x", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}, {"y", Array::from_doubles(f32, {2, 3}, {6, 5, 4, 3, 2, 1})}}}, "outputs");
  CHECK_THROWS(prog({}));
  CHECK_THROWS(prog({g.var("x", f32, {3}), x}));  // one name, two shapes
  // run() checks its inputs
  auto m = CModule::compile(prog({s}));
  CHECK_THROWS(m->run({}));
  CHECK_THROWS(m->run({{"x", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}}));
  CHECK_THROWS(m->run({{"x", Array::from_doubles(f32, {3, 2}, {1, 2, 3, 4, 5, 6})}, {"y", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}}));
  CHECK_THROWS(m->run({{"x", Array::from_doubles(f64, {2, 3}, {1, 2, 3, 4, 5, 6})}, {"y", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}}));
  // compile errors carry the compiler's words
  CProgram broken = p;
  broken.source = "int nfcuop_run( this is not C";
  try { CModule::compile(broken); CHECK(false); } catch (const Error& er) { CHECK(std::string(er.what()).find("error") != std::string::npos); }
  CHECK_THROWS(CModule::compile(p, "no-such-compiler-nfcuop"));
}

// ---- the arena: intermediates share one malloc'd arena, planned by liveness (nfcuop_arena.hpp) ----

// a[k+1] = (a[k] + expand(sum of the rows of a[k])) / 2: each step reads the previous tensor and its reduction, so a tensor
// is live only over the next step or two.
static std::vector<const UOp*> halving_chain(Graph& g, const UOp* x, int steps) {
  std::vector<const UOp*> a{x};
  const Shape s = x->shape;
  for (int k = 0; k < steps; k++) {
    const UOp* r = g.reduce_sum(a.back(), {1});   // [R, 1]
    a.push_back(g.mul(g.add(a.back(), g.expand(r, s)), g.fconst(f32, 0.5, s)));
  }
  return a;
}

static ArenaTensor tensor(const std::string& name, int64_t size, int start, int end) {
  ArenaTensor t;
  t.name = name;
  t.size = size;
  t.start = start;
  t.end = end;
  return t;
}

static void arena() {
  // the planner: a tensor may reuse the bytes of one that is dead before it starts, never of one live at the same step
  ArenaPlan q = plan_arena({tensor("a", 100, 0, 1), tensor("b", 100, 2, 3)}, 16);
  CHECK(q.offsets.at("a") == 0 && q.offsets.at("b") == 0 && q.arena_bytes == 112);
  ArenaPlan o = plan_arena({tensor("a", 100, 0, 2), tensor("b", 100, 2, 3)}, 16);   // step 2 is in both intervals
  CHECK(o.offsets.at("a") == 0 && o.offsets.at("b") == 112 && o.arena_bytes == 224);
  CHECK(plan_arena({}, 16).arena_bytes == 0);
  CHECK_THROWS(plan_arena({tensor("a", 1, 0, 0), tensor("a", 1, 0, 0)}, 16));   // two names
  CHECK_THROWS(plan_arena({tensor("a", 0, 0, 0)}, 16));                         // an empty size
  CHECK_THROWS(plan_arena({tensor("a", 1, 2, 1)}, 16));                         // an empty interval
  CHECK_THROWS(plan_arena({tensor("a", 1, 0, 0)}, 0));                          // an alignment of 0
  // random intervals: overlapping tensors never share bytes, offsets are aligned, the arena holds everything live at once
  // and is at most one slot per tensor
  unsigned long long seed = 4242;
  auto rnd = [&seed](unsigned n) {
    seed = seed * 6364136223846793005ull + 1442695040888963407ull;
    return static_cast<unsigned>((seed >> 33) % n);
  };
  for (int trial = 0; trial < 200; trial++) {
    std::vector<ArenaTensor> ts;
    const int n = 1 + static_cast<int>(rnd(40));
    for (int i = 0; i < n; i++) {
      const int start = static_cast<int>(rnd(30));
      ts.push_back(tensor("t" + std::to_string(i), 1 + static_cast<int64_t>(rnd(300)), start, start + static_cast<int>(rnd(6))));
    }
    const ArenaPlan pl = plan_arena(ts, 16);
    bool ok = true;
    int64_t sum = 0;
    for (size_t i = 0; i < ts.size(); i++) {
      const int64_t off = pl.offsets.at(ts[i].name), sz = (ts[i].size + 15) / 16 * 16;
      ok = ok && off % 16 == 0 && off + sz <= pl.arena_bytes;
      sum += sz;
      for (size_t j = 0; j < i; j++) {
        const int64_t off2 = pl.offsets.at(ts[j].name), sz2 = (ts[j].size + 15) / 16 * 16;
        const bool live_together = !(ts[i].end < ts[j].start || ts[j].end < ts[i].start);
        if (live_together) ok = ok && (off + sz <= off2 || off2 + sz2 <= off);
      }
    }
    ok = ok && pl.arena_bytes <= sum;
    for (int s = 0; s < 36; s++) {
      int64_t live = 0;
      for (const ArenaTensor& t : ts) if (t.start <= s && s <= t.end) live += (t.size + 15) / 16 * 16;
      ok = ok && pl.arena_bytes >= live;
    }
    CHECK(ok);
  }

  // the chain on the C backend: 10 steps of 32 x 128 float32 tensors (16 KB each) and 10 reductions (128 bytes each)
  Graph g;
  const Shape xs{32, 128};
  const UOp* x = g.var("x", f32, xs);
  const std::vector<const UOp*> a = halving_chain(g, x, 10);
  std::vector<double> vals;
  for (int i = 0; i < 32 * 128; i++) vals.push_back((i * 37) % 101 - 50 + 0.25 * (i % 4));
  const Env env{{"x", Array::from_doubles(f32, xs, vals)}};
  const CProgram p = render_c({a[10]});
  CHECK(p.temporaries == 19 && p.unplanned == 0 && p.naive_bytes == 9 * 16384 + 10 * 128);
  // two of the 16 KB tensors and one reduction are live at once (the peak); the planner reaches it
  CHECK(p.arena_bytes == 2 * 16384 + 128 && p.arena_bytes * 4 < p.naive_bytes);
  CHECK(p.source.find("malloc(") != std::string::npos && p.source.find("malloc(") == p.source.rfind("malloc("));   // one malloc: the arena
  compare_run({a[10]}, {env}, "arena chain");
  // an output that is also read by the next step is not in the arena, and stays correct
  compare_run({a[10], a[5]}, {env}, "arena chain with an intermediate output");

  // a symbol on the rows, with bounds: the arena is sized from the bound, and it is exact when the bound is the size
  RenderOptions sym;
  sym.input_symbols["x"] = {"N", ""};
  sym.symbol_bounds["N"] = 32;
  const CProgram ps = render_c({a[10]}, sym);
  CHECK(ps.arena_bytes == p.arena_bytes && ps.naive_bytes == p.naive_bytes && ps.unplanned == 0);
  sym.symbol_bounds["N"] = 64;   // every intermediate has the symbol as its first dimension, so the arena doubles
  const CProgram pb = render_c({a[10]}, sym);
  CHECK(pb.arena_bytes == 2 * p.arena_bytes && pb.naive_bytes == 2 * p.naive_bytes && pb.unplanned == 0);
  compare_run({a[10]}, {env}, "arena bounded", sym);
  sym.symbol_bounds["N"] = 16;   // x has 32 rows: the bound is below the input
  CHECK_THROWS(render_c({a[10]}, sym));
  sym.symbol_bounds["N"] = 0;
  CHECK_THROWS(render_c({a[10]}, sym));
  RenderOptions bad;
  bad.input_symbols["x"] = {"N"};   // one entry for two dimensions
  CHECK_THROWS(render_c({a[10]}, bad));
  bad.input_symbols.clear();                // no input q
  bad.input_symbols["q"] = {"N", ""};
  CHECK_THROWS(render_c({a[10]}, bad));
  // a symbol without a bound: each intermediate that depends on it keeps a malloc of its own, and the program is the same
  RenderOptions unbound;
  unbound.input_symbols["x"] = {"N", ""};
  const CProgram pu = render_c({a[10]}, unbound);
  CHECK(pu.arena_bytes == 0 && pu.unplanned == pu.temporaries && pu.temporaries == 19);
  compare_run({a[10]}, {env}, "arena unbounded", unbound);

  // A reshape that moves the symbol out of the leading dimension is not known, so its reduction keeps a malloc. The reduction
  // over the symbol's axis after a permute has no symbol left (an integer [128, 1]), so it is planned: 512 bytes.
  Graph h;
  const UOp* y = h.var("y", f32, {32, 128});
  const UOp* rr = h.reduce_sum(h.reshape(y, {128, 32}), {1});   // [128, 1]: the reshape moves N, so the size is not known
  const UOp* pr = h.reduce_sum(h.permute(y, {1, 0}), {1});      // [128, 1]: the reduction takes N away
  const UOp* both = h.add(h.mul(rr, h.fconst(f32, 2.0, {128, 1})), h.mul(pr, h.fconst(f32, 3.0, {128, 1})));
  RenderOptions ys;
  ys.input_symbols["y"] = {"N", ""};
  ys.symbol_bounds["N"] = 32;
  const CProgram py = render_c({both}, ys);
  CHECK(py.unplanned == 1 && py.temporaries == 2 && py.arena_bytes == 512);
  Env yenv{{"y", Array::from_doubles(f32, {32, 128}, vals)}};
  compare_run({both}, {yenv}, "arena reshape", ys);

  // two symbols on two axes: an intermediate's maximum is the product of the bounds. w = z * z is [N, M] (120 bytes, bounds
  // 5 and 7: 140, rounded to 144); r1 keeps N ([N, 1]: 32); r0 keeps M ([1, M]: 32). Live at once: all three at the last step.
  Graph k;
  const UOp* z = k.var("z", f32, {2, 3});
  const UOp* w = k.mul(z, z);                // used twice, so a buffer
  const UOp* r1 = k.reduce_sum(w, {1});      // [2, 1]
  const UOp* r0 = k.reduce_sum(w, {0});      // [1, 3]
  const UOp* sum2 = k.add(k.expand(r1, {2, 3}), k.expand(r0, {2, 3}));
  RenderOptions two;
  two.input_symbols["z"] = {"N", "M"};
  two.symbol_bounds["N"] = 5;
  two.symbol_bounds["M"] = 7;
  const CProgram pz = render_c({sum2}, two);
  CHECK(pz.temporaries == 3 && pz.unplanned == 0 && pz.naive_bytes == 144 + 32 + 32 && pz.arena_bytes == 208);
  Env zenv{{"z", Array::from_doubles(f32, {2, 3}, {1, -2, 3, 0.5, -0.25, 6})}};
  compare_run({sum2}, {zenv}, "arena two symbols", two);
  two.symbol_bounds["M"] = 2;                // z has 3 columns
  CHECK_THROWS(render_c({sum2}, two));
  two.symbol_bounds["M"] = 7;
  two.symbol_bounds.erase("N");              // N unbound: w and r1 keep a malloc of their own, r0 is planned
  const CProgram pm = render_c({sum2}, two);
  CHECK(pm.unplanned == 2 && pm.arena_bytes == 32);
}

// ---- random graphs ----

struct Rng {
  unsigned long long seed;
  unsigned operator()(unsigned n) { seed = seed * 6364136223846793005ull + 1442695040888963407ull; return static_cast<unsigned>((seed >> 33) % n); }
};

static void random_scalars() {
  Graph g;
  Rng rnd{12345};
  const UOp* x = g.var("x", i32);
  const UOp* y = g.var("y", i32);
  struct Gen {
    Graph& g; Rng& rnd; const UOp *x, *y;
    const UOp* leaf() {
      switch (rnd(7)) { case 0: return x; case 1: return y; default: return g.iconst(i32, static_cast<int>(rnd(7)) - 2); }
    }
    const UOp* boolean(int d) {
      if (d <= 0 || rnd(5) == 0) return rnd(2) ? g.cmplt(leaf(), leaf()) : g.cmpne(leaf(), leaf());
      switch (rnd(4)) {
        case 0: return g.band(boolean(d - 1), boolean(d - 1));
        case 1: return g.bor(boolean(d - 1), boolean(d - 1));
        case 2: return g.bxor(boolean(d - 1), boolean(d - 1));
        default: return g.cmplt(num(d - 1), num(d - 1));
      }
    }
    const UOp* num(int d) {
      if (d <= 0 || rnd(6) == 0) return leaf();
      switch (rnd(12)) {
        case 0: return g.add(num(d - 1), num(d - 1));
        case 1: return g.sub(num(d - 1), num(d - 1));
        case 2: return g.mul(num(d - 1), num(d - 1));
        case 3: return g.max(num(d - 1), num(d - 1));
        case 4: return g.band(num(d - 1), num(d - 1));
        case 5: return g.bor(num(d - 1), num(d - 1));
        case 6: return g.bxor(num(d - 1), num(d - 1));
        case 7: return g.neg(num(d - 1));
        case 8: return g.where(boolean(d - 1), num(d - 1), num(d - 1));
        case 9: return g.idiv(num(d - 1), g.iconst(i32, 1 + rnd(3)));
        case 10: return g.mod(num(d - 1), g.iconst(i32, 1 + rnd(3)));
        default: return g.cast(g.cast(num(d - 1), f32), i32);
      }
    }
  } gen{g, rnd, x, y};
  std::vector<const UOp*> roots;
  for (int k = 0; k < 250; k++) roots.push_back(gen.num(5));
  std::vector<Env> envs;
  for (int vx : {-3, -1, 0, 1, 2, 7, 2147483647})
    for (int vy : {-2, 0, 1, 5, -2147483647 - 1})
      envs.push_back(Env{{"x", Array(i32, {}, {Scalar::from_int(i32, vx)})}, {"y", Array(i32, {}, {Scalar::from_int(i32, vy)})}});
  compare_run(roots, envs, "random scalars");
}

static void random_int_tensors() {
  Graph g;
  Rng rnd{777};
  const UOp* a = g.var("a", i32, {2, 3, 2});
  std::vector<const UOp*> roots;
  for (int t = 0; t < 150; t++) {
    const UOp* e = a;
    for (int step = 0; step < 6; step++) {
      switch (rnd(12)) {
        case 0: {
          size_t r = e->shape.size();
          Shape perm;
          for (size_t k = 0; k < r; k++) perm.push_back(static_cast<int64_t>(rnd(2) ? (k + 1) % r : r - 1 - k));
          std::vector<bool> seen(r, false);
          bool ok = true;
          for (int64_t q : perm) { ok = ok && !seen[q]; seen[q] = true; }
          if (ok) e = g.permute(e, perm);
          break;
        }
        case 1: { int64_t n = numel(e->shape); e = g.reshape(g.reshape(e, {n}), {1, n}); break; }
        case 2: { Shape ax{static_cast<int64_t>(rnd(static_cast<unsigned>(e->shape.size())))}; e = g.reduce_sum(e, ax); break; }
        case 3: { Shape ax{static_cast<int64_t>(rnd(static_cast<unsigned>(e->shape.size())))}; e = g.reduce_max(e, ax); break; }
        case 4: e = g.add(e, g.iconst(i32, static_cast<int>(rnd(3)), e->shape)); break;
        case 5: e = g.mul(e, g.iconst(i32, static_cast<int>(rnd(3)) - 1, e->shape)); break;
        case 6: e = g.sub(e, e); e = g.add(e, g.neg(e)); break;
        case 7: { Shape s = e->shape; if (s.back() == 1) { s.back() = 3; e = g.expand(e, s); } break; }
        case 8: { Shape r = e->shape, lo(r.size(), 0), hi = r; size_t ax = rnd(static_cast<unsigned>(r.size())); if (r[ax] > 1) lo[ax] = 1; e = g.shrink(e, lo, hi); break; }
        case 9: { Shape z(e->shape.size(), 0), a2 = z; a2[rnd(static_cast<unsigned>(z.size()))] = static_cast<int64_t>(rnd(2) + 1); e = g.pad(e, z, a2); break; }
        case 10: { Shape ax{static_cast<int64_t>(rnd(static_cast<unsigned>(e->shape.size())))}; e = g.flip(e, ax); break; }
        default: e = g.where(g.cmplt(e, g.iconst(i32, 2, e->shape)), e, g.neg(e)); break;
      }
    }
    roots.push_back(e);
  }
  std::vector<Env> envs;
  for (int t = 0; t < 20; t++) {
    Array arr;
    arr.dtype = i32;
    arr.shape = {2, 3, 2};
    for (int k = 0; k < 12; k++) arr.data.push_back(Scalar::from_int(i32, static_cast<int>(rnd(9)) - 4));
    envs.push_back(Env{{"a", arr}});
  }
  compare_run(roots, envs, "random int tensors");
  // the same graphs after symbolic(): the rewritten graph renders and agrees too
  std::vector<const UOp*> simplified;
  for (const UOp* r : roots) simplified.push_back(graph_rewrite(g, symbolic(), r));
  compare_run(simplified, envs, "random int tensors, simplified");
}

static void random_float_tensors() {
  Graph g;
  Rng rnd{4242};
  const UOp* f = g.var("f", f32, {2, 3});
  const UOp* h = g.var("h", f32, {2, 3});
  struct Gen {
    Graph& g; Rng& rnd; const UOp *f, *h;
    const UOp* leaf() {
      static const double c[] = {0.5, -1, 2, 0, 3.25, -0.0, 1e30};
      switch (rnd(5)) { case 0: return f; case 1: return h; default: return g.fconst(f32, c[rnd(7)], {2, 3}); }
    }
    const UOp* num(int d) {
      if (d <= 0 || rnd(6) == 0) return leaf();
      switch (rnd(15)) {
        case 0: return g.add(num(d - 1), num(d - 1));
        case 1: return g.sub(num(d - 1), num(d - 1));
        case 2: return g.mul(num(d - 1), num(d - 1));
        case 3: return g.fdiv(num(d - 1), num(d - 1));
        case 4: return g.max(num(d - 1), num(d - 1));
        case 5: return g.neg(num(d - 1));
        case 6: return g.sqrt(num(d - 1));
        case 7: return g.exp2(num(d - 1));
        case 8: return g.log2(num(d - 1));
        case 9: return g.sin(num(d - 1));
        case 10: { const UOp* a = num(d - 1); const UOp* b = num(d - 1); return g.where(g.cmplt(a, b), a, b); }
        case 11: return g.cast(g.add(g.cast(num(d - 1), f64), g.cast(num(d - 1), f64)), f32);
        case 12: {  // a reduction over one axis, broadcast back
          const UOp* a = num(d - 1);
          int64_t ax = static_cast<int64_t>(rnd(2));
          const UOp* r = rnd(2) ? g.reduce_sum(a, {ax}) : g.reduce_max(a, {ax});
          return g.expand(r, {2, 3});
        }
        case 13: return g.flip(num(d - 1), {static_cast<int64_t>(rnd(2))});
        default: return g.permute(g.permute(num(d - 1), {1, 0}), {1, 0});
      }
    }
  } gen{g, rnd, f, h};
  std::vector<const UOp*> roots;
  for (int k = 0; k < 150; k++) roots.push_back(gen.num(5));
  std::vector<Env> envs;
  const double special[] = {0.0, -0.0, 1e30, -1e30, 1e-30, 3.5, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()};
  for (int t = 0; t < 14; t++) {
    Env env;
    for (const char* n : {"f", "h"}) {
      Array arr;
      arr.dtype = f32;
      arr.shape = {2, 3};
      for (int k = 0; k < 6; k++)
        arr.data.push_back(Scalar::from_double(f32, t >= 10 && rnd(3) == 0 ? special[rnd(8)] : (static_cast<double>(rnd(2001)) - 1000) / 250.0));
      env[n] = arr;
    }
    envs.push_back(env);
  }
  compare_run(roots, envs, "random float tensors");
}

// Random chains of operators on an input whose first axis is the symbol N. The bound of N is the input's own size, so an
// intermediate whose symbolic size is claimed wrongly would fail the render's check; the outputs must equal the interpreter's.
static void random_symbolic() {
  Rng rnd{777};
  for (int trial = 0; trial < 60; trial++) {
    Graph g;
    const int64_t rows = 1 + rnd(4);
    const UOp* x = g.var("x", f32, {rows, 6});
    std::vector<const UOp*> pool{x};
    const int steps = 3 + static_cast<int>(rnd(6));
    for (int s = 0; s < steps; s++) {
      const UOp* a = pool[rnd(static_cast<unsigned>(pool.size()))];
      const int64_t rank = static_cast<int64_t>(a->shape.size());
      const UOp* out = nullptr;
      switch (rnd(8)) {
        case 0: out = g.add(a, g.mul(a, g.fconst(f32, 0.5, a->shape))); break;
        case 1: out = g.reduce_sum(a, {static_cast<int64_t>(rnd(static_cast<unsigned>(rank)))}); break;
        case 2:
          if (rank == 2) out = g.permute(a, {1, 0});
          break;
        case 3:
          if (rank == 2 && a->shape[1] > 1) out = g.shrink(a, {0, 0}, {a->shape[0], a->shape[1] - 1});
          break;
        case 4:
          if (rank == 2) out = g.pad(a, {0, 0}, {0, 1});
          break;
        case 5:
          if (rank == 2) out = g.reshape(a, {a->shape[0], 1, a->shape[1]});   // keeps the leading axis
          break;
        case 6:
          if (rank == 2) out = g.reshape(a, {a->shape[1], a->shape[0]});      // moves it: not known
          break;
        default: out = g.flip(a, {rank - 1}); break;
      }
      if (out) pool.push_back(out);
    }
    const std::vector<const UOp*> roots{pool.back(), pool[rnd(static_cast<unsigned>(pool.size()))]};
    RenderOptions opts;
    opts.input_symbols["x"] = {"N", ""};
    opts.symbol_bounds["N"] = rows;
    std::vector<double> vals;
    for (int64_t i = 0; i < rows * 6; i++) vals.push_back(static_cast<double>((i * 7) % 11) - 5.0 + 0.125 * static_cast<double>(i % 3));
    const Env env{{"x", Array::from_doubles(f32, {rows, 6}, vals)}};
    compare_run(roots, {env}, "random symbolic", opts);
    // a bound above the size is fine as well: the arena is only larger
    opts.symbol_bounds["N"] = rows + 3;
    CHECK(render_c(roots, opts).arena_bytes >= 0);
  }
}

static void dtypes() {
  Graph g;
  // 64-bit integers: wrap, extremes, casts
  const UOp* p = g.var("p", i64);
  const UOp* q = g.var("q", i64);
  const UOp* big = g.iconst(i64, INT64_MAX);
  const UOp* mn = g.iconst(i64, INT64_MIN);
  std::vector<const UOp*> r = {
      g.add(p, big), g.mul(p, q), g.sub(mn, p), g.neg(mn), g.idiv(mn, g.iconst(i64, -1)), g.mod(mn, g.iconst(i64, -1)),
      g.idiv(p, g.iconst(i64, 7)), g.mod(p, g.iconst(i64, -7)), g.max(p, q), g.cast(p, i32), g.cast(g.cast(p, i32), i64),
      g.cast(p, f32), g.cast(p, f64), g.cast(p, bl), g.band(p, q), g.bor(p, q), g.bxor(p, q), g.cmplt(p, q), g.cmpne(p, q),
      g.where(g.cmplt(p, q), p, q), mn, big, g.reduce_sum(g.expand(g.reshape(p, {1}), {4}), {0}), g.reduce_max(g.expand(g.reshape(q, {1}), {3}), {0})};
  std::vector<Env> envs;
  for (int64_t vp : {int64_t(0), int64_t(1), int64_t(-1), INT64_MAX, INT64_MIN, int64_t(1) << 40, int64_t(-12345678901LL)})
    for (int64_t vq : {int64_t(3), int64_t(-3), INT64_MAX, INT64_MIN})
      envs.push_back(Env{{"p", Array(i64, {}, {Scalar::from_int(i64, vp)})}, {"q", Array(i64, {}, {Scalar::from_int(i64, vq)})}});
  compare_run(r, envs, "int64");
  // float64
  const UOp* u = g.var("u", f64);
  const UOp* v = g.var("v", f64);
  std::vector<const UOp*> d = {
      g.add(u, v), g.sub(u, v), g.mul(u, v), g.fdiv(u, v), g.max(u, v), g.neg(u), g.sqrt(u), g.exp2(u), g.log2(u), g.sin(u),
      g.cast(u, f32), g.cast(u, i32), g.cast(u, i64), g.cast(u, bl), g.cmplt(u, v), g.cmpne(u, v), g.fconst(f64, 0.1), g.fconst(f64, -0.0),
      g.fconst(f64, std::numeric_limits<double>::infinity()), g.fconst(f64, -std::numeric_limits<double>::infinity()),
      g.fconst(f64, std::numeric_limits<double>::quiet_NaN()), g.fconst(f32, 0.1), g.fconst(f32, std::numeric_limits<double>::max())};
  envs.clear();
  for (double vu : {0.0, -0.0, 1.0, -2.5, 3e10, -3e10, 1e19, -1e19, 2147483647.5, 0.1, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()})
    for (double vv : {1.0, -3.0, 0.0, 1e300})
      envs.push_back(Env{{"u", Array(f64, {}, {Scalar::from_double(f64, vu)})}, {"v", Array(f64, {}, {Scalar::from_double(f64, vv)})}});
  compare_run(d, envs, "float64");
  // bool, and ints around the 32-bit edge
  const UOp* b1 = g.var("b1", bl);
  const UOp* b2 = g.var("b2", bl);
  const UOp* k = g.var("k", i32);
  std::vector<const UOp*> b = {
      g.band(b1, b2), g.bor(b1, b2), g.bxor(b1, b2), g.cmpne(b1, b2), g.cmplt(b1, b2), g.where(b1, k, g.neg(k)), g.cast(b1, i32), g.cast(b1, f32),
      g.cast(b1, i64), g.cast(k, bl), g.cast(k, i64), g.cast(g.cast(k, f32), i32), g.idiv(k, g.iconst(i32, -1)), g.mod(k, g.iconst(i32, -1)),
      g.max(k, g.iconst(i32, INT32_MIN)), g.iconst(i32, INT32_MIN), g.iconst(i32, INT32_MAX), g.add(k, g.iconst(i32, INT32_MAX))};
  envs.clear();
  for (int vb1 : {0, 1}) for (int vb2 : {0, 1}) for (int vk : {0, 1, -1, INT32_MAX, INT32_MIN, 100000})
    envs.push_back(Env{{"b1", Array(bl, {}, {Scalar::from_int(bl, vb1)})}, {"b2", Array(bl, {}, {Scalar::from_int(bl, vb2)})}, {"k", Array(i32, {}, {Scalar::from_int(i32, vk)})}});
  compare_run(b, envs, "bool and int32");
  // division by zero: the interpreter throws, the C code gives 0
  const UOp* z = g.var("z", i32);
  const UOp* dz = g.idiv(g.iconst(i32, 7), z);
  const UOp* mz = g.mod(g.iconst(i32, 7), z);
  Env zero{{"z", Array(i32, {}, {Scalar::from_int(i32, 0)})}};
  CHECK_THROWS(evaluate_array(dz, zero));
  std::vector<Array> out = CModule::compile(render_c({dz, mz}))->run(zero);
  CHECK(out[0].data[0] == Scalar::from_int(i32, 0) && out[1].data[0] == Scalar::from_int(i32, 0));
}

// ---- through the numpy-like API ----

static void numpy_api() {
  using namespace nfcuop::np;
  Session np;
  Tensor x = np.placeholder("x", {2, 3});
  Tensor w = np.array({0.1, -0.2, 0.3, 0.4, 0.5, -0.6, 0.7, 0.8, -0.9, 1.0, 1.1, 1.2}, {3, 4});
  Tensor a = np.array({7, -7, 3, -3, 2, -5}, {2, 3}, i32);
  Tensor m = np.arange(24).reshape({2, 3, 4});
  std::vector<std::pair<std::string, Tensor>> cases = {
      {"mlp", softmax(relu(matmul(x, w) + 0.1))}, {"logsoftmax", (x * 3).log_softmax()}, {"var", x.var(Axes{1})}, {"std", x.stddev()},
      {"clip", x.clip(-1, 2)}, {"where", where(x > 0, x, -x * 2)}, {"slice", m.slice(2, None, None, 2).slice(1, 1, None)},
      {"neg_step", m.slice(2, None, None, -2)}, {"concat", concatenate({x, x * 2, x - 1}, 1)}, {"stack", stack({x, x + 1}, 2)},
      {"floor_divide", floor_divide(a, np.array({2, -2, 3}, i32))}, {"remainder", a % 3}, {"imatmul", matmul(a, a.T())},
      {"minmax", x.max(1) - x.min(0).sum()}, {"tanh", x.tanh() + x.sigmoid() + x.exp() * x.cos()}, {"mean", m.mean(Axes{0, 2})},
      {"cast", (x * 100).astype(i32).astype(DType::Float64)}, {"batched", matmul(m, np.ones({4, 2}))}};
  Env feeds{{"x", Array::from_doubles(f32, {2, 3}, {1, -2, 3, 0.5, -0.25, 6})}};
  std::vector<Tensor> ts;
  for (const auto& c : cases) ts.push_back(c.second);
  np.backend = ut::Session::Backend::Interpreter;
  std::vector<Array> want = np.eval_all(ts, feeds);
  np.backend = ut::Session::Backend::C;
  std::vector<Array> got = np.eval_all(ts, feeds);   // one program for all of them
  CHECK(np.uop_session().last_program() != nullptr && np.uop_session().last_program()->outputs.size() == cases.size());
  for (size_t k = 0; k < cases.size(); k++) {
    checks++;
    if (!same(want[k], got[k])) { failed++; std::printf("FAIL numpy api %s differs between the interpreter and C\n", cases[k].first.c_str()); }
  }
  CHECK(np.eval(cases[0].second, feeds).data[0] == want[0].data[0]);   // single tensor, C backend, cached module
  CHECK(cases[6].second.str().size() > 0);                               // str() works through the C backend
  // an eval with the optimizer off renders the unsimplified graph
  np.optimize = false;
  Array raw = np.eval(cases[4].second, feeds);
  np.optimize = true;
  CHECK(same(raw, want[4]));
  // 64-bit defaults
  Session wide;
  wide.default_float = f64;
  wide.default_int = i64;
  Tensor ints = wide.arange(10);
  Tensor fl = wide.linspace(0, 1, 10);
  std::vector<Tensor> t2 = {ints.sum(), (ints / 3).mean(), softmax(fl * 5), matmul(ints.reshape({2, 5}), ints.reshape({5, 2})), fl.var()};
  wide.backend = ut::Session::Backend::Interpreter;
  std::vector<Array> w2 = wide.eval_all(t2);
  wide.backend = ut::Session::Backend::C;
  std::vector<Array> g2 = wide.eval_all(t2);
  for (size_t k = 0; k < t2.size(); k++) CHECK(same(w2[k], g2[k]));
  CHECK(g2[0].dtype == i64 && g2[1].dtype == f64 && g2[0].data[0].i == 45);
}

int main(int argc, char** argv) {
  const bool quick = argc > 1 && std::string(argv[1]) == "quick";   // no random batches: for a slow C compiler
  auto timed = [](const char* what, void (*f)()) {
    auto t0 = std::chrono::steady_clock::now();
    f();
    if (std::getenv("NFCUOP_TIMING"))
      std::printf("  %-22s %.1f s\n", what, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
  };
  timed("structure", structure);
  timed("arena", arena);
  if (!quick) {
    timed("random scalars", random_scalars);
    timed("random int tensors", random_int_tensors);
    timed("random float tensors", random_float_tensors);
    timed("random symbolic", random_symbolic);
  }
  timed("dtypes", dtypes);
  timed("numpy api", numpy_api);
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
