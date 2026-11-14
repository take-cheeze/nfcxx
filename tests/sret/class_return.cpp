// libstdc++ and libc++ export functions that return a class by value (std::filesystem::path, file_status, std::string and
// std::wstring here). On Linux aarch64 and macOS their result goes through x8; the gcc backend gets it from EDG's C generator
// (docs/notes/aarch64-class-return.md), Path B from (sret ...). The EH shim's own current_exception keeps the EDG convention.
// Each check returns 1 when it fails.
#include <filesystem>
#include <cstdio>
#include <exception>
#include <sstream>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;

int main() {
  fs::path cwd = fs::current_path();
  fs::path abs = fs::absolute("x");
  fs::path wc = fs::weakly_canonical(".");
  fs::path tmp = fs::temp_directory_path();
  bool dir = fs::is_directory(".");
  fs::file_status st = fs::status(".");
  int failed = 0;
  auto check = [&](bool ok, const char* what) {
    if (!ok) { std::printf("FAIL %s\n", what); failed = 1; }
  };
  check(cwd.is_absolute(), "current_path is absolute");
  check(abs == cwd / "x", "absolute(\"x\") is cwd / \"x\"");
  check(wc == fs::weakly_canonical(cwd), "weakly_canonical(\".\") is weakly_canonical(cwd)");
  check(!tmp.empty() && tmp.is_absolute(), "temp_directory_path is absolute");
  check(dir, "is_directory(\".\") is true");
  check(fs::is_directory(st) && st.type() == fs::file_type::directory, "status(\".\") is a directory");
  // an 8-byte class that the library still returns through x8 (a C function would return it in x0)
  fs::file_status sy = fs::symlink_status(".");
  check(sy.type() == fs::file_type::directory, "symlink_status(\".\") is a directory");
  // 24-byte strings from the library
  check(std::to_string(42) == "42", "to_string(int)");
  check(std::to_string(123456789012LL) == "123456789012", "to_string(long long)");
  check(std::to_string(3.5) == "3.500000", "to_string(double)");
  check(std::to_wstring(7) == L"7", "to_wstring(int)");
  { std::ostringstream os; os << "x" << 5; check(os.str() == "x5", "ostringstream::str"); }
  check(fs::relative("/usr/lib", "/usr") == "lib", "relative(\"/usr/lib\", \"/usr\")");
  // the shim's current_exception and rethrow_exception
  std::exception_ptr ep;
  try { throw std::runtime_error("boom"); } catch (...) { ep = std::current_exception(); }
  bool caught = false;
  try { std::rethrow_exception(ep); } catch (const std::runtime_error& e) { caught = std::string(e.what()) == "boom"; }
  check(caught, "current_exception and rethrow_exception");
  return failed;
}
