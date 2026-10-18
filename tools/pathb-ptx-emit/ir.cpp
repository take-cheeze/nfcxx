// Reader for the Path B IR text. Each function here is the C++ form of the Ruby function of the same name in
// scripts/pathb-ptx-emit.rb; the byte rules (space, octal, escapes, lstrip, split) follow mruby's, which runs the Ruby.
#include <fstream>
#include <functional>
#include <map>
#include <set>

#include "ir.hpp"

namespace {

struct Tok {
  enum Kind { Open, Close, Atom, Str, Sym };
  Kind kind;
  std::string s;
  char sig;
};

// The Ruby's space_byte?: TAB..CR, the 28..32 separators, and the two Latin-1 spaces 0x85 and 0xa0.
bool space_byte(unsigned char c) {
  return (c >= 9 && c <= 13) || (c >= 28 && c <= 32) || c == 0x85 || c == 0xa0;
}

bool octal(unsigned char c) { return c >= '0' && c <= '7'; }

// The Ruby's read_string: i is at the opening quote; returns the decoded bytes and leaves i after the closing quote.
std::string read_string(const std::string &t, size_t &i) {
  std::string out;
  const size_t n = t.size();
  i += 1;
  while (true) {
    if (i >= n) throw BadIR("unterminated string in IR");
    unsigned char c = static_cast<unsigned char>(t[i]);
    if (c == '"') {
      i += 1;
      return out;
    }
    if (c == '\\') {
      i += 1;
      if (i >= n) throw BadIR("bad escape at end of IR");
      unsigned char e = static_cast<unsigned char>(t[i]);
      if (e == 'n') {
        out += '\n';
        i += 1;
      } else if (e == '"' || e == '\\') {
        out += static_cast<char>(e);
        i += 1;
      } else if (e >= '0' && e <= '7' && i + 2 < n && octal(static_cast<unsigned char>(t[i + 1])) &&
                 octal(static_cast<unsigned char>(t[i + 2]))) {
        // The Ruby keeps the value up to 511 and the IR string takes its low byte (to_s masks with 255).
        int v = (e - '0') * 64 + (static_cast<unsigned char>(t[i + 1]) - '0') * 8 +
                (static_cast<unsigned char>(t[i + 2]) - '0');
        out += static_cast<char>(v & 255);
        i += 3;
      } else {
        throw BadIR(std::string("unknown escape \\") + static_cast<char>(e) + " in IR string");
      }
    } else {
      out += static_cast<char>(c);
      i += 1;
    }
  }
}

// The Ruby's tokenize.
std::vector<Tok> tokenize(const std::string &t) {
  std::vector<Tok> toks;
  size_t i = 0;
  const size_t n = t.size();
  while (i < n) {
    unsigned char c = static_cast<unsigned char>(t[i]);
    if (space_byte(c)) {
      i += 1;
    } else if (c == '(') {
      toks.push_back({Tok::Open, "", 0});
      i += 1;
    } else if (c == ')') {
      toks.push_back({Tok::Close, "", 0});
      i += 1;
    } else if (c == '"') {
      toks.push_back({Tok::Str, read_string(t, i), 0});
    } else if ((c == '$' || c == '@' || c == '&') && i + 1 < n && t[i + 1] == '"') {
      size_t j = i + 1;
      std::string name = read_string(t, j);
      toks.push_back({Tok::Sym, name, static_cast<char>(c)});
      i = j;
    } else {
      size_t j = i;
      while (j < n) {
        unsigned char d = static_cast<unsigned char>(t[j]);
        if (space_byte(d) || d == '(' || d == ')' || d == '"') break;
        j += 1;
      }
      toks.push_back({Tok::Atom, t.substr(i, j - i), 0});
      i = j;
    }
  }
  return toks;
}

// The Ruby's parse_forms: the top-level list of forms.
std::vector<Node> parse_forms(const std::vector<Tok> &toks) {
  std::vector<std::vector<Node>> stack(1);
  for (const Tok &t : toks) {
    switch (t.kind) {
      case Tok::Open:
        stack.emplace_back();
        break;
      case Tok::Close: {
        if (stack.size() == 1) throw BadIR("unbalanced ')' in IR");
        Node list;
        list.kind = Node::List;
        list.items = std::move(stack.back());
        stack.pop_back();
        stack.back().push_back(std::move(list));
        break;
      }
      case Tok::Atom: {
        Node a;
        a.kind = Node::Atom;
        a.text = t.s;
        stack.back().push_back(std::move(a));
        break;
      }
      case Tok::Str: {
        Node a;
        a.kind = Node::Str;
        a.text = t.s;
        stack.back().push_back(std::move(a));
        break;
      }
      case Tok::Sym: {
        Node a;
        a.kind = Node::Sym;
        a.text = t.s;
        a.sig = t.sig;
        stack.back().push_back(std::move(a));
        break;
      }
    }
  }
  if (stack.size() != 1) throw BadIR("unbalanced '(' in IR");
  return std::move(stack[0]);
}

// The lines of src, as Ruby's split("\n") gives them (trailing empty fields dropped).
std::vector<std::string> split_lines(const std::string &src) {
  std::vector<std::string> lines;
  size_t start = 0;
  while (true) {
    size_t nl = src.find('\n', start);
    if (nl == std::string::npos) {
      lines.push_back(src.substr(start));
      break;
    }
    lines.push_back(src.substr(start, nl - start));
    start = nl + 1;
  }
  while (!lines.empty() && lines.back().empty()) lines.pop_back();
  return lines;
}

// The Ruby's lstrip for these lines: ASCII whitespace only (mruby keeps NUL and the 0xa0 byte).
bool lstrip_starts_with(const std::string &line, char ch) {
  size_t i = 0;
  while (i < line.size()) {
    char c = line[i];
    if (c == ' ' || (c >= 9 && c <= 13)) {
      i += 1;
    } else {
      break;
    }
  }
  return i < line.size() && line[i] == ch;
}

// The Ruby's strip_comments: the source without its full-line comments.
std::string strip_comments(const std::string &src) {
  std::string out;
  bool first = true;
  for (const std::string &line : split_lines(src)) {
    if (lstrip_starts_with(line, ';')) continue;
    if (!first) out += '\n';
    out += line;
    first = false;
  }
  return out;
}

// The module's chunks, one line at a time (the Ruby's module_chunks, see ModuleText): a line that begins with '(' starts a
// chunk, unless the chunk has no line yet; a full-line comment is left out; the empty lines at the end of the text are left
// out (an empty line before a comment or a line is kept, as split_lines keeps it).
class ChunkBuilder {
 public:
  explicit ChunkBuilder(const std::function<void(size_t, const std::string &)> &visit) : visit_(visit) {}

