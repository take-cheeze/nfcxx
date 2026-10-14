// C++ port of scripts/cuda-rewrite.rb (the Ruby script is the reference: same names, same comments, same output).
//
// CUDA launch rewrite for nfcxx: turns the kernel launch syntax of a .cu file into a call of __nfcxx_cuda_launch
// (lib/cuda/nfcxx_cuda.h), so the EDG front end sees only C++.
//   name<<<grid, block[, shmem[, stream]]>>>(args)  ->  __nfcxx_cuda_launch(name, grid, block, shmem, stream, args)
// Usage: build/cuda-rewrite [-I DIR]... [--device [--kernels=FILE]] [--edg-launches] FILE.cu > FILE.cpp
//
// Strings are byte strings, as in Ruby on mruby: indexes are byte offsets and a position past the end reads as
// "absent" (ch() returns -1), where Ruby's s[i] returns nil.
//
// PORT STATUS: the lexical layer (this file's first section) is ported. The remaining passes are listed in
// tools/cuda-rewrite/PORTING.md; until they are ported, main() refuses with exit 2 and the driver keeps the Ruby script.

#include <algorithm>
#include <functional>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>

namespace {

// ---- basic character helpers (Ruby: s[i], white?, ident_char?, refuse) ---------------------------------------------

// The byte at i, or -1 when i is outside the string (Ruby's nil).
int ch(const std::string &s, long i) {
  if (i < 0 || i >= (long)s.size()) return -1;
  return (unsigned char)s[(size_t)i];
}

bool white_c(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

bool ident_c(int c) {
  if (c < 0) return false;
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

[[noreturn]] void refuse(const std::string &msg) {
  std::fprintf(stderr, "refused: %s\n", msg.c_str());
  std::exit(3);
}

// Ruby's s.index(sub, from): the first index >= from where sub starts, or -1.
long str_index(const std::string &s, const std::string &sub, long from) {
  if (from < 0) from = 0;
  if (from > (long)s.size()) return -1;
  size_t p = s.find(sub, (size_t)from);
  return p == std::string::npos ? -1 : (long)p;
}

// The character before position i, skipping whitespace; "" at the start.
std::string text_before(const std::string &text, long i) {
  long j = i - 1;
  while (j >= 0 && white_c(ch(text, j))) j -= 1;
  return j < 0 ? std::string() : std::string(1, text[(size_t)j]);
}

// The [start, end) range of a sorted, non-overlapping list that holds position i, or nullptr. A scan asks it at
// increasing positions, so cursor only moves forward (see piece_at in the Ruby script).
struct Range { long start, end; };
const Range *piece_at(const std::vector<Range> &ranges, size_t &cursor, long i) {
  while (cursor < ranges.size() && ranges[cursor].end <= i) cursor += 1;
  if (cursor >= ranges.size()) return nullptr;
  return ranges[cursor].start <= i ? &ranges[cursor] : nullptr;
}

// ---- literals, comments and brackets (Ruby: skip_literal, matching_paren, split_config, split_top) ------------------

// If a literal or comment starts at s[i], returns the index just past it; otherwise -1 (Ruby's nil).
long skip_literal(const std::string &s, long i) {
  long n = (long)s.size();
  int c = ch(s, i);
  if (c == '/' && ch(s, i + 1) == '/') {
    long j = str_index(s, "\n", i);
    return j < 0 ? n : j;
  }
  if (c == '/' && ch(s, i + 1) == '*') {
    long j = str_index(s, "*/", i + 2);
    if (j < 0) refuse("unterminated comment");
    return j + 2;
  }
  if (c == 'R' && ch(s, i + 1) == '"' && !(i > 0 && ident_c(ch(s, i - 1)))) {
    long paren = str_index(s, "(", i + 2);
    if (paren < 0) refuse("raw string delimiter");
    std::string delim = s.substr((size_t)(i + 2), (size_t)(paren - (i + 2)));
    long close = str_index(s, ")" + delim + "\"", paren + 1);
    if (close < 0) refuse("unterminated raw string");
    return close + (long)delim.size() + 2;
  }
  // A quote after a digit is a digit separator (1'000), not a character literal.
  if (c == '\'' && i > 0 && ch(s, i - 1) >= '0' && ch(s, i - 1) <= '9') return -1;
  if (c == '"' || c == '\'') {
    long j = i + 1;
    while (j < n) {
      if (ch(s, j) == '\\') {
        j += 2;
      } else if (ch(s, j) == c) {
        return j + 1;
      } else {
        j += 1;
      }
    }
    refuse("unterminated literal");
  }
  return -1;
}

// Index of the bracket that closes the one at s[open] (which is `(`), skipping literals; -1 if none.
long matching_paren(const std::string &s, long open) {
  long depth = 0;
  long i = open;
  while (i < (long)s.size()) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(s, i);
    if (c == '(' || c == '[' || c == '{') {
      depth += 1;
    } else if (c == ')' || c == ']' || c == '}') {
      depth -= 1;
      if (depth == 0) return i;
    }
    i += 1;
  }
  return -1;
}

// Ruby's String#strip: leading and trailing ASCII whitespace (space, \t, \n, \v, \f, \r) and NUL.
std::string strip(const std::string &s) {
  auto sp = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' || c == '\0'; };
  size_t a = 0, b = s.size();
  while (a < b && sp(s[a])) a += 1;
  while (b > a && sp(s[b - 1])) b -= 1;
  return s.substr(a, b - a);
}

// Splits the launch configuration text at its top-level commas.
std::vector<std::string> split_config(const std::string &s, long from, long to) {
  std::vector<std::string> items;
  long depth = 0;
  long start = from;
  long i = from;
  while (i < to) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(s, i);
    if (c == '(' || c == '[' || c == '{') {
      depth += 1;
    } else if (c == ')' || c == ']' || c == '}') {
      depth -= 1;
    } else if (c == ',' && depth == 0) {
      items.push_back(strip(s.substr((size_t)start, (size_t)(i - start))));
      start = i + 1;
    }
    i += 1;
  }
  items.push_back(strip(s.substr((size_t)start, (size_t)(to - start))));
  return items;
}

// Splits at top-level commas, counting <...> as brackets too; empty parts are dropped (Ruby: split_top).
std::vector<std::string> split_top(const std::string &s) {
  std::vector<std::string> parts;
  long depth = 0;
  long start = 0;
  long i = 0;
  while (i < (long)s.size()) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(s, i);
    if (c == '(' || c == '[' || c == '{' || c == '<') {
      depth += 1;
    } else if (c == ')' || c == ']' || c == '}' || c == '>') {
      depth -= 1;
    } else if (c == ',' && depth == 0) {
      parts.push_back(strip(s.substr((size_t)start, (size_t)(i - start))));
      start = i + 1;
    }
    i += 1;
  }
  parts.push_back(strip(s.substr((size_t)start)));
  std::vector<std::string> kept;
  for (const auto &p : parts)
    if (!p.empty()) kept.push_back(p);
  return kept;
}

// Index of the first character c at or after from, outside comments and literals; -1 if none.
long index_code(const std::string &s, int c, long from) {
  long i = from;
  while (i < (long)s.size()) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (ch(s, i) == c) return i;
    i += 1;
  }
  return -1;
}

// Ruby's sanitize: every non-identifier byte becomes "_", then each "__" becomes "_" (gsub, left to right).
std::string sanitize(const std::string &s) {
  std::string out;
  for (char c : s) out.push_back(ident_c((unsigned char)c) ? c : '_');
  std::string res;
  for (size_t i = 0; i < out.size();) {
    if (out.compare(i, 2, "__") == 0) {
      res.push_back('_');
      i += 2;
    } else {
      res.push_back(out[i]);
      i += 1;
    }
  }
  return res;
}

// The name of the C-linkage wrapper of a template launch (Ruby: wrapper_name).
std::string wrapper_name(const std::string &name, const std::string &targs) {
  return "__nfcxx_k_" + sanitize(name) + "_" + sanitize(targs);
}

// ---- template kernels and launches (Ruby lines 190-690) ------------------------------------------------------------

// Ruby: $expanded, $kernel_text, $sites (insertion-ordered: a Ruby Hash keeps its order).
std::string g_expanded;
bool g_has_kernel_text = false;
std::string g_kernel_text;
struct Site {
  std::string wrapper, name, targs, decl;
  std::vector<std::string> call;
};
std::vector<Site> g_sites;
std::map<std::string, size_t> g_site_index;

// Ruby slicing text[a...b] / text[a, n] with the bounds clipped to the string (a past the end gives "").
std::string sl(const std::string &s, long a, long b) {
  long n = (long)s.size();
  if (a < 0) a = 0;
  if (b > n) b = n;
  if (a >= b) return std::string();
  return s.substr((size_t)a, (size_t)(b - a));
}
std::string sl_n(const std::string &s, long a, long count) { return sl(s, a, a + count); }

// Ruby: s.split("=")[0] (the text before the first "="; the text itself when there is none).
std::string ruby_split_eq0(const std::string &s) {
  size_t p = s.find('=');
  return p == std::string::npos ? s : s.substr(0, p);
}

// Ruby Array#join(sep).
std::string join(const std::vector<std::string> &v, const std::string &sep) {
  std::string out;
  for (size_t i = 0; i < v.size(); i++) {
    if (i) out += sep;
    out += v[i];
  }
  return out;
}

bool word_at(const std::string &s, long i, const std::string &w) {
  if (sl_n(s, i, (long)w.size()) != w) return false;
  if (i > 0 && ident_c(ch(s, i - 1))) return false;
  if (ident_c(ch(s, i + (long)w.size()))) return false;
  return true;
}

