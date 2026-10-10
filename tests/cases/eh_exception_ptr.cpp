// std::exception_ptr, current_exception, rethrow_exception, make_exception_ptr, nested exceptions on EDG's exception
// runtime (lib/ehshim/nfcxx_eh_shim.cpp, docs/notes/eh-shim.md; the runtime keeps an exception alive while a pointer
// refers to it). The exit code is the number of wrong results.
// EXPECT: 0
#include <exception>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
#include <cstdio>
#include <cstring>

// exception_ptr needs hooks in EDG's runtime (take-cheeze/edg-compiler, lib_src/throw.c). With a libC.a that predates
// them std::current_exception returns an empty pointer, and the test reports SKIP.
static bool runtime_supports_exception_ptr()
{
  bool ok = false;
  try { throw 1; } catch (...) { ok = std::current_exception() != nullptr; }
  return ok;
}

static int bad;
#define CHECK(c) do { if (!(c)) { bad++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

// live objects of a type that counts its copies and destructions
struct Counted {
  static int live, made, gone;
  int v;
  explicit Counted(int x) : v(x) { live++; made++; }
  Counted(const Counted &o) : v(o.v) { live++; made++; }
  ~Counted() { live--; gone++; }
};
int Counted::live, Counted::made, Counted::gone;

// a user exception with a std::string member: short strings keep a pointer into the object itself
struct MyErr : std::exception {
  std::string msg;
  explicit MyErr(const char *m) : msg(m) {}
  const char *what() const noexcept override { return msg.c_str(); }
};

struct Guard { int *n; ~Guard() { ++*n; } };

static std::exception_ptr capture_runtime(const char *m)
{
  std::exception_ptr p;
  try { throw std::runtime_error(m); } catch (...) { p = std::current_exception(); }
  return p;
}

[[noreturn]] static void rethrow(const std::exception_ptr &p) { std::rethrow_exception(p); }

static void print_nested(const std::exception &e, std::string &out)
{
  out += e.what();
  try { std::rethrow_if_nested(e); }
  catch (const std::exception &in) { out += "/"; print_nested(in, out); }
}