  void line(const std::string &l) {
    if (lstrip_starts_with(l, ';')) {
      flush_empty();
      return;
    }
    if (l.empty()) {
      empty_ += 1;
      return;
    }
    flush_empty();
    if (l[0] == '(' && started_) emit();
    add(l);
  }

  // The end of the text: the chunk in progress is the last one (the pending empty lines are the text's end).
  void finish() {
    if (started_) emit();
  }

 private:
  void add(const std::string &l) {
    if (!started_) {
      started_ = true;
      cur_.clear();
    } else {
      cur_ += '\n';
    }
    cur_ += l;
  }

  void flush_empty() {
    for (; empty_ > 0; empty_--) add("");
  }

  void emit() {
    visit_(index_++, cur_);
    started_ = false;
    cur_.clear();
  }

  const std::function<void(size_t, const std::string &)> &visit_;
  std::string cur_;
  bool started_ = false;
  size_t empty_ = 0;
  size_t index_ = 0;
};

// The Ruby's module_chunks: the chunks of the text, each starting at a line that begins with '(' (full-line comments
// dropped).
std::vector<std::string> module_chunks(const std::string &src) {
  std::vector<std::string> chunks;
  ModuleText(&src, "").each_chunk([&chunks](size_t, const std::string &t) { chunks.push_back(t); });
  return chunks;
}

bool starts_with(const std::string &s, const std::string &prefix) { return s.compare(0, prefix.size(), prefix) == 0; }

// The Ruby's function_chunk_name: the name in the header `(function "NAME"`, or false when the header is not of that form.
bool function_chunk_name(const std::string &chunk, std::string &name) {
  const std::string head = "(function \"";
  if (!starts_with(chunk, head)) return false;
  size_t q = chunk.find('"', head.size());
  if (q == std::string::npos) return false;
  name = chunk.substr(head.size(), q - head.size());
  return name.find('\\') == std::string::npos;
}

// The Ruby's text_symbol_names: the names of the `sig"name"` symbols in a function chunk's text. A chunk with an escape
// or a string form is not read this way (false).
bool text_symbol_names(const std::string &text, char sig, std::vector<std::string> &out) {
  if (text.find('\\') != std::string::npos || text.find("(string") != std::string::npos ||
      text.find("(bytes") != std::string::npos) {
    return false;
  }
  const std::string key = std::string(1, sig) + "\"";
  out.clear();
  size_t i = text.find(key);
  while (i != std::string::npos) {
    size_t j = text.find('"', i + key.size());
    if (j == std::string::npos) return false;
    out.push_back(text.substr(i + key.size(), j - (i + key.size())));
    i = text.find(key, j + 1);
  }
  return true;
}

}  // namespace

std::vector<Node> parse_forms_chunked(const std::string &src) {
  std::vector<Node> forms;
  for (const std::string &c : module_chunks(src)) {
    try {
      for (Node &f : parse_forms(tokenize(c))) forms.push_back(std::move(f));
    } catch (const BadIR &) {
      return parse_forms(tokenize(strip_comments(src)));
    }
  }
  return forms;
}

std::string form_text(const Node &n) {
  switch (n.kind) {
    case Node::List: {
      std::string out = "(";
      bool first = true;
      for (const Node &y : n.items) {
        if (!first) out += ' ';
        out += form_text(y);
        first = false;
      }
      return out + ")";
    }
    case Node::Sym:
      return std::string(1, n.sig) + "\"" + n.text + "\"";
    case Node::Str:
      return "\"" + n.text + "\"";
    case Node::Atom:
      return n.text;
  }
  return "";
}

