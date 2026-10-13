// WebGPU runtime for lib/sycl: the backend functions of sycl.hpp over a pipe to tests/sycl/server.cjs, a Node process
// that owns the WebGPU device (Chromium's, through Playwright). This is the only place that knows about the transport: a
// native implementation over webgpu.h (Dawn, wgpu-native) would replace this file and keep the same six operations.
//
// Environment: NFCXX_SYCL_IMAGE  path prefix of the files scripts/sycl-build.sh wrote (PREFIX.wgsl, PREFIX.man)
//              NFCXX_SYCL_SERVER path of server.cjs (default: the NFCXX_SYCL_SERVER_JS macro of the build)
//              NFCXX_SYCL_NODE   the node executable (default `node`)
//
// Protocol (little endian, host to server): u32 op, u32 payload size, payload. An address is a device address: the
// heap byte offset plus heap_base (kernels see the same numbers, and USM pointers have them as their low 32 bits).
//   1 ALLOC    u32 bytes                      -> u32 address (0 when the heap is full)
//   2 WRITE    u32 address, data              (no reply)
//   3 READ     u32 address, u32 bytes         -> the bytes
//   4 DISPATCH u32 g[3], l[3], local bytes, key size, closure size, key, closure   (no reply)
//   5 WAIT                                    -> u32 trap flag (0 when the kernels ran clean)
//   6 FREE     u32 address                    (no reply)
//   7 INFO                                    -> u32 heap size in bytes
// Replies are u32 size, data.
#ifndef NFCXX_SYCL_RT_PIPE_HPP
#define NFCXX_SYCL_RT_PIPE_HPP

#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

namespace sycl {
namespace detail {

inline constexpr unsigned heap_base = 0x10000000u;   // the device address of heap byte 0 (HEAP_BASE in the WGSL)

class rt_pipe {
 public:
  static rt_pipe &get() {
    static rt_pipe r;
    return r;
  }
  unsigned alloc(unsigned bytes) {
    uint32_t p[1] = {bytes};
    send(1, p, sizeof p);
    return reply_u32();
  }
  void write(unsigned off, const void *data, unsigned n) {
    uint32_t h[1] = {off};
    std::string payload((const char *)h, 4);
    payload.append((const char *)data, n);
    send(2, payload.data(), (unsigned)payload.size());
  }
  void read(unsigned off, void *dst, unsigned n) {
    uint32_t p[2] = {off, n};
    send(3, p, sizeof p);
    uint32_t sz = reply_size();
    if (sz != n) fail("short READ reply");
    read_all(dst, n);
  }
  void dispatch(const char *key, const void *closure, unsigned closure_bytes, const unsigned *g, const unsigned *l, unsigned lmem) {
    uint32_t h[9] = {g[0], g[1], g[2], l[0], l[1], l[2], lmem, (uint32_t)std::strlen(key), closure_bytes};
    std::string payload((const char *)h, sizeof h);
    payload.append(key);
    payload.append((const char *)closure, closure_bytes);
    send(4, payload.data(), (unsigned)payload.size());
  }
  unsigned wait() {
    send(5, nullptr, 0);
    return reply_u32();
  }
  void release(unsigned addr) {
    uint32_t p[1] = {addr};
    send(6, p, sizeof p);
  }
  unsigned heap_bytes() {
    send(7, nullptr, 0);
    return reply_u32();
  }

