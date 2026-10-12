// A command-line driver for the nfcast engine: runs a Lua file the way `lua file.lua` does (the chunk name is the path as
// given, so error messages carry the same "path:line:"). With --stats it prints the engine's counters to stderr.
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>

#include "nfcast.hpp"

int main(int argc, char** argv) {
  bool stats = false;
  const char* path = nullptr;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--stats") == 0) stats = true;
    else path = argv[i];
  }
  if (!path) {
    std::fprintf(stderr, "usage: nfcast_run [--stats] file.lua\n");
    return 2;
  }
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "nfcast_run: cannot open %s\n", path);
    return 2;
  }
  std::stringstream ss;
  ss << in.rdbuf();
  std::string code = ss.str();
  if (code.size() >= 2 && code[0] == '#') code = "--" + code;  // a shebang line
  nfcast::State S;
  S.open_libs();
  std::string err;
  nfcast::Closure* cl = S.load(code, path, &err);
  if (!cl) {
    std::fprintf(stderr, "lua: %s\n", err.c_str());
    return 1;
  }
  int rc = 0;
  try {
    nfcast::Rets out;
    S.call(nfcast::Value::function(cl), nullptr, 0, out);
  } catch (nfcast::Thrown& t) {
    std::string m;
    try {
      m = S.tostring(t.v);
    } catch (nfcast::Thrown&) {
      m = "(error object is not a string)";
    }
    std::fprintf(stderr, "lua: %s\n", m.c_str());
    for (const std::string& line : t.trace) std::fprintf(stderr, "\t%s\n", line.c_str());
    rc = 1;
  }
  std::fflush(stdout);
  if (stats) {
    std::fprintf(stderr, "rewrites=%llu deopts=%llu generic_ops=%llu gc_cycles=%llu inlined_sites=%llu inlined_calls=%llu inline_declined=%llu\n",
                 static_cast<unsigned long long>(S.stats.rewrites), static_cast<unsigned long long>(S.stats.deopts),
                 static_cast<unsigned long long>(S.stats.generic_ops), static_cast<unsigned long long>(S.stats.gc_cycles),
                 static_cast<unsigned long long>(S.stats.inlined_sites), static_cast<unsigned long long>(S.stats.inlined_calls),
                 static_cast<unsigned long long>(S.stats.inline_declined));
    if (S.tier) {  // NFCAST_TIER=sync|async
      const nfcast::Stats& st = S.stats;
      std::fprintf(stderr,
                   "tier: compiled=%llu compiles=%llu cache_hits=%llu ineligible=%llu failed=%llu calls=%llu bailouts=%llu (guard_misses=%llu aborts=%llu)\n",
                   static_cast<unsigned long long>(st.tier_compiled), static_cast<unsigned long long>(st.tier_compiles),
                   static_cast<unsigned long long>(st.tier_cache_hits), static_cast<unsigned long long>(st.tier_ineligible),
                   static_cast<unsigned long long>(st.tier_failed), static_cast<unsigned long long>(st.tier_calls),
                   static_cast<unsigned long long>(st.tier_bailouts), static_cast<unsigned long long>(st.tier_guard_misses),
                   static_cast<unsigned long long>(st.tier_aborts));
    }
  }
  return rc;
}
