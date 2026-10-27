// The IR reader and the helpers on forms (scripts/pathb-spirv-emit.rb: strip_comments, tokenize, parse_forms, head_of,
// form_text, as_int).
#include "ir.hpp"

namespace {

uint32_t next_uid = 1;

bool space_byte(unsigned char c) { return (c >= 9 && c <= 13) || (c >= 28 && c <= 32) || c == 0x85 || c == 0xa0; }
bool octal(unsigned char c) { return c >= '0' && c <= '7'; }

// the Ruby's strip_comments: the lines whose first non-blank character is ';' are dropped
std::string strip_comments(const std::string &src) {
  std::string out;
  out.reserve(src.size());
  size_t i = 0, n = src.size();
  bool first = true;
  while (i < n) {
    size_t e = src.find('\n', i);
    if (e == std::string::npos) e = n;
    size_t j = i;
    while (j < e && (src[j] == ' ' || src[j] == '\t' || src[j] == '\r' || src[j] == '\f' || src[j] == '\v' || src[j] == '\0'))
      j++;
    if (!(j < e && src[j] == ';')) {
      if (!first) out += '\n';
      out.append(src, i, e - i);
      first = false;
    }
    i = e + 1;
  }
  return out;
}

// a string literal from the '"' at i: its bytes, and the index after the closing quote
size_t read_string(const std::string &text, size_t i, std::string &out) {
  i += 1;
  size_t n = text.size();
  while (true) {
    if (i >= n) throw BadIR("unterminated string in IR");
    unsigned char c = text[i];
    if (c == '"') return i + 1;
    if (c == '\\') {
      i += 1;
      if (i >= n) throw BadIR("bad escape at end of IR");
      unsigned char e = text[i];
      if (e == 'n') {
        out += '\n';
        i += 1;
      } else if (e == '"' || e == '\\') {
        out += (char)e;
        i += 1;
      } else if (e >= '0' && e <= '7' && i + 2 < n && octal(text[i + 1]) && octal(text[i + 2])) {
        out += (char)(((e - '0') * 64 + (text[i + 1] - '0') * 8 + (text[i + 2] - '0')) & 255);
        i += 3;
      } else {
        throw BadIR(std::string("unknown escape \\") + (char)e + " in IR string");
      }
    } else {
      out += (char)c;
      i += 1;
    }
  }
}

}  // namespace

Node make_atom(const std::string &s) {
  Node n;
  n.kind = Node::Atom;
  n.text = s;
  n.uid = next_uid++;
  return n;
}

Node make_sym(char sig, const std::string &name) {
  Node n;
  n.kind = Node::Sym;
  n.sig = sig;
  n.text = name;
  n.uid = next_uid++;
  return n;
}

Node make_list(std::vector<Node> items) {
  Node n;
  n.kind = Node::List;
  n.items = std::move(items);
  n.uid = next_uid++;
  return n;
}

std::vector<Node> read_forms(const std::string &src0) {
  std::string text = strip_comments(src0);
  std::vector<std::vector<Node>> stack(1);
  size_t i = 0, n = text.size();
  while (i < n) {
    unsigned char c = text[i];
    if (space_byte(c)) {
      i += 1;
    } else if (c == '(') {
      stack.emplace_back();
      i += 1;
    } else if (c == ')') {
      if (stack.size() == 1) throw BadIR("unbalanced ')' in IR");
      Node l;
      l.kind = Node::List;
      l.uid = next_uid++;
      l.items = std::move(stack.back());
      stack.pop_back();
      stack.back().push_back(std::move(l));
      i += 1;
    } else if (c == '"') {
      Node s;
      s.kind = Node::Str;
      s.uid = next_uid++;
      i = read_string(text, i, s.text);
      stack.back().push_back(std::move(s));
    } else if ((c == '$' || c == '@' || c == '&') && i + 1 < n && text[i + 1] == '"') {
      Node s;
      s.kind = Node::Sym;
      s.sig = (char)c;
      s.uid = next_uid++;
      i = read_string(text, i + 1, s.text);
      stack.back().push_back(std::move(s));
    } else {
      size_t j = i;
      while (j < n) {
        unsigned char d = text[j];
        if (space_byte(d) || d == '(' || d == ')' || d == '"') break;
        j += 1;
      }
      Node a;
      a.kind = Node::Atom;
      a.uid = next_uid++;
      a.text.assign(text, i, j - i);
      stack.back().push_back(std::move(a));
      i = j;
    }
  }
  if (stack.size() != 1) throw BadIR("unbalanced '(' in IR");
  return std::move(stack[0]);
}

const std::string *head_of(const Node &x) {
  if (x.kind == Node::List && !x.items.empty() && x.items[0].kind == Node::Atom) return &x.items[0].text;
  return nullptr;
}

bool head_is(const Node &x, const char *h) {
  const std::string *s = head_of(x);
  return s && *s == h;
}

std::string form_text(const Node &x) {
  switch (x.kind) {
    case Node::List: {
      std::string s = "(";
      for (size_t i = 0; i < x.items.size(); i++) {
        if (i) s += ' ';
        s += form_text(x.items[i]);
      }
      return s + ")";
    }
    case Node::Sym: return std::string(1, x.sig) + "\"" + x.text + "\"";
    case Node::Str: return "\"" + x.text + "\"";
    default: return x.text;
  }
}

std::string to_s(const Node &x) { return x.kind == Node::List ? form_text(x) : x.text; }

int64_t as_int(const Node &x) {
  if (x.kind != Node::Atom || x.text.empty()) throw BadIR("expected an integer, got " + form_text(x));
  const std::string &t = x.text;
  size_t i = 0;
  bool neg = false;
  if (t[0] == '-') {
    neg = true;
    i = 1;
  }
  bool hex = t.size() - i > 2 && t[i] == '0' && (t[i + 1] == 'x' || t[i + 1] == 'X');
  if (hex) i += 2;
  if (i >= t.size()) throw BadIR("expected an integer, got " + t);
  uint64_t base = hex ? 16 : 10, v = 0;
  for (; i < t.size(); i++) {
    char c = t[i];
    uint64_t d;
    if (c >= '0' && c <= '9') d = c - '0';
    else if (hex && c >= 'a' && c <= 'f') d = c - 'a' + 10;
    else if (hex && c >= 'A' && c <= 'F') d = c - 'A' + 10;
    else throw BadIR("expected an integer, got " + t);
    v = v * base + d;
  }
  return (int64_t)(neg ? (0 - v) : v);
}
