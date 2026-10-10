// A pseudo-random mix of throws, nested handlers, "throw;", exception_ptr captures, rethrows from a pool of stored
// pointers, releases in any order, and throw_with_nested. The program prints a checksum of what the handlers saw; it must
// equal the host g++'s (whose exceptions are the reference), and all exception objects must be destroyed at the end.
// The exit code is 0 when the objects balance.
// BACKENDS: gcc qbe pathb
// EXPECT: 0
#include <exception>
#include <stdexcept>
#include <string>
#include <vector>
#include <cstdio>

#ifndef SEED
#define SEED 88172645463325252ULL
#endif
static unsigned long long seed = SEED;
static unsigned rnd(unsigned n)
{
  seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
  return (unsigned)(seed % n);
}

static int live;          // exception objects alive
static unsigned long sum; // what the handlers saw

struct Err : std::exception {
  int id;
  std::string text;       // short strings point into the object
  explicit Err(int i) : id(i), text("e" + std::to_string(i)) { live++; }
  Err(const Err &o) : std::exception(o), id(o.id), text(o.text) { live++; }
  ~Err() { live--; }
  const char *what() const noexcept override { return text.c_str(); }
};
struct Err2 : Err { explicit Err2(int i) : Err(i + 1000) {} };

static std::vector<std::exception_ptr> pool(16);
static int next_id;

static void see(const Err &e) { sum = sum * 31 + (unsigned long)e.id + (e.text.size() << 8); }

static void step(int depth)
{
  int actions = 1 + (int)rnd(4);
  for (int a = 0; a < actions; a++) {
    switch (rnd(9)) {
    case 0:   // throw and catch here, maybe keep a pointer
      try { if (rnd(2)) throw Err(next_id++); else throw Err2(next_id++); }
      catch (const Err &e) { see(e); if (rnd(2)) pool[rnd(16)] = std::current_exception(); }
      break;
    case 1:   // rethrow a stored pointer, catch it here
      if (pool[rnd(16)]) {
        std::exception_ptr p = pool[rnd(16)];
        if (!p) break;
        try { std::rethrow_exception(p); }
        catch (const Err &e) { see(e); }
      }
      break;
    case 2:   // release a slot
      pool[rnd(16)] = nullptr;
      break;
    case 3:   // a nested handler level
      if (depth < 6) {
        try { step(depth + 1); }
        catch (const Err &e) {
          see(e);
          switch (rnd(4)) {
          case 0: break;                                                        // swallow
          case 1: if (rnd(2)) pool[rnd(16)] = std::current_exception(); break;  // keep a pointer, swallow
          case 2: try { throw; } catch (const Err &again) { see(again); } break; // rethrow and catch inside
          default: throw;                                                       // pass it up
          }
        }
      }
      break;
    case 4:   // throw out of this level
      if (depth > 0) {
        if (rnd(2)) throw Err(next_id++);
        std::exception_ptr p = pool[rnd(16)];
        if (p) std::rethrow_exception(p);
      }
      break;
    case 5:   // nested exception: the one being handled is attached to a new one
      try {
        try { throw Err(next_id++); }
        catch (...) { std::throw_with_nested(Err2(next_id++)); }
      } catch (const Err &outer) {
        see(outer);
        try { std::rethrow_if_nested(outer); }
        catch (const Err &inner) { see(inner); }
      }
      break;
    case 6:   // make_exception_ptr
      pool[rnd(16)] = std::make_exception_ptr(Err(next_id++));
      break;
    case 7:   // copy and compare pointers
      {
        std::exception_ptr q = pool[rnd(16)];
        std::exception_ptr r = q;
        sum = sum * 31 + (q == r ? 1 : 2);
      }
      break;
    default:  // a handler that throws a different exception while one is stored
      try { throw Err(next_id++); }
      catch (const Err &e) {
        see(e);
        try { throw Err2(next_id++); } catch (const Err &e2) { see(e2); }
        std::exception_ptr keep = std::current_exception();   // still the first one
        try { std::rethrow_exception(keep); } catch (const Err &e3) { see(e3); }
      }
      break;
    }
  }
}

int main()
{
  for (int round = 0; round < 400; round++) {
    try { step(0); }
    catch (const Err &e) { see(e); }
  }
  for (auto &p : pool) p = nullptr;
  std::printf("sum=%lu ids=%d live=%d\n", sum, next_id, live);
  return live;
}
