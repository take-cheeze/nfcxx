// Reader for the nfcxx mid-level IR text (Path B), as scripts/pathb-ptx-emit.rb reads it. Phase 1 of the emitter port:
// the tokenizer, the form parser and the canonical form text. The lowering is still in the Ruby script.
#pragma once

#include <functional>
#include <stdexcept>
#include <string>
#include <utility>
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

// The top-level chunks of the module text, as the Ruby's module_chunks gives them: a chunk starts at a line that begins with
// '(' in column 0 (unless the chunk has no line yet), and the full-line comments and the empty lines at the end of the text are
// left out. The text is either a string the caller keeps, or a file read one chunk at a time (so the whole text is not held).
class ModuleText {
 public:
  // The text in src (the caller keeps it), or else the file at path (when src is null).
  ModuleText(const std::string *src, std::string path) : src_(src), path_(std::move(path)) {}
  // Calls visit(index, text) for each chunk in order; the index counts the chunks from 0. Throws std::runtime_error when the
  // file cannot be read.
  void each_chunk(const std::function<void(size_t, const std::string &)> &visit) const;
  // The whole text.
  std::string whole() const;

 private:
  const std::string *src_;
  std::string path_;
};

// The forms of a text (the tokenizer and the form parser on it). Throws BadIR.
std::vector<Node> parse_text_forms(const std::string &text);

// The function name of a chunk whose header is `(function "NAME"` (false otherwise, or when the name holds a backslash).
bool chunk_function_name(const std::string &chunk, std::string &name);

// The top-level forms of the text that are not functions, in order: parse_forms_chunked's forms without the functions, read one
// chunk at a time (a function chunk is parsed and dropped). Throws BadIR as parse_forms_chunked does.
std::vector<Node> parse_nonfunction_forms(const std::string &src);

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
