// nfceval implementation. See nfceval.hpp and docs/notes/eval.md.
#include "nfceval.hpp"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

namespace nfceval {

namespace {

// ---- hashing: two FNV-1a 64 passes with different offsets, 32 hex digits ----------------------
std::string hash_hex(const std::string& s) {
  unsigned long long a = 1469598103934665603ULL, b = 0x9e3779b97f4a7c15ULL;
  for (std::size_t i = 0; i < s.size(); ++i) {
    unsigned char c = (unsigned char)s[i];
    a = (a ^ c) * 1099511628211ULL;
    b = (b ^ (c + 31u)) * 1099511628211ULL;
    b ^= b >> 29;
  }
  char buf[40];
  std::snprintf(buf, sizeof buf, "%016llx%016llx", a, b);
  return buf;
}

bool is_ident(const std::string& s) {
  if (s.empty() || !(std::isalpha((unsigned char)s[0]) || s[0] == '_')) return false;
  for (std::size_t i = 0; i < s.size(); ++i)
    if (!(std::isalnum((unsigned char)s[i]) || s[i] == '_')) return false;
  return true;
}

bool blank(const std::string& s, std::size_t from = 0, std::size_t to = std::string::npos) {
  if (to > s.size()) to = s.size();
  for (std::size_t i = from; i < to; ++i)
    if (!std::isspace((unsigned char)s[i])) return false;
  return true;
}

// What the snippet looks like: does it contain a `return` token, and where does the last top-level
// ';' end the final statement (npos: none). Strings, characters and comments are skipped.
struct Scan {
  bool has_return = false;
  std::size_t last_semi = std::string::npos;
};

Scan scan(const std::string& s) {
  Scan r;
  int depth = 0;
  for (std::size_t i = 0; i < s.size();) {
    char c = s[i];
    if (c == '/' && i + 1 < s.size() && s[i + 1] == '/') {
      while (i < s.size() && s[i] != '\n') ++i;
    } else if (c == '/' && i + 1 < s.size() && s[i + 1] == '*') {
      i += 2;
      while (i + 1 < s.size() && !(s[i] == '*' && s[i + 1] == '/')) ++i;
      i += 2;
    } else if (c == '"' || c == '\'') {
      ++i;
      while (i < s.size() && s[i] != c) i += (s[i] == '\\') ? 2 : 1;
      ++i;
    } else if (std::isalpha((unsigned char)c) || c == '_') {
      std::size_t b = i;
      while (i < s.size() && (std::isalnum((unsigned char)s[i]) || s[i] == '_')) ++i;
      if (s.compare(b, i - b, "return") == 0) r.has_return = true;
    } else {
      if (c == '(' || c == '[' || c == '{') ++depth;
      else if (c == ')' || c == ']' || c == '}') --depth;
      else if (c == ';' && depth == 0) r.last_semi = i;
      ++i;
    }
  }
  return r;
}

// The snippet as a function body. Line numbers are preserved (no newline is added before the end).
std::string wrap_body(const std::string& code, bool is_void) {
  Scan sc = scan(code);
  if (sc.has_return) return code;
  std::size_t from = sc.last_semi == std::string::npos ? 0 : sc.last_semi + 1;
  if (blank(code, from)) return code;  // ends with ';' (or is empty)
  // a trailing block statement ("if (c) { ... }") is not an expression
  std::size_t e = code.find_last_not_of(" \t\r\n");
  std::size_t b = code.find_first_not_of(" \t\r\n", from);
  if (code[e] == '}') return code;
  static const char* const kw[] = {"if", "for", "while", "switch", "do", "try", "{"};
  for (const char* k : kw) {
    std::size_t n = std::strlen(k);
    if (code.compare(b, n, k) == 0 && (n == 1 || b + n >= code.size() || !(std::isalnum((unsigned char)code[b + n]) || code[b + n] == '_')))
      return code;
  }
  if (is_void) return code + ";";
  return code.substr(0, from) + " return (" + code.substr(from) + "\n);";
}

bool unspellable(const std::string& t) {
  return t.empty() || t.find("lambda") != std::string::npos || t.find("<unnamed") != std::string::npos ||
         t.find("anonymous") != std::string::npos || t.find('{') != std::string::npos ||
         t.find("<unknown") != std::string::npos;
}

std::string read_file(const std::string& path) {
  std::string out;
  if (FILE* f = std::fopen(path.c_str(), "rb")) {
    char buf[4096];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
    std::fclose(f);
  }
  return out;
}

bool write_file(const std::string& path, const std::string& data) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return false;
  bool ok = std::fwrite(data.data(), 1, data.size(), f) == data.size();
  return std::fclose(f) == 0 && ok;
}

bool file_exists(const std::string& p, int mode = F_OK) { return ::access(p.c_str(), mode) == 0; }

std::string default_driver() {
  if (const char* e = std::getenv("NFCXX")) {
    if (*e) return e;
  }
#ifdef NFCEVAL_DEFAULT_DRIVER
  if (file_exists(NFCEVAL_DEFAULT_DRIVER, X_OK)) return NFCEVAL_DEFAULT_DRIVER;
#endif
  // <repo>/lib/eval/nfceval.cpp -> <repo>/nfcxx
  std::string f = __FILE__;
  for (int i = 0; i < 3; ++i) {
    std::size_t s = f.rfind('/');
    if (s == std::string::npos) {
      f = i == 2 ? "." : "";  // a relative __FILE__ ("lib/eval/nfceval.cpp"): the repository is the cwd
      break;
    }
    f.resize(s);
  }
  if (!f.empty() && file_exists(f + "/nfcxx", X_OK)) return f + "/nfcxx";
  return "nfcxx";
}

struct Loaded {
  void* handle;
  int (*entry)(void* const*, void*, char*, unsigned long);
};

}  // namespace

