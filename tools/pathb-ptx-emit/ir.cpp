// Reader for the Path B IR text. Each function here is the C++ form of the Ruby function of the same name in
// scripts/pathb-ptx-emit.rb; the byte rules (space, octal, escapes, lstrip, split) follow mruby's, which runs the Ruby.
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

}  // namespace

std::vector<Node> parse_forms_chunked(const std::string &src) {
  std::vector<std::string> chunks;
  std::string cur;
  bool cur_empty = true;
  for (const std::string &line : split_lines(src)) {
    if (lstrip_starts_with(line, ';')) continue;
    if (!line.empty() && line[0] == '(' && !cur_empty) {
      chunks.push_back(cur);
      cur.clear();
      cur_empty = true;
    }
    if (!cur_empty) cur += '\n';
    cur += line;
    cur_empty = false;
  }
  if (!cur_empty) chunks.push_back(cur);

  std::vector<Node> forms;
  for (const std::string &c : chunks) {
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
