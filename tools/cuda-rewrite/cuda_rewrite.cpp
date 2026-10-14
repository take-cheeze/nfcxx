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
#include <filesystem>
#include <system_error>
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
    } else if (c == ')' || c == ']' || c == '}' || (c == '>' && !(i > 0 && ch(s, i - 1) == '-'))) {
      depth -= 1;  // the > of -> (a member access) closes nothing
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
    long lt = index_code(q, '<', 0);
    long depth = 0;
    long k = lt;
    while (k < (long)q.size()) {
      if (ch(q, k) == '<') depth += 1;
      if (ch(q, k) == '>') depth -= 1;
      if (depth == 0) break;
      k += 1;
    }
    // The name follows the template header: a function-pointer parameter's `(` inside the header is not the name's.
    if (function_name(sl(q, k + 1, (long)q.size())) != name) continue;
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

bool enclosing_block(const std::string &s, long pos, long &open_out, long &close_out);

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
    long blk_close = -1, blk_open_unused = -1;
    bool has_blk = enclosing_block(text, k, blk_open_unused, blk_close);
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
  long unused_open = -1;
  if (!enclosing_block(text, pos, unused_open, unused_close)) return targs;
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
  // A declaration has a type word and a name: a single word is a call's first argument (pool2d's `ih`), not a type.
  if (toks.size() < 2) return {};
  if (!toks.back().empty() && toks.back()[0] != '*' && toks.back()[0] != '&')
    toks.pop_back();
  for (const auto &t : toks)
    if (!t.empty() && ident_c((unsigned char)t[0])) return toks;
  return {};
}

// A leading all-caps word before a type is a macro that expands to declarations (GGML_TENSOR_BINARY_OP_LOCALS before
// `const float * src0_d`): drop it, so the declared type is the type that follows.
// Only a word the text defines with #define counts, so a template parameter named like a macro (D, T) is kept.
bool defined_macro(const std::string &text, const std::string &name) {
  const std::string key = "#define " + name;
  for (size_t p = text.find(key); p != std::string::npos; p = text.find(key, p + 1)) {
    size_t e = p + key.size();
    if (e >= text.size() || !ident_c((unsigned char)text[e])) return true;
  }
  return false;
}
std::vector<std::string> strip_macro_prefix(const std::string &text, std::vector<std::string> toks) {
  while (toks.size() > 1 && defined_macro(text, toks[0])) toks.erase(toks.begin());
  return toks;
}

// The position of the first top-level binary + or - in an expression (outside brackets and literals), or -1.
long additive_op(const std::string &a) {
  int depth = 0;
  for (long i = 0; i < (long)a.size(); i++) {
    long e = skip_literal(a, i);
    if (e >= 0) {
      i = e - 1;
      continue;
    }
    char c = a[(size_t)i];
    if (c == '(' || c == '[' || c == '{') depth += 1;
    else if (c == ')' || c == ']' || c == '}') depth -= 1;
    else if (depth == 0 && i > 0 && (c == '+' || c == '-')) return i;
  }
  return -1;
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
  // A cast `(T) x` has the type T: diag's and fill's `(float *) dst_d`.
  std::string a = strip(arg);
  if (!a.empty() && a[0] == '(') {
    long close = matching_paren(a, 0);
    if (close >= 0 && close + 1 < (long)a.size()) {
      std::string rest = strip(sl(a, close + 1, (long)a.size()));
      if (!rest.empty() && ident_c(ch(rest, 0))) return strip_macro_prefix(text, type_tokens(sl(a, 1, close)));
    }
  }
  // ggml_cuda_cast<T>(x) returns T (its first template argument): fill's `ggml_cuda_cast<half>(value)`.
  if (a.compare(0, 15, "ggml_cuda_cast<") == 0) {
    long close = matching_angle(a, 14);
    if (close > 0) {
      std::vector<std::string> targ = split_top(sl(a, 15, close));
      if (!targ.empty()) return strip_macro_prefix(text, type_tokens(targ[0]));
    }
  }
  // A pointer expression `p + n` has the type of its pointer operand p: concat's `src0_d + i3*(...)`.
  long op = additive_op(a);
  if (op > 0) {
    std::vector<std::string> lt = argument_type(text, pos, strip(sl(a, 0, op)), nm);
    if (std::find(lt.begin(), lt.end(), "*") != lt.end()) return lt;
  }
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
  return strip_macro_prefix(text, found);
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
  // A call with another number of arguments is an overload (set_rows_cuda's plain one), not this template's call.
  if (args.size() != head.parts.size()) return false;
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

// deduce_call_targs for only the names in missing (the template arguments a call leaves out): name -> its type.
std::map<std::string, std::string> deduce_missing_targs(const std::string &text, const std::string &name, long pos,
                                                        const std::vector<std::string> &args,
                                                        const std::vector<std::string> &missing) {
  TemplateHead head;
  if (!template_head_of(text, name, head)) refuse("call of " + name + ": its template is not in the unit");
  std::map<std::string, std::string> found;
  for (size_t idx = 0; idx < head.parts.size() && idx < args.size(); idx++) {
    std::vector<std::string> ptoks = type_tokens(head.parts[idx]);
    if (!ptoks.empty() && ptoks.back()[0] != '*' && ptoks.back()[0] != '&' && ptoks.size() > 1) ptoks.pop_back();
    for (const auto &p : missing) {
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
  for (const auto &p : missing)
    if (!found.count(p))
      refuse("call of " + name + " (at line " + std::to_string(line_of(text, pos)) + "): no argument gives " + p +
             ", so it cannot be deduced");
  return found;
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
  // A call that names only some template arguments (get_rows_cuda_q<QK, QR, dq>(...) with dst_t left out): the rest are
  // deduced from the call's own arguments, and the explicit ones are kept.
  TemplateHead head;
  bool have_head = template_head_of(text, name, head);
  for (const auto &cs : call_sites(text, name)) {
    std::vector<std::string> targs = split_top(cs.first);
    if (have_head && targs.size() < head.names.size()) {
      long k = cs.second + (long)name.size();
      while (k < (long)text.size() && white_c(ch(text, k))) k += 1;
      long close = matching_angle(text, k);
      long open = close < 0 ? -1 : close + 1;
      while (open >= 0 && open < (long)text.size() && white_c(ch(text, open))) open += 1;
      if (open >= 0 && ch(text, open) == '(') {
        std::vector<std::string> cargs = split_top(sl(text, open + 1, matching_paren(text, open)));
        if (cargs.size() != head.parts.size()) {
          sites.push_back({targs, cs.second});  // another overload of the name
          continue;
        }
        std::vector<std::string> missing(head.names.begin() + (long)targs.size(), head.names.end());
        std::map<std::string, std::string> got = deduce_missing_targs(text, name, cs.second, cargs, missing);
        for (const auto &p : missing) targs.push_back(got[p]);
      }
    }
    sites.push_back({targs, cs.second});
  }
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

// A macro in the conditionals' table: a text, or a function-like macro (Ruby :function).
struct Def {
  bool is_function = false;
  std::string text;
};
typedef std::map<std::string, Def> Defs;

// Ruby globals of the rewrite: $cond_strict, $edg_launches (the --edg-launches flag).
bool g_cond_strict = false;
bool g_edg_launches = false;
std::string resolve_conditionals(const std::string &text, Defs &defs);

// Ruby rewrite (line 1037): the launch rewrite of a host unit. The output keeps the line count of the input.
std::string rewrite(const std::string &text, const std::string &orig) {
  std::string out = "#line 1 \"" + orig + "\"\n";
  long n = (long)text.size();
  long i = 0;
  // The wrapper declarations of the template launches, at file scope just before the top-level piece that holds
  // each launch: EDG rejects a linkage specification in block scope. Keyed by the piece's start index.
  std::vector<Piece> pieces = top_pieces(text);
  std::map<long, std::vector<std::string>> decls_at;
  auto add_decl = [&](long at, const std::string &line) {
    auto &v = decls_at[at];
    if (std::find(v.begin(), v.end(), line) == v.end()) v.push_back(line);
  };
  g_cond_strict = true;
  Defs no_defs;
  std::string resolved = resolve_conditionals(text, no_defs);
  g_cond_strict = false;
  g_has_kernel_text = true;
  g_kernel_text = resolved;
  auto dl = dependent_launches(resolved);
  for (const auto &tl : template_launches(text)) {
    std::string dep;
    if (dependent_on_template(text, tl.pos, tl.targs, dep)) continue;
    std::string w = template_site(tl.name, tl.targs);
    long key = 0;
    for (const auto &pc : pieces)
      if (pc.st <= tl.pos && tl.pos < pc.en) {
        key = pc.st;
        break;
      }
    std::string decl;
    for (const auto &site : g_sites)
      if (site.wrapper == w) decl = site.decl;
    add_decl(key, "static void " + w + "(" + decl + ");\n");
  }
  for (const auto &at_line : dependent_decls(dl, text)) add_decl(at_line.first, at_line.second);
  std::map<long, long> dirs = directive_ends(text);
  while (i < n) {
    auto dit = decls_at.find(i);
    if (dit != decls_at.end()) {
      for (const auto &line : dit->second) out += line;
      decls_at.erase(dit);
    }
    auto dr = dirs.find(i);
    if (dr != dirs.end()) {
      // a directive ends before its newline: the newline (and the declarations of the piece after it) follow it
      long k = dr->second;
      out += sl(text, i, k);
      i = k;
      if (k < n && ch(text, k) == '\n') {
        out += "\n";
        i = k + 1;
        auto kit = decls_at.find(k);
        if (kit != decls_at.end()) {
          for (const auto &line : kit->second) out += line;
          decls_at.erase(kit);
        }
      }
      continue;
    }
    long e = skip_literal(text, i);
    if (e >= 0) {
      out += sl(text, i, e);
      i = e;
      continue;
    }
    if (sl_n(text, i, 3) == "<<<" && !(i + 3 < n && ch(text, i + 3) == '<')) {
      long line = line_col(text, i).first;
      // The kernel name is the identifier before `<<<`, or before its template argument list.
      long j = i - 1;
      while (j >= 0 && white_c(ch(text, j))) j -= 1;
      bool has_targs = false;
      std::string targs;
      long gt_at = j;
      if (ch(text, j) == '>') {
        long depth = 0;
        while (j >= 0) {
          if (ch(text, j) == '>') depth += 1;
          if (ch(text, j) == '<') depth -= 1;
          if (depth == 0) break;
          j -= 1;
        }
        targs = strip(sl(text, j + 1, gt_at));
        has_targs = true;
        j -= 1;
        while (j >= 0 && white_c(ch(text, j))) j -= 1;
      }
      long name_end = j + 1;
      long name_start = name_end;
      while (name_start > 0 && ident_c(ch(text, name_start - 1))) name_start -= 1;
      std::string name = sl(text, name_start, name_end);
      if (name.empty()) refuse("launch without a kernel name at line " + std::to_string(line));
      if (g_edg_launches && !has_targs) {
        // A launch without template arguments is left to the front end (--cuda parses it, see docs/notes/gpu.md).
        out.push_back(text[(size_t)i]);
        i += 1;
        continue;
      }
      // The same resolution as template_launches: the wrapper of this launch is named by the values of its constants.
      if (has_targs) targs = resolve_local_constants(text, targs, i);
      // The call copied so far ends with the name and its arguments: take them back out.
      long cut = (long)out.size() - (i - name_start);
      out = sl(out, 0, cut < 0 ? 0 : cut);

      // The configuration runs to the first `>>>` outside brackets.
      long k = i + 3;
      long depth = 0;
      long close_cfg = -1;
      while (k < n) {
        long e2 = skip_literal(text, k);
        if (e2 >= 0) {
          k = e2;
          continue;
        }
        int c = ch(text, k);
        if (c == '(' || c == '[' || c == '{') {
          depth += 1;
        } else if (c == ')' || c == ']' || c == '}') {
          depth -= 1;
        } else if (depth == 0 && sl_n(text, k, 3) == ">>>") {
          close_cfg = k;
          break;
        }
        k += 1;
      }
      if (close_cfg < 0) refuse("unterminated launch configuration for " + name);
      std::vector<std::string> cfg = split_config(text, i + 3, close_cfg);
      if (cfg.size() < 2 || cfg.size() > 4) refuse("launch of " + name + " needs 2 to 4 configuration items");
      while (cfg.size() < 4) cfg.push_back("0");
      if (cfg[2].empty()) cfg[2] = "0";
      if (cfg[3].empty()) cfg[3] = "0";

      long p = close_cfg + 3;
      while (p < n && white_c(ch(text, p))) p += 1;
      if (ch(text, p) != '(') refuse("launch of " + name + " without an argument list");
      long close_args = matching_paren(text, p);
      if (close_args < 0) refuse("unterminated argument list for " + name);
      std::string args = strip(sl(text, p + 1, close_args));

      long nls = 0;
      for (long q = i; q <= close_args && q < n; q++)
        if (ch(text, q) == '\n') nls += 1;
      std::string kernel = name;
      if (has_targs) {
        auto dit2 = dl.find(line_col(text, i));
        if (dit2 != dl.end()) {
          // The pack keeps its ... (disp<Ns...> expands it inside the template body).
          const DependentLaunch &d = dit2->second;
          std::vector<std::string> tn;
          for (size_t q = 0; q < d.outer.names.size(); q++)
            tn.push_back(d.outer.has_pack && (long)q == d.outer.pack ? d.outer.names[q] + "..." : d.outer.names[q]);
          kernel = d.dname + "<" + join(tn, ", ") + ">::fn";
        } else {
          std::string dep;
          if (dependent_on_template(text, i, targs, dep))
            refuse("template launch of " + name + "<" + targs + "> depends on a template parameter, and its enclosing "
                   "template is not resolved in this unit (at line " + std::to_string(line) + ")");
          kernel = template_site(name, targs);
        }
      }
      out += "__nfcxx_cuda_launch(" + kernel + ", " + cfg[0] + ", " + cfg[1] + ", " + cfg[2] + ", " + cfg[3];
      if (!args.empty()) out += ", " + args;
      out += ")";
      out += std::string((size_t)nls, '\n');
      i = close_args + 1;
      continue;
    }
    out.push_back(text[(size_t)i]);
    i += 1;
  }
  // The wrappers are defined here, after the calls; each call has the declaration in its block.
  if (!g_sites.empty()) {
    out += "\n";
    for (const auto &site : g_sites) out += "static void " + site.wrapper + "(" + site.decl + ") {}\n";
  }
  return out;
}

// Ruby tokens_of (line 1911): the identifiers of a text, outside literals and comments.
std::vector<std::string> tokens_of(const std::string &s) {
  std::vector<std::string> out;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    // comments are not code: a word in one (a `__device__` mentioned above a host function) is no token
    if (ch(s, i) == '/' && ch(s, i + 1) == '/') {
      long q = str_index(s, "\n", i);
      i = q < 0 ? n : q;
      continue;
    }
    if (ch(s, i) == '/' && ch(s, i + 1) == '*') {
      long q = str_index(s, "*/", i + 2);
      i = q < 0 ? n : q + 2;
      continue;
    }
    int c = ch(s, i);
    if (c == '_' || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)) {
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

// Ruby code_text (line 1948): the text with each comment replaced by blanks (its newlines kept).
std::string code_text(const std::string &s) {
  std::string out;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      if (ch(s, i) == '/') {
        for (long q = i; q < e; q++) out.push_back(s[(size_t)q] == '\n' ? '\n' : ' ');
      } else {
        out += sl(s, i, e);
      }
      i = e;
      continue;
    }
    out.push_back(s[(size_t)i]);
    i += 1;
  }
  return out;
}

// Ruby code_only? (line 1968): true if s has code outside comments and whitespace.
bool code_only(const std::string &s) {
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      if (ch(s, i) == '/') {
        i = e;
        continue;
      }
      return true;
    }
    int c = ch(s, i);
    if (!(c == ' ' || c == '\t' || c == '\n' || c == '\r')) return true;
    i += 1;
  }
  return false;
}

// Ruby brace_is_initializer? (line 1991): a depth-0 `{` after `=` in its piece is an initializer list, not a body.
bool brace_is_initializer(const std::string &chunk) {
  if (str_index(chunk, "(", 0) >= 0) return false;
  std::vector<std::string> toks = tokens_of(chunk);
  if (toks.empty()) return false;
  static const std::vector<std::string> kw = {"struct", "class", "union", "enum", "namespace", "template", "operator"};
  for (const auto &t : toks)
    if (std::find(kw.begin(), kw.end(), t) != kw.end()) return false;
  if (toks.front() == "extern" || toks.front() == "typedef" || toks.front() == "using") return false;
  return str_index(chunk, "=", 0) >= 0;
}

// Ruby top_pieces (line 1999): the top-level pieces of a unit. Kind "pp" (a directive) or "code"; body is true when the
// piece has a brace block at depth 0.
std::vector<Piece> top_pieces(const std::string &text) {
  std::vector<Piece> pieces;
  long n = (long)text.size();
  long i = 0;
  long start = 0;
  long depth = 0;
  bool paren0 = false;
  bool body = false;
  std::string opener;  // text of the depth-0 `{`'s chunk start, to tell namespaces and extern "C" blocks
  bool has_opener = false;
  while (i < n) {
    if (depth == 0 && ch(text, i) == '#' && !code_only(sl(text, start, i))) {
      // a directive ends at a newline that is not in a comment or literal, or after a backslash
      long k = i;
      while (k < n) {
        long e2 = skip_literal(text, k);
        if (e2 >= 0) {
          k = e2;
          continue;
        }
        if (ch(text, k) == '\n' && ch(text, k - 1) != '\\') break;
        k += 1;
      }
      pieces.push_back(Piece{i, k, "pp", false});
      i = k;
      start = k;
      continue;
    }
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(text, i);
    if (c == '(') {
      if (depth == 0) paren0 = true;
      depth += 1;
    } else if (c == '[') {
      depth += 1;
    } else if (c == ')' || c == ']') {
      depth -= 1;
    } else if (c == '{') {
      if (depth == 0 && !brace_is_initializer(sl(text, start, i))) {
        body = true;
        std::vector<std::string> tk = tokens_of(sl(text, start, i));
        opener = tk.empty() ? std::string() : tk.front();
        has_opener = !tk.empty();
      }
      depth += 1;
    } else if (c == '}') {
      depth -= 1;
      if (depth == 0 && has_opener && (opener == "namespace" || opener == "extern")) {
        pieces.push_back(Piece{start, i + 1, "code", true});
        start = i + 1;
        paren0 = false;
        body = false;
        has_opener = false;
      } else if (depth == 0 && has_opener && !(opener == "struct" || opener == "class" || opener == "union" ||
                                               opener == "enum" || opener == "typedef" || opener == "using") &&
                 paren0) {
        pieces.push_back(Piece{start, i + 1, "code", true});
        start = i + 1;
        paren0 = false;
        body = false;
        has_opener = false;
      }
    } else if (c == ';' && depth == 0) {
      pieces.push_back(Piece{start, i + 1, "code", body});
      start = i + 1;
      paren0 = false;
      body = false;
      has_opener = false;
    }
    i += 1;
  }
  if (!strip(sl(text, start, n)).empty()) pieces.push_back(Piece{start, n, "code", body});
  return pieces;
}

// Ruby remove_words (line 2068): removes the whole words of `words` from s, outside literals and comments.
std::string remove_words(const std::string &s, const std::vector<std::string> &words) {
  std::string out;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      out += sl(s, i, e);
      i = e;
      continue;
    }
    const std::string *hit = nullptr;
    for (const auto &w : words)
      if (word_at(s, i, w)) {
        hit = &w;
        break;
      }
    if (hit) {
      i += (long)hit->size();
      while (i < n && (ch(s, i) == ' ' || ch(s, i) == '\t')) i += 1;
      continue;
    }
    out.push_back(s[(size_t)i]);
    i += 1;
  }
  return out;
}

