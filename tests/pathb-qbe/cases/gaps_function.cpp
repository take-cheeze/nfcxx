// EXPECT: 0
// STDOUT: same
// libstdc++ facilities on Path B: std::function (lambdas, functors, member pointers, std::bind, empty, recursion),
// std::unique_ptr (deleters, arrays, release/reset/swap), std::shared_ptr / weak_ptr (make_shared, aliasing, custom
// deleter, enable_shared_from_this, use counts), all with destructor-order output compared against the gcc backend.
#include <cstdio>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

struct Tracer {
  std::string name;
  explicit Tracer(std::string n) : name(std::move(n)) { std::printf("ctor %s\n", name.c_str()); }
  Tracer(const Tracer &o) : name(o.name + "'") { std::printf("copy %s\n", name.c_str()); }
  Tracer(Tracer &&o) noexcept : name(std::move(o.name)) { std::printf("move %s\n", name.c_str()); }
  ~Tracer() { std::printf("dtor %s\n", name.c_str()); }
  int value() const { return (int)name.size(); }
};

struct Adder {
  int base;
  int operator()(int x) const { return base + x; }
};

struct Widget {
  int v = 3;
  int get() const { return v; }
  int add(int d) { v += d; return v; }
};

static int twice(int x) { return 2 * x; }

struct Node : std::enable_shared_from_this<Node> {
  std::vector<std::shared_ptr<Node>> kids;
  std::weak_ptr<Node> parent;
  int id;
  explicit Node(int i) : id(i) {}
  ~Node() { std::printf("node %d gone\n", id); }
  std::shared_ptr<Node> add(int i) {
    auto k = std::make_shared<Node>(i);
    k->parent = shared_from_this();
    kids.push_back(k);
    return k;
  }
};

int main() {
  // std::function
  std::function<int(int)> f = [](int x) { return x + 1; };
  std::printf("lambda %d\n", f(41));
  f = Adder{10};
  std::printf("functor %d\n", f(5));
  f = twice;
  std::printf("fn ptr %d\n", f(21));
  int captured = 100;
  f = [captured](int x) mutable { captured += x; return captured; };
  int m1 = f(1);
  int m2 = f(2);
  std::printf("mutable %d %d\n", m1, m2);
  std::function<int(Widget &, int)> m = &Widget::add;
  std::function<int(const Widget &)> g = &Widget::get;
  Widget w;
  int mw = m(w, 4);
  std::printf("member %d %d\n", mw, g(w));
  auto bound = std::bind(&Widget::add, &w, std::placeholders::_1);
  std::function<int(int)> bf = bound;
  std::printf("bind %d\n", bf(10));
  std::function<int(int)> empty;
  std::printf("empty %d\n", (int)(bool)empty);
  // (calling it would throw std::bad_function_call from libstdc++.so, which EDG's exception runtime cannot catch: docs/notes/pathb-hosted.md)
  std::function<int(int)> fact = [&fact](int n) { return n <= 1 ? 1 : n * fact(n - 1); };
  std::printf("fact %d\n", fact(10));
  {
    Tracer t("cap");
    std::function<int()> h = [t] { return t.value(); };
    std::function<int()> h2 = h;
    int h1v = h();
    std::printf("tracer fn %d %d\n", h1v, h2());
  }
  std::vector<std::function<int(int)>> fs;
  for (int k = 0; k < 4; k++) fs.push_back([k](int x) { return x * k; });
  int sum = 0;
  for (auto &fn : fs) sum += fn(7);
  std::printf("vec %d\n", sum);

  // unique_ptr
  {
    auto u = std::make_unique<Tracer>("u1");
    std::unique_ptr<Tracer> v = std::move(u);
    std::printf("moved %d %d\n", (int)(bool)u, v->value());
    v.reset(new Tracer("u2"));
    Tracer *raw = v.release();
    std::printf("released %s\n", raw->name.c_str());
    delete raw;
    auto arr = std::make_unique<int[]>(5);
    for (int i = 0; i < 5; i++) arr[i] = i * i;
    std::printf("arr %d\n", arr[4]);
    auto del = [](Tracer *p) { std::printf("custom delete %s\n", p->name.c_str()); delete p; };
    std::unique_ptr<Tracer, decltype(del)> c(new Tracer("u3"), del);
    std::unique_ptr<Tracer, decltype(del)> c2(new Tracer("u4"), del);
    c.swap(c2);
    std::printf("swapped %s %s\n", c->name.c_str(), c2->name.c_str());
  }

  // shared_ptr / weak_ptr
  {
    auto s = std::make_shared<Tracer>("s1");
    std::weak_ptr<Tracer> wp = s;
    {
      std::shared_ptr<Tracer> s2 = s;
      std::printf("count %ld\n", s.use_count());
      std::shared_ptr<int> alias(s2, (int *)nullptr);
      std::printf("alias count %ld\n", s.use_count());
    }
    std::printf("count after %ld expired %d\n", s.use_count(), (int)wp.expired());
    s.reset();
    std::printf("expired %d lock %d\n", (int)wp.expired(), (int)(bool)wp.lock());
    std::shared_ptr<Tracer> d(new Tracer("s2"), [](Tracer *p) { std::printf("shared deleter %s\n", p->name.c_str()); delete p; });
    std::shared_ptr<int[]> sa(new int[3]{1, 2, 3});
    std::printf("shared arr %d\n", sa[2]);
  }
  {
    auto root = std::make_shared<Node>(1);
    auto c1 = root->add(2);
    auto c2 = c1->add(3);
    std::printf("tree %d %d %d parent %d\n", root->id, c1->id, c2->id, c2->parent.lock()->id);
    std::printf("counts %ld %ld %ld\n", root.use_count(), c1.use_count(), c2.use_count());
  }
  std::printf("done\n");
  return 0;
}
