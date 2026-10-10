// Built with `nfcxx -shared`: uses a hosted libstdc++ type and a global with a constructor.
#include <string>
struct Table { std::string s; Table() : s("abcdef") {} };
static Table table;
extern "C" int probe_mul(int a, int b) { return (int)table.s.size() == 6 ? a * b : -1; }
