// EXPECT: 0
// STDOUT: same
// <fstream> and <filesystem> against a temp directory, virtual inheritance with dynamic_cast / typeid / bad_cast, exceptions thrown
// and caught in user code (derived from std types, strings, ints, catch-all), std::error_code, strftime. Output compared with gcc.
// (std::current_exception, throw_with_nested and exception_ptr use libstdc++.so exception state, which EDGs runtime does not share.)
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <typeinfo>
#include <stdexcept>
#include <memory>
#include <iomanip>
#include <ctime>
#include <cerrno>
#include <system_error>

struct Base {
  virtual ~Base() {}
  virtual const char *name() const { return "Base"; }
};
struct Mid : virtual Base {
  const char *name() const override { return "Mid"; }
};
struct Other : virtual Base {
  const char *name() const override { return "Other"; }
};
struct Leaf : Mid, Other {
  const char *name() const override { return "Leaf"; }
};

struct MyErr : std::runtime_error {
  int code;
  MyErr(const std::string &m, int c) : std::runtime_error(m), code(c) {}
};

static void thrower(int k) {
  switch (k) {
    case 0: throw MyErr("my error", 7);
    case 1: throw std::logic_error("logic");
    case 2: throw std::string("a string");
    case 3: throw 42;
    case 4: throw std::runtime_error("rt");
    default: break;
  }
}

int main() {
  namespace fs = std::filesystem;
  fs::path dir = fs::temp_directory_path() / "pathb_gaps_io";
  fs::create_directories(dir);
  fs::path file = dir / "a.txt";
  {
    std::ofstream out(file);
    for (int i = 0; i < 5; i++) out << "line " << i << " " << i * 1.5 << "\n";
  }
  std::ifstream in(file);
  std::string line;
  int lines = 0;
  double sum = 0;
  while (std::getline(in, line)) {
    std::istringstream ls(line);
    std::string w;
    int i;
    double d;
    ls >> w >> i >> d;
    sum += d;
    lines++;
  }
  std::printf("lines %d sum %g size %ju exists %d ext %s stem %s\n", lines, sum, (uintmax_t)fs::file_size(file), (int)fs::exists(file),
              file.extension().string().c_str(), file.stem().string().c_str());
  {
    std::ofstream bin(dir / "b.bin", std::ios::binary);
    int vals[4] = {1, 2, 3, 0x7fffffff};
    bin.write((const char *)vals, sizeof vals);
  }
  std::ifstream bin(dir / "b.bin", std::ios::binary);
  int back[4] = {0};
  bin.read((char *)back, sizeof back);
  std::printf("binary %d %d %d %d gcount %ld\n", back[0], back[1], back[2], back[3], (long)bin.gcount());
  int n = 0;
  for (auto &e : fs::directory_iterator(dir)) { (void)e; n++; }
  std::printf("dir entries %d\n", n);
  fs::remove_all(dir);
  std::printf("removed %d\n", (int)!fs::exists(dir));
  std::ifstream missing("/nonexistent/file");
  std::printf("missing open %d\n", (int)missing.is_open());

  // RTTI, virtual inheritance, dynamic_cast
  Leaf leaf;
  Base *b = &leaf;
  Mid *m = dynamic_cast<Mid *>(b);
  Other *o = dynamic_cast<Other *>(b);
  std::printf("rtti %s %s %s %d\n", b->name(), m->name(), o->name(), (int)(dynamic_cast<Leaf *>(b) == &leaf));
  std::printf("typeid %d %d %d\n", (int)(typeid(*b) == typeid(Leaf)), (int)(typeid(leaf) == typeid(Mid)), (int)(std::strlen(typeid(Leaf).name()) > 0));
  try {
    Mid mid;
    Base &bb = mid;
    (void)dynamic_cast<Other &>(bb);
  } catch (const std::bad_cast &) {
    std::printf("bad_cast\n");
  }

  // exceptions thrown by user code
  for (int k = 0; k < 6; k++) {
    try {
      thrower(k);
      std::printf("no throw %d\n", k);
    } catch (const MyErr &e) {
      std::printf("MyErr %s %d\n", e.what(), e.code);
    } catch (const std::logic_error &e) {
      std::printf("logic_error %s\n", e.what());
    } catch (const std::exception &e) {
      std::printf("exception %s\n", e.what());
    } catch (const std::string &s) {
      std::printf("string %s\n", s.c_str());
    } catch (...) {
      std::printf("other %d\n", k);
    }
  }
  // (std::current_exception / throw_with_nested / rethrow_exception use libstdc++.so's own exception state, which EDG's
  // exception runtime does not share: docs/notes/pathb-hosted.md)
  std::error_code ec = std::make_error_code(std::errc::no_such_file_or_directory);
  std::printf("error_code %d %s\n", ec.value(), ec.message().c_str());
  std::time_t t = 86400 * 365;
  std::tm tm = *std::gmtime(&t);
  char buf[64];
  std::strftime(buf, sizeof buf, "%Y-%m-%d %H:%M:%S", &tm);
  std::printf("time %s\n", buf);
  return 0;
}
