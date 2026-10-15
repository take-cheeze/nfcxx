// libstdc++ and libc++ export functions that return a class by value (std::filesystem::path here). On Linux aarch64 and
// macOS their result goes through x8, and scripts/sret.sh bridges it. Each check returns 1 when it fails.
#include <filesystem>
#include <cstdio>

namespace fs = std::filesystem;

int main() {
  fs::path cwd = fs::current_path();
  fs::path abs = fs::absolute("x");
  fs::path wc = fs::weakly_canonical(".");
  fs::path tmp = fs::temp_directory_path();
  int failed = 0;
  auto check = [&](bool ok, const char* what) {
    if (!ok) { std::printf("FAIL %s\n", what); failed = 1; }
  };
  check(cwd.is_absolute(), "current_path is absolute");
  check(abs == cwd / "x", "absolute(\"x\") is cwd / \"x\"");
  check(wc == fs::weakly_canonical(cwd), "weakly_canonical(\".\") is weakly_canonical(cwd)");
  check(fs::is_directory(tmp), "temp_directory_path is a directory");
  return failed;
}
