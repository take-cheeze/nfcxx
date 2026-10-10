// std::promise, std::future and std::packaged_task with exceptions: future_error thrown by libstdc++.so
// (std::__throw_future_error), broken_promise (an exception_ptr that libstdc++.so makes with make_exception_ptr), and
// user exceptions that travel through the shared state as exception_ptr. No threads: the EDG exception runtime is not
// thread safe. The exit code is the number of wrong results.
// BACKENDS: gcc
// EXPECT: 0
#include <future>
#include <stdexcept>
#include <string>
#include <cstdio>
#include <cstring>

static int bad;
#define CHECK(c) do { if (!(c)) { bad++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main()
{
  try { std::promise<int> p; p.get_future(); p.get_future(); CHECK(false); }
  catch (const std::future_error &e) { CHECK(e.code() == std::future_errc::future_already_retrieved); }

  try { std::promise<int> p; p.set_value(1); p.set_value(2); CHECK(false); }
  catch (const std::future_error &e) { CHECK(e.code() == std::future_errc::promise_already_satisfied); }

  // a promise that dies without a value: the future gets broken_promise
  {
    std::future<int> f;
    { std::promise<int> p; f = p.get_future(); }
    try { f.get(); CHECK(false); }
    catch (const std::future_error &e) { CHECK(e.code() == std::future_errc::broken_promise); }
  }

  // set_exception / get: the exception object travels as an exception_ptr
  {
    std::promise<int> p;
    std::future<int> f = p.get_future();
    try { throw std::runtime_error("via promise"); }
    catch (...) { p.set_exception(std::current_exception()); }
    try { f.get(); CHECK(false); }
    catch (const std::runtime_error &e) { CHECK(std::strcmp(e.what(), "via promise") == 0); }
  }

  // the same through a shared_future, read twice
  {
    std::promise<int> p;
    std::shared_future<int> f = p.get_future().share();
    p.set_exception(std::make_exception_ptr(std::domain_error("shared")));
    for (int i = 0; i < 2; i++) {
      try { f.get(); CHECK(false); }
      catch (const std::domain_error &e) { CHECK(std::strcmp(e.what(), "shared") == 0); }
    }
  }

  // packaged_task: the exception of the callable is stored and rethrown by get
  {
    std::packaged_task<int()> task([]() -> int { throw std::out_of_range("in task"); });
    std::future<int> f = task.get_future();
    task();
    try { f.get(); CHECK(false); }
    catch (const std::out_of_range &e) { CHECK(std::strcmp(e.what(), "in task") == 0); }
  }

  // a value still works
  {
    std::packaged_task<int(int)> task([](int x) { return x * 2; });
    std::future<int> f = task.get_future();
    task(21);
    CHECK(f.get() == 42);
  }

  std::printf("bad=%d\n", bad);
  return bad;
}
