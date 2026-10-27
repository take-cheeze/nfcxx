// weak-symbols: emit `.weak` directives for the functions and data objects that EDG marks __attribute__((__weak__)).
// The C++ port of scripts/weak-symbols.rb (the oracle is tests/mruby/oracle/weak-symbols.rb; tests/mruby/run.sh
// compares the two), with the same output byte for byte.
//
// EDG puts COMDAT functions (inline and template instantiations) in every translation unit that uses them (and COMDAT
// data: variable templates, static data members of templates, local statics of inline functions), marked __weak__.
// GCC honours the attribute so the link merges the copies; cproc drops attributes, so QBE emits them as strong symbols
// and the link fails with "multiple definition". The gcc back end needs it too (scripts/gcc-cc): a non-extern
// `__inline__` member is an external definition under gnu89.
// Usage: weak-symbols [--c-input] [--sym-prefix=P] [--marked=FILE] PREPROCESSED_C ASSEMBLY  (appends to ASSEMBLY)
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

using std::string;
const size_t npos = string::npos;

bool space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; }
bool ident_start(char c) { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
bool word_char(char c) { return ident_start(c) || (c >= '0' && c <= '9'); }

// The first whole-word occurrence of kw in s at or after i, or npos.
size_t keyword_at(const string &s, const char *kw, size_t i) {
  size_t n = strlen(kw);
  while (true) {
    size_t j = s.find(kw, i);
    if (j == npos) return npos;
    if (!((j > 0 && word_char(s[j - 1])) || (j + n < s.size() && word_char(s[j + n])))) return j;
    i = j + 1;
  }
}

// Remove __attribute__((...)) groups, which may contain nested parentheses, and _Alignas(...): qbe-prep.rb turns
// `T x[N] __attribute__((__aligned__(A)))` into `T _Alignas(A) x[N]`, and its "(" is not a function's.
string strip_attributes(const string &s) {
  string out;
  size_t i = 0;
  while (true) {
    size_t j = keyword_at(s, "__attribute__", i), a = keyword_at(s, "_Alignas", i);
    size_t kwlen = 13;
    if (a != npos && (j == npos || a < j)) {
      j = a;
      kwlen = 8;
    }
    if (j == npos) {
      out.append(s, i, npos);
      return out;
    }
    out.append(s, i, j - i);
    size_t k = j + kwlen;
    while (k < s.size() && space(s[k])) k++;
    long depth = 0;
    while (k < s.size()) {
      if (s[k] == '(') {
        depth++;
      } else if (s[k] == ')') {
        depth--;
        if (depth == 0) {
          k++;
          break;
        }
      }
      k++;
    }
    i = k;
  }
}

// The first identifier followed by optional whitespace and "(" (leftmost match; inside a word run the match starts at
// its first letter or underscore), unless the "(" is followed by "*" or "(": that opens a grouping declarator, as in
// "void (**name(args))(void *)", and the word before it is a type.
bool first_call_name(const string &s, string &name) {
  size_t from = 0;
  while (true) {
    size_t q = s.find('(', from);
    if (q == npos) return false;
    size_t e = q;
    while (e > 0 && space(s[e - 1])) e--;
    size_t b = e;
    while (b > 0 && word_char(s[b - 1])) b--;
    while (b < e && !ident_start(s[b])) b++;
    if (b < e) {
      size_t n = q + 1;
      while (n < s.size() && space(s[n])) n++;
      if (!(n < s.size() && (s[n] == '*' || s[n] == '('))) {
        name = s.substr(b, e - b);
        return true;
      }
    }
    from = q + 1;
  }
}

// A word (identifier-delimited) occurs in s[from, to).
bool has_word(const string &s, const char *w, size_t from = 0, size_t to = npos) {
  if (to > s.size()) to = s.size();
  size_t n = strlen(w), i = from;
  while (true) {
    size_t j = s.find(w, i);
    if (j == npos || j + n > to) return false;
    char before = j == from ? ' ' : s[j - 1];
    char after = j + n < to ? s[j + n] : ' ';
    if (!word_char(before) && !word_char(after)) return true;
    i = j + n;
  }
}

// Identifiers of s (outside attributes, which the caller strips).
std::vector<string> identifiers(const string &s) {
  std::vector<string> ids;
  size_t i = 0;
  while (i < s.size()) {
    char c = s[i];
    if (ident_start(c)) {
      size_t j = i + 1;
      while (j < s.size() && word_char(s[j])) j++;
      ids.push_back(s.substr(i, j - i));
      i = j;
    } else if (c >= '0' && c <= '9') {
      i++;
      while (i < s.size() && word_char(s[i])) i++;
    } else {
      i++;
    }
  }
  return ids;
}

// The chunk (between the ; { } delimiters) around position w: [b, e).
void chunk_around(const string &text, size_t w, size_t &b, size_t &e) {
  b = 0;
  if (w > 0) {
    size_t x = text.find_last_of(";{}", w - 1);
    if (x != npos) b = x + 1;
  }
  e = text.find_first_of(";{}", w);
  if (e == npos) e = text.size();
}

enum How { NOT_WEAK = 0, HAND = 1, EDG = 2 };

// Whether the __attribute__ at position a has a group that names weak (hand-written C: __attribute__((weak)); EDG's
// __weak__ is found on its own). The group runs from the next "(" to its matching ")" (or the end of the text).
How attribute_weak(const string &text, size_t a) {
  size_t i = text.find('(', a);
  if (i == npos) return NOT_WEAK;
  long depth = 0;
  size_t j = i;
  for (; j < text.size(); j++) {
    if (text[j] == '(') {
      depth++;
    } else if (text[j] == ')') {
      depth--;
      if (depth == 0) break;
    }
  }
  size_t end = j < text.size() ? j + 1 : text.size();
  // no "weak" substring in the group: the common case (aligned, always_inline, ...)
  size_t k = text.find("weak", i);
  if (k == npos || k + 4 > end) return NOT_WEAK;
  if (has_word(text, "__weak__", i, end)) return EDG;
  return has_word(text, "weak", i, end) ? HAND : NOT_WEAK;
}

void add_name(std::map<string, How> &names, const string &n, How how) {
  How &h = names[n];
  if (how == EDG || h == NOT_WEAK) h = how;
}

// Declarations and definitions are delimited by ; { } at top level; each chunk that mentions __weak__ names the
// function or object it declares. A function is the first identifier followed by "(". An object (COMDAT data:
// variable templates, static data members of templates, local statics of inline functions, helper constants such as
// __cmp_cat_id) has no such name, so every identifier before its "=" is a candidate; the caller keeps only the ones
// the assembly defines. Each name is EDG (EDG's __weak__) or HAND (only hand-written C's __attribute__((weak))).
std::map<string, How> weak_names(const string &text) {
  std::map<string, How> names;
  size_t nw = text.find("__weak__");       // the next EDG spelling
  size_t na = text.find("__attribute__");  // the next attribute group, which may be hand-written C's weak
  while (true) {
    while (na != npos && attribute_weak(text, na) == NOT_WEAK) na = text.find("__attribute__", na + 13);
    size_t w = (nw != npos && na != npos) ? std::min(nw, na) : (nw != npos ? nw : na);
    if (w == npos) break;
    How how = w == nw ? EDG : attribute_weak(text, w);
    size_t b, e;
    chunk_around(text, w, b, e);
    string s = strip_attributes(text.substr(b, e - b));
    size_t q = s.find('=');
    if (q != npos) s.resize(q);
    string n;
    if (first_call_name(s, n)) {
      add_name(names, n, how);
    } else {
      for (const string &x : identifiers(s)) add_name(names, x, how);
    }
    size_t pos = e + 1;
    if (nw != npos && nw < pos) nw = text.find("__weak__", pos);
    if (na != npos && na < pos) na = text.find("__attribute__", pos);
  }
  return names;
}

// A function declared "extern" and "__inline__" is weak too: EDG emits the inline members of an "extern template" class
// that way (GNU89 meaning: the out-of-line copy lives in another translation unit, for libstdc++'s
// std::allocator<char> that is libstdc++ itself), while a C99 compiler such as cproc makes it a strong definition in
// every object that uses it.
void add_extern_inline(const string &text, std::map<string, How> &names) {
  size_t pos = 0;
  while (true) {
    size_t w = text.find("__inline__", pos);
    if (w == npos) break;
    size_t b, e;
    chunk_around(text, w, b, e);
    if (has_word(text, "extern", b, e) && !has_word(text, "static", b, e)) {
      string n;
      if (first_call_name(strip_attributes(text.substr(b, e - b)), n)) names[n] = EDG;
    }
    pos = e + 1;
  }
}

// The lines of s, each with its "\n" (the last one may have none).
template <class F>
void each_line(const string &s, F f) {
  size_t pos = 0;
  while (pos < s.size()) {
    size_t nl = s.find('\n', pos);
    size_t end = nl == npos ? s.size() : nl + 1;
    f(pos, end);
    pos = end;
  }
}

// The names the assembly already marks weak (".weak NAME" lines; cproc writes them for hand-written C's weak). A line is
// read as Ruby's strip reads it: leading whitespace, trailing whitespace and NULs removed.
void weak_marked(const string &asm_text, std::unordered_set<string> &marked) {
  each_line(asm_text, [&](size_t b, size_t e) {
    while (b < e && (space(asm_text[b]) || asm_text[b] == '\0')) b++;
    while (e > b && (space(asm_text[e - 1]) || asm_text[e - 1] == '\0')) e--;
    if (e - b >= 6 && asm_text.compare(b, 6, ".weak ") == 0) marked.insert(asm_text.substr(b + 6, e - b - 6));
  });
}

bool label_char(char c) { return word_char(c) || c == '.' || c == '$'; }

// Labels at the start of a line: ^([A-Za-z_.$][\w.$]*):
std::unordered_set<string> defined_labels(const string &asm_text) {
  std::unordered_set<string> defs;
  each_line(asm_text, [&](size_t b, size_t e) {
    if (!(ident_start(asm_text[b]) || asm_text[b] == '.' || asm_text[b] == '$')) return;
    size_t i = b + 1;
    while (i < e && label_char(asm_text[i])) i++;
    if (i < e && asm_text[i] == ':') defs.insert(asm_text.substr(b, i - b));
  });
  return defs;
}

// Names the assembly mentions outside a label definition: the operands of instructions and directives
// ([A-Za-z_.$][\w.$]* runs, as defined_labels reads a label). A run that starts with a digit is skipped whole.
std::unordered_set<string> referenced_names(const string &asm_text) {
  std::unordered_set<string> refs;
  size_t i = 0, n = asm_text.size();
  while (i < n) {
    char c = asm_text[i];
    if (ident_start(c) || c == '.' || c == '$') {
      size_t j = i + 1;
      while (j < n && label_char(asm_text[j])) j++;
      if (!(j < n && asm_text[j] == ':')) refs.insert(asm_text.substr(i, j - i));
      i = j;
    } else if (word_char(c)) {
      while (i < n && word_char(asm_text[i])) i++;
    } else {
      i++;
    }
  }
  return refs;
}

bool read_file(const string &path, string &out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::ostringstream ss;
  ss << f.rdbuf();
  out = ss.str();
  return true;
}

}  // namespace