// Forward declarations of the passes that follow in the Ruby order.
std::vector<std::string> tokens_of(const std::string &s);
std::string remove_words(const std::string &s, const std::vector<std::string> &words);
std::string function_name(const std::string &text);
struct Piece {
  long st, en;
  std::string kind;   // "code", "directive", "other" (Ruby symbols)
  bool body;
};
std::vector<Piece> top_pieces(const std::string &text);
std::string member_qualifier_placeholder();  // replaced by the real member_qualifier below

// Ruby: DEVICE_QUALIFIERS (line 1521).
const std::vector<std::string> DEVICE_QUALIFIERS = {"__global__", "__device__", "__host__", "__forceinline__"};

// Ruby kernel_template_uncached (line 202): the template header of the __global__ template named name.
struct KernelTemplate {
  std::vector<std::string> names;
  std::string params;
  bool has_pack = false;
  long pack = 0;
};
bool g_kernel_pieces_ready = false;
std::string g_kernel_pieces_for;
std::vector<Piece> g_kernel_pieces;

bool kernel_template_uncached(const std::string &name, const std::string &src, KernelTemplate &out) {
  if (!g_kernel_pieces_ready || g_kernel_pieces_for != src) {
    g_kernel_pieces = top_pieces(src);
    g_kernel_pieces_for = src;
    g_kernel_pieces_ready = true;
  }
  for (const auto &pc : g_kernel_pieces) {
    if (!(pc.kind == "code" && pc.body)) continue;
    std::string t = sl(src, pc.st, pc.en);
    std::vector<std::string> toks = tokens_of(t);
    bool has_global = false;
    for (const auto &x : toks) has_global = has_global || x == "__global__";
    if (!(!toks.empty() && toks.front() == "template" && has_global)) continue;
    std::string q = remove_words(t, DEVICE_QUALIFIERS);
    if (function_name(q) != name) continue;
    long lt = index_code(q, '<', 0);
    long depth = 0;
    long k = lt;
    while (k < (long)q.size()) {
      if (ch(q, k) == '<') depth += 1;
      if (ch(q, k) == '>') depth -= 1;
      if (depth == 0) break;
      k += 1;
    }
    std::vector<std::string> parts = split_top(sl(q, lt + 1, k));
    std::vector<std::string> names;
    bool pack_found = false;
    long pack = 0;
    for (size_t idx = 0; idx < parts.size(); idx++) {
      std::vector<std::string> pt = tokens_of(ruby_split_eq0(parts[idx]));
      if (!pt.empty()) names.push_back(pt.back());
      if (!pack_found && parts[idx].find("...") != std::string::npos) {
        pack_found = true;
        pack = (long)idx;
      }
    }
    long open = index_code(q, '(', k);
    long close = matching_paren(q, open);
    if (close < 0) refuse("unterminated parameter list for " + name);
    out.names = names;
    out.params = sl(q, open + 1, close);
    out.has_pack = pack_found;
    out.pack = pack;
    return true;
  }
  return false;
}

// Ruby kernel_template (line 192): memoized per unit. The memo is keyed by the unit's identity (the same unit string
// object); here the unit is the g_kernel_text or g_expanded string, compared by value.
std::map<std::string, KernelTemplate> g_kernel_memo;
std::map<std::string, bool> g_kernel_memo_found;
std::string g_kernel_memo_for;
bool g_kernel_memo_valid = false;

bool kernel_template(const std::string &name, KernelTemplate &out) {
  const std::string &src = g_has_kernel_text ? g_kernel_text : g_expanded;
  if (!g_kernel_memo_valid || g_kernel_memo_for != src) {
    g_kernel_memo.clear();
    g_kernel_memo_found.clear();
    g_kernel_memo_for = src;
    g_kernel_memo_valid = true;
  }
  auto it = g_kernel_memo_found.find(name);
  if (it != g_kernel_memo_found.end()) {
    if (it->second) out = g_kernel_memo[name];
    return it->second;
  }
  bool found = kernel_template_uncached(name, src, out);
  g_kernel_memo_found[name] = found;
  if (found) g_kernel_memo[name] = out;
  return found;
}

// Ruby substitute (line 238): replaces the template parameter names in the parameter list by the explicit arguments.
std::string substitute(const std::string &text, const std::vector<std::string> &names,
                       const std::vector<std::string> &args, bool has_pack, long pack) {
  // Each name maps to a list of replacement texts (Ruby: map[n] is a String or an Array).
  std::map<std::string, std::vector<std::string>> map;
  if (!has_pack) {
    for (size_t idx = 0; idx < names.size(); idx++)
      map[names[idx]] = {idx < args.size() ? args[idx] : std::string()};
  } else {
    long size = (long)args.size() - ((long)names.size() - 1);
    for (size_t idx = 0; idx < names.size(); idx++) {
      long ii = (long)idx;
      if (ii < pack) {
        map[names[idx]] = {args[idx]};
      } else if (ii == pack) {
        std::vector<std::string> v;
        for (long q = 0; q < size && pack + q < (long)args.size(); q++) v.push_back(args[(size_t)(pack + q)]);
        map[names[idx]] = v;
      } else {
        long at = ii - 1 + size;
        map[names[idx]] = {at >= 0 && at < (long)args.size() ? args[(size_t)at] : std::string()};
      }
    }
  }
  std::string out;
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      out += sl(text, i, e);
      i = e;
      continue;
    }
    if (ident_c(ch(text, i)) && !(ch(text, i) >= '0' && ch(text, i) <= '9')) {
      long j = i;
      while (j < n && ident_c(ch(text, j))) j += 1;
      std::string w = sl(text, i, j);
      if (has_pack && pack < (long)names.size() && names[(size_t)pack] == w && map.count(w)) {
        long k = j;
        while (k < n && white_c(ch(text, k))) k += 1;
        if (sl_n(text, k, 3) != "...") refuse("parameter pack " + w + " used without ...");
        const auto &vals = map[w];
        for (size_t q = 0; q < vals.size(); q++) {
          if (q) out += ", ";
          out += vals[q];
        }
        i = k + 3;
        continue;
      }
      auto it = map.find(w);
      if (it != map.end()) {
        // Ruby: an Array value prints its first element (v[0].to_s); nil (an empty pack) prints "".
        out += it->second.empty() ? std::string() : it->second.front();
      } else {
        out += w;
      }
      i = j;
    } else {
      out.push_back(text[(size_t)i]);
      i += 1;
    }
  }
  return out;
}

// Ruby template_site (line 288): the wrapper of a template launch. Registers it in g_sites.
std::string template_site(const std::string &name, const std::string &targs) {
  KernelTemplate kt;
  if (!kernel_template(name, kt)) refuse("template kernel " + name + ": no __global__ template of that name in the source");
  std::vector<std::string> args = split_top(targs);
  bool bad = kt.has_pack ? (long)args.size() < (long)kt.names.size() - 1 : args.size() != kt.names.size();
  if (bad) refuse("template kernel " + name + "<" + targs + ">: explicit arguments must give every template parameter");
  std::string decl = substitute(kt.params, kt.names, args, kt.has_pack, kt.pack);
  std::vector<std::string> call;
  for (const auto &part : split_top(decl)) {
    std::vector<std::string> pt = tokens_of(ruby_split_eq0(part));
    if (pt.empty()) refuse("template kernel " + name + ": unnamed parameter " + part);
    call.push_back(pt.back());
  }
  std::string w = wrapper_name(name, targs);
  if (!g_site_index.count(w)) {
    g_site_index[w] = g_sites.size();
    g_sites.push_back(Site{w, name, targs, decl, call});
  }
  return w;
}


// Ruby angle_index (line 323): every code `<` of the text, with its matching `>` (or -1), indexed once per text.
std::map<long, long> g_angle_index;
const std::string *g_angle_index_for = nullptr;
std::string g_angle_index_text;

const std::map<long, long> &angle_index(const std::string &s) {
  if (g_angle_index_for && g_angle_index_text == s) return g_angle_index;
  std::map<long, long> idx;
  std::vector<long> stack;
  long k = 0;
  long n = (long)s.size();
  while (k < n) {
    long e = skip_literal(s, k);
    if (e >= 0) {
      k = e;
      continue;
    }
    if (ch(s, k) == '<') {
      idx[k] = -1;
      stack.push_back(k);
    } else if (ch(s, k) == '>' && !stack.empty()) {
      idx[stack.back()] = k;
      stack.pop_back();
    }
    k += 1;
  }
  g_angle_index = idx;
  g_angle_index_text = s;
  g_angle_index_for = &g_angle_index_text;
  return g_angle_index;
}

// Ruby matching_angle (line 347): the `>` closing the `<` at open, or -1 (nil).
long matching_angle(const std::string &s, long open) {
  if ((long)s.size() >= 4000) {
    const auto &idx = angle_index(s);
    auto it = idx.find(open);
    if (it != idx.end()) return it->second;
  }
  long depth = 0;
  long k = open;
  long n = (long)s.size();
  while (k < n) {
    long e = skip_literal(s, k);
    if (e >= 0) {
      k = e;
      continue;
    }
    if (ch(s, k) == '<') depth += 1;
    if (ch(s, k) == '>') {
      depth -= 1;
      if (depth == 0) return k;
    }
    k += 1;
  }
  return -1;
}