// Ruby function_name (line 2091): the identifier before the first `(` (outside comments and literals); "" when none.
std::string function_name(const std::string &text) {
  long paren = -1;
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (ch(text, i) == '(') {
      paren = i;
      break;
    }
    i += 1;
  }
  if (paren < 0) return std::string();  // Ruby nil: callers compare it to a name, which never equals nil
  std::string head = strip(sl(text, 0, paren));
  std::string rev;
  for (size_t k = head.size(); k-- > 0;) {
    if (!ident_c((unsigned char)head[k])) break;
    rev.push_back(head[k]);
  }
  std::reverse(rev.begin(), rev.end());
  return rev;
}

// Ruby $incdirs (line 2120): the -I directories of the driver.
std::vector<std::string> g_incdirs;

// Ruby system_path? (line 2123): the toolkit and system prefixes are never inlined.
bool system_path(const std::string &path) {
  std::string p = path;
  return p.compare(0, 5, "/usr/") == 0 || p.compare(0, 5, "/opt/") == 0 || p.compare(0, 16, "/usr/local/cuda/") == 0;
}

// Ruby find_include (line 2128): the file a quoted or angle-bracket include names, when it exists and is not a system path.
bool find_include(const std::string &dir, const std::string &name, bool quoted, std::string &path_out);

// Ruby expand_includes (line 2135): the quoted local includes of a unit are expanded in place (once per file).
std::string expand_includes(const std::string &text, const std::string &dir, int depth,
                            std::map<std::string, bool> &seen);
std::string strip_launch_bounds(const std::string &s);
std::string blank_comments(const std::string &s);
std::string dynamic_shared_rewrite(const std::string &s);
bool g_device_mode = false;  // Ruby $device

// Ruby CondUnsupported (line 2179): a conditional the evaluator does not handle.
struct CondUnsupported {
  std::string msg;
};
[[noreturn]] void cond_fail(const std::string &msg) { throw CondUnsupported{msg}; }

// Ruby DEVICE_PASS_MACROS (line 2192).
const std::vector<std::pair<std::string, std::string>> DEVICE_PASS_MACROS = {
    {"__CUDACC__", "1"}, {"__NVCC__", "1"}, {"__CUDA_ARCH__", "750"}, {"__cplusplus", "201703"}};


// Ruby $cond_strict (see g_cond_strict above): a name the unit does not define is an unsupported conditional.

// Ruby cond token: kind :num (value) or :id / :op (text).
struct CondTok {
  int kind;  // 0 = num, 1 = id, 2 = op
  long long value;
  std::string text;
};