namespace {

// The Ruby's head_of(x) == name for a form.
bool head_is(const Node &x, const char *name) {
  return x.kind == Node::List && !x.items.empty() && x.items[0].kind == Node::Atom && x.items[0].text == name;
}

}  // namespace

bool parse_module_forms(const std::string &src, const std::vector<std::string> &kernels, ModuleForms &out) {
  if (kernels.empty()) return false;
  const std::vector<std::string> chunks = module_chunks(src);
  std::map<std::string, size_t> fn_chunks;  // function name => chunk index
  std::map<size_t, size_t> fn_pos;          // chunk index => position among the module's functions
  size_t nfn = 0;
  for (size_t i = 0; i < chunks.size(); i++) {
    if (!starts_with(chunks[i], "(function")) continue;
    std::string name;
    if (!function_chunk_name(chunks[i], name) || fn_chunks.count(name)) return false;
    fn_chunks[name] = i;
    fn_pos[i] = nfn++;
  }
  if (fn_chunks.empty()) return false;

  // Each kernel names exactly one function: its own name, or its mangled name (_Z<len><name>...).
  std::vector<std::string> roots;
  for (const std::string &k : kernels) {
    const std::string mangled = "_Z" + std::to_string(k.size()) + k;
    std::vector<std::string> hits;
    for (const auto &fc : fn_chunks) {
      if (fc.first == k || starts_with(fc.first, mangled)) hits.push_back(fc.first);
    }
    if (hits.size() != 1) return false;
    roots.push_back(hits[0]);
  }

  // The functions reachable from the kernels, through the function symbols (&"name") in their text.
  std::map<std::string, std::vector<std::string>> callees;
  for (const auto &fc : fn_chunks) {
    std::vector<std::string> cs;
    if (!text_symbol_names(chunks[fc.second], '&', cs)) return false;
    callees[fc.first] = cs;
  }
  std::set<std::string> live;
  std::vector<std::string> stack = roots;
  while (!stack.empty()) {
    std::string n = stack.back();
    stack.pop_back();
    if (live.count(n)) continue;
    live.insert(n);
    for (const std::string &c : callees[n]) {
      if (fn_chunks.count(c)) stack.push_back(c);
    }
  }

  out.forms.clear();
  out.fn_indices.clear();
  for (size_t i = 0; i < chunks.size(); i++) {
    const bool is_fn = starts_with(chunks[i], "(function");
    if (is_fn) {
      std::string name;
      function_chunk_name(chunks[i], name);
      if (!live.count(name)) continue;
      out.fn_indices.push_back(fn_pos[i]);
    }
    std::vector<Node> parsed;
    try {
      parsed = parse_forms(tokenize(chunks[i]));
    } catch (const BadIR &) {
      return false;
    }
    if (is_fn && (parsed.size() != 1 || !head_is(parsed[0], "function"))) return false;
    for (Node &f : parsed) out.forms.push_back(std::move(f));
  }
  return true;
}

void ModuleText::each_chunk(const std::function<void(size_t, const std::string &)> &visit) const {
  ChunkBuilder b(visit);
  if (src_) {
    const std::string &src = *src_;
    size_t start = 0;
    while (true) {
      size_t nl = src.find('\n', start);
      if (nl == std::string::npos) {
        b.line(src.substr(start));
        break;
      }
      b.line(src.substr(start, nl - start));
      start = nl + 1;
    }
  } else {
    std::ifstream f(path_, std::ios::binary);
    if (!f) throw std::runtime_error("cannot read " + path_);
    std::string line;
    while (std::getline(f, line)) b.line(line);
  }
  b.finish();
}

std::string ModuleText::whole() const {
  if (src_) return *src_;
  std::ifstream f(path_, std::ios::binary);
  if (!f) throw std::runtime_error("cannot read " + path_);
  std::string out;
  f.seekg(0, std::ios::end);
  const std::streamoff size = f.tellg();
  f.seekg(0, std::ios::beg);
  if (size > 0) {
    out.resize(static_cast<size_t>(size));
    f.read(&out[0], size);
    out.resize(static_cast<size_t>(f.gcount()));
  }
  return out;
}

std::vector<Node> parse_text_forms(const std::string &text) { return parse_forms(tokenize(text)); }

bool chunk_function_name(const std::string &chunk, std::string &name) { return function_chunk_name(chunk, name); }

std::vector<Node> parse_nonfunction_forms(const std::string &src) {
  std::vector<Node> forms;
  try {
    ModuleText(&src, "").each_chunk([&forms](size_t, const std::string &text) {
      for (Node &f : parse_text_forms(text)) {
        if (!head_is(f, "function")) forms.push_back(std::move(f));
      }
    });
  } catch (const BadIR &) {
    // parse_forms_chunked's fallback: the whole text, with its comments stripped
    forms.clear();
    for (Node &f : parse_forms(tokenize(strip_comments(src)))) {
      if (!head_is(f, "function")) forms.push_back(std::move(f));
    }
  }
  return forms;
}