// Ruby directive_spans (line 372): [start, end) of each directive, continuation lines included.
std::vector<std::pair<long, long>> directive_spans(const std::string &text) {
  std::vector<std::pair<long, long>> spans;
  long n = (long)text.size();
  long i = 0;
  bool bol = true;
  while (i < n) {
    if (bol) {
      long j = i;
      while (j < n && (text[(size_t)j] == ' ' || text[(size_t)j] == '\t')) j += 1;
      if (j < n && text[(size_t)j] == '#') {
        long k = j;
        while (true) {
          long nl = str_index(text, "\n", k);
          if (nl < 0) nl = n;
          if (nl < n && nl > 0 && text[(size_t)(nl - 1)] == '\\') {
            k = nl + 1;
          } else {
            k = nl;
            break;
          }
        }
        spans.push_back({i, k});
        i = k;
        bol = false;
        continue;
      }
    }
    bol = (ch(text, i) == '\n');
    i += 1;
  }
  return spans;
}

// Ruby directive_ends (line 406): start index => end index.
std::map<long, long> directive_ends(const std::string &text) {
  std::map<long, long> out;
  for (const auto &sp : directive_spans(text)) out[sp.first] = sp.second;
  return out;
}

// Ruby local_constant_visible (line 415): the value of the nearest visible local constant `name = VALUE` before pos.
bool local_constant_visible(const std::string &text, long pos, const std::string &name, std::string &value);

// Ruby int_expr_value (line 440): a recursive-descent reader of integer expressions over literals and local constants.
bool int_expr_value(const std::string &text, long pos, const std::string &s, long &value, int depth = 0);

// Ruby resolve_local_constants (line 517): replaces the names of local constants in a launch's template arguments.
std::string resolve_local_constants(const std::string &text, const std::string &targs, long pos);


// 1-based line number of position pos: the newlines before pos, plus one (Ruby: text[0...pos].count("\n") + 1).
long line_of(const std::string &text, long pos) {
  long n = 1;
  for (long i = 0; i < pos && i < (long)text.size(); i++)
    if (text[(size_t)i] == '\n') n++;
  return n;
}

// Ruby local_constant (line 685): the value of a local constant `T name = VALUE;` before pos, in the body at open.
bool local_constant(const std::string &text, long open, long pos, const std::string &name, std::string &value) {
  std::string seg = sl(text, open, pos);
  bool found = false;
  long i = 0;
  while (true) {
    long k = str_index(seg, name, i);
    if (k < 0) break;
    long e = k + (long)name.size();
    i = e;
    if ((k > 0 && ident_c(ch(seg, k - 1))) || (e < (long)seg.size() && ident_c(ch(seg, e)))) continue;
    long b = k - 1;
    while (b >= 0 && white_c(ch(seg, b))) b -= 1;
    if (!(b >= 0 && ident_c(ch(seg, b)))) continue;
    long a = e;
    while (a < (long)seg.size() && white_c(ch(seg, a))) a += 1;
    if (!(ch(seg, a) == '=' && ch(seg, a + 1) != '=')) continue;
    long semi = str_index(seg, ";", a);
    if (semi < 0) continue;
    found = true;
    value = strip(sl(seg, a + 1, semi));
  }
  return found;
}

// Ruby member_qualifier (line 707): `Q<args>::member` in a header; false when none.
struct MemberQualifier {
  std::string name;
  std::vector<std::string> args;
};
bool member_qualifier(const std::string &header, MemberQualifier &out) {
  long cc = str_index(header, "::", 0);
  if (cc < 0) return false;
  std::string before = header.substr(0, (size_t)cc);
  // Ruby rstrip: trailing ASCII whitespace.
  while (!before.empty() && (before.back() == ' ' || before.back() == '\t' || before.back() == '\n' ||
                             before.back() == '\r' || before.back() == '\v' || before.back() == '\f' || before.back() == '\0'))
    before.pop_back();
  if (before.empty() || before.back() != '>') return false;
  long open = (long)before.size() - 1;
  long depth = 0;
  while (open >= 0) {
    if (ch(before, open) == '>') depth += 1;
    if (ch(before, open) == '<') depth -= 1;
    if (depth == 0) break;
    open -= 1;
  }
  if (open < 0) return false;
  long name_start = open;
  while (name_start > 0 && ident_c(ch(before, name_start - 1))) name_start -= 1;
  std::string name = sl(before, name_start, open);
  if (name.empty()) return false;
  out.name = name;
  out.args = split_top(sl(before, open + 1, (long)before.size() - 1));
  return true;
}

// Ruby member_instances (line 730): the explicit instantiations of the class template, mapped onto the member
// template's names (one list per instance, in the member's parameter order).
struct OuterTemplate {
  long st = 0, open = 0;
  long line = 0;  // Ruby: outer[:line] (set by dependent_launches)
  std::vector<std::string> names;
  std::vector<std::string> decls;
  std::string fname;
  bool has_qual = false;
  MemberQualifier qual;
  bool has_pack = false;
  long pack = 0;
};

std::vector<std::vector<std::string>> member_instances(const OuterTemplate &outer, const std::string &text) {
  const MemberQualifier &q = outer.qual;
  std::vector<std::vector<std::string>> raw;
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (word_at(text, i, "template")) {
      long k = i + 8;
      while (k < n && white_c(ch(text, k))) k += 1;
      if (word_at(text, k, "class") || word_at(text, k, "struct")) {
        k += (sl_n(text, k, 5) == "class" ? 5 : 6);
        while (k < n && white_c(ch(text, k))) k += 1;
        if (word_at(text, k, q.name)) {
          k += (long)q.name.size();
          while (k < n && white_c(ch(text, k))) k += 1;
          if (ch(text, k) == '<') {
            long close = matching_angle(text, k);
            if (close >= 0) raw.push_back(split_top(sl(text, k + 1, close)));
          }
        }
      }
    }
    i += 1;
  }
  std::vector<std::vector<std::string>> out;
  for (const auto &args : raw) {
    if (args.size() != q.args.size())
      refuse("member template " + outer.fname + ": the class instance " + q.name + "<" + join(args, ", ") +
             "> does not give all its arguments");
    std::vector<std::string> one;
    for (const auto &nm : outer.names) {
      long k = -1;
      for (size_t x = 0; x < q.args.size(); x++)
        if (q.args[x] == nm) {
          k = (long)x;
          break;
        }
      if (k < 0) refuse("member template " + outer.fname + ": its parameter " + nm + " is not a parameter of " + q.name);
      one.push_back(args[(size_t)k]);
    }
    if (std::find(out.begin(), out.end(), one) == out.end()) out.push_back(one);  // Ruby uniq
  }
  return out;
}

// Ruby call_sites (line 770): the explicit template-argument lists of the calls of template function name, indexed
// once per text. Each entry is { targs, position }.
struct CallSite {
  std::vector<std::string> targs;  // unused for the text form (see call_sites)
  std::string text_targs;
  long pos;
};
std::map<std::string, std::vector<std::pair<std::string, long>>> g_call_index;
std::string g_call_index_text;
bool g_call_index_ready = false;

const std::vector<std::pair<std::string, long>> &call_sites(const std::string &text, const std::string &name) {
  static const std::vector<std::pair<std::string, long>> none;
  if (!g_call_index_ready || g_call_index_text != text) {
    std::map<std::string, std::vector<std::pair<std::string, long>>> index;
    // Directives are not code: a #define's body names its parameters (DECL_MMQ_CASE(type)), which are not calls.
    std::vector<Range> pp;
    for (const auto &pc : top_pieces(text))
      if (pc.kind == "pp") pp.push_back(Range{pc.st, pc.en});
    size_t pp_cursor = 0;
    long i = 0;
    long n = (long)text.size();
    while (i < n) {
      long e = skip_literal(text, i);
      if (e >= 0) {
        i = e;
        continue;
      }
      if (const Range *hit = piece_at(pp, pp_cursor, i)) {
        i = hit->end;
        continue;
      }
      if (ident_c(ch(text, i)) && !(i > 0 && ident_c(ch(text, i - 1))) && !(ch(text, i) >= '0' && ch(text, i) <= '9')) {
        long j = i;
        while (j < n && ident_c(ch(text, j))) j += 1;
        std::string id = sl(text, i, j);
        long k = j;
        while (k < n && white_c(ch(text, k))) k += 1;
        if (ch(text, k) == '<') {
          long close = matching_angle(text, k);
          if (close >= 0) {
            long m = close + 1;
            while (m < n && white_c(ch(text, m))) m += 1;
            if (ch(text, m) == '(') index[id].push_back({strip(sl(text, k + 1, close)), i});
          }
        }
        i = j;
        continue;
      }
      i += 1;
    }
    g_call_index = index;
    g_call_index_text = text;
    g_call_index_ready = true;
  }
  auto it = g_call_index.find(name);
  return it != g_call_index.end() ? it->second : none;
}

// Ruby DECL_WORDS (line 817).
const std::vector<std::string> DECL_WORDS = {"void", "static", "inline", "int", "float", "double", "bool", "size_t",
                                             "unsigned", "long", "char", "short", "template", "__device__", "__host__",
                                             "__global__", "__forceinline__", "constexpr", "auto"};

