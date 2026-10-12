// nfcast tier, internal declarations (docs/notes/ast.md, "Tiering"): what the translation units share. The tier itself is in
// nfcast_tier.cpp; nfcast_nodes.cpp includes nfcast_tier_view.inc, which turns a node into a TierView; the engine calls
// tier_dispatch (a call), tier_backedge (a loop iteration) and tier_free (a Proto going away).
#pragma once
#include <string>
#include <vector>

#include "nfcast.hpp"

namespace nfcast {

struct Node;
struct Proto;
struct Frame;
struct TierProto;

// A node, seen through the interface the tier needs: its kind, its operator, and its children. Everything the lowering knows
// about the node classes of nfcast_nodes.cpp is in this struct; a node of a class it does not list is K_NONE (not a kernel).
struct TierView {
  enum Kind {
    K_NONE,
    // expressions
    K_CONST,   // k
    K_LOCAL,   // slot, flag (boxed in a Cell)
    K_UPVAL,   // index
    K_GLOBAL,  // name
    K_ARITH,   // op (AR_*), kids = {left, right}
    K_UNARY,   // op (AR_UNM, AR_BNOT, OPX_NOT, OPX_LEN), kids = {operand}
    K_CMP,     // op (CMP_LT..CMP_GE), kids = {left, right}
    K_EQ,      // flag (~=), kids = {left, right}
    K_AND,     // kids = {left, right}
    K_OR,
    K_CALL,    // kids = {callee, arguments...}, multi_last
    // statements
    K_BLOCK,   // kids = statements
    K_DECL,    // slots = declared locals, kids = values, captured
    K_ASSIGN,  // slots = assigned locals, kids = values, captured (a target that is not a plain local: captured is set)
    K_IF,      // kids = conditions, blocks = their blocks, els = else block or null
    K_WHILE,   // cond, blocks = {body}
    K_REPEAT,  // cond, blocks = {body}
    K_FOR,     // slots = {loop variable}, kids = {start, limit, step or null}, blocks = {body}, captured
    K_RETURN,  // kids = values, multi_last
    K_BREAK
  };
  Kind kind = K_NONE;
  int line = 0;
  int op = 0;
  bool flag = false;
  int slot = -1;
  int index = -1;
  Value k;
  String* name = nullptr;
  std::vector<Node*> kids;
  std::vector<Node*> blocks;
  Node* els = nullptr;
  Node* cond = nullptr;
  std::vector<int> slots;
  bool captured = false;
  bool multi_last = false;
};

// nfcast_tier_view.inc (compiled inside nfcast_nodes.cpp, where the node classes are).
void tier_view(Node* n, TierView& v);

// The engine's hooks.
bool tier_dispatch(State& S, Closure* cl, Value* args, int n, Rets& out);  // true: the call was run as native code, results in OUT
void tier_backedge(Frame& f);                                              // an iteration of a loop of a script function ended
void tier_free(TierProto* tp);                                             // the Proto that owned TP is being destroyed
void tier_init_from_env(State& S);                                         // State::State
void tier_shutdown(State& S);                                              // State::~State, after the heap is gone

}  // namespace nfcast