struct Engine::Impl {
  std::string driver = default_driver();
  std::string cache;
  std::vector<std::string> flags;
  unsigned timeout = 300;
  std::string prelude;
  std::vector<detail::Slot> slots;
  std::map<std::string, Loaded> loaded;  // key -> handle
  unsigned compiles = 0, loads = 0;

  std::string cache_dir() {
    if (cache.empty()) {
      if (const char* e = std::getenv("NFCEVAL_CACHE")) cache = e;
      if (cache.empty()) {
        const char* t = std::getenv("TMPDIR");
        cache = std::string(t && *t ? t : "/tmp") + "/nfceval-cache-" + std::to_string((unsigned long)::getuid());
      }
    }
    return cache;
  }

  void ensure_cache() {
    std::string d = cache_dir();
    // mkdir -p
    for (std::size_t i = 1; i <= d.size(); ++i) {
      if (i == d.size() || d[i] == '/') {
        std::string part = d.substr(0, i);
        if (::mkdir(part.c_str(), 0700) != 0 && errno != EEXIST)
          throw Error("nfceval: cannot create cache directory " + part + ": " + std::strerror(errno));
      }
    }
    struct stat st;
    if (::stat(d.c_str(), &st) != 0 || !S_ISDIR(st.st_mode))
      throw Error("nfceval: cache path is not a directory: " + d);
    // Shared objects from this directory are executed: refuse one another user could write to.
    if (st.st_uid != ::getuid() || (st.st_mode & (S_IWGRP | S_IWOTH)))
      throw Error("nfceval: cache directory " + d + " must be owned by the current user and not group/world writable");
  }

  // Runs the driver; returns its output, sets status (exit code, -1: killed by the timeout, -2: spawn failed).
  std::string run_driver(const std::vector<std::string>& args, const std::string& logfile, int& status) {
    std::vector<char*> argv;
    for (const std::string& a : args) argv.push_back(const_cast<char*>(a.c_str()));
    argv.push_back(nullptr);
    pid_t pid = ::fork();
    if (pid < 0) {
      status = -2;
      return std::string("fork failed: ") + std::strerror(errno);
    }
    if (pid == 0) {
      ::setpgid(0, 0);
      int fd = ::open(logfile.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
      int in = ::open("/dev/null", O_RDONLY);
      if (fd >= 0) {
        ::dup2(fd, 1);
        ::dup2(fd, 2);
      }
      if (in >= 0) ::dup2(in, 0);
      ::execvp(argv[0], argv.data());
      std::fprintf(stderr, "nfceval: cannot run %s: %s\n", argv[0], std::strerror(errno));
      ::_exit(127);
    }
    ::setpgid(pid, pid);
    long waited_ms = 0;
    bool killed = false;
    int ws = 0;
    for (;;) {
      pid_t r = ::waitpid(pid, &ws, WNOHANG);
      if (r == pid) break;
      if (r < 0 && errno != EINTR) {
        ws = 0;
        break;
      }
      struct timespec ts = {0, 5 * 1000 * 1000};
      ::nanosleep(&ts, nullptr);
      waited_ms += 5;
      if (timeout && !killed && waited_ms > (long)timeout * 1000) {
        ::kill(-pid, SIGKILL);
        killed = true;
      }
    }
    status = killed ? -1 : WIFEXITED(ws) ? WEXITSTATUS(ws) : 128 + (WIFSIGNALED(ws) ? WTERMSIG(ws) : 0);
    return read_file(logfile);
  }

  Loaded load(const std::string& key, const std::string& src) {
    auto it = loaded.find(key);
    if (it != loaded.end()) return it->second;
    ensure_cache();
    std::string base = cache_dir() + "/nfceval-" + key;
    std::string so = base + ".so";
    if (!file_exists(so)) {
      std::string pid = std::to_string((long)::getpid());
      std::string cpp = base + ".cpp", tmp = base + "." + pid + ".so", log = base + "." + pid + ".log";
      if (!write_file(cpp, src)) throw Error("nfceval: cannot write " + cpp);
      std::vector<std::string> args;
      args.push_back(driver);
      args.push_back("-shared");
      for (const std::string& f : flags) args.push_back(f);
      args.push_back(cpp);
      args.push_back("-o");
      args.push_back(tmp);
      int status = 0;
      ++compiles;
      std::string out = run_driver(args, log, status);
      ::unlink(log.c_str());
      if (status != 0 || !file_exists(tmp)) {
        ::unlink(tmp.c_str());
        std::string why = status == -1 ? "compiler timed out after " + std::to_string(timeout) + " s"
                          : status == 127 ? "cannot run the nfcxx driver '" + driver + "' (set NFCXX or Engine::set_driver)"
                                          : "compile failed (driver exit " + std::to_string(status) + ")";
        if (status == 127 || status == -2) throw Error("nfceval: " + why + "\n" + out);
        throw CompileError("nfceval: " + why + "\n" + out);
      }
      if (::rename(tmp.c_str(), so.c_str()) != 0) {
        ::unlink(tmp.c_str());
        throw Error("nfceval: cannot install " + so + ": " + std::strerror(errno));
      }
    }
    void* h = ::dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) {
      const char* e = ::dlerror();
      throw Error(std::string("nfceval: dlopen failed: ") + (e ? e : "?"));
    }
    void* sym = ::dlsym(h, "nfceval_entry");
    if (!sym) {
      ::dlclose(h);
      throw Error("nfceval: " + so + " has no nfceval_entry");
    }
    ++loads;
    Loaded l;
    l.handle = h;
    *reinterpret_cast<void**>(&l.entry) = sym;
    loaded[key] = l;
    return l;
  }