 private:
  rt_pipe() {
    std::signal(SIGPIPE, SIG_IGN);
    const char *prefix = std::getenv("NFCXX_SYCL_IMAGE");
#ifdef NFCXX_SYCL_IMAGE_PREFIX
    if (!prefix) prefix = NFCXX_SYCL_IMAGE_PREFIX;
#endif
    const char *server = std::getenv("NFCXX_SYCL_SERVER");
#ifdef NFCXX_SYCL_SERVER_JS
    if (!server) server = NFCXX_SYCL_SERVER_JS;
#endif
    const char *node = std::getenv("NFCXX_SYCL_NODE");
    if (!node) node = "node";
    if (!prefix || !server) fail("set NFCXX_SYCL_IMAGE (see scripts/sycl-build.sh) and NFCXX_SYCL_SERVER");
    std::string wgsl = std::string(prefix) + ".wgsl", man = std::string(prefix) + ".man";
    int to[2], from[2];
    if (pipe(to) || pipe(from)) fail("pipe");
    pid_ = fork();
    if (pid_ < 0) fail("fork");
    if (pid_ == 0) {
      dup2(to[0], 0);
      dup2(from[1], 1);
      close(to[0]); close(to[1]); close(from[0]); close(from[1]);
      execlp(node, node, server, wgsl.c_str(), man.c_str(), (char *)nullptr);
      std::fprintf(stderr, "sycl: cannot run %s\n", node);
      _exit(127);
    }
    close(to[0]);
    close(from[1]);
    out_ = to[1];
    in_ = from[0];
  }
  ~rt_pipe() {
    if (out_ >= 0) close(out_);
    if (in_ >= 0) close(in_);
    if (pid_ > 0) { int st; waitpid(pid_, &st, 0); }
  }
  [[noreturn]] void fail(const char *why) {
    std::fprintf(stderr, "sycl: WebGPU runtime: %s\n", why);
    std::exit(70);
  }
  void write_all(const void *p, unsigned n) {
    const char *c = (const char *)p;
    while (n) {
      ssize_t k = ::write(out_, c, n);
      if (k <= 0) fail("the WebGPU server exited (see its messages above)");
      c += k; n -= (unsigned)k;
    }
  }
  void read_all(void *p, unsigned n) {
    char *c = (char *)p;
    while (n) {
      ssize_t k = ::read(in_, c, n);
      if (k <= 0) fail("the WebGPU server exited (see its messages above)");
      c += k; n -= (unsigned)k;
    }
  }
  void send(uint32_t op, const void *payload, unsigned n) {
    uint32_t h[2] = {op, n};
    write_all(h, 8);
    if (n) write_all(payload, n);
  }
  uint32_t reply_size() {
    uint32_t sz;
    read_all(&sz, 4);
    return sz;
  }
  uint32_t reply_u32() {
    if (reply_size() != 4) fail("bad reply size");
    uint32_t v;
    read_all(&v, 4);
    return v;
  }
  int out_ = -1, in_ = -1;
  pid_t pid_ = -1;
};

// ---- Unified shared memory. A USM pointer is a host address whose low 32 bits are the device address: the runtime maps an
// arena of the heap's size at a virtual address with low word heap_base (so device byte i is arena[i]) and hands out
// blocks of it that the server also allocated. A kernel that captures such a pointer reads the right device bytes, and the
// host reads and writes the arena directly (the "mirror"). Coherence is by copying: a `shared` or `host` allocation goes
// to the device before a dispatch if the host may have changed it, and comes back at every wait; a `device` allocation
// moves only through memcpy/memset/fill.
struct usm_block {
  void *user;         // the pointer the program got
  unsigned addr;      // the server's block (device address)
  unsigned bytes;     // the block size the server holds (usable from `user`)
  unsigned usable;    // bytes from `user` on
  int kind;           // 0 device, 1 shared, 2 host
};

class usm_state {
 public:
  static usm_state &get() {
    static usm_state u;
    return u;
  }
  void *alloc(unsigned long bytes, unsigned align, int kind) {
    ensure();
    if (align < 16) align = 16;
    unsigned long total = bytes + align;
    unsigned addr = rt_pipe::get().alloc((unsigned)total);
    if (addr == 0) return nullptr;
    unsigned long user_addr = (addr + align - 1) / align * align;
    char *user = arena_ + (user_addr - heap_base);
    blocks_.push_back({user, addr, (unsigned)total, (unsigned)(total - (user_addr - addr)), kind});
    if (kind != 0) host_dirty_ = true;
    return user;
  }
  void release(void *p) {
    for (size_t i = 0; i < blocks_.size(); i++)
      if (blocks_[i].user == p) {
        rt_pipe::get().release(blocks_[i].addr);
        blocks_.erase(blocks_.begin() + (long)i);
        return;
      }
  }
  bool in_arena(const void *p) const { return arena_ && (const char *)p >= arena_ && (const char *)p < arena_ + size_; }
  unsigned addr_of(const void *p) const { return heap_base + (unsigned)((const char *)p - arena_); }
  void *mirror_of(unsigned addr) const { return arena_ + (addr - heap_base); }
  bool any_shared() const {
    for (const usm_block &b : blocks_) if (b.kind != 0) return true;
    return false;
  }
  // before a dispatch: upload the shared and host allocations if the host may have changed them
  void before_dispatch() {
    if (host_dirty_) {
      for (const usm_block &b : blocks_) if (b.kind != 0) rt_pipe::get().write(addr_of(b.user), b.user, b.usable);
      host_dirty_ = false;
    }
    dev_dirty_ = true;
  }
  // after the kernels finished: bring the shared and host allocations back
  void after_wait() {
    if (!dev_dirty_) return;
    for (const usm_block &b : blocks_) if (b.kind != 0) rt_pipe::get().read(addr_of(b.user), b.user, b.usable);
    dev_dirty_ = false;
    host_dirty_ = true;
  }
  void note_host_write() { host_dirty_ = true; }

