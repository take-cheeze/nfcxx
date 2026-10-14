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

}  // namespace

int main(int argc, char **argv) {
  // The CLI is ported with the passes. Until then the Ruby script is the rewriter (the driver calls it).
  (void)argc;
  (void)argv;
  std::fprintf(stderr, "cuda-rewrite: not ported yet (see tools/cuda-rewrite/PORTING.md); use scripts/cuda-rewrite.rb\n");
  return 2;
}