// Ruby plain_call_sites (line 819): the unqualified calls name(args) of a template function, as {args, position}.
std::vector<std::pair<std::vector<std::string>, long>> plain_call_sites(const std::string &text, const std::string &name) {
  std::vector<std::pair<std::vector<std::string>, long>> out;
  std::vector<Range> pp;
  for (const auto &pc : top_pieces(text))
    if (pc.kind == "pp") pp.push_back(Range{pc.st, pc.en});
  size_t pp_cursor = 0;
  long i = 0;
  long n = (long)text.size();
  long nl = (long)name.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (const Range *hit = piece_at(pp, pp_cursor, i)) {
      i = hit->end;
      continue;
    }
    // A qualified call (`cg::reduce(...)`) or a member call (`x.reduce(...)`) names another function.
    bool qualified = (i >= 2 && sl_n(text, i - 2, 2) == "::") || (i >= 1 && ch(text, i - 1) == '.') ||
                     (i >= 2 && sl_n(text, i - 2, 2) == "->");
    if (sl_n(text, i, nl) == name && !qualified && !(i > 0 && ident_c(ch(text, i - 1))) &&
        !ident_c(ch(text, i + nl) < 0 ? ' ' : ch(text, i + nl))) {
      long k = i + nl;
      while (k < n && white_c(ch(text, k))) k += 1;
      if (ch(text, k) == '(') {
        long close = matching_paren(text, k);
        if (close >= 0) {
          long after = close + 1;
          while (after < n && white_c(ch(text, after))) after += 1;
          long b = i - 1;
          while (b >= 0 && white_c(ch(text, b))) b -= 1;
          long e2 = b;
          while (b >= 0 && ident_c(ch(text, b))) b -= 1;
          std::string prev = sl(text, b + 1, e2 + 1);
          bool is_decl = std::find(DECL_WORDS.begin(), DECL_WORDS.end(), prev) != DECL_WORDS.end() ||
                         ch(text, after) == '{';
          if (!is_decl) out.push_back({split_top(sl(text, k + 1, close)), i});
        }
      }
    }
    i += 1;
  }
  return out;
}

// Ruby caller_arg_type (line 860): the type of a call argument in the caller.
std::vector<std::string> argument_type(const std::string &text, long pos, const std::string &arg, const std::string &nm);
std::vector<std::string> type_tokens(const std::string &s);
std::vector<std::string> caller_arg_type(const std::string &text, long pos, const std::string &arg, const std::string &name) {
  std::string a = strip(arg);
  if (!a.empty() && a[0] == '(') {
    long close = matching_paren(a, 0);
    if (close >= 0 && close + 1 < (long)a.size()) {
      std::string rest = strip(sl(a, close + 1, (long)a.size()));
      if (!rest.empty() && ident_c(ch(rest, 0))) return type_tokens(sl(a, 1, close));
    }
  }
  return argument_type(text, pos, a, name);
}

// Ruby template_head_of (line 872): the parameter names and parts of a template function's definition.
struct TemplateHead {
  std::vector<std::string> names;
  std::vector<std::string> parts;
  long pos = 0;
};
bool template_head_of(const std::string &text, const std::string &name, TemplateHead &out);

// Ruby deduce_call_targs (line 889): the explicit template arguments of a call, deduced from its arguments' types.
// Returns false when the template is unknown (Ruby nil).
bool deduce_call_targs(const std::string &text, const std::string &name, long pos,
                       const std::vector<std::string> &args, std::vector<std::string> &out);

// Ruby enclosing_block (line 2988): the innermost `{ ... }` block containing pos, as [open, close]; false at file scope.
// (The perf version of the Ruby script indexes the braces once; the answer is the same.)
bool enclosing_block_bounds(const std::string &s, long pos, long &close_out) {
  std::vector<long> stack;
  long i = 0;
  long n = (long)s.size();
  while (i < pos && i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (ch(s, i) == '{') stack.push_back(i);
    if (ch(s, i) == '}' && !stack.empty()) stack.pop_back();
    i += 1;
  }
  if (stack.empty()) return false;
  long open = stack.back();
  long depth = 0;
  long j = open;
  while (j < n) {
    long e = skip_literal(s, j);
    if (e >= 0) {
      j = e;
      continue;
    }
    if (ch(s, j) == '{') depth += 1;
    if (ch(s, j) == '}') depth -= 1;
    if (depth == 0) {
      close_out = j;
      return true;
    }
    j += 1;
  }
  close_out = n;
  return true;
}

// Ruby identity memo (`equal?`): the cache is valid for the same string object (address and size).
struct IdentKey {
  const std::string *obj = nullptr;
  size_t size = 0;
  bool is(const std::string &s) const { return obj == &s && size == s.size(); }
  void set(const std::string &s) { obj = &s; size = s.size(); }
};

// Ruby template_bodies (line 617) entries: { open, close, tmpl } where tmpl is the template header.
struct TmplHeader {
  long st = 0, lt = 0, close = 0;
};
struct TemplateBody {
  long open = 0, close = 0;
  TmplHeader tmpl;
};
IdentKey g_template_bodies_key;
std::vector<TemplateBody> g_template_bodies;

// Ruby matching_brace (line 595).
long matching_brace(const std::string &s, long open) {
  long depth = 0;
  long i = open;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (ch(s, i) == '{') depth += 1;
    if (ch(s, i) == '}') {
      depth -= 1;
      if (depth == 0) return i;
    }
    i += 1;
  }
  return -1;
}

// Ruby template_bodies (line 617): each `{` whose header starts with `template <...>`, with its body's braces.
const std::vector<TemplateBody> &template_bodies(const std::string &text) {
  if (g_template_bodies_key.is(text)) return g_template_bodies;
  std::vector<TemplateBody> out;
  struct Frame {
    long hs;
    long open;
    bool has_tmpl;
    TmplHeader tmpl;
  };
  std::vector<Frame> stack;
  stack.push_back(Frame{0, 0, false, TmplHeader()});
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(text, i);
    if (c == '{') {
      // the header's last `template <`: a comment, a preprocessor line or a declaration may come before it
      bool has_tmpl = false;
      TmplHeader tmpl;
      long k = stack.back().hs;
      while (k < i) {
        long e2 = skip_literal(text, k);
        if (e2 >= 0) {
          k = e2;
          continue;
        }
        if (word_at(text, k, "template")) {
          long lt = index_code(text, '<', k + 8);
          if (lt >= 0 && lt < i && strip(sl(text, k + 8, lt)).empty()) {
            long close = matching_angle(text, lt);
            if (close >= 0 && close < i) {
              has_tmpl = true;
              tmpl = TmplHeader{k, lt, close};
            }
          }
        }
        k += 1;
      }
      stack.push_back(Frame{i + 1, i, has_tmpl, tmpl});
    } else if (c == '}') {
      Frame frame = stack.size() > 1 ? stack.back() : stack.back();
      if (stack.size() > 1) stack.pop_back();
      if (frame.has_tmpl) out.push_back(TemplateBody{frame.open, i, frame.tmpl});
      stack.back().hs = i + 1;
    } else if (c == ';') {
      stack.back().hs = i + 1;
    }
    i += 1;
  }
  g_template_bodies = out;
  g_template_bodies_key.set(text);
  return g_template_bodies;
}

// Ruby enclosing_template (line 665): the innermost template body holding pos, as the function template's facts.
bool enclosing_template(const std::string &text, long pos, OuterTemplate &out) {
  const auto &all = template_bodies(text);
  const TemplateBody *best = nullptr;
  for (const auto &tb : all)
    if (tb.open < pos && pos < tb.close && (!best || tb.open > best->open)) best = &tb;  // max_by: first max wins
  if (!best) return false;
  TmplHeader t = best->tmpl;
  std::vector<std::string> params = split_top(sl(text, t.lt + 1, t.close));
  // One parameter pack is allowed (`int... Ns`): its index is recorded; its values come from the explicit calls.
  std::vector<long> packs;
  for (size_t k = 0; k < params.size(); k++)
    if (params[k].find("...") != std::string::npos) packs.push_back((long)k);
  if (packs.size() > 1)
    refuse("template with " + std::to_string(packs.size()) + " parameter packs (at line " +
           std::to_string(line_of(text, pos)) + "): one is supported");
  std::vector<std::string> decls, names;
  for (const auto &pr : params) {
    std::string d = strip(ruby_split_eq0(pr));
    decls.push_back(d);
    std::vector<std::string> pt = tokens_of(d);
    names.push_back(pt.empty() ? std::string() : pt.back());
  }
  std::string header = sl(text, t.close + 1, best->open);
  out = OuterTemplate();
  out.st = t.st;
  out.names = names;
  out.decls = decls;
  out.fname = function_name(header);
  out.has_qual = member_qualifier(header, out.qual);
  out.open = best->open;
  out.has_pack = !packs.empty();
  out.pack = packs.empty() ? 0 : packs.front();
  return true;
}

// Ruby dependent_on_template (line 311): the parameter name the template arguments use, when the launch is inside a
// template body; false (Ruby nil) otherwise.
bool dependent_on_template(const std::string &text, long i, const std::string &targs, std::string &name) {
  const TemplateBody *best = nullptr;
  for (const auto &tb : template_bodies(text))
    if (tb.open < i && i < tb.close && (!best || tb.open > best->open)) best = &tb;
  if (!best) return false;
  TmplHeader t = best->tmpl;
  std::vector<std::string> names;
  for (const auto &pr : split_top(sl(text, t.lt + 1, t.close))) {
    std::vector<std::string> pt = tokens_of(ruby_split_eq0(pr));
    if (!pt.empty()) names.push_back(pt.back());
  }
  std::vector<std::string> used = tokens_of(targs);
  for (const auto &nm : names)
    if (std::find(used.begin(), used.end(), nm) != used.end()) {
      name = nm;
      return true;
    }
  return false;
}

