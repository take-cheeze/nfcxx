#pragma once
// A template with a local class and a lambda: each unit that instantiates it has the same local entities (one COMDAT
// group each), and the link must merge them.
template <class T> int tfun(T x) {
  struct L { int v; int get() const { return v * 2; } };
  auto lam = [](int y) { return y + 1; };
  L l{static_cast<int>(x)};
  return l.get() + lam(0);
}
int b_work();