// Ruby cond_tokens (line 2194).
std::vector<CondTok> cond_tokens(const std::string &s, long line) {
  std::vector<CondTok> toks;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    int c = ch(s, i);
    if (white_c(c)) {
      i += 1;
    } else if (ident_c(c)) {
      long j = i;
      while (j < n && ident_c(ch(s, j))) j += 1;
      std::string w = sl(s, i, j);
      if (c >= 48 && c <= 57) {
        while (!w.empty() && std::string("uUlL").find(w.back()) != std::string::npos) w.pop_back();
        long long v;
        if (w.size() > 2 && w[0] == '0' && (w[1] == 'x' || w[1] == 'X')) v = std::strtoll(w.c_str() + 2, nullptr, 16);
        else v = std::strtoll(w.c_str(), nullptr, 10);
        toks.push_back(CondTok{0, v, ""});
      } else {
        toks.push_back(CondTok{1, 0, w});
      }
      i = j;
    } else {
      std::string two = i + 1 < n ? sl(s, i, i + 2) : std::string();
      static const std::vector<std::string> twos = {"&&", "||", "==", "!=", "<=", ">=", "<<", ">>"};
      if (std::find(twos.begin(), twos.end(), two) != twos.end()) {
        toks.push_back(CondTok{2, 0, two});
        i += 2;
      } else if (c != 0 && std::string("!~+-*/%<>&|^()?:,").find((char)c) != std::string::npos) {
        toks.push_back(CondTok{2, 0, std::string(1, (char)c)});
        i += 1;
      } else {
        cond_fail("unsupported character in #if at line " + std::to_string(line));
      }
    }
  }
  return toks;
}

// The state of a #if expression reader (Ruby: st = { toks:, pos: }).
struct CondState {
  std::vector<CondTok> toks;
  size_t pos = 0;
};

bool cond_peek(const CondState &st, const std::string &x) {
  if (st.pos >= st.toks.size()) return false;
  const CondTok &t = st.toks[st.pos];
  return t.kind == 2 && t.text == x;
}
bool cond_peek_any(const CondState &st) { return st.pos < st.toks.size(); }

long long cond_eval(const std::string &s, const Defs &defs, long line, int depth);
long long cond_expr(CondState &st, const Defs &defs, long line, int depth);
long long cond_binary(CondState &st, const Defs &defs, long line, int depth, int level);
long long cond_unary(CondState &st, const Defs &defs, long line, int depth);

// Ruby cond_eval (line 2232): evaluates a #if expression.
long long cond_eval(const std::string &s, const Defs &defs, long line, int depth) {
  if (depth > 16) cond_fail("#if nesting too deep at line " + std::to_string(line));
  CondState st;
  st.toks = cond_tokens(s, line);
  long long v = cond_expr(st, defs, line, depth);
  if (st.pos != st.toks.size()) cond_fail("unsupported #if expression at line " + std::to_string(line));
  return v;
}

// Ruby cond_expr (line 2247): the conditional operator.
long long cond_expr(CondState &st, const Defs &defs, long line, int depth) {
  long long c = cond_binary(st, defs, line, depth, 0);
  if (!cond_peek(st, "?")) return c;
  st.pos += 1;
  long long a = cond_expr(st, defs, line, depth);
  if (!cond_peek(st, ":")) cond_fail("expected ':' in #if at line " + std::to_string(line));
  st.pos += 1;
  long long b = cond_expr(st, defs, line, depth);
  return c != 0 ? a : b;
}

// Ruby COND_LEVELS (line 2259): binary operators by precedence, lowest first.
const std::vector<std::vector<std::string>> COND_LEVELS = {
    {"||"}, {"&&"}, {"|"}, {"^"}, {"&"}, {"==", "!="}, {"<", ">", "<=", ">="}, {"<<", ">>"}, {"+", "-"}, {"*", "/", "%"}};

// Ruby cond_binary (line 2261).
long long cond_binary(CondState &st, const Defs &defs, long line, int depth, int level) {
  if (level >= (int)COND_LEVELS.size()) return cond_unary(st, defs, line, depth);
  long long l = cond_binary(st, defs, line, depth, level + 1);
  while (true) {
    if (st.pos >= st.toks.size()) break;
    const CondTok &t = st.toks[st.pos];
    if (!(t.kind == 2 && std::find(COND_LEVELS[(size_t)level].begin(), COND_LEVELS[(size_t)level].end(), t.text) !=
                             COND_LEVELS[(size_t)level].end()))
      break;
    std::string op = t.text;
    st.pos += 1;
    if (op == "||") {
      long long r = cond_binary(st, defs, line, depth, level + 1);
      l = (l != 0 || r != 0) ? 1 : 0;
    } else if (op == "&&") {
      long long r = cond_binary(st, defs, line, depth, level + 1);
      l = (l != 0 && r != 0) ? 1 : 0;
    } else {
      long long r = cond_binary(st, defs, line, depth, level + 1);
      if (op == "|") l = l | r;
      else if (op == "^") l = l ^ r;
      else if (op == "&") l = l & r;
      else if (op == "==") l = l == r ? 1 : 0;
      else if (op == "!=") l = l != r ? 1 : 0;
      else if (op == "<") l = l < r ? 1 : 0;
      else if (op == ">") l = l > r ? 1 : 0;
      else if (op == "<=") l = l <= r ? 1 : 0;
      else if (op == ">=") l = l >= r ? 1 : 0;
      else if (op == "<<") l = l << r;
      else if (op == ">>") l = l >> r;
      else if (op == "+") l = l + r;
      else if (op == "-") l = l - r;
      else if (op == "*") l = l * r;
      else if (op == "/") {
        if (r == 0) cond_fail("division by zero in #if at line " + std::to_string(line));
        l = l / r;
      } else if (op == "%") {
        if (r == 0) cond_fail("division by zero in #if at line " + std::to_string(line));
        l = l % r;
      }
    }
  }
  return l;
}

// Ruby cond_unary (line 2300).
long long cond_unary(CondState &st, const Defs &defs, long line, int depth) {
  if (!cond_peek_any(st)) cond_fail("unexpected end of #if expression at line " + std::to_string(line));
  const CondTok t = st.toks[st.pos];
  if (t.kind == 2 && t.text == "!") {
    st.pos += 1;
    return cond_unary(st, defs, line, depth) == 0 ? 1 : 0;
  }
  if (t.kind == 2 && t.text == "-") {
    st.pos += 1;
    return -cond_unary(st, defs, line, depth);
  }
  if (t.kind == 2 && t.text == "+") {
    st.pos += 1;
    return cond_unary(st, defs, line, depth);
  }
  if (t.kind == 2 && t.text == "~") {
    st.pos += 1;
    return ~cond_unary(st, defs, line, depth);
  }
  if (t.kind == 2 && t.text == "(") {
    st.pos += 1;
    long long v = cond_expr(st, defs, line, depth);
    if (!cond_peek(st, ")")) cond_fail("expected ')' in #if at line " + std::to_string(line));
    st.pos += 1;
    return v;
  }
  if (t.kind == 0) {
    st.pos += 1;
    return t.value;
  }
  if (t.kind == 1 && t.text == "defined") {
    st.pos += 1;
    bool paren = cond_peek(st, "(");
    if (paren) st.pos += 1;
    if (!(st.pos < st.toks.size() && st.toks[st.pos].kind == 1))
      cond_fail("defined without a name at line " + std::to_string(line));
    std::string name = st.toks[st.pos].text;
    st.pos += 1;
    if (paren) {
      if (!cond_peek(st, ")")) cond_fail("expected ')' after defined at line " + std::to_string(line));
      st.pos += 1;
    }
    return defs.count(name) ? 1 : 0;
  }
  if (t.kind == 1) {
    st.pos += 1;
    if (cond_peek(st, "(")) {
      // a call of a function-like macro or an unknown function: 0, with its arguments skipped
      st.pos += 1;
      long nest = 1;
      while (nest > 0) {
        if (!cond_peek_any(st)) cond_fail("unbalanced parentheses in #if at line " + std::to_string(line));
        const CondTok &u = st.toks[st.pos];
        if (u.kind == 2 && u.text == "(") nest += 1;
        if (u.kind == 2 && u.text == ")") nest -= 1;
        st.pos += 1;
      }
      return 0;
    }
    auto it = defs.find(t.text);
    // The host analysis keeps both branches of a condition on a name the unit does not define (it may come from a
    // system header): the device pass refuses it (see g_cond_strict).
    if (it == defs.end() && g_cond_strict) cond_fail("#if names " + t.text + ", which the unit does not define (line " + std::to_string(line) + ")");
    if (it == defs.end() || it->second.is_function) return 0;
    return cond_eval(it->second.text, defs, line, depth + 1);
  }
  cond_fail("unsupported #if expression at line " + std::to_string(line));
}

// Ruby split("\n", -1): every line, including empty ones at the end.
std::vector<std::string> split_lines_keep(const std::string &text) {
  std::vector<std::string> out;
  size_t start = 0;
  while (true) {
    size_t p = text.find('\n', start);
    if (p == std::string::npos) {
      out.push_back(text.substr(start));
      break;
    }
    out.push_back(text.substr(start, p - start));
    start = p + 1;
  }
  return out;
}