  std::string cache_key(const std::string& src) const {
    std::string k = src;
    k += "\n//driver:" + driver;
    for (const std::string& f : flags) k += "\n//flag:" + f;
    const char* be = std::getenv("NFCXX_BACKEND");
    k += std::string("\n//backend:") + (be ? be : "");
    return hash_hex(k);
  }
};

Engine::Engine() : p_(new Impl) {}

Engine::~Engine() {
  for (auto& kv : p_->loaded) ::dlclose(kv.second.handle);
}

Engine& Engine::set_driver(std::string path) {
  p_->driver = std::move(path);
  return *this;
}
Engine& Engine::set_cache_dir(std::string dir) {
  p_->cache = std::move(dir);
  return *this;
}
Engine& Engine::add_flag(std::string flag) {
  p_->flags.push_back(std::move(flag));
  return *this;
}
Engine& Engine::set_compile_timeout(unsigned seconds) {
  p_->timeout = seconds;
  return *this;
}
Engine& Engine::prelude(const std::string& code) {
  p_->prelude += code;
  p_->prelude += "\n";
  return *this;
}
Engine& Engine::include(const std::string& header) {
  if (!header.empty() && header[0] == '<') return prelude("#include " + header);
  return prelude("#include \"" + header + "\"");
}

static detail::Slot* find_slot(std::vector<detail::Slot>& v, const std::string& name) {
  for (detail::Slot& s : v)
    if (s.name == name) return &s;
  return nullptr;
}

static void put_slot(std::vector<detail::Slot>& v, detail::Slot s) {
  if (detail::Slot* old = find_slot(v, s.name)) *old = std::move(s);
  else v.push_back(std::move(s));
}

Engine& Engine::bind_ref(const std::string& name, const std::string& type, void* addr) {
  if (!is_ident(name)) throw Error("nfceval: '" + name + "' is not an identifier");
  if (unspellable(type))
    throw Error("nfceval: cannot spell the type of '" + name + "' (" + type + "); pass it as the third argument of bind()");
  detail::Slot s;
  s.name = name;
  s.decl = "typedef " + type + " nfceval_T_" + name + "; [[maybe_unused]] nfceval_T_" + name + "& " + name + " = *static_cast<nfceval_T_" + name +
           "*>(nfceval_t[@0]);";
  s.words.push_back(addr);
  put_slot(p_->slots, std::move(s));
  return *this;
}

