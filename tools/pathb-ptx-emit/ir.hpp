// Reader for the nfcxx mid-level IR text (Path B), as scripts/pathb-ptx-emit.rb reads it. Phase 1 of the emitter port:
// the tokenizer, the form parser and the canonical form text. The lowering is still in the Ruby script.
#pragma once

#include <stdexcept>
#include <string>
#include <vector>

// Malformed IR text (the Ruby's BadIR, exit status 1).
struct BadIR : std::runtime_error {
  explicit BadIR(const std::string &m) : std::runtime_error(m), text(m) {}
  std::string text;   // the whole message: what() stops at a NUL byte, and a name from the IR may hold one
};

// A form: a list, or an atom. A string literal is a Str (its decoded bytes); a sigil and a quoted name ($"x", @"x",
// &"f") is a Sym (the sigil and the name's bytes).
struct Node {
  enum Kind { List, Atom, Str, Sym };
  Kind kind = Atom;
  std::string text;          // Atom: the bytes; Str: the decoded bytes; Sym: the name
  char sig = 0;              // Sym: the sigil
  std::vector<Node> items;   // List: the elements
};

// The top-level forms of the IR text, parsed one chunk at a time (a chunk starts at a line that begins with '(' in
// column 0), with the same fallback to the whole text as the Ruby's parse_forms_chunked. Throws BadIR.
std::vector<Node> parse_forms_chunked(const std::string &src);

// The canonical text of a form, as the Ruby's form_text.
std::string form_text(const Node &n);

// The module's forms for emission when the kernels are given, as the Ruby's parse_module_forms: only the functions
// the kernels reach are parsed (their names and the symbols they take are read from the text), every non-function
// form is parsed, and fn_indices holds the position of each parsed function among all the module's functions. Returns
// false where the Ruby returns nil (the caller then parses the whole text with parse_forms_chunked).
struct ModuleForms {
  std::vector<Node> forms;
  std::vector<size_t> fn_indices;
};
bool parse_module_forms(const std::string &src, const std::vector<std::string> &kernels, ModuleForms &out);
