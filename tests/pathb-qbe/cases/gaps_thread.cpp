// EXPECT: 0
// STDOUT: same
// std::chrono::steady_clock / system_clock / duration arithmetic, std::thread, std::mutex, std::lock_guard,
// std::unique_lock + condition_variable, std::atomic (add, CAS, exchange, memory orders), std::call_once,
// std::this_thread::sleep_for, std::future/std::promise/std::async, thread_local. Output is deterministic.
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

static std::mutex m;
static long counter = 0;
static std::atomic<long> acounter{0};
static thread_local int tls = 0;
static std::once_flag once;
static int once_runs = 0;

int main() {
  using namespace std::chrono;
  auto t0 = steady_clock::now();
  auto s0 = system_clock::now();
  std::this_thread::sleep_for(milliseconds(5));
  auto t1 = steady_clock::now();
  auto dt = duration_cast<microseconds>(t1 - t0).count();
  std::printf("slept enough %d monotonic %d epoch %d\n", (int)(dt >= 4000), (int)(t1 >= t0), (int)(s0.time_since_epoch().count() > 0));
  std::printf("durations %lld %lld %d\n", (long long)duration_cast<milliseconds>(seconds(3)).count(),
              (long long)(milliseconds(1500) + microseconds(500)).count(), (int)(hours(1) == minutes(60)));
  duration<double> half(0.5);
  std::printf("double duration %g %lld\n", half.count(), (long long)duration_cast<milliseconds>(half).count());

  // threads + mutex + atomics
  std::vector<std::thread> ts;
  for (int i = 0; i < 4; i++)
    ts.emplace_back([i] {
      tls = i + 1;
      for (int k = 0; k < 1000; k++) {
        std::lock_guard<std::mutex> g(m);
        counter++;
      }
      for (int k = 0; k < 1000; k++) acounter.fetch_add(2, std::memory_order_relaxed);
      std::call_once(once, [] { once_runs++; });
      if (tls != i + 1) acounter.store(-1000000);
    });
  for (auto &t : ts) t.join();
  std::printf("counter %ld atomic %ld once %d main tls %d\n", counter, acounter.load(), once_runs, tls);

  std::atomic<int> a{5};
  int expected = 5;
  bool ok1 = a.compare_exchange_strong(expected, 9);
  expected = 5;
  bool ok2 = a.compare_exchange_strong(expected, 11);
  int after_cas = a.load();
  int old = a.exchange(3);
  std::printf("cas %d %d %d expected %d exchange %d now %d\n", (int)ok1, (int)ok2, after_cas, expected, old, a.load());
  std::atomic<unsigned char> flags{0};
  flags |= 0x0f;
  flags &= 0x3c;
  flags ^= 0x01;
  std::printf("flags %d\n", (int)flags.load());
  std::atomic_flag af = ATOMIC_FLAG_INIT;
  int f1 = af.test_and_set();
  int f2 = af.test_and_set();
  std::printf("flag %d %d\n", f1, f2);
  std::atomic<long long> wide{1};
  wide.fetch_add(1LL << 40);
  std::printf("wide %lld lockfree %d\n", wide.load(), (int)wide.is_lock_free());

  // condition_variable producer / consumer
  std::mutex qm;
  std::condition_variable cv;
  std::vector<int> queue;
  bool done = false;
  long consumed = 0;
  std::thread consumer([&] {
    std::unique_lock<std::mutex> lk(qm);
    for (;;) {
      cv.wait(lk, [&] { return !queue.empty() || done; });
      while (!queue.empty()) {
        consumed += queue.back();
        queue.pop_back();
      }
      if (done) break;
    }
  });
  for (int i = 1; i <= 100; i++) {
    {
      std::lock_guard<std::mutex> g(qm);
      queue.push_back(i);
    }
    cv.notify_one();
  }
  {
    std::lock_guard<std::mutex> g(qm);
    done = true;
  }
  cv.notify_all();
  consumer.join();
  std::printf("consumed %ld\n", consumed);

  // future / promise / async
  std::promise<int> pr;
  std::future<int> fu = pr.get_future();
  std::thread prod([&pr] { pr.set_value(1234); });
  std::printf("future %d\n", fu.get());
  prod.join();
  auto af2 = std::async(std::launch::async, [](int x) { return x * 3; }, 14);
  std::printf("async %d\n", af2.get());
  auto def = std::async(std::launch::deferred, [] { return 77; });
  std::printf("deferred %d\n", def.get());
  std::printf("hardware >= 1: %d\n", (int)(std::thread::hardware_concurrency() >= 1));
  return 0;
}