 private:
  usm_state() {}
  void ensure() {
    if (arena_) return;
    size_ = rt_pipe::get().heap_bytes();
    for (unsigned long k = 0x2000; k < 0x2400; k++) {
      void *hint = (void *)((k << 32) | heap_base);
      void *p = mmap(hint, size_, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED_NOREPLACE, -1, 0);
      if (p == hint) { arena_ = (char *)p; return; }
      if (p != MAP_FAILED) munmap(p, size_);
    }
    std::fprintf(stderr, "sycl: cannot map the USM arena\n");
    std::exit(70);
  }
  char *arena_ = nullptr;
  unsigned long size_ = 0;
  std::vector<usm_block> blocks_;
  bool host_dirty_ = true, dev_dirty_ = false;
};

// ---- the backend functions declared in sycl.hpp
inline void backend_wait_checked() {
  unsigned flag = rt_pipe::get().wait();
  if (flag) {
    static const char *why[] = {"", "integer division by zero or INT_MIN / -1", "shift count out of range", "index out of bounds",
                                "null pointer dereference", "trap or unreachable", "float to integer conversion out of range",
                                "write to the kernel's captured state (it is read-only on the device: a mutable lambda?)"};
    std::fprintf(stderr, "sycl: a kernel trapped: %s\n", flag < 8 ? why[flag] : "unknown");
    std::exit(71);
  }
  usm_state::get().after_wait();
}
inline unsigned backend_dev_offset(buffer_state &s) {
  if (s.dev == 0) {
    s.dev = rt_pipe::get().alloc(s.bytes ? s.bytes : 4);
    if (s.dev == 0) { std::fprintf(stderr, "sycl: out of device memory\n"); std::exit(70); }
    s.dev_valid = false;
  }
  return s.dev;
}
inline void backend_sync_to_host(buffer_state &s) {
  if (s.dev == 0 || s.host_valid) return;
  backend_wait_checked();
  rt_pipe::get().read(s.dev, s.host, s.bytes);
  s.host_valid = true;
}
inline void backend_release(buffer_state &s) {
  if (s.dev) { rt_pipe::get().release(s.dev); s.dev = 0; }
}
inline void backend_dispatch(const char *key, const void *closure, unsigned closure_bytes, const unsigned *g, const unsigned *l,
                             unsigned lmem, buffer_use *uses, int nuses) {
  rt_pipe &r = rt_pipe::get();
  for (int i = 0; i < nuses; i++) {
    buffer_state &s = *uses[i].st;
    if (s.dev == 0) backend_dev_offset(s);
    if (reads(uses[i].mode) && !s.dev_valid) {
      if (s.host_valid) r.write(s.dev, s.host, s.bytes);   // when the host copy is stale the device one is the newer
      s.dev_valid = true;
    }
    if (writes(uses[i].mode)) { s.dev_valid = true; s.host_valid = false; }
  }
  usm_state::get().before_dispatch();
  r.dispatch(key, closure, closure_bytes, g, l, lmem);
}
inline void backend_wait() { backend_wait_checked(); }

inline void *backend_usm_alloc(unsigned long bytes, unsigned align, int kind) { return usm_state::get().alloc(bytes, align, kind); }
inline void backend_usm_free(void *p) { usm_state::get().release(p); }
inline void backend_memcpy(void *dst, const void *src, unsigned long n) {
  usm_state &u = usm_state::get();
  rt_pipe &r = rt_pipe::get();
  if (u.in_arena(src)) { backend_wait_checked(); r.read(u.addr_of(src), (void *)src, (unsigned)n); }
  std::memmove(dst, src, n);
  if (u.in_arena(dst)) { r.write(u.addr_of(dst), dst, (unsigned)n); }
  else if (u.in_arena(src)) {}
}
inline void backend_memset(void *p, int v, unsigned long n) {
  usm_state &u = usm_state::get();
  std::memset(p, v, n);
  if (u.in_arena(p)) rt_pipe::get().write(u.addr_of(p), p, (unsigned)n);
}
inline bool backend_is_usm(const void *p) { return usm_state::get().in_arena(p); }

}  // namespace detail
}  // namespace sycl

#endif