// Ruby lstrip (ASCII whitespace), rstrip.
std::string lstrip_str(const std::string &s) {
  size_t a = 0;
  while (a < s.size() && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\v' || s[a] == '\f' || s[a] == '\r' || s[a] == '\0')) a += 1;
  return s.substr(a);
}

// Ruby split(" ")[0].to_s: the first whitespace-separated word, "" when there is none.
std::string first_word(const std::string &s) {
  size_t a = 0;
  while (a < s.size() && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\v' || s[a] == '\f' || s[a] == '\r')) a += 1;
  size_t b = a;
  while (b < s.size() && !(s[b] == ' ' || s[b] == '\t' || s[b] == '\n' || s[b] == '\v' || s[b] == '\f' || s[b] == '\r')) b += 1;
  return s.substr(a, b - a);
}

// Ruby strip_comments_line (line 2365): a line without its comments.
std::string strip_comments_line(const std::string &v) {
  std::string out;
  long i = 0;
  long n = (long)v.size();
  while (i < n) {
    if (ch(v, i) == '/' && ch(v, i + 1) == '/') {
      break;
    } else if (ch(v, i) == '/' && ch(v, i + 1) == '*') {
      long e = str_index(v, "*/", i + 2);
      if (e < 0) break;
      out += " ";
      i = e + 2;
    } else {
      out.push_back(v[(size_t)i]);
      i += 1;
    }
  }
  return out;
}

// Ruby resolve_conditionals (line 2384): the conditionals of a unit. A conditional that cannot be evaluated is kept
// with its branches; the other conditional lines are blanked, so the line count does not change.
std::string resolve_conditionals(const std::string &text, Defs &defs) {
  std::vector<std::string> out;
  struct Frame {
    bool parent, taken, kept;
  };
  std::vector<Frame> stack;
  bool active = true;
  bool has_pending = false;
  std::string pending;
  long lineno = 0;
  for (const std::string &raw : split_lines_keep(text)) {
    lineno += 1;
    std::string line = raw;
    if (has_pending) {
      // the joined line is one output line: a newline here would shift every later line (launches are keyed by line)
      line = pending + " " + raw;
      has_pending = false;
    }
    if (!line.empty() && line.back() == '\\') {
      pending = line.substr(0, line.size() - 1);
      has_pending = true;
      out.push_back("");
      continue;
    }
    std::string s = lstrip_str(line);
    if (s.empty() || s[0] != '#') {
      out.push_back(active ? line : "");
      continue;
    }
    std::string d = lstrip_str(s.substr(1));
    std::string name;
    size_t k = 0;
    while (k < d.size() && ident_c((unsigned char)d[k])) {
      name += d[k];
      k += 1;
    }
    std::string rest = strip(k <= d.size() ? d.substr(k) : std::string());
    if (name == "if" || name == "ifdef" || name == "ifndef") {
      bool parent = active;
      try {
        bool cond;
        if (name == "if") {
          cond = parent ? cond_eval(rest, defs, lineno, 0) != 0 : false;
        } else {
          std::string nm = first_word(rest);
          cond = parent ? (defs.count(nm) > 0) == (name == "ifdef") : false;
        }
        stack.push_back(Frame{parent, cond, false});
        active = parent && cond;
        out.push_back("");
      } catch (CondUnsupported &) {
        stack.push_back(Frame{parent, true, true});
        active = parent;
        out.push_back(parent ? line : "");
      }
    } else if (name == "elif") {
      if (stack.empty()) refuse("#elif without #if at line " + std::to_string(lineno));
      Frame &fr = stack.back();
      if (fr.kept) {
        out.push_back(fr.parent ? line : "");
      } else if (fr.taken) {
        active = false;
        out.push_back("");
      } else {
        try {
          bool cond = fr.parent ? cond_eval(rest, defs, lineno, 0) != 0 : false;
          fr.taken = cond;
          active = fr.parent && cond;
          out.push_back("");
        } catch (CondUnsupported &) {
          fr.kept = true;
          fr.taken = true;
          active = fr.parent;
          out.push_back(fr.parent ? line : "");
        }
      }
    } else if (name == "else") {
      if (stack.empty()) refuse("#else without #if at line " + std::to_string(lineno));
      Frame &fr = stack.back();
      if (fr.kept) {
        out.push_back(fr.parent ? line : "");
      } else {
        active = fr.parent && !fr.taken;
        fr.taken = true;
        out.push_back("");
      }
    } else if (name == "endif") {
      if (stack.empty()) refuse("#endif without #if at line " + std::to_string(lineno));
      Frame fr = stack.back();
      stack.pop_back();
      active = fr.parent;
      out.push_back(fr.kept && fr.parent ? line : "");
    } else if (name == "define") {
      if (active) {
        std::string mname;
        size_t j = 0;
        while (j < rest.size() && ident_c((unsigned char)rest[j])) {
          mname += rest[j];
          j += 1;
        }
        if (j < rest.size() && rest[j] == '(') {
          Def df;
          df.is_function = true;
          defs[mname] = df;
        } else {
          // the value without its comment: `#define CUDART_HMAX 11070 // CUDA 11.7` is 11070
          Def df;
          df.text = strip(strip_comments_line(j <= rest.size() ? rest.substr(j) : std::string()));
          defs[mname] = df;
        }
      }
      out.push_back(active ? line : "");
    } else if (name == "undef") {
      if (active) defs.erase(first_word(rest));
      out.push_back(active ? line : "");
    } else {
      out.push_back(active ? line : "");
    }
  }
  if (!stack.empty()) refuse("#if without #endif");
  std::string joined;
  for (size_t x = 0; x < out.size(); x++) {
    if (x) joined += "\n";
    joined += out[x];
  }
  return joined;
}

// Ruby tag_after (line 2498): the identifier written right after the first whole-word occurrence of kw, or "" (nil).
std::string tag_after(const std::string &t, const std::string &kw) {
  long i = 0;
  while (true) {
    long j = str_index(t, kw, i);
    if (j < 0) break;
    long k = j + (long)kw.size();
    bool whole = (j == 0 || !ident_c(ch(t, j - 1))) && (k >= (long)t.size() || !ident_c(ch(t, k)));
    if (whole) {
      while (k < (long)t.size() && white_c(ch(t, k))) k += 1;
      if (!(k < (long)t.size() && ident_c(ch(t, k)) && !(ch(t, k) >= 48 && ch(t, k) <= 57))) return std::string();
      long e = k;
      while (e < (long)t.size() && ident_c(ch(t, e))) e += 1;
      return sl(t, k, e);
    }
    i = k;
  }
  return std::string();
}

// Ruby enum_enumerators (line 2517): the enumerators of the enum keyword's own braces.
std::vector<std::string> enum_enumerators(const std::string &t) {
  long e0 = str_index(t, "enum", 0);
  long open = str_index(t, "{", e0 < 0 ? 0 : e0);
  std::vector<std::string> names;
  if (open < 0) return names;
  long close = matching_brace(t, open);
  std::string body = sl(t, open + 1, close < 0 ? (long)t.size() : close);
  // Ruby body.split(","): empty trailing fields are dropped
  std::vector<std::string> items;
  size_t start = 0;
  while (true) {
    size_t q = body.find(',', start);
    if (q == std::string::npos) {
      items.push_back(body.substr(start));
      break;
    }
    items.push_back(body.substr(start, q - start));
    start = q + 1;
  }
  while (!items.empty() && items.back().empty()) items.pop_back();
  for (const auto &item : items) {
    std::vector<std::string> first = tokens_of(ruby_split_eq0(item));
    if (!first.empty()) names.push_back(first.front());
  }
  return names;
}


// Ruby function_head? (line 2557): a head with a `(` before any `=`, before the first brace.
bool function_head(const std::string &t) {
  long b = str_index(t, "{", 0);
  std::string h = b < 0 ? t : sl(t, 0, b);
  long lp = str_index(h, "(", 0);
  if (lp < 0) return false;
  long eq = str_index(h, "=", 0);
  return !(eq >= 0 && eq < lp);
}

// Ruby device_constant_decl? (line 2567): a host const or constexpr declaration that device code may read as a value.
bool device_constant_decl(const std::string &t) {
  long eq = str_index(t, "=", 0);
  long cut = (long)t.size();
  for (long c : {eq, str_index(t, "[", 0), str_index(t, ";", 0)})
    if (c >= 0 && c < cut) cut = c;
  std::string head = sl(t, 0, cut);
  if (head.find('&') != std::string::npos || head.find('*') != std::string::npos) return false;
  if (eq < 0 || eq >= (long)t.size()) return true;
  std::string init = sl(t, eq + 1, (long)t.size());
  long semi = str_index(init, ";", 0);
  if (semi >= 0) init = sl(init, 0, semi);
  if (init.find('&') != std::string::npos) return false;
  if (!strip(init).empty() && strip(init)[0] == '*') return false;
  if (init.find('*') != std::string::npos && init.find('(') != std::string::npos) return false;
  long i = 0;
  while ((i = str_index(init, "(", i)) >= 0) {
    long j = i - 1;
    while (j >= 0 && white_c(ch(init, j))) j -= 1;
    long word_end = j;
    while (j >= 0 && ident_c(ch(init, j))) j -= 1;
    std::string word = word_end > j ? sl(init, j + 1, word_end + 1) : std::string();
    if (!word.empty() && !(word == "sizeof" || word == "alignof" || word == "decltype" || word == "static_cast")) return false;
    i += 1;
  }
  return true;
}

// Ruby linkage_block (line 2594): the braces of an `extern "C" {` or `namespace n {` piece, or false.
bool linkage_block(const std::string &t, long &open_out, long &close_out) {
  long f = 0;
  while (f < (long)t.size() && white_c(ch(t, f))) f += 1;
  std::string s = sl(t, f, (long)t.size());
  if (!(s.compare(0, 8, "extern \"") == 0 || s.compare(0, 10, "namespace ") == 0)) return false;
  long b = str_index(s, "{", 0);
  if (b < 0) return false;
  std::string h = sl(s, 0, b);
  if (h.find('(') != std::string::npos || h.find('=') != std::string::npos || h.find(';') != std::string::npos) return false;
  long open = f + b;
  long close = matching_brace(t, open);
  if (close < 0) return false;
  open_out = open;
  close_out = close;
  return true;
}

// Ruby namespace_opened? (line 2609).
bool namespace_opened(const std::string &opener, const std::string &ns) {
  std::string key = "namespace " + ns;
  long i = str_index(opener, key, 0);
  if (i < 0) return false;
  std::string rest = sl(opener, i + (long)key.size(), (long)opener.size());
  size_t j = 0;
  while (j < rest.size() && white_c((unsigned char)rest[j])) j += 1;
  return j < rest.size() && rest[j] == '{';
}

// A unit piece: a top-level piece with its wrap (the opener and closer of the linkage or namespace blocks around it).
struct UnitPiece {
  long st, en;
  std::string kind;
  bool body;
  bool has_wrap = false;
  std::string wo, wc;
};

// Ruby flatten_linkage (line 2623): the linkage and namespace blocks with device code are cut into their own pieces.
std::vector<UnitPiece> flatten_linkage(const std::string &text, const std::vector<UnitPiece> &raw) {
  std::vector<UnitPiece> out;
  for (const auto &pc : raw) {
    std::string t = sl(text, pc.st, pc.en);
    long open = 0, close = 0;
    bool blk = pc.kind != "pp" && pc.body && linkage_block(t, open, close);
    if (!blk) {
      out.push_back(pc);
      continue;
    }
    std::string inner = sl(t, open + 1, close);
    long base = pc.st + open + 1;
    std::vector<UnitPiece> sub;
    for (const auto &q : top_pieces(inner))
      sub.push_back(UnitPiece{base + q.st, base + q.en, q.kind, q.body, false, std::string(), std::string()});
    std::string wo = sl(t, 0, open + 1);
    std::string wc = sl(t, close, (long)t.size());
    for (const auto &inn : flatten_linkage(text, sub)) {
      UnitPiece np = inn;
      std::string iw0 = inn.has_wrap ? inn.wo : std::string();
      std::string iw1 = inn.has_wrap ? inn.wc : std::string();
      np.has_wrap = true;
      np.wo = wo + iw0;
      np.wc = iw1 + wc;
      out.push_back(np);
    }
  }
  return out;
}

// ---- embedded tables (defined with the device prelude below; see PORTING.md) ---------------------------------------
extern const char *const DEVICE_PRELUDE;
extern const char *const COOP_DEF;
// grid_group::sync: a sense-reversing grid barrier on two zero-initialized device words (the emitter places them in
// device memory). Each block's thread 0 arrives; the last arrival releases the generation and the others spin on it.
// The launch is cooperative (cudaLaunchCooperativeKernel), so every block is resident and the spin cannot deadlock.
static const char *const GRID_DEF =
    "__device__ unsigned __nfcxx_grid_arrived;\n"
    "__device__ unsigned __nfcxx_grid_gen;\n"
    "namespace cooperative_groups {\n"
    "struct grid_group {\n"
    "  void sync(void) const {\n"
    "    __nfcxx_syncthreads();\n"
    "    if (threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0) {\n"
    "      unsigned n = gridDim.x * gridDim.y * gridDim.z;\n"
    "      unsigned gen = atomicAdd(&__nfcxx_grid_gen, 0u);\n"
    "      __threadfence_system();\n"
    "      if (atomicAdd(&__nfcxx_grid_arrived, 1u) == n - 1u) {\n"
    "        atomicAdd(&__nfcxx_grid_arrived, 0u - n);\n"
    "        __threadfence_system();\n"
    "        atomicAdd(&__nfcxx_grid_gen, 1u);\n"
    "      } else {\n"
    "        while (atomicAdd(&__nfcxx_grid_gen, 0u) == gen) {}\n"
    "      }\n"
    "      __threadfence_system();\n"
    "    }\n"
    "    __nfcxx_syncthreads();\n"
    "  }\n"
    "};\n"
    "inline grid_group this_grid(void) { return grid_group(); }\n"
    "}\n";
std::string device_decls();
std::string rewrite_builtins(const std::string &t);
std::string rewrite_is_same_v(const std::string &s);
const std::vector<std::pair<std::string, std::string>> &vector_defs_table();   // Ruby VECTOR_DEFS (ordered)
const std::vector<std::pair<std::string, std::string>> &builtin_defs_table();  // Ruby BUILTIN_DEFS (ordered)
bool lookup_def(const std::vector<std::pair<std::string, std::string>> &tbl, const std::string &key, std::string &out);

// A piece of the device unit (Ruby: the info hash of device_tu).
struct DevPiece {
  UnitPiece u;
  std::string text;
  std::string kind;  // "pp" or "code"
  bool body = false;
  std::vector<std::string> toks;
  std::vector<std::string> defined;
  bool keep = false, device = false, macro = false;
};

// Ruby drop_host_members: a __host__ member definition (no __device__ or __global__) is removed with its body, keeping its
// newlines. A __host__ that does not start a member (after ; { } : or the start of the text) is left alone.
std::string drop_host_members(const std::string &t) {
  std::string out;
  long i = 0;
  long n = (long)t.size();
  const std::string w = "__host__";
  while (i < n) {
    long e = skip_literal(t, i);
    if (e >= 0) {
      out += sl(t, i, e);
      i = e;
      continue;
    }
    if (word_at(t, i, w)) {
      // Ruby out.rstrip[-1]: the last non-whitespace character of out (nil if none)
      int prev = -1;
      for (long q = (long)out.size() - 1; q >= 0; q--) {
        char c = out[(size_t)q];
        if (!(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' || c == '\0')) {
          prev = (unsigned char)c;
          break;
        }
      }
      long open = str_index(t, "{", i);
      long semi = str_index(t, ";", i);
      bool has_header = open >= 0 && (semi < 0 || open < semi);
      std::string header = has_header ? sl(t, i, open) : std::string();
      long close = -1;
      bool prev_ok = prev < 0 || std::string(";{}:").find((char)prev) != std::string::npos;
      if (has_header && header.find('(') != std::string::npos && header.find("__device__") == std::string::npos &&
          header.find("__global__") == std::string::npos && prev_ok)
        close = matching_brace(t, open);
      if (close >= 0) {
        long nls = 0;
        for (long q = i; q <= close; q++)
          if (ch(t, q) == '\n') nls += 1;
        out += std::string((size_t)nls, '\n');
        i = close + 1;
        continue;
      }
    }
    out.push_back(t[(size_t)i]);
    i += 1;
  }
  return out;
}

// Ruby device_tu (line 2642): the device translation unit of a unit: [text, kernel names].
std::pair<std::string, std::vector<std::string>> device_tu(const std::string &text) {
  std::vector<DevPiece> pieces;
  for (const auto &u : flatten_linkage(text, [&]() {
         std::vector<UnitPiece> raw;
         for (const auto &pc : top_pieces(text))
           raw.push_back(UnitPiece{pc.st, pc.en, pc.kind, pc.body, false, std::string(), std::string()});
         return raw;
       }())) {
    DevPiece d;
    d.u = u;
    d.text = sl(text, u.st, u.en);
    d.kind = u.kind;
    d.body = u.body;
    d.toks = tokens_of(d.text);
    if (d.kind == "pp") {
      // Ruby: t.sub("#", "").gsub("\n", " ").strip
      std::string raw = d.text;
      size_t hp = raw.find('#');
      if (hp != std::string::npos) raw.erase(hp, 1);
      for (char &c : raw)
        if (c == '\n') c = ' ';
      std::string rest = strip(raw);
      std::string dw = first_word(rest);
      if (dw == "define") {
        std::string after = strip(rest.size() >= 6 ? rest.substr(6) : std::string());
        std::string first = first_word(after);
        long lp = str_index(first, "(", 0);
        std::string name = lp >= 0 ? first.substr(0, (size_t)lp) : first;
        d.defined = {name};
        d.toks = tokens_of(sl(after, (long)name.size(), (long)after.size()));
        d.macro = true;
      } else if (dw == "undef") {
        d.keep = true;
      } else if (dw == "if" || dw == "ifdef" || dw == "ifndef" || dw == "elif" || dw == "else" || dw == "endif") {
        d.keep = true;
      }
    } else {
      bool g = std::find(d.toks.begin(), d.toks.end(), "__global__") != d.toks.end();
      bool dv = std::find(d.toks.begin(), d.toks.end(), "__device__") != d.toks.end();
      d.device = g || dv;
    }
    pieces.push_back(d);
  }

  std::vector<std::string> kernels;
  std::vector<std::string> seeds;
  // The template launches of the source: each instance is a wrapper kernel (see template_site).
  for (const auto &tl : template_launches(text)) {
    std::string dep;
    if (!dependent_on_template(text, tl.pos, tl.targs, dep)) template_site(tl.name, tl.targs);
  }
  // the dependent launches: the wrapper of each instance of their enclosing template (see dependent_launches)
  for (auto &kv : dependent_launches(text)) {
    const DependentLaunch &dl = kv.second;
    for (const auto &inst : dl.insts) {
      std::vector<std::string> concrete;
      for (const auto &a : split_top(dl.targs))
        concrete.push_back(substitute(a, dl.outer.names, inst, dl.outer.has_pack, dl.outer.pack));
      template_site(dl.name, join(concrete, ", "));
    }
  }
  static const std::vector<std::string> dq(DEVICE_QUALIFIERS.begin(), DEVICE_QUALIFIERS.end());
  for (auto &pc : pieces) {
    if (pc.kind == "pp") continue;
    if (!pc.device) continue;
    if (str_index(pc.text, "__device__", 0) >= 0 && !pc.body && str_index(pc.text, "(", 0) < 0)
      refuse("device variable: " + sl(strip(pc.text), 0, 60));
    if (pc.body) {
      bool has_g = std::find(pc.toks.begin(), pc.toks.end(), "__global__") != pc.toks.end();
      if (has_g && (pc.toks.empty() || pc.toks.front() != "template")) {
        std::string name = function_name(remove_words(pc.text, DEVICE_QUALIFIERS));
        if (name.empty()) refuse("kernel without a name: " + sl(strip(pc.text), 0, 60));
        kernels.push_back(name);
      }
      pc.keep = true;
      // a class of the device side keeps its device members only: its host-only members go, and so do their tokens
      if (std::find(pc.toks.begin(), pc.toks.end(), "struct") != pc.toks.end() ||
          std::find(pc.toks.begin(), pc.toks.end(), "class") != pc.toks.end()) {
        std::string dropped = drop_host_members(pc.text);
        if (dropped != pc.text) {
          pc.text = dropped;
          pc.toks = tokens_of(dropped);
        }
      }
      // a kernel has external linkage (it is launched from the host): `static __global__ void k()` is not static in the
      // device unit, or the front end drops it when no device code calls it
      std::vector<std::string> words = dq;
      if (has_g) words.push_back("static");
      pc.text = remove_words(pc.text, words);
      seeds.insert(seeds.end(), pc.toks.begin(), pc.toks.end());
    } else if (str_index(pc.text, "(", 0) >= 0) {
      pc.keep = true;
      pc.text = remove_words(pc.text, DEVICE_QUALIFIERS);
      seeds.insert(seeds.end(), pc.toks.begin(), pc.toks.end());
    }
  }

  auto has_tok = [](const std::vector<std::string> &v, const std::string &x) {
    return std::find(v.begin(), v.end(), x) != v.end();
  };
  // Host declarations: defined names, as far as a piece's text tells them.
  for (auto &pc : pieces) {
    if (pc.keep || pc.device) continue;
    std::string t = blank_comments(pc.text);
    const auto &toks = pc.toks;
    if (pc.kind == "pp") continue;  // Ruby: both branches are `next`
    if (toks.empty()) continue;
    if (pc.body && str_index(t, "(", 0) >= 0 && !has_tok(toks, "struct") && !has_tok(toks, "class") &&
        !has_tok(toks, "union") && !has_tok(toks, "enum"))
      continue;
    if (!pc.body && str_index(t, "(", 0) >= 0 && str_index(t, "=", 0) < 0 && toks.front() != "typedef") continue;
    if (toks.front() == "typedef") {
      // `typedef R (*name)(args)` names `name`, which follows the `(*`; otherwise the name is the last identifier.
      long fp = str_index(t, "(*", 0);
      pc.defined.clear();
      if (fp >= 0) {
        std::vector<std::string> tt = tokens_of(sl(t, fp + 2, (long)t.size()));
        if (!tt.empty()) pc.defined.push_back(tt.front());
      } else {
        pc.defined.push_back(toks.back());
      }
    } else if (toks.front() == "using") {
      pc.defined.clear();
      if (toks.size() > 1) pc.defined.push_back(toks[1]);
    } else {
      std::string kw;
      for (const auto &tk : toks)
        if (tk == "struct" || tk == "class" || tk == "union" || tk == "enum") {
          kw = tk;
          break;
        }
      if (!kw.empty() && !function_head(t)) {
        // The tag is the identifier written right after the keyword; an anonymous one names nothing.
        // `enum class E` and `enum struct E` name E: the tag follows the scoped-enum keyword.
        std::string tag = tag_after(t, kw);
        if (kw == "enum" && (tag == "class" || tag == "struct")) tag = tag_after(t, tag);
        pc.defined.clear();
        if (!tag.empty()) pc.defined.push_back(tag);
        if (kw == "enum")
          for (const auto &en : enum_enumerators(t)) pc.defined.push_back(en);
      } else if (pc.body) {
        continue;
      } else if ((has_tok(toks, "const") || has_tok(toks, "constexpr")) && device_constant_decl(t)) {
        // a constant: device code may read it; other host variables are not reachable from device code.
        long eq = str_index(t, "=", 0), lb = str_index(t, "[", 0), sc = str_index(t, ";", 0);
        long cut = (long)t.size();
        if (eq >= 0) cut = eq;
        else if (lb >= 0) cut = lb;
        else if (sc >= 0) cut = sc;
        std::vector<std::string> tt = tokens_of(sl(t, 0, cut));
        pc.defined.clear();
        if (!tt.empty()) pc.defined.push_back(tt.back());
      }
    }
  }

  // Fixed point: a host declaration is carried over when the unit refers to a name it defines.
  // The wrappers (see template_site) name their template arguments and parameters: a macro or constant among them is
  // a name the unit needs even when no kept kernel body mentions it (ggml-cuda's mmf: MMF_ROWS_PER_BLOCK_CDNA).
  for (const auto &site : g_sites) {
    for (const auto &x : tokens_of(site.targs)) seeds.push_back(x);
    for (const auto &x : tokens_of(site.decl)) seeds.push_back(x);
  }
  std::map<std::string, bool> needed;
  for (const auto &x : seeds) needed[x] = true;
  for (const auto &x : tokens_of(DEVICE_PRELUDE)) needed[x] = true;
  bool changed = true;
  while (changed) {
    changed = false;
    for (auto &pc : pieces) {
      if (pc.keep || pc.device) continue;
      if (pc.defined.empty()) continue;
      bool any = false;
      for (const auto &dn : pc.defined)
        if (needed.count(dn)) any = true;
      if (!any) continue;
      pc.keep = true;
      changed = true;
      for (const auto &x : pc.toks) needed[x] = true;
    }
  }
  // Injected text (COOP_DEF, GRID_DEF) names builtins that the device unit does not scan, so they are needed here.
  if (needed["cg"] || needed["cooperative_groups"])
    for (const auto &x : tokens_of(COOP_DEF)) needed[x] = true;
  if (needed["this_grid"] || needed["grid_group"])
    for (const auto &x : tokens_of(GRID_DEF)) needed[x] = true;
  // A builtin that is emitted names the builtins its own text uses (the cooperative-groups tile uses threadIdx).
  for (bool grew = true; grew;) {
    grew = false;
    for (const auto &kv : builtin_defs_table()) {
      if (!needed[kv.first]) continue;
      for (const auto &x : tokens_of(kv.second))
        if (!needed[x]) { needed[x] = true; grew = true; }
    }
  }
  for (auto &pc : pieces) {
    if (!(pc.kind == "pp" && pc.macro)) continue;
    bool any = false;
    for (const auto &dn : pc.defined)
      if (needed.count(dn)) any = true;
    if (any) pc.keep = true;
  }
  // A `using namespace n;` is kept when the unit keeps a piece of n (ggml-cuda's mmq-vec-dot.cuh uses tile that way).
  for (auto &pc : pieces) {
    if (pc.keep || pc.kind == "pp") continue;
    if (pc.toks.size() < 2 || pc.toks[0] != "using" || pc.toks[1] != "namespace") continue;
    if (pc.toks.size() < 3) continue;
    const std::string ns = pc.toks[2];
    bool kept = false;
    for (const auto &k : pieces)
      if (k.keep && k.kind != "pp" && k.u.has_wrap && namespace_opened(k.u.wo, ns)) kept = true;
    if (kept) pc.keep = true;
  }

  std::string out = "// Device side of a .cu file, generated by scripts/cuda-rewrite.rb --device. Do not edit.\n";
  out += DEVICE_PRELUDE;
  out += device_decls();
  out += "\n";
  // A vector type the device code names, and the source does not define: its declaration (once per type).
  std::map<std::string, bool> done;
  // The float2 conversions below take or return float2: its declaration is needed whenever one of them is.
  if (needed["__half22float2"] || needed["__float22half2_rn"]) needed["float2"] = true;
  for (const auto &kv : vector_defs_table()) {
    const std::string &name = kv.first;
    if (!needed[name]) continue;
    bool defined_here = false;
    for (const auto &pc : pieces)
      if (pc.keep && has_tok(pc.defined, name)) defined_here = true;
    if (defined_here) continue;
    std::string base = name.compare(0, 5, "make_") == 0 ? name.substr(5) : name;
    if (done[base]) continue;
    done[base] = true;
    std::string text_base;
    lookup_def(vector_defs_table(), base, text_base);
    out += text_base + "\n";
  }
  if (needed["half2"] || needed["__half2"]) {
    needed["__nfcxx_half2_ops"] = true;
    for (const char *n : {"__hadd2", "__hsub2", "__hmul2", "__hdiv2"}) needed[n] = true;
  }
  if (needed["is_same_v"]) needed["is_same"] = true;  // std::is_same_v is rewritten to std::is_same (rewrite_is_same_v)
  // Shared helpers of the math wrappers: each is emitted once, whichever of its users the unit names.
  if (needed["sinf"] || needed["cosf"]) needed["__nfcxx_sincosf"] = true;
  if (needed["expm1f"] || needed["tanhf"]) needed["__nfcxx_expm1f"] = true;
  if (needed["log2f"]) needed["__float_as_uint"] = true;
  for (const auto &kv : builtin_defs_table()) {
    if (!needed[kv.first]) continue;
    bool defined_here = false;
    for (const auto &pc : pieces)
      if (pc.keep && has_tok(pc.defined, kv.first)) defined_here = true;
    if (defined_here) continue;
    out += kv.second;
  }
  bool coop_defined = false;
  for (const auto &pc : pieces)
    if (pc.keep && has_tok(pc.defined, "cooperative_groups")) coop_defined = true;
  if ((needed["cg"] || needed["cooperative_groups"]) && !coop_defined) out += rewrite_builtins(COOP_DEF);
  if (needed["this_grid"] || needed["grid_group"]) out += rewrite_builtins(GRID_DEF);
  for (const auto &pc : pieces) {
    if (!pc.keep) continue;
    std::string code = rewrite_is_same_v(rewrite_builtins(pc.text));
    if (pc.u.has_wrap && pc.kind != "pp") out += pc.u.wo + code + pc.u.wc;
    else out += code;
    out += "\n";
  }
  for (const auto &site : g_sites) {
    out += "extern \"C\" void " + site.wrapper + "(" + site.decl + ") { " + site.name + "<" + site.targs + ">(" +
           join(site.call, ", ") + "); }\n";
    kernels.push_back(site.wrapper);
  }
  // Ruby kernels.uniq (first occurrences kept)
  std::vector<std::string> uniq;
  for (const auto &k : kernels)
    if (std::find(uniq.begin(), uniq.end(), k) == uniq.end()) uniq.push_back(k);
  return {out, uniq};
}

// Ruby rewrite_is_same_v (line 2824): std::is_same_v<A, B> is read through the struct form std::is_same<A, B>::value.
std::string rewrite_is_same_v(const std::string &s) {
  const std::string key = "std::is_same_v<";
  std::string out;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      out += sl(s, i, e);
      i = e;
      continue;
    }
    if (sl_n(s, i, (long)key.size()) == key && !(i > 0 && ident_c(ch(s, i - 1)))) {
      long j = i + (long)key.size();
      long depth = 1;
      while (j < n && depth > 0) {
        long e2 = skip_literal(s, j);
        if (e2 >= 0) {
          j = e2;
          continue;
        }
        if (ch(s, j) == '<') depth += 1;
        if (ch(s, j) == '>') depth -= 1;
        j += 1;
      }
      out += "std::is_same<" + sl(s, i + (long)key.size(), j - 1) + ">::value";
      i = j;
      continue;
    }
    out.push_back(s[(size_t)i]);
    i += 1;
  }
  return out;
}

// Ruby strip_launch_bounds (line 2860): __launch_bounds__(...) is removed with its argument list (newlines kept).
std::string strip_launch_bounds(const std::string &s) {
  std::string out;
  long i = 0;
  long n = (long)s.size();
  const std::string lb = "__launch_bounds__";
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      out += sl(s, i, e);
      i = e;
      continue;
    }
    if (word_at(s, i, lb)) {
      long j = i + (long)lb.size();
      while (j < n && white_c(ch(s, j))) j += 1;
      if (j < n && ch(s, j) == '(') {
        long close = matching_paren(s, j);
        if (close < 0) refuse("unterminated __launch_bounds__");
        // keep the newlines inside the argument list, so line numbers do not move
        long nls = 0;
        for (long q = i; q <= close; q++)
          if (ch(s, q) == '\n') nls += 1;
        out += std::string((size_t)nls, '\n');
        i = close + 1;
        continue;
      }
    }
    out.push_back(s[(size_t)i]);
    i += 1;
  }
  return out;
}

