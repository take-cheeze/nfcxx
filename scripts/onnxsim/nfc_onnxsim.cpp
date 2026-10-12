// A C ABI around onnxsim's C++ reverse-mode differentiator (graph_grad.cpp, qat_graph_builder.cpp), for lib/uop to dlopen
// (lib/uop/nfcuop_onnxgrad.cpp, docs/notes/uop-autodiff.md). Built by scripts/setup-onnxsim.sh into libnfconnxsim.so with
// onnx and protobuf; nothing of this is linked into nfcuop itself.
//
// nfc_onnxsim_gradients takes the bytes of a forward ModelProto (the sub-graph of a scalar float loss), the loss and the
// names to differentiate against, and returns a ModelProto holding the same forward nodes plus the gradient nodes, with one
// graph output `<prefix>grad_<k>` per name. scripts/onnx_grad.py does the same in Python (the fallback); keep the two in step.
#include <onnx/inliner/inliner.h>
#include <onnx/onnx_pb.h>
#include <onnx/shape_inference/implementation.h>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "graph_grad.h"
#include "qat_graph_builder.h"

namespace {

using onnx::TensorProto;

// The gradient nodes are built in float32 (GraphBuilder::Const, Cast to FLOAT for the masks); a float64 model gets the
// constants and the masks in float64.
void to_double(GraphBuilder& b) {
  for (TensorProto& t : b.initializer()) {
    if (t.data_type() != TensorProto::FLOAT) continue;
    std::vector<double> v;
    if (!t.raw_data().empty()) {
      const size_t n = t.raw_data().size() / 4;
      for (size_t k = 0; k < n; k++) {
        float f;
        std::memcpy(&f, t.raw_data().data() + 4 * k, 4);
        v.push_back(f);
      }
    } else {
      for (float f : t.float_data()) v.push_back(f);
    }
    t.clear_raw_data();
    t.clear_float_data();
    for (double& d : v) {
      // the mean rules build 1/N in float32; N is recovered so that float64 models get 1/N to double precision
      if (d > 0 && d < 1) {
        double n = std::floor(1.0 / d + 0.5);
        if (n >= 2 && static_cast<float>(1.0 / n) == static_cast<float>(d)) d = 1.0 / n;
      }
      t.add_double_data(d);
    }
    t.set_data_type(TensorProto::DOUBLE);
  }
  for (onnx::NodeProto& n : b.nodes())
    if (n.op_type() == "Cast")
      for (onnx::AttributeProto& a : *n.mutable_attribute())
        if (a.name() == "to" && a.i() == TensorProto::FLOAT) a.set_i(TensorProto::DOUBLE);
}

std::string run(const char* bytes, size_t n, const std::string& loss, const std::vector<std::string>& wrt, const std::string& prefix) {
  onnx::ModelProto model;
  if (!model.ParseFromArray(bytes, static_cast<int>(n))) throw std::invalid_argument("the forward model is not a valid ONNX ModelProto");
  onnx::shape_inference::InferShapes(model);
  onnx::GraphProto* graph = model.mutable_graph();

  std::map<std::string, std::vector<int64_t>> shapes;
  std::map<std::string, int> dtypes;
  auto note = [&](const onnx::ValueInfoProto& vi) {
    if (!vi.type().has_tensor_type()) return;
    const auto& tt = vi.type().tensor_type();
    std::vector<int64_t> dims;
    for (const auto& d : tt.shape().dim()) {
      if (!d.has_dim_value()) throw std::invalid_argument("value " + vi.name() + " has no static shape");
      dims.push_back(d.dim_value());
    }
    shapes[vi.name()] = dims;
    dtypes[vi.name()] = tt.elem_type();
  };
  for (const auto& v : graph->input()) note(v);
  for (const auto& v : graph->value_info()) note(v);
  for (const auto& v : graph->output()) note(v);
  for (const TensorProto& t : graph->initializer()) {
    shapes[t.name()] = std::vector<int64_t>(t.dims().begin(), t.dims().end());
    dtypes[t.name()] = t.data_type();
  }
  if (!shapes.count(loss)) throw std::invalid_argument("the loss " + loss + " is not a value of the model");
  if (!shapes[loss].empty()) throw std::invalid_argument("the loss " + loss + " must be a scalar, it has rank " + std::to_string(shapes[loss].size()));
  const int ldt = dtypes[loss];
  if (ldt != TensorProto::FLOAT && ldt != TensorProto::DOUBLE) throw std::invalid_argument("the loss " + loss + " must be float32 or float64");
  for (const std::string& w : wrt) {
    if (!shapes.count(w)) throw std::invalid_argument("cannot differentiate with respect to " + w + ": not a value of the model");
    if (dtypes[w] != TensorProto::FLOAT && dtypes[w] != TensorProto::DOUBLE) throw std::invalid_argument("cannot differentiate with respect to " + w + ": not a float value");
  }

  // the nodes the loss needs, and among them the ones that depend on a wrt: those are the slice to differentiate
  const int nn = graph->node_size();
  std::set<std::string> needed = {loss};
  std::vector<bool> need(static_cast<size_t>(nn), false);
  for (int k = nn; k-- > 0;) {
    const onnx::NodeProto& nd = graph->node(k);
    bool used = false;
    for (const std::string& o : nd.output()) used = used || needed.count(o);
    if (!used) continue;
    need[static_cast<size_t>(k)] = true;
    for (const std::string& i : nd.input()) if (!i.empty()) needed.insert(i);
  }
  std::set<std::string> dep(wrt.begin(), wrt.end());
  std::vector<onnx::NodeProto> slice;
  for (int k = 0; k < nn; k++) {
    if (!need[static_cast<size_t>(k)]) continue;
    const onnx::NodeProto& nd = graph->node(k);
    bool d = false;
    for (const std::string& i : nd.input()) d = d || (!i.empty() && dep.count(i));
    if (!d) continue;
    for (const std::string& o : nd.output()) dep.insert(o);
    slice.push_back(nd);
  }

  // targets the loss does not reach get a zero gradient: BuildBackward throws for them, so retry without
  std::vector<std::string> targets;
  for (const std::string& w : wrt) if (needed.count(w)) targets.push_back(w);
  std::unique_ptr<GraphBuilder> b;
  std::map<std::string, std::string> got;
  for (;;) {
    b.reset(new GraphBuilder(prefix));
    std::map<std::string, std::string> seeds;
    seeds[loss] = b->Const(1.0f, "seed");
    try {
      got = BuildBackward(*b, slice, shapes, seeds, targets);
      break;
    } catch (const UnsupportedOpError&) {
      throw;
    } catch (const std::invalid_argument& e) {
      std::string m = e.what();
      const std::string key = "no gradient reaches '";
      size_t p = m.find(key);
      if (p == std::string::npos) throw;
      size_t q = m.find('\'', p + key.size());
      std::string who = m.substr(p + key.size(), q - p - key.size());
      std::vector<std::string> keep;
      for (const std::string& t : targets) if (t != who) keep.push_back(t);
      if (keep.size() == targets.size()) throw;
      targets = keep;
    }
  }
  if (ldt == TensorProto::DOUBLE) to_double(*b);

  // the zero gradients, and one Identity per wrt so that every result has a name of its own
  std::vector<std::string> results;
  std::vector<onnx::NodeProto> tail;
  std::vector<TensorProto> tail_init;
  for (size_t k = 0; k < wrt.size(); k++) {
    auto it = got.find(wrt[k]);
    std::string src;
    if (it != got.end()) {
      src = it->second;
    } else {
      GraphBuilder z(prefix + "z" + std::to_string(k) + "_");
      const std::string zero = z.Const(0.0f, "zero");
      src = zero;
      if (!shapes[wrt[k]].empty()) src = z.Op("Expand", {zero, z.ConstInt64(shapes[wrt[k]], "shape")}, "zeros");
      if (dtypes[wrt[k]] == TensorProto::DOUBLE) to_double(z);
      for (const auto& nd : z.nodes()) tail.push_back(nd);
      for (const auto& t : z.initializer()) tail_init.push_back(t);
    }
    onnx::NodeProto id;
    id.set_op_type("Identity");
    id.add_input(src);
    id.add_output(prefix + "grad_" + std::to_string(k));
    results.push_back(id.output(0));
    tail.push_back(id);
  }

  // The templated rules emit calls of model-local functions, written for opset 17; they are inlined in a model of their own
  // (opset 17, the forward values it reads declared as inputs), because the inliner does not convert versions here.
  std::vector<onnx::NodeProto> gnodes(b->nodes().begin(), b->nodes().end());
  if (!b->functions().empty()) {
    onnx::ModelProto gm;
    gm.set_ir_version(model.ir_version());
    onnx::OperatorSetIdProto* base = gm.add_opset_import();
    base->set_domain("");
    base->set_version(17);
    std::set<std::string> domains;
    for (const onnx::FunctionProto& fn : b->functions()) {
      *gm.add_functions() = fn;
      if (domains.insert(fn.domain()).second) {
        onnx::OperatorSetIdProto* o = gm.add_opset_import();
        o->set_domain(fn.domain());
        o->set_version(1);
      }
    }
    onnx::GraphProto* gg = gm.mutable_graph();
    gg->set_name("rules");
    std::set<std::string> made;
    for (const auto& t : b->initializer()) { made.insert(t.name()); *gg->add_initializer() = t; }
    for (const auto& nd : b->nodes()) for (const std::string& o : nd.output()) made.insert(o);
    std::set<std::string> declared;
    for (const auto& nd : b->nodes())
      for (const std::string& i : nd.input()) {
        if (i.empty() || made.count(i) || !declared.insert(i).second) continue;
        onnx::ValueInfoProto* vi = gg->add_input();
        vi->set_name(i);
        onnx::TypeProto_Tensor* tt = vi->mutable_type()->mutable_tensor_type();
        tt->set_elem_type(dtypes.at(i));
        tt->mutable_shape();
        for (int64_t d : shapes.at(i)) tt->mutable_shape()->add_dim()->set_dim_value(d);
      }
    for (const auto& nd : b->nodes()) *gg->add_node() = nd;
    onnx::shape_inference::InferShapes(gm);
    onnx::inliner::InlineLocalFunctions(gm, false);
    gnodes.assign(gg->node().begin(), gg->node().end());
  }
  // every new name starts with the prefix (inlined bodies bring names like `tmp`, which may be a user's)
  std::set<std::string> fwd_names;
  for (const auto& v : graph->input()) fwd_names.insert(v.name());
  for (const auto& t : graph->initializer()) fwd_names.insert(t.name());
  for (int k = 0; k < nn; k++) for (const std::string& o : graph->node(k).output()) fwd_names.insert(o);
  auto fresh = [&](const std::string& nm) { return nm.empty() || fwd_names.count(nm) || nm.compare(0, prefix.size(), prefix) == 0 ? nm : prefix + nm; };
  for (auto& nd : gnodes) {
    for (std::string& i : *nd.mutable_input()) i = fresh(i);
    for (std::string& o : *nd.mutable_output()) o = fresh(o);
  }
  for (auto& t : b->initializer()) t.set_name(fresh(t.name()));
  for (auto& nd : tail) for (std::string& i : *nd.mutable_input()) i = fresh(i);

  onnx::ModelProto out;
  out.set_ir_version(model.ir_version());
  out.set_producer_name("nfcuop-onnxsim");
  *out.mutable_opset_import() = model.opset_import();
  onnx::GraphProto* og = out.mutable_graph();
  og->set_name("nfcuop_grad");
  for (const auto& v : graph->input()) *og->add_input() = v;
  for (const TensorProto& t : graph->initializer()) *og->add_initializer() = t;
  for (int k = 0; k < nn; k++) if (need[static_cast<size_t>(k)]) *og->add_node() = graph->node(k);
  for (const auto& nd : gnodes) *og->add_node() = nd;
  for (const auto& t : b->initializer()) *og->add_initializer() = t;
  for (const auto& nd : tail) *og->add_node() = nd;
  for (const auto& t : tail_init) *og->add_initializer() = t;
  onnx::ModelProto& clean = out;
  // declare the outputs (shape inference gives their type)
  onnx::shape_inference::InferShapes(clean);
  onnx::GraphProto* cg = clean.mutable_graph();
  std::map<std::string, onnx::ValueInfoProto> vis;
  for (const auto& v : cg->value_info()) vis[v.name()] = v;
  for (const std::string& r : results) {
    onnx::ValueInfoProto* vi = cg->add_output();
    auto it = vis.find(r);
    if (it != vis.end()) *vi = it->second;
    vi->set_name(r);
  }
  std::string bytes_out;
  if (!clean.SerializeToString(&bytes_out)) throw std::runtime_error("cannot serialize the gradient model");
  return bytes_out;
}

char* dup_str(const std::string& s, size_t* n = nullptr) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  std::memcpy(p, s.data(), s.size());
  p[s.size()] = 0;
  if (n) *n = s.size();
  return p;
}

}  // namespace

extern "C" {

__attribute__((visibility("default"))) const char* nfc_onnxsim_version() { return "onnxsim 0.8.1 graph_grad (C++)"; }

// 0 on success (*out/*out_n hold the model), 1 for an operator without a gradient rule (*err has the library's message),
// 2 for any other failure (*err). Free *out and *err with nfc_onnxsim_free.
__attribute__((visibility("default"))) int nfc_onnxsim_gradients(const char* model, size_t n, const char* loss, const char* const* wrt, size_t nwrt, const char* prefix, char** out, size_t* out_n, char** err) {
  *out = nullptr;
  *err = nullptr;
  try {
    std::string r = run(model, n, loss, std::vector<std::string>(wrt, wrt + nwrt), prefix);
    *out = dup_str(r, out_n);
    return 0;
  } catch (const UnsupportedOpError& e) {
    *err = dup_str(e.what());
    return 1;
  } catch (const std::exception& e) {
    *err = dup_str(e.what());
    return 2;
  } catch (...) {
    *err = dup_str("unknown failure");
    return 2;
  }
}

__attribute__((visibility("default"))) void nfc_onnxsim_free(void* p) { std::free(p); }

}