Engine& Engine::bind_function(const std::string& name, const std::string& ret, const std::vector<std::string>& args,
                              void* thunk, void* state, std::unique_ptr<void, void (*)(void*)> keep) {
  if (!is_ident(name)) throw Error("nfceval: '" + name + "' is not an identifier");
  if (unspellable(ret)) throw Error("nfceval: cannot spell the return type of '" + name + "'");
  std::string params, call, ptrty = ret + " (*)(void*";
  for (std::size_t i = 0; i < args.size(); ++i) {
    if (unspellable(args[i])) throw Error("nfceval: cannot spell parameter " + std::to_string(i) + " of '" + name + "'");
    std::string n = "a" + std::to_string(i);
    params += (i ? ", " : "") + args[i] + " " + n;
    call += ", nfceval_fwd<" + args[i] + ">(" + n + ")";
    ptrty += ", " + args[i];
  }
  ptrty += ")";
  detail::Slot s;
  s.name = name;
  // fn: file-scope function (placed before the snippet function); @0/@1 are the table indices.
  s.decl = "@F [[maybe_unused]] static " + ret + " " + name + "(" + params + ") { return reinterpret_cast<" + ptrty + ">(nfceval_tbl_[@0])(nfceval_tbl_[@1]" +
           call + "); }";
  s.words.push_back(thunk);
  s.words.push_back(state);
  s.keep = std::move(keep);
  put_slot(p_->slots, std::move(s));
  return *this;
}

Engine& Engine::unbind(const std::string& name) {
  for (std::size_t i = 0; i < p_->slots.size(); ++i)
    if (p_->slots[i].name == name) {
      p_->slots.erase(p_->slots.begin() + i);
      break;
    }
  return *this;
}

static void replace_all(std::string& s, const std::string& from, const std::string& to) {
  for (std::size_t p = 0; (p = s.find(from, p)) != std::string::npos; p += to.size()) s.replace(p, from.size(), to);
}

std::string Engine::generate(const std::string& code, const std::string& r_type) const {
  bool is_void = r_type.empty();
  std::string fns, refs;
  std::size_t idx = 0;
  for (const detail::Slot& s : p_->slots) {
    std::string d = s.decl;
    bool is_fn = d.compare(0, 3, "@F ") == 0;
    if (is_fn) d = d.substr(3);
    replace_all(d, "@0", std::to_string(idx));
    replace_all(d, "@1", std::to_string(idx + 1));
    idx += s.words.size();
    (is_fn ? fns : refs) += d + "\n";
  }
  std::string o;
  o += "// generated by nfceval\n";
  o += "#include <new>\n#include <exception>\n#include <stdexcept>\n#include <string>\n#include <cstdio>\n"
       "#include <cstdlib>\n#include <cstring>\n#include <cmath>\n#include <type_traits>\n";
  o += p_->prelude;
  o += "static void* const* nfceval_tbl_;\n"
       "template <class T> T&& nfceval_fwd(typename std::remove_reference<T>::type& t) { return static_cast<T&&>(t); }\n";
  o += fns;
  if (!is_void) o += "typedef " + r_type + " nfceval_R;\n";
  o += is_void ? "static void nfceval_body(void* const* nfceval_t) {\n" : "static nfceval_R nfceval_body(void* const* nfceval_t) {\n";
  o += refs;
  o += "#line 1 \"snippet\"\n";
  o += wrap_body(code, is_void);
  o += "\n#line 1 \"nfceval-generated\"\n";
  // not reached when the snippet returns; the condition keeps the compiler from warning about unreachable code
  if (!is_void) o += "  if (nfceval_tbl_) throw std::runtime_error(\"snippet did not return a value\");\n  __builtin_unreachable();\n";
  o += "}\n";
  o += "static void nfceval_msg(char* d, unsigned long n, const char* m) {\n"
       "  if (n == 0) return;\n  std::strncpy(d, m, n - 1);\n  d[n - 1] = 0;\n}\n";
  o += "extern \"C\" int nfceval_entry(void* const* t, void* res, char* err, unsigned long errn) {\n"
       "  nfceval_tbl_ = t;\n  (void)res;\n  try {\n";
  o += is_void ? "    nfceval_body(t);\n" : "    ::new (res) nfceval_R(nfceval_body(t));\n";
  o += "    return 0;\n"
       "  } catch (const std::exception& e) {\n    nfceval_msg(err, errn, e.what());\n    return 1;\n"
       "  } catch (...) {\n    nfceval_msg(err, errn, \"unknown exception\");\n    return 1;\n  }\n}\n";
  return o;
}

void Engine::run(const std::string& code, const std::string& r_type, void* result) {
  std::string src = generate(code, r_type);
  Loaded l = p_->load(p_->cache_key(src), src);
  std::vector<void*> table;
  for (const detail::Slot& s : p_->slots)
    for (void* w : s.words) table.push_back(w);
  table.push_back(nullptr);
  char err[2048];
  err[0] = 0;
  if (l.entry(table.data(), result, err, sizeof err) != 0) throw RuntimeError(err);
}

unsigned Engine::compiles() const { return p_->compiles; }
unsigned Engine::loads() const { return p_->loads; }
const std::string& Engine::cache_dir() const {
  static thread_local std::string s;
  s = p_->cache_dir();
  return s;
}

}  // namespace nfceval