std::string replace_dynamic_uses(const std::string &s, const std::map<std::string, std::string> &names);
bool enclosing_block(const std::string &s, long pos, long &open_out, long &close_out);

// Ruby dynamic_shared_rewrite (line 2894): `extern __shared__ T name[];` is removed and its uses become typed pointers.
std::string dynamic_shared_rewrite(const std::string &s) {
  std::map<std::string, std::string> names;
  std::vector<std::string> order;  // Ruby Hash keeps insertion order (names are looked up by key only)
  std::string out;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      out += sl(s, i, e);
      i = e;
      continue;
    }
    if (word_at(s, i, "extern")) {
      long j = i + 6;
      while (j < n && white_c(ch(s, j))) j += 1;
      if (word_at(s, j, "__shared__")) {
        long k = j + 10;
        long semi = str_index(s, ";", k);
        if (semi < 0) refuse("extern __shared__ declaration without ';'");
        std::string decl = strip(sl(s, k, semi));
        long m = -1;
        for (long q = (long)decl.size() - 1; q >= 0; q--)
          if (decl[(size_t)q] == '[') {
            m = q;
            break;
          }
        bool bracket_ok = m >= 0 && !decl.empty() && decl.back() == ']' && strip(sl(decl, m + 1, (long)decl.size() - 1)).empty();
        if (!bracket_ok) refuse("extern __shared__ " + decl + ": only an unsized array (T name[]) is dynamic shared memory");
        std::string head = strip(sl(decl, 0, m));
        long q = (long)head.size();
        while (q > 0 && ident_c(ch(head, q - 1))) q -= 1;
        std::string name = sl(head, q, (long)head.size());
        std::string type = strip(sl(head, 0, q));
        if (name.empty() || type.empty()) refuse("extern __shared__ " + decl + ": no type or name");
        if (names.count(name) && names[name] != type)
          refuse("extern __shared__ " + name + ": declared with types " + names[name] + " and " + type);
        names[name] = type;
        for (long q2 = i; q2 <= semi; q2++)
          if (ch(s, q2) == '\n') out += "\n";
        i = semi + 1;
        continue;
      }
    }
    out.push_back(s[(size_t)i]);
    i += 1;
  }
  if (names.empty()) return out;
  return replace_dynamic_uses(out, names);
}

