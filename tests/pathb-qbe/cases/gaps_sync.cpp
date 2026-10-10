// EXPECT: 0
// STDOUT: same
// C++20 synchronization and utilities: shared_mutex, latch, barrier, counting_semaphore, scoped_lock, jthread / stop_token,
// pmr monotonic_buffer_resource, valarray, hash, put_time, locale("C"), system_clock <-> time_t. Over-aligned
// statics (alignas(64) in libstdc++'s waiter pools) and slots. Output compared with gcc.
#include <atomic>
#include <barrier>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <functional>
#include <iomanip>
#include <iostream>
#include <latch>
#include <locale>
#include <memory_resource>
#include <mutex>
#include <semaphore>
#include <shared_mutex>
#include <sstream>
#include <stop_token>
#include <string>
#include <thread>
#include <valarray>
#include <vector>

int main() {
  std::valarray<double> va = {1, 2, 3, 4};
  va *= 2;
  std::printf("valarray %g %g\n", va.sum(), va[3]);
  std::printf("hash %d %d\n", (int)(std::hash<std::string>()("abc") == std::hash<std::string>()("abc")), (int)(std::hash<int>()(5) == 5));

  alignas(64) std::byte buf[512];
  std::pmr::monotonic_buffer_resource mr(buf, sizeof buf);
  std::pmr::vector<int> pv(&mr);
  for (int i = 0; i < 20; i++) pv.push_back(i);
  std::printf("pmr %zu %d aligned %d\n", pv.size(), pv[19], (int)(((unsigned long)buf & 63) == 0));

  std::shared_mutex sm;
  int shared = 0;
  std::latch done(3);
  std::vector<std::thread> ts;
  for (int i = 0; i < 3; i++)
    ts.emplace_back([&, i] {
      for (int k = 0; k < 100; k++) {
        if (i == 0) { std::unique_lock l(sm); shared++; }
        else { std::shared_lock l(sm); (void)shared; }
      }
      done.count_down();
    });
  done.wait();
  for (auto &t : ts) t.join();
  std::printf("shared %d\n", shared);

  std::counting_semaphore<4> sem(0);
  std::atomic<int> got{0};
  std::thread a([&] { sem.acquire(); got = 1; });
  sem.release();
  a.join();
  std::printf("semaphore %d\n", got.load());

  std::mutex m1, m2;
  { std::scoped_lock sl(m1, m2); std::printf("scoped_lock\n"); }

  std::barrier bar(2);
  std::thread b([&] { bar.arrive_and_wait(); });
  bar.arrive_and_wait();
  b.join();
  std::printf("barrier\n");

  std::atomic<int> cnt{0};
  {
    std::jthread jt([&](std::stop_token st) {
      while (!st.stop_requested()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
      cnt = 1;
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  std::printf("jthread %d\n", cnt.load());

  std::time_t t = 1700000000;
  std::tm tm = *std::gmtime(&t);
  std::ostringstream os;
  os << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");
  std::printf("put_time %s\n", os.str().c_str());
  std::locale loc("C");
  std::ostringstream os2;
  os2.imbue(loc);
  os2 << std::fixed << std::setprecision(2) << 1234567.891 << " " << std::showpos << 5;
  std::printf("locale %s\n", os2.str().c_str());
  auto tp = std::chrono::system_clock::from_time_t(t);
  std::printf("to_time_t %ld\n", (long)std::chrono::system_clock::to_time_t(tp));
  return 0;
}