int main()
{
  if (!runtime_supports_exception_ptr()) { std::puts("SKIP: this EDG runtime (libC.a) has no exception_ptr support"); return 0; }

  // the empty pointer
  {
    std::exception_ptr e;
    CHECK(!e && e == nullptr);
    std::exception_ptr c = std::current_exception();
    CHECK(!c);
  }

  // current_exception in a handler, rethrown later, by type and by base
  {
    std::exception_ptr p = capture_runtime("boom");
    CHECK(p && p != nullptr);
    try { std::rethrow_exception(p); CHECK(false); }
    catch (const std::runtime_error &e) { CHECK(std::strcmp(e.what(), "boom") == 0); }
    try { rethrow(p); CHECK(false); }
    catch (const std::exception &e) { CHECK(std::strcmp(e.what(), "boom") == 0); }
    try { rethrow(p); CHECK(false); }
    catch (...) { }
  }

  // copies share the exception; the object survives the original and lives until the last copy goes
  {
    int live0 = Counted::live;
    std::exception_ptr a, b;
    try { throw Counted(11); } catch (...) { a = std::current_exception(); }
    CHECK(Counted::live == live0 + 1);   // the exception object, no extra copy
    b = a;
    CHECK(a == b && Counted::live == live0 + 1);
    a = nullptr;
    CHECK(!a && b && Counted::live == live0 + 1);
    try { std::rethrow_exception(b); CHECK(false); }
    catch (const Counted &c) { CHECK(c.v == 11); }
    CHECK(Counted::live == live0 + 1);   // still held by b
    std::exception_ptr m = std::move(b);
    CHECK(!b && m);
    m = nullptr;
    CHECK(Counted::live == live0);
  }

  // an exception whose object has a pointer into itself (short std::string) survives the handler
  {
    std::exception_ptr p;
    try { throw MyErr("short"); } catch (...) { p = std::current_exception(); }
    for (int i = 0; i < 5; i++) {   // overwrite the runtime's memory with other throws
      try { throw MyErr("another"); } catch (const MyErr &) { }
    }
    try { std::rethrow_exception(p); CHECK(false); }
    catch (const MyErr &e) { CHECK(e.msg == "short" && std::strcmp(e.what(), "short") == 0); }
  }

  // thrown pointers and scalars
  {
    std::exception_ptr p, q, r;
    try { throw "text"; } catch (...) { p = std::current_exception(); }
    try { throw 42; } catch (...) { q = std::current_exception(); }
    try { throw 2.5; } catch (...) { r = std::current_exception(); }
    try { std::rethrow_exception(p); CHECK(false); } catch (const char *s) { CHECK(std::strcmp(s, "text") == 0); }
    try { std::rethrow_exception(q); CHECK(false); } catch (int i) { CHECK(i == 42); }
    try { std::rethrow_exception(r); CHECK(false); } catch (double d) { CHECK(d == 2.5); }
    try { std::rethrow_exception(q); CHECK(false); } catch (...) { }
  }

  // rethrow_exception inside a handler, and "throw;" after it, picks the right exception
  {
    std::exception_ptr p = capture_runtime("stored");
    int step = 0;
    try {
      try { throw std::logic_error("outer"); }
      catch (const std::logic_error &) {
        try { std::rethrow_exception(p); }
        catch (const std::runtime_error &e) { step += std::strcmp(e.what(), "stored") == 0; }
        throw;   // the logic_error, not the exception just handled
      }
    } catch (const std::logic_error &e) { step += std::strcmp(e.what(), "outer") == 0 ? 10 : 0; }
    CHECK(step == 11);
  }

  // current_exception taken in a nested handler; the enclosing handler's "throw;" still rethrows its own exception
  {
    std::exception_ptr inner;
    int step = 0;
    try {
      try { throw std::logic_error("A"); }
      catch (...) {
        try { throw std::runtime_error("B"); } catch (...) { inner = std::current_exception(); }
        throw;
      }
    } catch (const std::logic_error &e) { step = std::strcmp(e.what(), "A") == 0; }
    CHECK(step == 1);
    try { std::rethrow_exception(inner); } catch (const std::runtime_error &e) { CHECK(std::strcmp(e.what(), "B") == 0); }
  }

  // a stored pointer is the exception being handled, not a previous one
  {
    std::exception_ptr a, b;
    try { throw std::runtime_error("first"); } catch (...) { a = std::current_exception(); }
    try { throw std::runtime_error("second"); } catch (...) { b = std::current_exception(); }
    CHECK(a != b);
    try { std::rethrow_exception(a); } catch (const std::exception &e) { CHECK(std::strcmp(e.what(), "first") == 0); }
    try { std::rethrow_exception(b); } catch (const std::exception &e) { CHECK(std::strcmp(e.what(), "second") == 0); }
    std::exception_ptr c;
    try { std::rethrow_exception(a); } catch (...) { c = std::current_exception(); }
    CHECK(c == a);   // same exception object
  }

  // many pointers alive at once, released in a different order
  {
    int live0 = Counted::live;
    std::vector<std::exception_ptr> v;
    for (int i = 0; i < 300; i++) {
      try { throw Counted(i); } catch (...) { v.push_back(std::current_exception()); }
    }
    CHECK(Counted::live == live0 + 300);
    for (int i = 0; i < 300; i += 2) v[i] = nullptr;   // every other one first
    CHECK(Counted::live == live0 + 150);
    int sum = 0;
    for (int i = 1; i < 300; i += 2) {
      try { std::rethrow_exception(v[i]); } catch (const Counted &c) { sum += c.v; }
    }
    CHECK(sum == 150 * 150);   // 1 + 3 + ... + 299
    for (int i = 299; i >= 0; i--) v[i] = nullptr;
    CHECK(Counted::live == live0);
    // the runtime is intact: ordinary throws still work
    int n = 0;
    for (int i = 0; i < 50; i++) { try { throw i; } catch (int k) { n += k; } }
    CHECK(n == 1225);
  }

  // destructors of the scopes the rethrown exception leaves
  {
    std::exception_ptr p = capture_runtime("guarded");
    int guards = 0;
    try { Guard g1{&guards}; { Guard g2{&guards}; std::rethrow_exception(p); } }
    catch (const std::exception &) { guards += 10; }
    CHECK(guards == 12);
  }

  // make_exception_ptr: a class, a scalar, a pointer, and a derived class sliced to its static type
  {
    int live0 = Counted::live;
    {
      std::exception_ptr a = std::make_exception_ptr(Counted(5));
      std::exception_ptr b = std::make_exception_ptr(std::out_of_range("made"));
      std::exception_ptr c = std::make_exception_ptr(9);
      std::exception_ptr d = std::make_exception_ptr(MyErr("my"));
      CHECK(a && b && c && d);
      CHECK(Counted::live == live0 + 1);
      try { std::rethrow_exception(a); CHECK(false); } catch (const Counted &x) { CHECK(x.v == 5); }
      try { std::rethrow_exception(b); CHECK(false); } catch (const std::logic_error &x) { CHECK(std::strcmp(x.what(), "made") == 0); }
      try { std::rethrow_exception(c); CHECK(false); } catch (int x) { CHECK(x == 9); }
      try { std::rethrow_exception(d); CHECK(false); } catch (const std::exception &x) { CHECK(std::strcmp(x.what(), "my") == 0); }
      try { std::rethrow_exception(b); CHECK(false); } catch (const std::runtime_error &) { CHECK(false); } catch (const std::exception &) { }
    }
    CHECK(Counted::live == live0);
  }

  // make_exception_ptr of pointers: matched by the pointee type, by void *, and by a base class pointer
  {
    struct PB { virtual ~PB() {} };
    struct PD : PB {};
    const char *s = "lit";
    int x = 5;
    PD d;
    std::exception_ptr a = std::make_exception_ptr(s);
    std::exception_ptr b = std::make_exception_ptr(&x);
    std::exception_ptr c = std::make_exception_ptr(&d);
    std::exception_ptr n = std::make_exception_ptr(nullptr);
    try { std::rethrow_exception(a); CHECK(false); } catch (const char *p) { CHECK(std::strcmp(p, "lit") == 0); }
    try { std::rethrow_exception(b); CHECK(false); } catch (int *p) { CHECK(p == &x); }
    try { std::rethrow_exception(b); CHECK(false); } catch (void *p) { CHECK(p == &x); }
    try { std::rethrow_exception(c); CHECK(false); } catch (PB *p) { CHECK(p == &d); }
    try { std::rethrow_exception(n); CHECK(false); } catch (int *p) { CHECK(p == nullptr); }
  }

  // nested exceptions
  {
    std::string out;
    try {
      try {
        try { throw std::runtime_error("c"); }
        catch (...) { std::throw_with_nested(std::logic_error("b")); }
      } catch (...) { std::throw_with_nested(std::invalid_argument("a")); }
    } catch (const std::exception &e) { print_nested(e, out); }
    CHECK(out == "a/b/c");

    // an exception that is not nested: rethrow_if_nested does nothing
    try { throw std::runtime_error("plain"); }
    catch (const std::exception &e) { std::rethrow_if_nested(e); out = "no nested"; }
    CHECK(out == "no nested");

    // nested_exception members; the nested exception is a pointer to the one being handled
    try {
      try { throw std::runtime_error("inner"); }
      catch (...) { std::throw_with_nested(std::logic_error("outer")); }
    } catch (const std::logic_error &e) {
      const std::nested_exception *ne = dynamic_cast<const std::nested_exception *>(&e);
      CHECK(ne != nullptr);
      if (ne) {
        CHECK(ne->nested_ptr() != nullptr);
        try { ne->rethrow_nested(); CHECK(false); }
        catch (const std::runtime_error &in) { CHECK(std::strcmp(in.what(), "inner") == 0); }
      }
    }

    // throw_with_nested outside a handler: the nested pointer is empty
    try { std::throw_with_nested(std::runtime_error("lonely")); }
    catch (const std::exception &e) {
      const std::nested_exception *ne = dynamic_cast<const std::nested_exception *>(&e);
      CHECK(ne && ne->nested_ptr() == nullptr);
    }
  }

  // the runtime is clean afterwards
  CHECK(Counted::live == 0);
  std::printf("bad=%d\n", bad);
  return bad;
}