// Ruby refuse_unlowered_cccl (line 2961): CUB and grid-wide cooperative groups are refused by name.
void refuse_unlowered_cccl(const std::string &s) {
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (word_at(s, i, "cub")) {
      long j = i + 3;
      while (j < n && white_c(ch(s, j))) j += 1;
      if (sl_n(s, j, 2) == "::") {
        long line = 1;
        for (long q = 0; q < i; q++)
          if (s[(size_t)q] == '\n') line++;
        refuse("cub:: at line " + std::to_string(line) + ": CUB is not lowered (the device unit does not carry its headers)");
      }
    }
    i += 1;
  }
}

// Ruby block_index (line 3010): every brace event of a text in one pass.
struct BlockEvent {
  long pos;
  long open;  // the innermost open `{` after the brace, or -1 (nil)
};
struct BlockIndex {
  std::vector<BlockEvent> events;
  std::map<long, long> closes;  // `{` => its `}` (or the text length when unclosed)
};
IdentKey g_block_key;
BlockIndex g_block_index;

const BlockIndex &block_index(const std::string &s) {
  if (g_block_key.is(s)) return g_block_index;
  BlockIndex idx;
  std::vector<long> stack;
  long k = 0;
  long n = (long)s.size();
  while (k < n) {
    long e = skip_literal(s, k);
    if (e >= 0) {
      k = e;
      continue;
    }
    if (ch(s, k) == '{') {
      stack.push_back(k);
      idx.events.push_back(BlockEvent{k, stack.back()});
    } else if (ch(s, k) == '}' && !stack.empty()) {
      idx.closes[stack.back()] = k;
      stack.pop_back();
      idx.events.push_back(BlockEvent{k, stack.empty() ? -1 : stack.back()});
    }
    k += 1;
  }
  for (long o : stack) idx.closes[o] = n;
  g_block_index = idx;
  g_block_key.set(s);
  return g_block_index;
}

// Ruby enclosing_block_scan (line 3037): the innermost block of pos by a scan from the start (short texts).
bool enclosing_block_scan(const std::string &s, long pos, long &open_out, long &close_out) {
  std::vector<long> stack;
  long i = 0;
  while (i < pos) {
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
  long n = (long)s.size();
  while (j < n) {
    long e = skip_literal(s, j);
    if (e >= 0) {
      j = e;
      continue;
    }
    if (ch(s, j) == '{') depth += 1;
    if (ch(s, j) == '}') depth -= 1;
    if (depth == 0) {
      open_out = open;
      close_out = j;
      return true;
    }
    j += 1;
  }
  open_out = open;
  close_out = n;
  return true;
}

// Ruby enclosing_block (line 2988): the innermost `{ ... }` block containing pos, as [open, close]; false at file scope.
bool enclosing_block(const std::string &s, long pos, long &open_out, long &close_out) {
  if ((long)s.size() < 4000) return enclosing_block_scan(s, pos, open_out, close_out);
  const BlockIndex &idx = block_index(s);
  const auto &events = idx.events;
  size_t lo = 0, hi = events.size();
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    if (events[mid].pos < pos) lo = mid + 1;
    else hi = mid;
  }
  if (lo == 0) return false;
  long open = events[lo - 1].open;
  if (open < 0) return false;
  open_out = open;
  close_out = idx.closes.at(open);
  return true;
}