// Ruby int_expr_value (line 440): an integer expression of literals, `+ - * / %`, parentheses and visible local
// constants. Recursive descent over the tokens (no eval). Returns false when it is not one (Ruby nil).
bool int_expr_value(const std::string &text, long pos, const std::string &s, long &value, int depth) {
  if (depth > 8) return false;
  struct Tok {
    int kind;  // 0 = num, 1 = id, 2 = op
    std::string text;
  };
  std::vector<Tok> toks;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    int c = ch(s, i);
    if (white_c(c)) {
      i += 1;
    } else if ((c >= '0' && c <= '9') || ident_c(c)) {
      long j = i;
      while (j < n && ident_c(ch(s, j))) j += 1;
      toks.push_back(Tok{(c >= '0' && c <= '9') ? 0 : 1, sl(s, i, j)});
      i = j;
    } else if (std::string("+-*/%()").find((char)c) != std::string::npos) {
      toks.push_back(Tok{2, std::string(1, (char)c)});
      i += 1;
    } else {
      return false;
    }
  }
  if (toks.empty()) return false;
  size_t p = 0;
  bool ok = true;
  // Recursive descent: expr = term (('+'|'-') term)*; term = factor (('*'|'/'|'%') factor)*; factor as in Ruby.
  std::function<bool(long &)> expr, factor;
  std::function<bool(long &)> term;
  term = [&](long &out) -> bool {
    long v;
    if (!factor(v)) return false;
    while (p < toks.size() && toks[p].kind == 2 && std::string("*/%").find(toks[p].text) != std::string::npos) {
      std::string op = toks[p].text;
      p += 1;
      long r;
      if (!factor(r)) return false;
      if (op != "*" && r == 0) return false;
      if (op == "*") v = v * r;
      else if (op == "/") v = v / r;
      else v = v % r;
    }
    out = v;
    return true;
  };
  expr = [&](long &out) -> bool {
    long v;
    if (!term(v)) return false;
    while (p < toks.size() && toks[p].kind == 2 && (toks[p].text == "+" || toks[p].text == "-")) {
      std::string op = toks[p].text;
      p += 1;
      long r;
      if (!term(r)) return false;
      v = op == "+" ? v + r : v - r;
    }
    out = v;
    return true;
  };
  factor = [&](long &out) -> bool {
    if (p >= toks.size()) return false;
    Tok tk = toks[p];
    p += 1;
    if (tk.kind == 0) {
      std::string digits = tk.text;
      while (!digits.empty() && std::string("uUlL").find(digits.back()) != std::string::npos) digits.pop_back();
      if (digits.size() >= 2 && digits.compare(0, 2, "0x") == 0) out = std::strtol(digits.c_str() + 2, nullptr, 16);
      else out = std::strtol(digits.c_str(), nullptr, 10);
      return true;
    }
    if (tk.kind == 1) {
      std::string val;
      if (!local_constant_visible(text, pos, tk.text, val)) return false;
      return int_expr_value(text, pos, val, out, depth + 1);
    }
    if (tk.text == "(") {
      long v;
      if (!expr(v)) return false;
      if (!(p < toks.size() && toks[p].kind == 2 && toks[p].text == ")")) return false;
      p += 1;
      out = v;
      return true;
    }
    if (tk.text == "-") {
      long v;
      if (!factor(v)) return false;
      out = -v;
      return true;
    }
    return false;
  };
  long value_out = 0;
  ok = expr(value_out);
  if (!ok) return false;
  if (p != toks.size()) return false;
  value = value_out;
  return true;
}

// Ruby local_constant_visible (line 415): the value of the nearest local constant `name = VALUE` before pos whose block
// is still open at pos.
bool local_constant_visible(const std::string &text, long pos, const std::string &name, std::string &value) {
  std::string seg = sl(text, 0, pos);
  bool found = false;
  long i = 0;
  while (true) {
    long k = str_index(seg, name, i);
    if (k < 0) break;
    long e = k + (long)name.size();
    i = e;
    if ((k > 0 && ident_c(ch(seg, k - 1))) || (e < (long)seg.size() && ident_c(ch(seg, e)))) continue;
    long b = k - 1;
    while (b >= 0 && white_c(ch(seg, b))) b -= 1;
    if (!(b >= 0 && ident_c(ch(seg, b)))) continue;
    long a = e;
    while (a < (long)seg.size() && white_c(ch(seg, a))) a += 1;
    if (!(ch(seg, a) == '=' && ch(seg, a + 1) != '=')) continue;
    long semi = str_index(seg, ";", a);
    if (semi < 0) continue;
    // Ruby: blk = enclosing_block(text, k); next unless blk.nil? || blk[1] > pos
    long blk_close = -1;
    bool has_blk = enclosing_block_bounds(text, k, blk_close);
    if (has_blk && !(blk_close > pos)) continue;
    found = true;
    value = strip(sl(seg, a + 1, semi));
  }
  return found;
}

// Ruby resolve_local_constants (line 517): the template arguments of a launch with its local constants' values.
std::string resolve_local_constants(const std::string &text, const std::string &targs, long pos) {
  bool has_ident = false;
  for (char c : targs)
    if (ident_c((unsigned char)c) && !(c >= '0' && c <= '9')) has_ident = true;
  if (!has_ident) return targs;
  long unused_close = -1;
  if (!enclosing_block_bounds(text, pos, unused_close)) return targs;
  OuterTemplate outer;
  bool has_outer = enclosing_template(text, pos, outer);
  std::string out;
  long i = 0;
  long n = (long)targs.size();
  while (i < n) {
    int c = ch(targs, i);
    if (ident_c(c) && !(c >= '0' && c <= '9')) {
      long j = i;
      while (j < n && ident_c(ch(targs, j))) j += 1;
      std::string v = sl(targs, i, j);
      // A parameter of the enclosing template is that template's, not a local: its launch is dependent.
      bool is_param = has_outer && std::find(outer.names.begin(), outer.names.end(), v) != outer.names.end();
      std::string val;
      bool have = !is_param && local_constant_visible(text, pos, v, val);
      if (have) {
        // An integer expression of constants is its value. A single name (a macro, or a type alias) is carried as the
        // name. Anything else (a generic lambda's decltype(I)::value) is not carried.
        long nv;
        if (int_expr_value(text, pos, val, nv, 0)) {
          out += std::to_string(nv);
          i = j;
          continue;
        }
        bool single = !val.empty();
        for (char cc : val)
          if (!ident_c((unsigned char)cc)) single = false;
        if (!single)
          refuse("template argument " + v + " of the launch at line " + std::to_string(line_of(text, pos)) + " is " + val +
                 ": only an integer constant or a name is carried");
        out += val;
      } else {
        out += v;
      }
      i = j;
    } else {
      out.push_back(targs[(size_t)i]);
      i += 1;
    }
  }
  return out;
}

// Ruby template_launches (line 556): [name, targs, position] of each `<<<` after a template argument list.
struct TemplateLaunch {
  std::string name, targs;
  long pos;
};
std::vector<TemplateLaunch> template_launches(const std::string &text) {
  std::vector<TemplateLaunch> found;
  long i = 0;
  long n = (long)text.size();
  std::map<long, long> dirs = directive_ends(text);
  while (i < n) {
    auto dit = dirs.find(i);
    if (dit != dirs.end()) {
      i = dit->second;
      continue;
    }
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (sl_n(text, i, 3) == "<<<" && text_before(text, i) == ">") {
      // the `>` closing the template arguments: the nearest one before `<<<` (a line break may come between)
      long gt = i - 1;
      while (gt >= 0 && white_c(ch(text, gt))) gt -= 1;
      long j = gt;
      long depth = 0;
      while (j >= 0) {
        if (ch(text, j) == '>') depth += 1;
        if (ch(text, j) == '<') depth -= 1;
        if (depth == 0) break;
        j -= 1;
      }
      long k = j - 1;
      while (k >= 0 && white_c(ch(text, k))) k -= 1;
      long e2 = k + 1;
      while (k >= 0 && ident_c(ch(text, k))) k -= 1;
      std::string name = sl(text, k + 1, e2);
      if (!name.empty()) {
        std::string targs = strip(sl(text, j + 1, gt));
        found.push_back(TemplateLaunch{name, resolve_local_constants(text, targs, i), i});
      }
    }
    i += 1;
  }
  return found;
}

// Ruby QUAL_WORDS (line 1191).
const std::vector<std::string> QUAL_WORDS = {"const", "volatile", "__restrict__", "__restrict", "restrict"};

// Ruby: text.index-based helpers used by the deduction code.
std::vector<std::string> remove_qual(const std::vector<std::string> &v) {
  std::vector<std::string> out;
  for (const auto &x : v)
    if (std::find(QUAL_WORDS.begin(), QUAL_WORDS.end(), x) == QUAL_WORDS.end()) out.push_back(x);
  return out;
}

