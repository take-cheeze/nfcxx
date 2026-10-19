#include "sqlcache.hpp"

#include <sqlite3.h>

#include <cstddef>
#include <ctime>
#include <stdexcept>

namespace nfcxx {
namespace {

std::int64_t now() { return static_cast<std::int64_t>(std::time(nullptr)); }

[[noreturn]] void fail(sqlite3* db, const char* what) {
  throw std::runtime_error(std::string("sqlcache: ") + what + ": " + sqlite3_errmsg(db));
}

sqlite3_stmt* prepare(sqlite3* db, const char* sql) {
  sqlite3_stmt* stmt = nullptr;
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) != SQLITE_OK) fail(db, "prepare");
  return stmt;
}

// Runs STMT to completion (after its bindings are set) and resets it for the next use.
void run(sqlite3* db, sqlite3_stmt* stmt) {
  int rc = sqlite3_step(stmt);
  sqlite3_reset(stmt);
  sqlite3_clear_bindings(stmt);
  if (rc != SQLITE_DONE) fail(db, "step");
}

}  // namespace

SqlCache::SqlCache(const std::string& path) {
  if (sqlite3_open_v2(path.c_str(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nullptr) != SQLITE_OK) {
    std::string msg = "sqlcache: open " + path + ": " + sqlite3_errmsg(db_);
    sqlite3_close(db_);  // db_ is set even when the open fails; NULL is accepted too
    db_ = nullptr;
    throw std::runtime_error(msg);
  }
  try {
    // expires_at is Unix seconds, 0 for an entry that never expires.
    char* err = nullptr;
    if (sqlite3_exec(db_,
                     "PRAGMA journal_mode=WAL;"
                     "PRAGMA busy_timeout=5000;"
                     "CREATE TABLE IF NOT EXISTS cache ("
                     "  key TEXT PRIMARY KEY,"
                     "  value BLOB NOT NULL,"
                     "  expires_at INTEGER NOT NULL);",
                     nullptr, nullptr, &err) != SQLITE_OK) {
      std::string msg = std::string("sqlcache: setup: ") + (err ? err : "unknown error");
      sqlite3_free(err);
      throw std::runtime_error(msg);
    }
    get_ = prepare(db_, "SELECT value FROM cache WHERE key = ?1 AND (expires_at = 0 OR expires_at > ?2)");
    put_ = prepare(db_, "INSERT OR REPLACE INTO cache (key, value, expires_at) VALUES (?1, ?2, ?3)");
    erase_ = prepare(db_, "DELETE FROM cache WHERE key = ?1");
    prune_ = prepare(db_, "DELETE FROM cache WHERE expires_at > 0 AND expires_at <= ?1");
  } catch (...) {
    release();
    throw;
  }
}

SqlCache::~SqlCache() { release(); }

void SqlCache::release() noexcept {
  sqlite3_finalize(get_);
  sqlite3_finalize(put_);
  sqlite3_finalize(erase_);
  sqlite3_finalize(prune_);
  sqlite3_close(db_);  // SQLITE_OK or not, the connection is gone after this
  get_ = put_ = erase_ = prune_ = nullptr;
  db_ = nullptr;
}

std::optional<std::string> SqlCache::get(std::string_view key) {
  sqlite3_bind_text(get_, 1, key.data(), static_cast<int>(key.size()), SQLITE_TRANSIENT);
  sqlite3_bind_int64(get_, 2, now());
  int rc = sqlite3_step(get_);
  std::optional<std::string> value;
  if (rc == SQLITE_ROW) {
    const void* data = sqlite3_column_blob(get_, 0);
    int size = sqlite3_column_bytes(get_, 0);
    value.emplace(data ? std::string(static_cast<const char*>(data), static_cast<std::size_t>(size)) : std::string());
  } else if (rc != SQLITE_DONE) {
    sqlite3_reset(get_);
    sqlite3_clear_bindings(get_);
    fail(db_, "get");
  }
  sqlite3_reset(get_);
  sqlite3_clear_bindings(get_);
  return value;
}

void SqlCache::put(std::string_view key, std::string_view value, std::int64_t ttl_seconds) {
  std::int64_t expires_at = ttl_seconds > 0 ? now() + ttl_seconds : 0;
  sqlite3_bind_text(put_, 1, key.data(), static_cast<int>(key.size()), SQLITE_TRANSIENT);
  sqlite3_bind_blob64(put_, 2, value.data(), static_cast<sqlite3_uint64>(value.size()), SQLITE_TRANSIENT);
  sqlite3_bind_int64(put_, 3, expires_at);
  run(db_, put_);
}

bool SqlCache::erase(std::string_view key) {
  sqlite3_bind_text(erase_, 1, key.data(), static_cast<int>(key.size()), SQLITE_TRANSIENT);
  run(db_, erase_);
  return sqlite3_changes(db_) > 0;
}

std::int64_t SqlCache::prune() {
  sqlite3_bind_int64(prune_, 1, now());
  run(db_, prune_);
  return sqlite3_changes(db_);
}

}  // namespace nfcxx