int main(int argc, char **argv) {
  bool extern_inline = true;
  string prefix, marked_path, weak_directive = ".weak ";
  int a = 1;
  for (; a < argc && strncmp(argv[a], "--", 2) == 0; a++) {
    string opt = argv[a];
    if (opt == "--c-input") {
      extern_inline = false;
    } else if (opt.compare(0, 9, "--marked=") == 0) {
      marked_path = opt.substr(9);
    } else if (opt.compare(0, 13, "--sym-prefix=") == 0) {
      // the target's prefix on every label (QBE's Apple targets prefix "_"); Mach-O's assembler rejects ".weak", and
      // a weak definition is ".weak_definition"
      prefix = opt.substr(13);
      weak_directive = ".weak_definition ";
    }
  }
  if (argc - a != 2) {
    fprintf(stderr, "usage: weak-symbols [--c-input] [--sym-prefix=P] [--marked=FILE] PREPROCESSED_C ASSEMBLY\n");
    return 2;
  }
  string text, asm_text;
  if (!read_file(argv[a], text) || !read_file(argv[a + 1], asm_text)) {
    fprintf(stderr, "weak-symbols: cannot read %s or %s\n", argv[a], argv[a + 1]);
    return 1;
  }
  std::unordered_set<string> defs = defined_labels(asm_text);
  // A name only hand-written C's __attribute__((weak)) marks gets no second .weak where cproc already wrote one (x86-64
  // ELF, its inline-asm side file); elsewhere (Mach-O) this line is the only one. EDG's names are taken as they are.
  std::unordered_set<string> marked;
  weak_marked(asm_text, marked);
  string side;
  if (!marked_path.empty() && read_file(marked_path, side)) weak_marked(side, marked);
  std::map<string, How> attr_names = weak_names(text);
  std::map<string, How> all_names = attr_names;
  if (extern_inline) add_extern_inline(text, all_names);
  std::vector<string> weak;
  for (const auto &[n, how] : all_names) {
    if (how != EDG && marked.count(prefix + n)) continue;
    if (defs.count(prefix + n)) weak.push_back(prefix + n);
  }
  std::sort(weak.begin(), weak.end());
  // A weak declaration the assembly only refers to is a weak undefined reference, as gcc makes it: the address of an
  // absent definition reads as null. EDG declares the init function of an extern thread_local this way (extern
  // __attribute__((__weak__)) void _ZTH<name>(void)), and its wrapper calls it only when the address is not null. ELF
  // only (Mach-O would need .weak_reference), and only the attribute's names: an extern __inline__ function that lives
  // in another unit must stay a strong reference. Mach-O: the prefixed mode, or clang's assembly for an Apple target,
  // which ends with .subsections_via_symbols (the gcc back end on macOS runs this without --sym-prefix).
  std::vector<string> weak_refs;
  bool macho = !prefix.empty() || asm_text.find(".subsections_via_symbols") != npos;
  if (!macho) {
    std::unordered_set<string> refs = referenced_names(asm_text);
    for (const auto &[n, how] : attr_names) {
      if (!defs.count(n) && refs.count(n) && (how == EDG || !marked.count(prefix + n))) weak_refs.push_back(n);
    }
    std::sort(weak_refs.begin(), weak_refs.end());
  }
  if (weak.empty() && weak_refs.empty()) return 0;
  string out = "\n";
  for (const string &n : weak) out += weak_directive + n + "\n";
  for (const string &n : weak_refs) out += ".weak " + n + "\n";
  FILE *f = fopen(argv[a + 1], "ab");
  if (!f || fwrite(out.data(), 1, out.size(), f) != out.size() || fclose(f) != 0) {
    fprintf(stderr, "weak-symbols: cannot append to %s\n", argv[a + 1]);
    return 1;
  }
  return 0;
}