// Ruby launch_macros (line 1194): name => { params, body } for the function-like macros whose body holds a launch.
struct LaunchMacro {
  std::string name;
  std::vector<std::string> params;
  std::string body;
};
std::vector<LaunchMacro> launch_macros(const std::string &text) {
  std::vector<LaunchMacro> out;
  for (const auto &sp : directive_spans(text)) {
    // Ruby: text[st...en].sub("#", "").gsub("\\\n", " ").strip
    std::string raw = sl(text, sp.first, sp.second);
    size_t hp = raw.find('#');
    if (hp != std::string::npos) raw.erase(hp, 1);
    std::string t;
    for (size_t x = 0; x < raw.size(); x++) {
      if (raw[x] == '\\' && x + 1 < raw.size() && raw[x + 1] == '\n') {
        t += ' ';
        x += 1;
      } else {
        t += raw[x];
      }
    }
    t = strip(t);
    if (t.compare(0, 6, "define") != 0 || t.size() < 6) continue;
    std::string rest = t.substr(6);
    size_t a = 0;
    while (a < rest.size() && (rest[a] == ' ' || rest[a] == '\t' || rest[a] == '\n' || rest[a] == '\r' || rest[a] == '\v' || rest[a] == '\f')) a += 1;
    rest = rest.substr(a);
    long k = 0;
    while (k < (long)rest.size() && ident_c(ch(rest, k))) k += 1;
    std::string name = sl(rest, 0, k);
    std::string after = sl(rest, k, (long)rest.size());
    if (name.empty() || after.empty() || after[0] != '(') continue;
    long close = str_index(after, ")", 0);
    if (close < 0) continue;
    std::string body = strip(sl(after, close + 1, (long)after.size()));
    bool keep = body.find("<<<") != std::string::npos || body.compare(0, 9, "template ") == 0 ||
                body.compare(0, 16, "extern template ") == 0;
    if (!keep) continue;
    LaunchMacro m;
    m.name = name;
    m.params = split_top(sl(after, 1, close));
    m.body = body;
    bool replaced = false;
    for (auto &x : out)
      if (x.name == name) {
        x = m;
        replaced = true;
      }
    if (!replaced) out.push_back(m);  // Ruby Hash: a later definition of a name replaces the value
  }
  return out;
}

// Ruby define_name_at? (line 1217).
bool define_name_at(const std::string &text, long i) {
  long ls = i;
  while (ls > 0 && ch(text, ls - 1) != '\n') ls -= 1;
  std::string pre = strip(sl(text, ls, i));
  if (pre.empty() || pre[0] != '#') return false;
  std::string rest = strip(pre.substr(1));
  if (rest.compare(0, 6, "define") != 0) return false;
  return strip(rest.size() >= 6 ? rest.substr(6) : std::string()).empty();
}

// Ruby expand_launch_macros (line 1227): expands the calls of the launch macros in code, nested calls included.
std::string expand_launch_macros(const std::string &text, int depth) {
  auto macros = launch_macros(text);
  if (macros.empty()) return text;
  if (depth > 4) refuse("launch macros nest more than 4 deep");
  std::vector<Range> code;
  for (const auto &pc : top_pieces(text))
    if (pc.kind == "code") code.push_back(Range{pc.st, pc.en});
  size_t code_cursor = 0;
  long n = (long)text.size();
  std::string out;
  bool changed = false;
  long i = 0;
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      out += sl(text, i, e);
      i = e;
      continue;
    }
    if (ident_c(ch(text, i)) && !(i > 0 && ident_c(ch(text, i - 1))) && piece_at(code, code_cursor, i)) {
      long j = i;
      while (j < n && ident_c(ch(text, j))) j += 1;
      std::string name = sl(text, i, j);
      const LaunchMacro *m = nullptr;
      for (const auto &x : macros)
        if (x.name == name) m = &x;
      long k = j;
      while (k < n && white_c(ch(text, k))) k += 1;
      // The name in a macro's own #define header is not a call (see DECL_FATTN_TILE_CASE in the Ruby script).
      if (m && k < n && ch(text, k) == '(' && !define_name_at(text, i)) {
        long close = matching_paren(text, k);
        if (close < 0) refuse("unterminated call of launch macro " + name);
        std::vector<std::string> args = split_top(sl(text, k + 1, close));
        if (args.size() != m->params.size())
          refuse("launch macro " + name + " takes " + std::to_string(m->params.size()) + " arguments, its call gives " +
                 std::to_string(args.size()));
        std::string body = substitute(m->body, m->params, args, false, 0);
        for (char &c : body)
          if (c == '\n') c = ' ';
        out += body;
        long nls = 0;
        for (long q = i; q <= close; q++)
          if (ch(text, q) == '\n') nls += 1;
        out += std::string((size_t)nls, '\n');
        i = close + 1;
        changed = true;
        continue;
      }
      out += name;
      i = j;
      continue;
    }
    out.push_back(text[(size_t)i]);
    i += 1;
  }
  return changed ? expand_launch_macros(out, depth + 1) : out;
}

// Ruby launch_arguments (line 1275): the argument expressions of the launch whose <<< is at i; false when not readable.
bool launch_arguments(const std::string &text, long i, std::vector<std::string> &out) {
  long k = i + 3;
  long depth = 0;
  long n = (long)text.size();
  while (k < n) {
    long e = skip_literal(text, k);
    if (e >= 0) {
      k = e;
      continue;
    }
    int c = ch(text, k);
    if (c == '(' || c == '[' || c == '{') {
      depth += 1;
    } else if (c == ')' || c == ']' || c == '}') {
      depth -= 1;
    } else if (depth == 0 && sl_n(text, k, 3) == ">>>") {
      break;
    }
    k += 1;
  }
  if (k >= n) return false;
  long p = k + 3;
  while (p < n && white_c(ch(text, p))) p += 1;
  if (ch(text, p) != '(') return false;
  long close = matching_paren(text, p);
  if (close < 0) return false;
  out = split_top(sl(text, p + 1, close));
  return true;
}

// Ruby targs_span (line 1304): [start, end) of the template arguments of the launch whose <<< is at i.
std::pair<long, long> targs_span(const std::string &text, long i) {
  long gt = i - 1;
  while (gt >= 0 && white_c(ch(text, gt))) gt -= 1;
  long j = gt;
  long depth = 0;
  while (j >= 0) {
    if (ch(text, j) == '>') depth += 1;
    if (ch(text, j) == '<') depth -= 1;
    if (depth == 0) break;
    j -= 1;
  }
  return {j + 1, gt};
}

// Ruby type_tokens (line 1319): the identifiers, `*` and `&` of a parameter's text, in order.
std::vector<std::string> type_tokens(const std::string &s) {
  std::vector<std::string> out;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(s, i);
    if (c == '*' || c == '&') {
      out.push_back(std::string(1, (char)c));
      i += 1;
    } else if (ident_c(c) && !(c >= '0' && c <= '9')) {
      long j = i;
      while (j < n && ident_c(ch(s, j))) j += 1;
      out.push_back(sl(s, i, j));
      i = j;
    } else {
      i += 1;
    }
  }
  return out;
}

// Ruby type_before (line 1346): the declared type written before the identifier at i; empty when it is not a declaration.
std::vector<std::string> type_before(const std::string &text, long i) {
  std::vector<std::string> toks;
  long j = i - 1;
  while (true) {
    while (j >= 0 && white_c(ch(text, j))) j -= 1;
    if (j < 0) break;
    int c = ch(text, j);
    if (c == '*' || c == '&') {
      toks.insert(toks.begin(), std::string(1, (char)c));
      j -= 1;
    } else if (ident_c(c)) {
      long k = j;
      while (k >= 0 && ident_c(ch(text, k))) k -= 1;
      toks.insert(toks.begin(), sl(text, k + 1, j + 1));
      j = k;
    } else {
      break;
    }
  }
  static const std::vector<std::string> stop = {"return", "else", "case", "new", "delete", "throw", "do"};
  if (toks.empty() || std::find(stop.begin(), stop.end(), toks.front()) != stop.end()) return {};
  bool has_ident = false;
  for (const auto &t : toks)
    if (!t.empty() && ident_c((unsigned char)t[0]) && !(t[0] >= '0' && t[0] <= '9')) has_ident = true;
  if (!has_ident) return {};
  return toks;
}

// Ruby comma_declaration_type (line 1373): the type of a later declarator of a comma-separated declaration.
std::vector<std::string> comma_declaration_type(const std::string &text, long i) {
  // Ruby: [rindex(";", i - 1), rindex("{", i - 1), rindex("}", i - 1), rindex("(", i - 1)].compact.max
  auto rindex_at = [&](char c) -> long {
    long from = i - 1;
    if (from >= (long)text.size()) from = (long)text.size() - 1;
    for (long q = from; q >= 0; q--)
      if (text[(size_t)q] == c) return q;
    return -1;
  };
  long start = -1;
  for (char c : std::string(";{}(")) {
    long r = rindex_at(c);
    if (r >= 0 && r > start) start = r;
  }
  std::string seg = sl(text, start + 1, i);
  std::vector<std::string> parts = split_top(seg);
  if (parts.size() < 2) return {};
  std::vector<std::string> toks = type_tokens(parts[0]);
  if (!toks.empty() && !toks.back().empty() && toks.back()[0] != '*' && toks.back()[0] != '&' && toks.size() > 1)
    toks.pop_back();
  for (const auto &t : toks)
    if (!t.empty() && ident_c((unsigned char)t[0])) return toks;
  return {};
}

