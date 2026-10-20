#include "nested.h"

namespace outer {
namespace inner {
class Widget {
public:
  typedef unsigned long size_type;
  enum class Mode { Off, On };
  struct Node { int v; Node *next; };
  Widget() = default;
  explicit Widget(int n);
  static Widget make(int n) { return Widget(n); }
  int value;
  int first, second;
  static constexpr int limit = 8;
};
union U { int i; float f; };
}
}

struct Plain { double x; };
extern int g_count;
namespace outer { using Alias = inner::Widget; }
void helper(int a, const char *b);
