// lib/sqlcache on the SQLite build: round trips, binary values, expiry and prune, erase, reopen, and a failed open.
// Exit 0 when every check passes; tests/sqlite/run.sh builds this with nfcxx on each backend.
#include "../../lib/sqlcache/sqlcache.hpp"

#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

static int failures = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::printf("FAIL line %d: %s\n", __LINE__, #cond);                 \
      ++failures;                                                         \
    }                                                                     \
  } while (0)

int main() {
  char dir[] = "/tmp/sqlcache-test-XXXXXX";
  if (!mkdtemp(dir)) {
    std::printf("FAIL mkdtemp\n");
    return 1;
  }
  std::string path = std::string(dir) + "/cache.db";

  {
    nfcxx::SqlCache cache(path);

    CHECK(!cache.get("missing").has_value());

    cache.put("k", "v1");
    CHECK(cache.get("k") == std::optional<std::string>("v1"));
    cache.put("k", "v2");  // replaces
    CHECK(cache.get("k") == std::optional<std::string>("v2"));

    // Values are bytes: an embedded NUL and an empty value both round-trip.
    std::string bin("a\0b\xff", 4);
    cache.put("bin", bin);
    CHECK(cache.get("bin") == std::optional<std::string>(bin));
    cache.put("empty", "");
    CHECK(cache.get("empty") == std::optional<std::string>(""));

    // A TTL expires the entry; prune() removes it and reports one row.
    cache.put("short", "gone soon", 1);
    CHECK(cache.get("short").has_value());
    std::this_thread::sleep_for(std::chrono::milliseconds(2100));
    CHECK(!cache.get("short").has_value());
    CHECK(cache.prune() == 1);
    CHECK(cache.prune() == 0);
    CHECK(cache.get("k") == std::optional<std::string>("v2"));  // entries without a TTL stay

    CHECK(cache.erase("k"));
    CHECK(!cache.erase("k"));
    CHECK(!cache.get("k").has_value());

    // Keys are compared as bytes, not as C strings.
    cache.put(std::string_view("a\0x", 3), "nul-key");
    CHECK(cache.get(std::string_view("a\0x", 3)) == std::optional<std::string>("nul-key"));
    CHECK(!cache.get("a").has_value());
  }

  {
    // The entries survive closing the file.
    nfcxx::SqlCache again(path);
    CHECK(again.get("bin") == std::optional<std::string>(std::string("a\0b\xff", 4)));
    CHECK(!again.get("k").has_value());
  }

  bool threw = false;
  try {
    nfcxx::SqlCache bad(std::string(dir) + "/no-such-dir/cache.db");
  } catch (const std::runtime_error&) {
    threw = true;
  }
  CHECK(threw);

  std::string cleanup = std::string("rm -rf ") + dir;
  (void)std::system(cleanup.c_str());

  if (failures == 0) std::printf("ok   sqlcache\n");
  return failures ? 1 : 0;
}
