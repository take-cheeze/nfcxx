// Real-world check: doctest v2.4.12 (MIT, single header) driven by a small test file.
// Built by tests/realworld/run_doctest.sh with nfcxx on the hosted path (not --freestanding).
//
// EXPECT: exit code 2. Two CHECKs below fail on purpose (tagged "deliberate failure"); every other
// assertion passes. main() returns the failed-assertion count that doctest reports to a listener,
// so the exit code is the count, not a pass/fail flag.
#define DOCTEST_CONFIG_IMPLEMENT
#include "doctest/doctest.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

// Reads the run statistics at the end of the run: doctest's Context::run() only returns
// EXIT_FAILURE or EXIT_SUCCESS, so the count comes from the listener.
int g_failed_asserts = -1;

struct FailCount : doctest::IReporter {
  explicit FailCount(const doctest::ContextOptions&) {}
  void report_query(const doctest::QueryData&) override {}
  void test_run_start() override {}
  void test_run_end(const doctest::TestRunStats& s) override { g_failed_asserts = s.numAssertsFailed; }
  void test_case_start(const doctest::TestCaseData&) override {}
  void test_case_reenter(const doctest::TestCaseData&) override {}
  void test_case_end(const doctest::CurrentTestCaseStats&) override {}
  void test_case_exception(const doctest::TestCaseException&) override {}
  void subcase_start(const doctest::SubcaseSignature&) override {}
  void subcase_end() override {}
  void log_assert(const doctest::AssertData&) override {}
  void log_message(const doctest::MessageData&) override {}
  void test_case_skipped(const doctest::TestCaseData&) override {}
};

}  // namespace

REGISTER_LISTENER("failcount", 1, FailCount);

TEST_CASE("integers and recursion") {
  CHECK(fib(1) == 1);
  CHECK(fib(10) == 55);
  REQUIRE(fib(0) == 0);
  SUBCASE("small") { CHECK(fib(2) == 1); }
  SUBCASE("larger") { CHECK(fib(12) == 144); }
}

TEST_CASE("strings and containers") {
  std::string s = "doctest";
  CHECK(s.size() == 7);
  REQUIRE(!s.empty());
  SUBCASE("append") {
    s += "!";
    CHECK(s == "doctest!");
  }
  SUBCASE("sorted vector") {
    std::vector<int> v{3, 1, 2};
    std::sort(v.begin(), v.end());
    CHECK(v[0] == 1);
    CHECK(v.back() == 3);
  }
  SUBCASE("map") {
    std::map<std::string, int> m{{"a", 1}, {"b", 2}};
    CHECK(m.size() == 2);
    CHECK(m["b"] == 2);
  }
}

TEST_CASE("exceptions") {
  CHECK_THROWS_AS(throw std::runtime_error("boom"), std::runtime_error);
  CHECK_NOTHROW(fib(3));
  CHECK_FALSE(fib(4) == 4);
}

TEST_CASE("deliberate failures") {
  CHECK(std::strcmp("abc", "abd") == 0);  // deliberate failure 1
  CHECK(fib(5) == 6);                     // deliberate failure 2
  CHECK(std::strlen("nfcxx") == 5);
}

int main(int argc, char** argv) {
  doctest::Context ctx;
  ctx.setOption("no-colors", true);
  ctx.applyCommandLine(argc, argv);
  ctx.run();
  if (g_failed_asserts < 0) return 255;  // the listener did not run
  return g_failed_asserts;
}
