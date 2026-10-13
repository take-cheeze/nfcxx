// The part of nfceval that turns a source text into a loaded shared object, without any C++ exceptions or other nfceval types, so
// that other run-time code generators can use it (nfceval itself, and the tier of lib/ast, docs/notes/ast.md): find the nfcxx
// driver, hash a source, keep a per-user cache directory, run the driver in a child process (blocking, or started now and polled
// later), install the result atomically, dlopen it. Header only (everything is inline), so a program may still #include
// nfceval.cpp into its single translation unit (tests/eval/host_single.cpp).
#pragma once
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace nfceval {
namespace build {

// Two FNV-1a 64 passes with different offsets, 32 hex digits.
inline std::string hash_hex(const std::string& s) {
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

inline std::string read_file(const std::string& path) {
  std::string out;
  if (FILE* f = std::fopen(path.c_str(), "rb")) {
    char buf[4096];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
    std::fclose(f);
  }
  return out;
}

inline bool write_file(const std::string& path, const std::string& data) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return false;
  bool ok = std::fwrite(data.data(), 1, data.size(), f) == data.size();
  return std::fclose(f) == 0 && ok;
}

inline bool file_exists(const std::string& p, int mode = F_OK) { return ::access(p.c_str(), mode) == 0; }

// The repository root, given the path of a source file two directories below it (<repo>/lib/<dir>/<file>), as __FILE__ spells it.
// A relative spelling means the repository is the current directory.
inline std::string repo_root_of(const char* anchor_file) {
  std::string f = anchor_file;
  for (int i = 0; i < 3; ++i) {
    std::size_t s = f.rfind('/');
    if (s == std::string::npos) {
      f = i == 2 ? "." : "";
      break;
    }
    f.resize(s);
  }
  return f;
}

// The nfcxx driver: $NFCXX, the compiled-in default, <repo>/nfcxx found from ANCHOR_FILE (the caller's __FILE__), `nfcxx` on PATH.
inline std::string default_driver(const char* anchor_file, const char* compiled_in = nullptr) {
  if (const char* e = std::getenv("NFCXX")) {
    if (*e) return e;
  }
  if (compiled_in && file_exists(compiled_in, X_OK)) return compiled_in;
  std::string f = repo_root_of(anchor_file);
  if (!f.empty() && file_exists(f + "/nfcxx", X_OK)) return f + "/nfcxx";
  return "nfcxx";
}

// The per-user cache directory: $ENV_VAR if set, else $TMPDIR (or /tmp)/LEAF-<uid>.
inline std::string default_cache_dir(const char* env_var, const char* leaf) {
  std::string cache;
  if (const char* e = std::getenv(env_var)) cache = e;
  if (cache.empty()) {
    const char* t = std::getenv("TMPDIR");
    cache = std::string(t && *t ? t : "/tmp") + "/" + leaf + "-" + std::to_string((unsigned long)::getuid());
  }
  return cache;
}

// mkdir -p DIR; shared objects in it are executed, so a directory another user could write to is refused. Returns "" or the error
// text (starting with a lower-case message, no prefix).
inline std::string ensure_cache_dir(const std::string& d) {
  for (std::size_t i = 1; i <= d.size(); ++i) {
    if (i == d.size() || d[i] == '/') {
      std::string part = d.substr(0, i);
      if (::mkdir(part.c_str(), 0700) != 0 && errno != EEXIST) return "cannot create cache directory " + part + ": " + std::strerror(errno);
    }
  }
  struct stat st;
  if (::stat(d.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) return "cache path is not a directory: " + d;
  if (st.st_uid != ::getuid() || (st.st_mode & (S_IWGRP | S_IWOTH)))
    return "cache directory " + d + " must be owned by the current user and not group/world writable";
  return "";
}

inline long now_ms() {
  struct timespec ts;
  ::clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// A driver run in a child process of its own process group (so that a timeout kills the compiler's children too). Its stdout and
// stderr go to LOGFILE. spawn() returns at once; wait() polls or blocks. The exit code is 127 when the driver could not be run.
struct Child {
  pid_t pid = -1;
  long started_ms = 0;
  bool killed = false;  // the timeout expired and the group was killed
  int status = 0;       // once finished: the exit code, -1 killed by the timeout, -2 could not be spawned
  bool finished = false;
};

inline bool spawn(Child& c, const std::vector<std::string>& args, const std::string& logfile) {
  std::vector<char*> argv;
  for (const std::string& a : args) argv.push_back(const_cast<char*>(a.c_str()));
  argv.push_back(nullptr);
  c = Child();
  c.started_ms = now_ms();
  pid_t pid = ::fork();
  if (pid < 0) {
    c.status = -2;
    c.finished = true;
    return false;
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
  c.pid = pid;
  return true;
}

// Looks at the child once (BLOCK: until it ends). Returns true once it has finished (c.status is set). TIMEOUT_S 0: no timeout.
inline bool wait(Child& c, bool block, unsigned timeout_s) {
  if (c.finished) return true;
  for (;;) {
    int ws = 0;
    pid_t r = ::waitpid(c.pid, &ws, WNOHANG);
    if (r == c.pid) {
      c.status = c.killed ? -1 : WIFEXITED(ws) ? WEXITSTATUS(ws) : 128 + (WIFSIGNALED(ws) ? WTERMSIG(ws) : 0);
      c.finished = true;
      return true;
    }
    if (r < 0 && errno != EINTR) {
      // Not ours to wait for any more (the program ignores SIGCHLD, so the child is reaped on its own): it has ended when the process
      // is gone, and its exit status is not known (the caller looks at what it was to make).
      if (errno == ECHILD && (::kill(c.pid, 0) == 0 || errno == EPERM)) {
        if (!block) return false;
      } else {
        c.status = c.killed ? -1 : 0;
        c.finished = true;
        return true;
      }
    }
    if (timeout_s && !c.killed && now_ms() - c.started_ms > (long)timeout_s * 1000) {
      ::kill(-c.pid, SIGKILL);
      c.killed = true;
    }
    if (!block) return false;
    struct timespec ts = {0, 5 * 1000 * 1000};
    ::nanosleep(&ts, nullptr);
  }
}

// Kills a running child (and its group) and reaps it.
inline void abandon(Child& c) {
  if (c.finished || c.pid < 0) return;
  ::kill(-c.pid, SIGKILL);
  int ws = 0;
  while (::waitpid(c.pid, &ws, 0) < 0 && errno == EINTR) {
  }
  c.finished = true;
  c.status = -1;
}

// Runs the driver and waits; returns its output, sets STATUS (exit code, -1 killed by the timeout, -2 spawn failed).
inline std::string run_driver(const std::vector<std::string>& args, const std::string& logfile, unsigned timeout_s, int& status) {
  Child c;
  if (!spawn(c, args, logfile)) {
    status = -2;
    return std::string("fork failed: ") + std::strerror(errno);
  }
  wait(c, true, timeout_s);
  status = c.status;
  return read_file(logfile);
}

// The text for a failed driver run, as nfceval reports it ("compiler timed out after N s", "cannot run the nfcxx driver 'X'" ...).
inline std::string failure_reason(int status, const std::string& driver, unsigned timeout_s) {
  return status == -1 ? "compiler timed out after " + std::to_string(timeout_s) + " s"
         : status == 127 ? "cannot run the nfcxx driver '" + driver + "' (set NFCXX or Engine::set_driver)"
                         : "compile failed (driver exit " + std::to_string(status) + ")";
}

// dlopen a shared object and look up SYM. Returns the handle (null with *ERR set) and stores the symbol in *SYM_OUT.
inline void* open_so(const std::string& so, const char* sym, void** sym_out, std::string* err) {
  void* h = ::dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    const char* e = ::dlerror();
    *err = std::string("dlopen failed: ") + (e ? e : "?");
    return nullptr;
  }
  void* s = ::dlsym(h, sym);
  if (!s) {
    ::dlclose(h);
    *err = so + " has no " + sym;
    return nullptr;
  }
  *sym_out = s;
  return h;
}

}  // namespace build
}  // namespace nfceval
