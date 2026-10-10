// Exceptions thrown inside libstdc++ (std::__throw_*, called from the library's inline code and from libstdc++.so
// itself) are caught by EDG-compiled handlers: lib/ehshim/nfcxx_eh_shim.cpp, docs/notes/eh-shim.md. The exit code is the
// number of wrong results.
// EXPECT: 0
#include <array>
#include <bitset>
#include <deque>
#include <exception>
#include <functional>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>
#include <cstdio>
#include <cstring>

static int bad;
#define CHECK(c) do { if (!(c)) { bad++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

struct Guard { int *n; ~Guard() { ++*n; } };

// run f; report the exception it throws as: 0 none, else the matching code
template <class F> static int kind(F f)
{
  try { f(); }
  catch (const std::out_of_range &) { return 1; }
  catch (const std::invalid_argument &) { return 2; }
  catch (const std::length_error &) { return 3; }
  catch (const std::domain_error &) { return 4; }
  catch (const std::range_error &) { return 5; }
  catch (const std::overflow_error &) { return 6; }
  catch (const std::underflow_error &) { return 7; }
  catch (const std::logic_error &) { return 8; }
  catch (const std::runtime_error &) { return 9; }
  catch (const std::bad_function_call &) { return 10; }
  catch (const std::bad_optional_access &) { return 11; }
  catch (const std::bad_variant_access &) { return 12; }
  catch (const std::bad_alloc &) { return 13; }
  catch (const std::bad_cast &) { return 14; }
  catch (const std::exception &) { return 99; }
  return 0;
}

int main()
{
  // inline library code calling std::__throw_*
  std::vector<int> v(3);
  CHECK(kind([&] { (void)v.at(7); }) == 1);
  std::string s("abc");
  CHECK(kind([&] { (void)s.at(10); }) == 1);
  CHECK(kind([&] { (void)s.substr(5); }) == 1);
  std::array<int, 2> a{};
  CHECK(kind([&] { (void)a.at(2); }) == 1);
  std::deque<int> dq(2);
  CHECK(kind([&] { (void)dq.at(2); }) == 1);
  std::map<int, int> m;
  CHECK(kind([&] { (void)m.at(1); }) == 1);
  std::string_view sv("abc");
  CHECK(kind([&] { (void)sv.at(3); }) == 1);
  CHECK(kind([] { (void)std::stoi("x"); }) == 2);
  CHECK(kind([] { (void)std::stoi("99999999999999999999"); }) == 1);
  CHECK(kind([] { (void)std::stod("zz"); }) == 2);
  CHECK(kind([] { std::bitset<4> b("12"); }) == 2);
  CHECK(kind([] { std::bitset<4>().set(9); }) == 1);
  CHECK(kind([&] { v.reserve(v.max_size() + 1); }) == 3);
  CHECK(kind([&] { s.reserve(s.max_size() + 1); }) == 3);
  CHECK(kind([&] { s.append(s.max_size(), 'x'); }) == 3);
  std::function<void()> f;
  CHECK(kind([&] { f(); }) == 10);
  std::optional<int> o;
  CHECK(kind([&] { (void)o.value(); }) == 11);
  std::variant<int, double> var(1);
  CHECK(kind([&] { (void)std::get<double>(var); }) == 12);

  // by base class, with the message of the library
  try { (void)v.at(7); CHECK(false); }
  catch (const std::exception &e) { CHECK(std::strstr(e.what(), "vector::_M_range_check") != nullptr); }
  try { (void)std::stoi("x"); CHECK(false); }
  catch (const std::logic_error &e) { CHECK(std::strcmp(e.what(), "stoi") == 0); }
  try { f(); CHECK(false); }
  catch (const std::exception &e) { CHECK(std::strcmp(e.what(), "bad_function_call") == 0); }

  // exceptions raised inside libstdc++.so itself, with frames of the library between throw and catch
  try { std::string big; big.resize(big.max_size() + 1); CHECK(false); }
  catch (const std::length_error &) { }
  try { std::basic_string<char> t("abc"); t.replace(10, 1, "x"); CHECK(false); }
  catch (const std::out_of_range &e) { CHECK(std::strstr(e.what(), "basic_string::replace") != nullptr); }

  // destructors of the frames between the throw and the handler that EDG's runtime knows about run
  int guards = 0;
  try { Guard g{&guards}; (void)v.at(9); }
  catch (const std::out_of_range &) { guards += 10; }
  CHECK(guards == 11);

  // catch (...), rethrow, and a throw out of a handler
  int caught = 0;
  try { try { (void)v.at(9); } catch (...) { caught++; throw; } } catch (const std::out_of_range &) { caught++; }
  CHECK(caught == 2);
  try { try { (void)v.at(9); } catch (const std::out_of_range &) { throw std::runtime_error("second"); } }
  catch (const std::runtime_error &e) { CHECK(std::strcmp(e.what(), "second") == 0); }

  // many in a row: nothing accumulates in the runtime
  int rounds = 0;
  for (int i = 0; i < 2000; i++) {
    try { (void)s.at(100 + i); } catch (const std::out_of_range &) { rounds++; }
  }
  CHECK(rounds == 2000);

  // new failure and bad_cast are EDG's own and keep working
  size_t huge = ~size_t(0) / 2;
  CHECK(kind([&] { delete[] new char[huge]; }) == 13);
  struct A { virtual ~A() {} };
  struct B : A {};
  A aa;
  CHECK(kind([&] { (void)dynamic_cast<B &>(aa); }) == 14);

  std::printf("bad=%d\n", bad);
  return bad;
}
