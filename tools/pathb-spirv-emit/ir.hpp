// The C++ port of scripts/pathb-spirv-emit.rb: the IR forms, their reader and the helpers on them. The reader is the
// Ruby's (tokenize, parse_forms, strip_comments), so the forms, their order and the error messages are the same.
#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

// A node this emitter does not handle (the Ruby's Refused, exit status 3).
struct Refused : std::runtime_error {
  explicit Refused(const std::string &m) : std::runtime_error(m), text(m) {}
  std::string text;
};

// Malformed IR text (the Ruby's BadIR, exit status 1).
struct BadIR : std::runtime_error {
  explicit BadIR(const std::string &m) : std::runtime_error(m), text(m) {}
  std::string text;
};

// A form: a list, or an atom. Atom is the Ruby's String token; Str a string literal (IRStr: its decoded bytes); Sym a sigil
// and a quoted name ($"x" slot, @"x" static object, &"f" function). uid names the node for the passes that the Ruby keys by
// object_id (it is unique within a parse; a copy keeps it, and a copied tree is only scanned on its own).
struct Node {
  enum Kind : uint8_t { List, Atom, Str, Sym };
  Kind kind = Atom;
  char sig = 0;
  uint32_t uid = 0;
  std::string text;          // Atom: the bytes; Str: the decoded bytes; Sym: the name
  std::vector<Node> items;   // List: the elements

  bool is_list() const { return kind == List; }
  bool is_atom() const { return kind == Atom; }
  bool is_sym(char s) const { return kind == Sym && sig == s; }
  // the Ruby's `x == "text"` for a String token
  bool atom_is(const char *s) const { return kind == Atom && text == s; }
  size_t size() const { return items.size(); }
  const Node &operator[](size_t i) const { return items[i]; }
  Node &operator[](size_t i) { return items[i]; }
};

Node make_atom(const std::string &s);
Node make_sym(char sig, const std::string &name);
Node make_list(std::vector<Node> items);

// the forms of the IR text: strip_comments, tokenize and parse_forms as the Ruby has them
std::vector<Node> read_forms(const std::string &src);

// the head of a list whose first element is an atom (the Ruby's head_of), or null
const std::string *head_of(const Node &x);
bool head_is(const Node &x, const char *h);

// the canonical text of a form (the Ruby's form_text)
std::string form_text(const Node &x);
// the Ruby's x.to_s for a token: the bytes of an atom or a string literal, the name of a symbol; a list prints its text
std::string to_s(const Node &x);

// a decimal or hexadecimal integer with an optional minus sign (the Ruby's as_int), as its 64-bit pattern
int64_t as_int(const Node &x);

// a deep copy whose nodes keep their uids
inline Node copy_form(const Node &x) { return x; }
