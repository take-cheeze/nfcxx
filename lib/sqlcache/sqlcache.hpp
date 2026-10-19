// sqlcache: a string-keyed cache kept in one SQLite file. It backs run-time caches of tools built by nfcxx
// (scripts/setup-sqlite.sh builds SQLite; tests/sqlite/run.sh covers the library).
//
//   nfcxx::SqlCache cache("cache.db");
//   cache.put("key", "value", /*ttl_seconds=*/3600);   // 0 keeps the entry until erase()
//   if (auto v = cache.get("key")) use(*v);            // empty when absent or expired
//
// The file is in WAL mode with a busy timeout, so several processes can share it. One SqlCache is one connection:
// SQLite serializes calls on it (SQLITE_THREADSAFE=1), so threads may share one object, but they take turns.
#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

struct sqlite3;
struct sqlite3_stmt;

namespace nfcxx {

class SqlCache {
public:
  // Opens PATH, creating the file and its table when they are missing. Throws std::runtime_error when SQLite cannot
  // open or set up the file.
  explicit SqlCache(const std::string& path);
  ~SqlCache();
  SqlCache(const SqlCache&) = delete;
  SqlCache& operator=(const SqlCache&) = delete;

  // The value stored under KEY, unless there is none or it has expired.
  std::optional<std::string> get(std::string_view key);
  // Stores VALUE under KEY, replacing an earlier value. TTL_SECONDS > 0 makes the entry expire that many seconds from
  // now; 0 or less keeps it until erase().
  void put(std::string_view key, std::string_view value, std::int64_t ttl_seconds = 0);
  // Removes KEY, expired or not; false when no entry was there.
  bool erase(std::string_view key);
  // Deletes the expired entries and returns how many.
  std::int64_t prune();

private:
  void release() noexcept;

  sqlite3* db_ = nullptr;
  sqlite3_stmt* get_ = nullptr;
  sqlite3_stmt* put_ = nullptr;
  sqlite3_stmt* erase_ = nullptr;
  sqlite3_stmt* prune_ = nullptr;
};

}  // namespace nfcxx
