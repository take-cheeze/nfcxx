// nfcuop::hir: a high-level graph in the shape of ONNX (opset 18): tensors with static shapes, one node per
// operator with ONNX's names, inputs and attributes (Reshape takes its shape as a constant input, ReduceSum its
// axes, and so on), shape and dtype inference, an exporter to an ONNX ModelProto and a reader for one (merge_onnx). The numpy-like API
// (nfcuop_np.hpp) builds this graph; Lowerer turns it into UOps (nfcuop_ut.hpp) for evaluation, so a model can be
// exported to ONNX before it is lowered, from the same graph that is run here.
//
//   nfcuop::hir::Graph g;
//   int x = g.add_input("x", DType::Float32, {2, 3});
//   int w = g.add_initializer("w", Array::from_doubles(DType::Float32, {3, 4}, ...));
//   int y = g.add_node("MatMul", {x, w});
//   std::string onnx = g.to_onnx({y});          // bytes of a ModelProto; write them to a .onnx file
//
// Supported operators: Identity Cast Neg Abs Relu Not Sqrt Exp Log Sin Cos Tanh Sigmoid Erf Add Sub Mul Div Mod Max Min
// And Or Xor BitwiseAnd BitwiseOr BitwiseXor Equal Less Greater LessOrEqual GreaterOrEqual Where Clip MatMul Gemm
// Transpose Reshape Squeeze Unsqueeze Expand ReduceSum ReduceMean ReduceMax ReduceMin Softmax LogSoftmax Slice Concat Pad (mode constant)
// Gather Conv MaxPool AveragePool BatchNormalization (inference) InstanceNormalization LayerNormalization (see the operator notes in
// nfcuop_lower.cpp for their lowering and cost). A dimension may be a symbol (ONNX dim_param, e.g. "N"): see Dim, Graph::bind and
// Evaluator below. Everything is static once the symbols are bound. See docs/notes/uop.md.
#pragma once
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "nfcuop.hpp"
#include "nfcuop_ut.hpp"