// Ruby static_shared_names (line 3069): each static `__shared__ T name[...]` as [name, position of name].
std::vector<std::pair<std::string, long>> static_shared_names(const std::string &s) {
  std::vector<std::pair<std::string, long>> found;
  long i = 0;
  long n = (long)s.size();
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (word_at(s, i, "__shared__")) {
      long j = i + 10;
      long stop = j;
      while (stop < n && ch(s, stop) != '[' && ch(s, stop) != ';' && ch(s, stop) != '=') stop += 1;
      if (stop < n && ch(s, stop) == '[') {
        long k = stop;
        while (k > j && white_c(ch(s, k - 1))) k -= 1;
        long q = k;
        while (q > j && ident_c(ch(s, q - 1))) q -= 1;
        if (q < k) found.push_back({sl(s, q, k), q});
      }
      i = j;
      continue;
    }
    i += 1;
  }
  return found;
}

// Ruby shadowed_by_static? (line 3099): the use at pos is inside a range where the name is declared again.
bool shadowed_by_static(const std::map<std::string, std::vector<std::pair<long, long>>> &blocks, const std::string &tok,
                        long pos) {
  auto it = blocks.find(tok);
  if (it == blocks.end()) return false;
  for (const auto &blk : it->second)
    if (pos >= blk.first && pos < blk.second) return true;
  return false;
}

// Ruby PAREN_WORDS (line 3104) and USE_WORDS (line 3106).
const std::vector<std::string> PAREN_WORDS = {"if", "while", "for", "switch", "catch", "return", "sizeof", "decltype", "alignof"};
const std::vector<std::string> USE_WORDS = {"return", "case", "else", "do", "throw", "delete", "new", "goto", "sizeof",
                                            "co_return", "co_await", "co_yield"};

// Ruby token_positions (line 3109): the positions of the identifier tok as whole words.
std::vector<long> token_positions(const std::string &s, const std::string &tok) {
  std::vector<long> found;
  long from = 0;
  while (true) {
    long k = str_index(s, tok, from);
    if (k < 0) break;
    long e = k + (long)tok.size();
    if ((k == 0 || !ident_c(ch(s, k - 1))) && (e >= (long)s.size() || !ident_c(ch(s, e)))) found.push_back(k);
    from = e;
  }
  return found;
}

// Ruby declares_name? (line 3122): a type word, `*` or `&` before the identifier, and `,`, `)`, `;`, `=` or `[` after.
bool declares_name(const std::string &s, long pos, const std::string &tok) {
  long q = pos - 1;
  while (q >= 0 && white_c(ch(s, q))) q -= 1;
  if (q < 0) return false;
  if (ident_c(ch(s, q))) {
    long w = q;
    while (w >= 0 && ident_c(ch(s, w))) w -= 1;
    std::string prev = sl(s, w + 1, q + 1);
    if (std::find(USE_WORDS.begin(), USE_WORDS.end(), prev) != USE_WORDS.end()) return false;
  } else if (ch(s, q) != '*' && ch(s, q) != '&') {
    return false;
  }
  long n = pos + (long)tok.size();
  while (n < (long)s.size() && white_c(ch(s, n))) n += 1;
  if (n >= (long)s.size()) return false;
  return std::string(",);=[").find((char)ch(s, n)) != std::string::npos;
}

// Ruby declaration_scope (line 3140): the range where a name declared at pos is visible, as [start, end].
bool declaration_scope(const std::string &s, long pos, std::pair<long, long> &out) {
  long o = pos - 1;
  long depth = 0;
  long open = -1;
  while (o >= 0) {
    int c = ch(s, o);
    if (c == ')') {
      depth += 1;
    } else if (c == '(') {
      if (depth == 0) {
        open = o;
        break;
      }
      depth -= 1;
    } else if (c == ';' || c == '{' || c == '}') {
      break;
    }
    o -= 1;
  }
  if (open < 0) {
    long bo = 0, bc = 0;
    if (!enclosing_block(s, pos, bo, bc)) return false;
    out = {pos, bc};
    return true;
  }
  long w = open - 1;
  while (w >= 0 && white_c(ch(s, w))) w -= 1;
  long w_end = w;
  while (w >= 0 && ident_c(ch(s, w))) w -= 1;
  std::string word = sl(s, w + 1, w_end + 1);
  if (word.empty() || std::find(PAREN_WORDS.begin(), PAREN_WORDS.end(), word) != PAREN_WORDS.end()) return false;
  long close = matching_paren(s, open);
  if (close < 0) return false;
  long b = close + 1;
  while (b < (long)s.size() && (white_c(ch(s, b)) || ident_c(ch(s, b)))) b += 1;
  if (!(b < (long)s.size() && ch(s, b) == '{')) return false;
  long bclose = matching_brace(s, b);
  if (bclose < 0) return false;
  out = {pos, bclose};
  return true;
}

// Ruby replace_dynamic_uses (line 3180): the uses of the dynamic shared arrays become typed pointers.
std::string replace_dynamic_uses(const std::string &s, const std::map<std::string, std::string> &names) {
  std::string out;
  long i = 0;
  long n = (long)s.size();
  // name => the ranges where the name is declared again (a static __shared__ array, a parameter, a local)
  std::map<std::string, std::vector<std::pair<long, long>>> blocks;
  for (const auto &sn : static_shared_names(s)) {
    if (!names.count(sn.first)) continue;
    long bo = 0, bc = 0;
    if (enclosing_block(s, sn.second, bo, bc)) blocks[sn.first].push_back({bo, bc});
  }
  for (const auto &nm : names) {
    for (long p : token_positions(s, nm.first)) {
      if (!declares_name(s, p, nm.first)) continue;
      std::pair<long, long> sc;
      if (declaration_scope(s, p, sc)) blocks[nm.first].push_back(sc);
    }
  }
  while (i < n) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      out += sl(s, i, e);
      i = e;
      continue;
    }
    if (ident_c(ch(s, i)) && !(ch(s, i) >= '0' && ch(s, i) <= '9')) {
      long j = i;
      while (j < n && ident_c(ch(s, j))) j += 1;
      std::string tok = sl(s, i, j);
      long q = i - 1;
      while (q >= 0 && white_c(ch(s, q))) q -= 1;
      bool member = q >= 0 && (ch(s, q) == '.' || (ch(s, q) == '>' && q > 0 && ch(s, q - 1) == '-'));
      auto nit = names.find(tok);
      if (nit != names.end() && !member && !shadowed_by_static(blocks, tok, i)) {
        out += "((" + nit->second + " *)__nfcxx_dynshared_addr())";
        i = j;
        continue;
      }
      out += tok;
      i = j;
      continue;
    }
    out.push_back(s[(size_t)i]);
    i += 1;
  }
  return out;
}

// Ruby blank_comments (line 3337; the later of the two definitions, so it is the one in effect): each comment character
// becomes a space and a newline stays; literals stay. Positions and line numbers do not change.
std::string blank_comments(const std::string &text) {
  std::string out;
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    int c = ch(text, i);
    if (c == '/' && ch(text, i + 1) == '/') {
      while (i < n && ch(text, i) != '\n') {
        out.push_back(' ');
        i += 1;
      }
      continue;
    }
    if (c == '/' && ch(text, i + 1) == '*') {
      long close = str_index(text, "*/", i + 2);
      long stop = close < 0 ? n : close + 2;
      while (i < stop) {
        out.push_back(ch(text, i) == '\n' ? '\n' : ' ');
        i += 1;
      }
      continue;
    }
    long e = skip_literal(text, i);
    if (e >= 0) {
      out += sl(text, i, e);
      i = e;
      continue;
    }
    out.push_back((char)c);
    i += 1;
  }
  return out;
}

// Ruby String#rindex(sub, pos): the last position <= pos (a negative pos counts from the end); -1 (nil) if none.
long rindex_from(const std::string &s, char c, long pos) {
  long len = (long)s.size();
  if (pos < 0) {
    pos += len;
    if (pos < 0) return -1;
  }
  if (pos >= len) pos = len - 1;
  for (long q = pos; q >= 0; q--)
    if (s[(size_t)q] == c) return q;
  return -1;
}

// Ruby host_storage (line 3241): `static`, unless the declaration so far already has a storage keyword.
std::string host_storage(const std::string &out, const std::string &kw) {
  long a = rindex_from(out, ';', (long)out.size());
  long b = rindex_from(out, '{', (long)out.size());
  long c = rindex_from(out, '}', (long)out.size());
  long start = -1;
  for (long v : {a, b, c})
    if (v >= 0 && v > start) start = v;
  std::string decl = start >= 0 ? sl(out, start + 1, (long)out.size()) : out;
  bool already = false;
  std::string word;
  for (char c2 : decl + " ") {
    if (ident_c((unsigned char)c2)) {
      word.push_back(c2);
    } else {
      if (word == "static") already = true;
      word.clear();
    }
  }
  return already ? std::string() : kw;
}

// Ruby KEYWORDS_OF_CLASS (line 3289).
const std::vector<std::string> KEYWORDS_OF_CLASS = {"class", "struct", "union"};

// Ruby in_class_body? (line 3259): the output so far is inside a class, struct or union body.
bool in_class_body(const std::string &out) {
  long depth = 0;
  long j = (long)out.size() - 1;
  while (j >= 0) {
    char c = out[(size_t)j];
    if (c == '}') {
      depth += 1;
    } else if (c == '{') {
      if (depth == 0) {
        long a = rindex_from(out, ';', j - 1);
        long b = rindex_from(out, '}', j - 1);
        long d = rindex_from(out, '{', j - 1);
        long start = -1;
        for (long v : {a, b, d})
          if (v >= 0 && v > start) start = v;
        std::string head = start >= 0 ? sl(out, start + 1, j) : sl(out, 0, j);
        std::string word;
        for (char ch2 : head + " ") {
          if (ident_c((unsigned char)ch2)) {
            word.push_back(ch2);
          } else {
            if (std::find(KEYWORDS_OF_CLASS.begin(), KEYWORDS_OF_CLASS.end(), word) != KEYWORDS_OF_CLASS.end()) return true;
            word.clear();
          }
        }
        return false;
      }
      depth -= 1;
    }
    j -= 1;
  }
  return false;
}

// Ruby host_linkage (line 3291): the host copy of a unit: kernels and __device__ functions get internal linkage.
std::string host_linkage(const std::string &text) {
  std::string out;
  long i = 0;
  long n = (long)text.size();
  const std::string word = "__global__";
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      out += sl(text, i, e);
      i = e;
      continue;
    }
    if (sl_n(text, i, (long)word.size()) == word && !(i > 0 && ident_c(ch(text, i - 1))) &&
        !ident_c(ch(text, i + (long)word.size()))) {
      out += host_storage(out, "static");
      i += (long)word.size();
      continue;
    }
    // A __device__ function (not a variable): its host copy is static too.
    if (sl_n(text, i, 8) == "__device" && !(i > 0 && ident_c(ch(text, i - 1))) && sl_n(text, i, 10) == "__device__" &&
        !ident_c(ch(text, i + 10))) {
      long j = i + 10;
      while (j < n && (ch(text, j) == ' ' || ch(text, j) == '\n' || ch(text, j) == '\t')) j += 1;
      long k = j;
      while (k < n && std::string("(=;{").find((char)ch(text, k)) == std::string::npos) k += 1;
      if (k < n && ch(text, k) == '(') {
        // `__device__ static T f(...)`: the keyword after the qualifier already gives the storage class.
        bool after_static = sl_n(text, j, 6) == "static" && !ident_c(ch(text, j + 6));
        // `[&] __device__ (...) {...}`: a device lambda. Its qualifier goes.
        long p = (long)out.size() - 1;
        while (p >= 0 && white_c((unsigned char)out[(size_t)p])) p -= 1;
        bool lambda = p >= 0 && out[(size_t)p] == ']';
        if (!(after_static || lambda || in_class_body(out))) out += host_storage(out, "static");
        i += 10;
        continue;
      }
    }
    out.push_back(text[(size_t)i]);
    i += 1;
  }
  return out;
}

