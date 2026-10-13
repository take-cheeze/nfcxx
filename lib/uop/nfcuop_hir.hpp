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
// Pow Floor Ceil IsNaN IsInf CumSum ReduceProd ArgMax ArgMin Tile Gather Conv MaxPool AveragePool BatchNormalization (inference) InstanceNormalization LayerNormalization (see the operator notes in
// nfcuop_lower.cpp for their lowering and cost). All shapes are static; dynamic dimensions come in a later stage. See docs/notes/uop.md.
#pragma once
#include <deque>
#include <map>
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

struct Value {
  std::string name;  // unique in the graph; the name in the ONNX file
  DType dtype;
  Shape shape;
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

// ONNX TensorProto.DataType of a dtype (FLOAT 1, INT32 6, INT64 7, BOOL 9, DOUBLE 11).
int onnx_dtype(DType d);

class Graph {
 public:
  // An input to be fed when the graph runs. Names must be unique among all values.
  int add_input(const std::string& name, DType d, const Shape& shape);
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
  int new_value(const std::string& name, DType d, const Shape& shape);
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
// may grow between calls.
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

}  // namespace hir
}  // namespace nfcuop