namespace nfcuop {
namespace hir {

enum class AttrKind { Int, Ints, String, Float, Floats, Tensor };
struct Attribute {
  std::string name;
  AttrKind kind = AttrKind::Int;
  int64_t i = 0;
  std::vector<int64_t> ints;
  std::string s;
  double f = 0;             // Float (stored as an ONNX float: 32 bits)
  std::vector<double> floats;
  Array t;                  // Tensor
  static Attribute Int(const std::string& name, int64_t v) { Attribute a; a.name = name; a.kind = AttrKind::Int; a.i = v; return a; }
  static Attribute Ints(const std::string& name, std::vector<int64_t> v) { Attribute a; a.name = name; a.kind = AttrKind::Ints; a.ints = std::move(v); return a; }
  static Attribute String(const std::string& name, const std::string& v) { Attribute a; a.name = name; a.kind = AttrKind::String; a.s = v; return a; }
  static Attribute Float(const std::string& name, double v) { Attribute a; a.name = name; a.kind = AttrKind::Float; a.f = static_cast<float>(v); return a; }
  static Attribute Floats(const std::string& name, std::vector<double> v) { Attribute a; a.name = name; a.kind = AttrKind::Floats; a.floats = std::move(v); for (double& x : a.floats) x = static_cast<float>(x); return a; }
  static Attribute Tensor(const std::string& name, Array v) { Attribute a; a.name = name; a.kind = AttrKind::Tensor; a.t = std::move(v); return a; }
};

// A dimension of a value: an integer (at least 1), or a symbol (ONNX dim_param, e.g. "N") whose size is given when the graph is
// evaluated (Graph::bind). Symbols are equal when their names are: N against N is N, N against 1 broadcasts to N, and any other
// combination of a symbol with a different dimension is an Error (the operators say which combinations they accept).
struct Dim {
  int64_t size = 1;  // the size of an integer dimension
  std::string sym;   // the symbol of a symbolic dimension (then size is unused); "" for an integer dimension
  Dim() {}
  Dim(int64_t n) : size(n) {}
  static Dim symbol(const std::string& s) { Dim d; d.size = 0; d.sym = s; return d; }
  bool is_symbol() const { return !sym.empty(); }
  bool operator==(const Dim& o) const { return is_symbol() == o.is_symbol() && (is_symbol() ? sym == o.sym : size == o.size); }
  bool operator!=(const Dim& o) const { return !(*this == o); }
};
using Dims = std::vector<Dim>;
// The size each symbol takes at evaluation time (every symbol of the graph, each at least 1).
using Bindings = std::map<std::string, int64_t>;

struct Value {
  std::string name;  // unique in the graph; the name in the ONNX file
  DType dtype;
  Shape shape;       // the size of every dimension; 0 where the dimension is a symbol
  // The symbol of every dimension, when some dimension is symbolic ("" for an integer one); empty when the value is static.
  std::vector<std::string> syms;
};

struct Node {
  std::string op;
  std::string name;
  std::vector<int> inputs;  // value ids; -1 is an omitted optional input
  int output = -1;          // every supported operator has one output
  std::vector<Attribute> attrs;
  const Attribute* attr(const std::string& n) const;
  int64_t attr_int(const std::string& n, int64_t dflt) const;
  double attr_float(const std::string& n, double dflt) const;        // the value of a FLOAT attribute (float32 precision)
  std::vector<int64_t> attr_ints(const std::string& n) const;        // the INTS attribute, or {} when absent
  bool has_attr(const std::string& n) const { return attr(n) != nullptr; }
};

using nfcuop::to_string;  // the Shape overload stays visible in hir
std::string to_string(const Dims& d);  // "[N,4]": a symbol by its name

// ONNX TensorProto.DataType of a dtype (FLOAT 1, INT32 6, INT64 7, BOOL 9, DOUBLE 11).
int onnx_dtype(DType d);

class Graph {
 public:
  // An input to be fed when the graph runs. Names must be unique among all values.
  int add_input(const std::string& name, DType d, const Shape& shape) { return add_symbolic_input(name, d, to_dims(shape)); }
  // An input whose dimensions may be symbols (ONNX dim_param); the same as add_input when none is.
  int add_symbolic_input(const std::string& name, DType d, const Dims& shape);
  static Dims to_dims(const Shape& s) { return Dims(s.begin(), s.end()); }
  // A constant tensor; name "" picks one.
  int add_initializer(const std::string& name, const Array& a);
  // Appends a node, infers its output (throws Error for an unknown operator, a bad input, dtype or attribute) and
  // returns the id of the output value. Operator inputs that ONNX wants as constants (Reshape's shape, axes, Slice
  // bounds, ...) must be initializers.
  // `out_name` names the output value in the ONNX file; "" picks one.
  int add_node(const std::string& op, std::vector<int> inputs, std::vector<Attribute> attrs = {}, const std::string& out_name = "");

  // The reader for to_onnx's format: parses a ModelProto (any producer; IR version 3+, default-domain opset 13+; nodes, initializers
  // in raw_data or the typed fields, Constant nodes, int/ints/float/floats/string/tensor attributes, static shapes) and adds its
  // values to this graph. Values whose names already exist here (inputs, initializers, node outputs) are the existing values
  // (dtype and shape must agree, else Error), a node whose output exists is skipped, everything else is appended: this is how a
  // model computed from a sub-graph of this graph (the gradient models of nfcuop_onnxgrad.hpp) is merged back. Constant nodes
  // become initializers; an input that has an initializer of the same name is the initializer. Returns the ids of the model's
  // graph outputs in order. Throws Error for what hir does not support (unknown operator, dtype, dynamic shape, several outputs).
  std::vector<int> merge_onnx(const std::string& model_bytes);
  // A new graph with the model's content; `outputs` receives the ids of its graph outputs.
  static Graph from_onnx(const std::string& model_bytes, std::vector<int>* outputs = nullptr);
  int find_value(const std::string& name) const;  // the id of the value of this name, or -1
  Dims dims(int id) const;                  // the shape of a value, with its symbols
  bool symbolic(int id) const { return !value(id).syms.empty(); }  // whether a dimension of the value is a symbol
  std::vector<std::string> symbols() const;  // the symbols of the graph's inputs, sorted, without repetitions
  // A copy of the graph with every symbol bound to its size: the inputs get the bound shapes and every operator is inferred again
  // with them (so a Reshape that copied a symbol gets its integer). Value ids are the same in both graphs. Throws Error when a
  // symbol has no binding, when a binding names no symbol of the graph or is below 1, or when an operator cannot take the sizes.
  Graph bind(const Bindings& b) const;

