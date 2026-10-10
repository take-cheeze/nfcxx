// Path B, hosted: exceptions thrown from libstdc++.so's system-level classes reach EDG handlers through the EH shim
// (lib/ehshim, docs/notes/eh-shim.md): std::system_error (std::thread::join) and std::ios_base::failure (a stream with
// an exception mask). The exit code is the number of wrong results. (std::promise/future: tests/ehshim, Path B cannot
// compile std::atomic_flag yet.)
// EXPECT: 0
// STDOUT: same
#include <ios>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <cstdio>
#include <cstring>

static int bad;
#define CHECK(c) do { if (!(c)) { bad++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main()
{
  try { std::thread t; t.join(); CHECK(false); }
  catch (const std::system_error &e) { CHECK(e.code() == std::errc::invalid_argument); }

  try {
    std::istringstream in("x");
    in.exceptions(std::ios_base::failbit);
    int i;
    in >> i;
    CHECK(false);
  } catch (const std::ios_base::failure &) { }

  std::printf("bad=%d\n", bad);
  return bad;
}