// Ruby system_path? (line 2123) uses File.expand_path: an absolute, normalized path.
std::string expand_path(const std::string &path) {
  std::error_code ec;
  std::filesystem::path p = std::filesystem::absolute(std::filesystem::path(path), ec);
  if (ec) return path;
  return p.lexically_normal().string();
}

// Ruby File.dirname (for a path given on the command line).
std::string dirname_of(const std::string &path) {
  size_t p = path.find_last_of('/');
  if (p == std::string::npos) return ".";
  if (p == 0) return "/";
  return path.substr(0, p);
}

// Ruby find_include (line 2128): a quoted include is looked up beside the including file first, then in -I.
bool find_include(const std::string &dir, const std::string &name, bool quoted, std::string &path_out) {
  std::vector<std::string> cands;
  if (quoted) cands.push_back(dir + "/" + name);
  for (const auto &d : g_incdirs) cands.push_back(d + "/" + name);
  for (const auto &c : cands) {
    std::error_code ec;
    if (std::filesystem::is_regular_file(c, ec) && !system_path(expand_path(c))) {
      path_out = c;
      return true;
    }
  }
  return false;
}

// Ruby read: the whole file as bytes (File.open(path, "rb") { |f| f.read }).
bool read_file(const std::string &path, std::string &out) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  out.clear();
  char buf[65536];
  size_t got;
  while ((got = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, got);
  std::fclose(f);
  return true;
}

// Ruby expand_includes (line 2135): the quoted and -I includes of a unit are expanded in place, once per file.
std::string expand_includes(const std::string &text, const std::string &dir, int depth, std::map<std::string, bool> &seen) {
  if (depth > 8) return text;
  std::string out;
  long last = 0;
  for (const auto &pc : top_pieces(text)) {
    if (pc.kind != "pp") continue;
    std::string rest = strip(sl(text, pc.st, pc.en));
    size_t hp = rest.find('#');
    if (hp != std::string::npos) rest.erase(hp, 1);
    rest = strip(rest);
    if (rest.compare(0, 7, "include") != 0) continue;
    std::string q = strip(rest.size() >= 7 ? rest.substr(7) : std::string());
    bool quoted = !q.empty() && q[0] == '"';
    if (!(quoted || (!q.empty() && q[0] == '<'))) continue;
    std::string after = q.size() >= 1 ? q.substr(1) : std::string();
    size_t dl = after.find(quoted ? '"' : '>');
    std::string name = dl == std::string::npos ? after : after.substr(0, dl);
    std::string path;
    if (!find_include(dir, name, quoted, path)) continue;
    std::string key = expand_path(path);
    out += sl(text, last, pc.st);
    if (seen.count(key)) {
      out += "\n";
    } else {
      seen[key] = true;
      // The same two rewrites as the main file: a header of the backend has __launch_bounds__ in front of its
      // template kernels, which kernel_template would not match.
      std::string inc;
      if (!read_file(path, inc)) refuse("cannot read " + path);
      inc = dynamic_shared_rewrite(strip_launch_bounds(g_device_mode ? blank_comments(inc) : inc));
      out += "\n" + expand_includes(inc, dirname_of(path), depth + 1, seen) + "\n";
    }
    last = pc.en;
  }
  out += sl(text, last, (long)text.size());
  return out;
}

// Ruby split("\n") (no limit): the fields, with trailing empty fields removed.
std::vector<std::string> ruby_split_nl(const std::string &text) {
  std::vector<std::string> v = split_lines_keep(text);
  while (!v.empty() && v.back().empty()) v.pop_back();
  return v;
}

// ---- embedded tables (generated from the Ruby text by tools/cuda-rewrite/gen-tables.sh) ------------------------------
struct TblEntry {
  const char *key;
  const char *val;
};
#include "tables.inc"

// Ruby VECTOR_DEFS, BUILTIN_DEFS and DEVICE_BUILTINS as insertion-ordered lists (a Ruby Hash keeps its order).
const std::vector<std::pair<std::string, std::string>> &table_vec(const TblEntry *t, size_t n) {
  static std::map<const TblEntry *, std::vector<std::pair<std::string, std::string>>> cache;
  auto it = cache.find(t);
  if (it != cache.end()) return it->second;
  std::vector<std::pair<std::string, std::string>> v;
  for (size_t i = 0; i < n; i++) v.push_back({t[i].key, t[i].val});
  return cache[t] = v;
}
const std::vector<std::pair<std::string, std::string>> &vector_defs_table() {
  static const std::vector<std::pair<std::string, std::string>> &v =
      table_vec(VECTOR_DEFS_TBL, sizeof(VECTOR_DEFS_TBL) / sizeof(VECTOR_DEFS_TBL[0]));
  return v;
}
const std::vector<std::pair<std::string, std::string>> &builtin_defs_table() {
  static const std::vector<std::pair<std::string, std::string>> &v =
      table_vec(BUILTIN_DEFS_TBL, sizeof(BUILTIN_DEFS_TBL) / sizeof(BUILTIN_DEFS_TBL[0]));
  return v;
}
const std::vector<std::pair<std::string, std::string>> &device_builtins_table() {
  static const std::vector<std::pair<std::string, std::string>> &v =
      table_vec(DEVICE_BUILTINS_TBL, sizeof(DEVICE_BUILTINS_TBL) / sizeof(DEVICE_BUILTINS_TBL[0]));
  return v;
}

// Ruby hash lookup: the value of key, or false (Ruby nil).
bool lookup_def(const std::vector<std::pair<std::string, std::string>> &tbl, const std::string &key, std::string &out) {
  for (const auto &kv : tbl)
    if (kv.first == key) {
      out = kv.second;
      return true;
    }
  return false;
}

// Ruby DEVICE_AXES (line 1520).
const std::vector<std::string> DEVICE_AXES = {"x", "y", "z"};

// Ruby rewrite_builtins (line 1528): threadIdx.x and the others become calls of the intrinsics, and the syncthreads and
// syncwarp spellings become the nfcxx names.
std::string rewrite_builtins(const std::string &t) {
  std::string out;
  long i = 0;
  long n = (long)t.size();
  while (i < n) {
    long e = skip_literal(t, i);
    if (e >= 0) {
      out += sl(t, i, e);
      i = e;
      continue;
    }
    // `extern __shared__ T x[];` is a shared-memory declaration: the prelude's static replaces both words
    if (word_at(t, i, "extern")) {
      long j = i + 6;
      while (j < n && (ch(t, j) == ' ' || ch(t, j) == '\t' || ch(t, j) == '\n')) j += 1;
      if (word_at(t, j, "__shared__")) {
        i = j;
        continue;
      }
    }
    if (word_at(t, i, "__syncthreads") && ch(t, i + 13) == '(') {
      out += "__nfcxx_syncthreads";
      i += 13;
      continue;
    }
    // __syncwarp(mask) is the warp barrier of the mask; __syncwarp() is the full warp (CUDA's default mask)
    if (word_at(t, i, "__syncwarp") && ch(t, i + 10) == '(') {
      out += "__nfcxx_syncwarp(";
      long j = i + 11;
      while (j < n && white_c(ch(t, j))) j += 1;
      if (ch(t, j) == ')') out += "0xffffffffu";
      i += 11;
      continue;
    }
    bool hit = false;
    for (const auto &kv : device_builtins_table()) {
      if (hit || !word_at(t, i, kv.first)) continue;
      long j = i + (long)kv.first.size();
      if (!(ch(t, j) == '.' && (ch(t, j + 1) == 'x' || ch(t, j + 1) == 'y' || ch(t, j + 1) == 'z') && !ident_c(ch(t, j + 2))))
        continue;
      out += "__nfcxx_" + kv.second + "_" + std::string(1, (char)ch(t, j + 1)) + "()";
      i = j + 2;
      hit = true;
    }
    if (hit) continue;
    out.push_back(t[(size_t)i]);
    i += 1;
  }
  return out;
}

// Ruby device_decls (line 1577): the extern declarations of the builtins' intrinsics.
std::string device_decls() {
  std::vector<std::string> decls;
  for (const auto &kv : device_builtins_table())
    for (const char *a : {"x", "y", "z"})
      decls.push_back("extern \"C\" unsigned __nfcxx_" + kv.second + "_" + a + "(void);");
  return join(decls, "\n");
}

}  // namespace

// The command line of the Ruby script (line 3371): -I DIR, --device, --kernels=FILE, --edg-launches, FILE.cu.
int usage() {
  std::fprintf(stderr, "usage: cuda-rewrite.rb [--device [--kernels=FILE]] [--edg-launches] FILE.cu\n");
  return 2;
}

int main(int argc, char **argv) {
  bool device = false;
  bool has_kernels = false;
  std::string kernels_path;
  bool has_path = false;
  std::string path;
  for (int a = 1; a < argc; a++) {
    std::string arg = argv[a];
    if (arg.compare(0, 2, "-I") == 0) {
      g_incdirs.push_back(arg.substr(2));
    } else if (arg == "--device") {
      device = true;
      g_device_mode = true;
    } else if (arg == "--edg-launches") {
      g_edg_launches = true;
    } else if (arg.compare(0, 10, "--kernels=") == 0) {
      has_kernels = true;
      kernels_path = arg.substr(10);
    } else if (!has_path) {
      has_path = true;
      path = arg;
    } else {
      return usage();
    }
  }
  if (!has_path) return usage();
  std::string text;
  if (!read_file(path, text)) {
    std::fprintf(stderr, "cuda-rewrite: cannot read %s\n", path.c_str());
    return 1;
  }
  if (device) text = blank_comments(text);
  text = dynamic_shared_rewrite(strip_launch_bounds(text));
  if (device) refuse_unlowered_cccl(text);
  std::map<std::string, bool> seen;
  g_expanded = expand_includes(text, dirname_of(path), 0, seen);
  g_expanded = launch_prepare(g_expanded);
  std::string result;
  if (device) {
    // The device unit is built from the conditionals of the device pass (see resolve_conditionals).
    Defs defs;
    for (const auto &kv : DEVICE_PASS_MACROS) {
      Def df;
      df.text = kv.second;
      defs[kv.first] = df;
    }
    g_expanded = resolve_conditionals(g_expanded, defs);
    // #include lines of system headers are not in the device unit (a top-level piece may carry one in front of a
    // declaration, so they are removed here, not by the piece's keep decision).
    std::string joined;
    bool first = true;
    for (const auto &l : ruby_split_nl(g_expanded)) {
      std::string ls = lstrip_str(l);
      std::string after_hash = lstrip_str(ls.size() >= 1 ? ls.substr(1) : std::string());
      bool drop = ls.compare(0, 8, "#include") == 0 || (!ls.empty() && ls[0] == '#' && after_hash.compare(0, 7, "include") == 0);
      if (drop) continue;
      if (!first) joined += "\n";
      joined += l;
      first = false;
    }
    g_expanded = joined;
    auto dk = device_tu(g_expanded);
    if (has_kernels) {
      FILE *kf = std::fopen(kernels_path.c_str(), "wb");
      if (kf) {
        for (const auto &k : dk.second) std::fprintf(kf, "%s\n", k.c_str());
        std::fclose(kf);
      }
    }
    result = dk.first;
  } else {
    // The host copy has the local headers expanded too: their launches are in the host unit as well.
    result = host_linkage(rewrite(g_expanded, path));
  }
  std::fwrite(result.data(), 1, result.size(), stdout);
  return 0;
}
