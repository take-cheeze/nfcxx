// EXPECT: 0
// BACKENDS: gcc qbe pathb
// Exception handling on several threads at once: each thread runs code with destructors and throws and catches in a
// loop, while the others do the same. EDG's exception handling state (the stack of EH entries, __curr_eh_stack_entry,
// and the throw in progress) is per thread (the runtime's RUNTIME_EH_TLS, the front end's --nfcxx_eh_thread_local).
// When it was one global, the threads pushed and popped each other's entries, and llama.cpp's CPU backend (ggml's
// worker threads) crashed at exit in std::uncaught_exceptions, which libstdc++'s cout flush calls. The exit code is
// the number of wrong results; the flush at exit must not crash.
#include <atomic>
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

static std::atomic<int> live{0};

struct Guard {
  int v;
  explicit Guard(int x) : v(x) { live++; }
  ~Guard() { live--; }
};

static int work(int id, int rounds) {
  int bad = 0;
  for (int i = 0; i < rounds; i++) {
    Guard outer(i);
    try {
      Guard inner(id);
      if ((i + id) % 3 == 0) throw std::runtime_error("odd");
      if ((i + id) % 3 == 1) throw i;
    } catch (const std::runtime_error &e) {
      bad += std::string(e.what()) != "odd";
    } catch (int x) {
      bad += x != i;
    }
    bad += std::uncaught_exceptions() != 0;
  }
  return bad;
}

int main() {
  const int n = 8, rounds = 20000;
  std::vector<int> bad(n, 0);
  std::vector<std::thread> ts;
  for (int t = 0; t < n; t++) ts.emplace_back([&bad, t] { bad[t] = work(t, rounds); });
  for (auto &t : ts) t.join();
  int total = live.load() != 0;
  for (int b : bad) total += b;
  std::cout << "eh threads: " << total << " wrong\n";   // flushed at exit, as llama-simple's output is
  return total;
}