// Ruby argument_type (line 1384): the type of a launch argument: a literal's, or the declared type of an identifier.
std::vector<std::string> argument_type(const std::string &text, long pos, const std::string &arg, const std::string &nm) {
  bool all_num = !arg.empty();
  for (char c : arg)
    if (!((c >= '0' && c <= '9') || c == 'u' || c == 'U' || c == 'l' || c == 'L')) all_num = false;
  if (all_num) return {"int"};
  if (arg.size() > 1 && arg[0] >= '0' && arg[0] <= '9' && (arg.back() == 'f' || arg.back() == 'F')) return {"float"};
  if (!arg.empty() && arg[0] >= '0' && arg[0] <= '9' &&
      (arg.find('.') != std::string::npos || arg.find('e') != std::string::npos || arg.find('E') != std::string::npos))
    return {"double"};
  bool ident_only = !arg.empty();
  for (char c : arg)
    if (!ident_c((unsigned char)c)) ident_only = false;
  if (!(ident_only && !(arg[0] >= '0' && arg[0] <= '9')))
    refuse("template launch of " + nm + ": cannot deduce a template argument from the argument " + arg +
           " (only identifiers and literals)");
  // Ruby: piece = top_pieces(text).find { kind == :code && st <= pos < en }
  long lo = 0;
  for (const auto &pc : top_pieces(text))
    if (pc.kind == "code" && pc.st <= pos && pos < pc.en) {
      lo = pc.st;
      break;
    }
  bool have = false;
  std::vector<std::string> found;
  long i = lo;
  while (i < pos) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (sl_n(text, i, (long)arg.size()) == arg && !(i > 0 && ident_c(ch(text, i - 1))) && i + (long)arg.size() < pos &&
        !ident_c(ch(text, i + (long)arg.size()))) {
      long after = i + (long)arg.size();
      while (after < pos && white_c(ch(text, after))) after += 1;
      int ac = ch(text, after);
      if (ac >= 0 && std::string("=;,)").find((char)ac) != std::string::npos) {
        std::vector<std::string> t = type_before(text, i);
        if (t.empty()) t = comma_declaration_type(text, i);
        if (!t.empty()) {
          found = t;
          have = true;
        }
      }
    }
    i += 1;
  }
  if (!have) refuse("template launch of " + nm + ": no declaration of " + arg + " before the launch, so its type is not known");
  return found;
}

// Ruby match_type (line 1425): the type a kernel parameter of type ptoks gives to the template parameter p.
bool match_type(const std::vector<std::string> &ptoks, const std::vector<std::string> &atoks, const std::string &p,
                std::string &out) {
  std::vector<std::string> pt = remove_qual(ptoks);
  std::vector<std::string> at = remove_qual(atoks);
  if (pt.size() == 1 && pt[0] == p) {
    out = join(at, " ");
    return true;
  }
  if (pt.size() != at.size()) return false;
  long k = -1;
  for (size_t x = 0; x < pt.size(); x++)
    if (pt[x] == p) {
      k = (long)x;
      break;
    }
  if (k < 0) return false;
  out = at[(size_t)k];
  return true;
}

// Ruby deduce_types (line 1436): the explicit arguments for the missing template parameters, from the launch arguments.
struct KernelTemplateRef {
  std::string params;
  std::vector<std::string> names;
  bool has_pack = false;
  long pack = 0;
};
std::vector<std::string> deduce_types(const std::string &nm, const std::string &ta, const KernelTemplateRef &kt,
                                      const std::vector<std::string> &missing, const std::vector<std::string> &args,
                                      const std::string &text, long pos) {
  std::vector<std::string> parts = split_top(kt.params);
  if (args.size() != parts.size())
    refuse("launch of " + nm + ": " + std::to_string(args.size()) + " arguments for " + std::to_string(parts.size()) +
           " kernel parameters");
  std::map<std::string, std::string> found;
  for (size_t idx = 0; idx < parts.size(); idx++) {
    std::vector<std::string> ptoks = type_tokens(parts[idx]);
    if (!ptoks.empty() && ptoks.back()[0] != '*' && ptoks.back()[0] != '&' && ptoks.size() > 1) ptoks.pop_back();
    for (const auto &p : missing) {
      if (std::find(ptoks.begin(), ptoks.end(), p) == ptoks.end()) continue;
      std::vector<std::string> at = argument_type(text, pos, args[idx], nm);
      std::string t;
      if (!match_type(ptoks, at, p, t))
        refuse("template launch of " + nm + "<" + ta + ">: cannot deduce " + p + " from the argument " + args[idx] +
               " of type " + join(at, " "));
      if (found.count(p) && found[p] != t)
        refuse("template launch of " + nm + "<" + ta + ">: " + p + " is deduced as " + found[p] + " and as " + t +
               " (ambiguous)");
      found[p] = t;
    }
  }
  std::vector<std::string> out;
  for (const auto &p : missing) {
    if (!found.count(p)) refuse("template launch of " + nm + "<" + ta + ">: no argument gives " + p + ", so it cannot be deduced");
    out.push_back(found[p]);
  }
  return out;
}

// Ruby plain_launches (line 1458): [name, end of name, position of <<<] for the launches with no template arguments.
struct PlainLaunch {
  std::string name;
  long at, pos;
};
std::vector<PlainLaunch> plain_launches(const std::string &text) {
  std::vector<PlainLaunch> out;
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (sl_n(text, i, 3) == "<<<") {
      long b = i - 1;
      while (b >= 0 && white_c(ch(text, b))) b -= 1;
      long e2 = b;
      while (b >= 0 && ident_c(ch(text, b))) b -= 1;
      std::string name = sl(text, b + 1, e2 + 1);
      bool digit_first = !name.empty() && name[0] >= '0' && name[0] <= '9';
      if (!(name.empty() || digit_first || ch(text, b) == '>')) out.push_back(PlainLaunch{name, e2 + 1, i});
    }
    i += 1;
  }
  return out;
}

// Ruby deduce_launch_targs (line 1481): the deduced template arguments are written into the launches.
std::string deduce_launch_targs(const std::string &text_in) {
  std::string text = text_in;
  struct Edit {
    long a, b;
    std::string nw;
  };
  std::vector<Edit> edits;
  for (const auto &pl : plain_launches(text)) {
    KernelTemplate kt;
    if (!kernel_template(pl.name, kt)) continue;
    std::vector<std::string> args;
    if (!launch_arguments(text, pl.pos, args))
      refuse("template launch of " + pl.name + ": its arguments are not readable (at line " +
             std::to_string(line_of(text, pl.pos)) + ")");
    KernelTemplateRef ref{kt.params, kt.names, kt.has_pack, kt.pack};
    std::vector<std::string> deduced = deduce_types(pl.name, "", ref, kt.names, args, text, pl.pos);
    edits.push_back(Edit{pl.at, pl.at, "<" + join(deduced, ", ") + ">"});
  }
  for (const auto &tl : template_launches(text)) {
    KernelTemplate kt;
    if (!kernel_template(tl.name, kt)) continue;
    std::vector<std::string> given = split_top(tl.targs);
    if (given.size() >= kt.names.size()) continue;
    std::vector<std::string> args;
    if (!launch_arguments(text, tl.pos, args))
      refuse("template launch of " + tl.name + "<" + tl.targs + ">: its arguments are not readable (at line " +
             std::to_string(line_of(text, tl.pos)) + ")");
    std::vector<std::string> missing(kt.names.begin() + (long)given.size(), kt.names.end());
    KernelTemplateRef ref{kt.params, kt.names, kt.has_pack, kt.pack};
    std::vector<std::string> deduced = deduce_types(tl.name, tl.targs, ref, missing, args, text, tl.pos);
    auto span = targs_span(text, tl.pos);
    std::vector<std::string> all = given;
    all.insert(all.end(), deduced.begin(), deduced.end());
    edits.push_back(Edit{span.first, span.second, join(all, ", ")});
  }
  // Ruby: edits.sort_by { -a }, applied in that order (each edit is applied to the text as it is then).
  std::stable_sort(edits.begin(), edits.end(), [](const Edit &x, const Edit &y) { return x.a > y.a; });
  for (const auto &ed : edits) text = sl(text, 0, ed.a) + ed.nw + sl(text, ed.b, (long)text.size());
  return text;
}

// Ruby launch_prepare (line 1509): the launch forms before the scan.
std::string launch_prepare(const std::string &text) {
  std::string t = expand_launch_macros(text, 0);
  g_expanded = t;
  return deduce_launch_targs(t);
}

// Ruby template_head_of (line 872): the parameter names and parts of a template function's definition.
bool template_head_of(const std::string &text, const std::string &name, TemplateHead &out) {
  for (const auto &tb : template_bodies(text)) {
    TmplHeader t = tb.tmpl;
    std::string header = sl(text, t.close + 1, tb.open);
    if (function_name(header) != name) continue;
    long lp = str_index(header, "(", 0);
    if (lp < 0) continue;
    long rp = matching_paren(header, lp);
    std::vector<std::string> parts = split_top(sl(header, lp + 1, rp));
    std::vector<std::string> names;
    for (const auto &pr : split_top(sl(text, t.lt + 1, t.close))) {
      std::vector<std::string> pt = tokens_of(strip(ruby_split_eq0(pr)));
      names.push_back(pt.empty() ? std::string() : pt.back());
    }
    out.names = names;
    out.parts = parts;
    out.pos = tb.open;
    return true;
  }
  return false;
}

// Ruby deduce_call_targs (line 889): the explicit template arguments of a call, deduced from the argument types.
bool deduce_call_targs(const std::string &text, const std::string &name, long pos,
                       const std::vector<std::string> &args, std::vector<std::string> &out) {
  TemplateHead head;
  if (!template_head_of(text, name, head)) return false;
  std::map<std::string, std::string> found;
  for (size_t idx = 0; idx < head.parts.size(); idx++) {
    if (idx >= args.size()) break;
    std::vector<std::string> ptoks = type_tokens(head.parts[idx]);
    if (!ptoks.empty() && ptoks.back()[0] != '*' && ptoks.back()[0] != '&' && ptoks.size() > 1) ptoks.pop_back();
    for (const auto &p : head.names) {
      if (std::find(ptoks.begin(), ptoks.end(), p) == ptoks.end()) continue;
      std::vector<std::string> at = caller_arg_type(text, pos, args[idx], name);
      std::string t;
      if (!match_type(ptoks, at, p, t))
        refuse("call of " + name + ": " + p + " cannot be deduced from the argument " + args[idx] + " of type " +
               join(at, " ") + " (at line " + std::to_string(line_of(text, pos)) + ")");
      if (found.count(p) && found[p] != t)
        refuse("call of " + name + ": " + p + " is deduced as " + found[p] + " and as " + t + " (ambiguous, at line " +
               std::to_string(line_of(text, pos)) + ")");
      found[p] = t;
    }
  }
  out.clear();
  for (const auto &p : head.names) {
    if (!found.count(p))
      refuse("call of " + name + " (at line " + std::to_string(line_of(text, pos)) + "): no argument gives " + p +
             ", so it cannot be deduced");
    out.push_back(found[p]);
  }
  return true;
}