  size_t num_values() const { return values_.size(); }
  const Value& value(int id) const;
  const std::vector<Node>& nodes() const { return nodes_; }
  const std::vector<int>& inputs() const { return inputs_; }
  const Array* initializer(int id) const;  // nullptr unless `id` is an initializer
  int producer(int id) const;              // index into nodes(), or -1 for inputs and initializers
  std::vector<int64_t> const_ints(int id) const;  // an int32 or int64 initializer's values; throws Error otherwise

  // The ModelProto (ONNX IR version 8, opset 18, domain "") that computes `outputs` from the graph's inputs, as bytes.
  // Only what the outputs depend on is written. An output that is an input or an initializer needs an Identity first
  // (the numpy API adds one). `outputs` must be distinct values.
  std::string to_onnx(const std::vector<int>& outputs, const std::string& graph_name = "nfcuop") const;
  std::string str() const;  // one line per node: `%v5 = MatMul(%v1, %v2) : float32[2,4]`

 private:
  int new_value(const std::string& name, DType d, const Dims& shape);
  int add_node_named(const std::string& op, std::vector<int> inputs, std::vector<Attribute> attrs, const std::string& out_name, const std::string& node_name);
  std::deque<Value> values_;  // stable addresses: Tensor::shape() hands out references
  std::vector<Node> nodes_;
  std::vector<int> inputs_;
  std::vector<int> producer_;
  std::map<int, Array> inits_;
  std::map<std::string, int> names_;
  std::map<std::string, int> node_names_;  // node names are unique too (ONNX tools want that)
};

// Lowers values of a hir::Graph to tensors of a ut::Session (memoized), so they can be evaluated with the UOp
// interpreter or rendered. Inputs become placeholders named like the inputs, initializers become buffers. The graph
// may grow between calls. A value with a symbolic dimension cannot be lowered: bind the graph first (Graph::bind).
class Lowerer {
 public:
  Lowerer(const Graph& g, ut::Session& s) : g_(g), s_(s) {}
  // Iterative (no recursion on the depth of the graph: a chain of thousands of nodes is fine).
  ut::Tensor get(int value);

 private:
  ut::Tensor lower_one(int value);  // its inputs are in memo_ already
  const Graph& g_;
  ut::Session& s_;
  std::map<int, ut::Tensor> memo_;
};

// Evaluates values of a graph whose inputs may have symbolic dimensions. For each binding of the symbols the graph is bound
// (Graph::bind), lowered and evaluated by the UOp interpreter; the lowering is cached per binding, keyed on the bindings in
// symbol-name order, so the same sizes again cost nothing to lower. The graph must outlive the Evaluator and must not change
// while it is in use (values added later are fine if they are not evaluated from an earlier binding).
class Evaluator {
 public:
  explicit Evaluator(const Graph& g) : g_(g) {}
  // The values of `outputs` (value ids of the graph) for the feeds (input name -> Array of the bound shape and dtype).
  std::vector<Array> eval(const Bindings& b, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds = {});
  size_t bindings_lowered() const { return cache_.size(); }  // the number of distinct bindings lowered so far

 private:
  struct Entry {
    explicit Entry(Graph g) : bound(std::move(g)), low(bound, s) {}
    Graph bound;
    ut::Session s;
    Lowerer low;
  };
  const Graph& g_;
  std::map<std::string, std::unique_ptr<Entry>> cache_;
};

}  // namespace hir
}  // namespace nfcuop