// Ruby template_instances (line 911): the concrete argument lists that instantiate template function name.
// Memoized per text (identity), like the Ruby script.
IdentKey g_instances_key;
std::map<std::string, std::vector<std::vector<std::string>>> g_instances;

std::vector<std::vector<std::string>> template_instances(const std::string &name, const std::string &text,
                                                       const std::vector<std::string> &stack) {
  std::vector<std::string> chain = stack;
  if (std::find(stack.begin(), stack.end(), name) != stack.end()) {
    std::vector<std::string> path = stack;
    path.push_back(name);
    refuse("dependent launch: " + join(path, " -> ") + " instantiates itself through its template arguments");
  }
  if (!g_instances_key.is(text)) {
    g_instances_key.set(text);
    g_instances.clear();
  }
  auto memo = g_instances.find(name);
  if (memo != g_instances.end()) return memo->second;
  std::vector<std::pair<std::vector<std::string>, long>> sites;
  for (const auto &cs : call_sites(text, name)) sites.push_back({split_top(cs.first), cs.second});
  // Calls without explicit template arguments: their arguments' types give the instance (softmax's soft_max_f32_cuda).
  for (const auto &pc : plain_call_sites(text, name)) {
    std::vector<std::string> deduced;
    if (deduce_call_targs(text, name, pc.second, pc.first, deduced)) sites.push_back({deduced, pc.second});
  }
  std::vector<std::vector<std::string>> out;
  std::vector<std::string> next_stack = stack;
  next_stack.push_back(name);
  for (auto &site : sites) {
    std::vector<std::string> args = site.first;
    long pos = site.second;
    OuterTemplate outer;
    bool has_outer = enclosing_template(text, pos, outer);
    // A bare local constant of the enclosing body (fallback in mmq's mul_mat_q_case) is its literal value.
    if (has_outer) {
      for (auto &a : args) {
        std::string v = strip(a);
        bool plain = !v.empty();
        for (char c : v)
          if (!ident_c((unsigned char)c)) plain = false;
        if (plain && std::find(outer.names.begin(), outer.names.end(), v) == outer.names.end()) {
          std::string val;
          if (local_constant(text, outer.open, pos, v, val)) a = val;
        }
      }
    }
    bool mentions = false;
    if (has_outer) {
      for (const auto &a : args)
        for (const auto &tk : tokens_of(a))
          if (std::find(outer.names.begin(), outer.names.end(), tk) != outer.names.end()) mentions = true;
    }
    if (has_outer && mentions) {
      for (const auto &inst : template_instances(outer.fname, text, next_stack)) {
        // A pack expands to several arguments: the list is split again after the substitution.
        std::vector<std::string> subbed;
        for (const auto &a : args) subbed.push_back(substitute(a, outer.names, inst, outer.has_pack, outer.pack));
        out.push_back(split_top(join(subbed, ", ")));
      }
    } else {
      out.push_back(args);
    }
  }
  // Ruby: out.uniq (first occurrences kept, in order).
  std::vector<std::vector<std::string>> uniq;
  for (const auto &x : out)
    if (std::find(uniq.begin(), uniq.end(), x) == uniq.end()) uniq.push_back(x);
  g_instances[name] = uniq;
  return uniq;
}

// Ruby line_col (line 955): [line (1-based), column] of pos. The newline positions are indexed once per text.
IdentKey g_newlines_key;
std::vector<long> g_newlines;
std::pair<long, long> line_col(const std::string &s, long pos) {
  if (!g_newlines_key.is(s)) {
    g_newlines.clear();
    for (long k = 0; k < (long)s.size(); k++)
      if (s[(size_t)k] == '\n') g_newlines.push_back(k);
    g_newlines_key.set(s);
  }
  long lo = 0, hi = (long)g_newlines.size();
  while (lo < hi) {
    long mid = (lo + hi) / 2;
    if (g_newlines[(size_t)mid] < pos) lo = mid + 1;
    else hi = mid;
  }
  long start = lo == 0 ? 0 : g_newlines[(size_t)(lo - 1)] + 1;
  return {lo + 1, pos - start};
}

// Ruby line_start (line 980): the position of the first character of a 1-based line.
long line_start(const std::string &s, long line) {
  long i = 0;
  for (long k = 0; k < line - 1; k++) {
    long nl = str_index(s, "\n", i);
    i = nl + 1;
  }
  return i;
}

// Ruby dependent_launches (line 991): the launches whose template arguments depend on an enclosing template parameter.
struct DependentLaunch {
  std::string name, targs, dname;
  OuterTemplate outer;
  std::vector<std::vector<std::string>> insts;
  // Ruby: d[:wrapper] (instance key => wrapper name), filled by dependent_decls
  std::vector<std::pair<std::vector<std::string>, std::string>> wrapper;
};
std::map<std::pair<long, long>, DependentLaunch> dependent_launches(const std::string &text) {
  std::map<std::pair<long, long>, DependentLaunch> out;
  long idx = 0;
  for (const auto &tl : template_launches(text)) {
    long at = idx++;
    if (tl.targs.empty()) continue;
    std::string dep;
    if (!dependent_on_template(text, tl.pos, tl.targs, dep)) continue;
    OuterTemplate outer;
    if (!enclosing_template(text, tl.pos, outer))
      refuse("template launch of " + tl.name + "<" + tl.targs + "> depends on the template parameter " + dep +
             ", which is not a parameter of a top-level template function (at line " +
             std::to_string(line_of(text, tl.pos)) + ")");
    std::vector<std::vector<std::string>> insts;
    if (outer.has_qual) insts = member_instances(outer, text);
    else insts = template_instances(outer.fname, text, {});
    if (insts.empty())
      refuse("template launch of " + tl.name + "<" + tl.targs + "> depends on the template parameter " + dep + " of " +
             outer.fname + ": the unit has no explicit call of it with all its template arguments, so its instances are "
             "not known");
    for (const auto &inst : insts) {
      bool ok = outer.has_pack ? (long)inst.size() >= (long)outer.names.size() - 1 : inst.size() == outer.names.size();
      if (!ok)
        refuse("template launch of " + tl.name + "<" + tl.targs + ">: a call of " + outer.fname +
               " does not give all its template arguments explicitly");
    }
    outer.line = line_col(text, outer.st).first;
    DependentLaunch d;
    d.name = tl.name;
    d.targs = tl.targs;
    d.outer = outer;
    d.insts = insts;
    d.dname = "__nfcxx_disp_" + sanitize(tl.name) + "_" + std::to_string(at);
    out[line_col(text, tl.pos)] = d;
  }
  return out;
}

// Ruby dependent_decls (line 1017): the dispatch declarations of the dependent launches, at their enclosing templates.
std::vector<std::pair<long, std::string>> dependent_decls(std::map<std::pair<long, long>, DependentLaunch> &dl,
                                                          const std::string &orig) {
  std::vector<std::pair<long, std::string>> lines;
  for (auto &kv : dl) {
    DependentLaunch &d = kv.second;
    for (const auto &inst : d.insts) {
      std::vector<std::string> concrete;
      for (const auto &a : split_top(d.targs))
        concrete.push_back(substitute(a, d.outer.names, inst, d.outer.has_pack, d.outer.pack));
      d.wrapper.push_back({inst, template_site(d.name, join(concrete, ", "))});
    }
  }
  for (auto &kv : dl) {
    DependentLaunch &d = kv.second;
    long at = line_start(orig, d.outer.line);
    // Ruby: d[:wrapper].values.uniq (first occurrences kept)
    std::vector<std::string> uniq_w;
    for (const auto &pr : d.wrapper)
      if (std::find(uniq_w.begin(), uniq_w.end(), pr.second) == uniq_w.end()) uniq_w.push_back(pr.second);
    for (const auto &w : uniq_w) {
      std::string decl;
      for (const auto &site : g_sites)
        if (site.wrapper == w) decl = site.decl;
      lines.push_back({at, "static void " + w + "(" + decl + ");\n"});
    }
    lines.push_back({at, "template <" + join(d.outer.decls, ", ") + "> struct " + d.dname + ";\n"});
    for (const auto &inst : d.insts) {
      std::string w;
      for (const auto &pr : d.wrapper)
        if (pr.first == inst) w = pr.second;
      lines.push_back({at, "template <> struct " + d.dname + "<" + join(inst, ", ") + "> { static constexpr auto fn = &" + w +
                               "; };\n"});
    }
  }
  return lines;
}

}  // namespace

int main(int argc, char **argv) {
  // The CLI is ported with the passes. Until then the Ruby script is the rewriter (the driver calls it).
  (void)argc;
  (void)argv;
  std::fprintf(stderr, "cuda-rewrite: not ported yet (see tools/cuda-rewrite/PORTING.md); use scripts/cuda-rewrite.rb\n");
  return 2;
}
