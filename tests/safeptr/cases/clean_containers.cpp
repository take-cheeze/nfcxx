// Programs that are correct run unchanged: containers, strings, exceptions, one-past-the-end iterators.
// EXPECT: 0
#include <map>
#include <string>
#include <vector>
#include <stdexcept>
#include <cstdio>
#include <cstring>
struct Node { int v; Node *next; };
static int walk(const int *b, const int *e) { int s = 0; while (b != e) s += *b++; return s; }
int main() {
  std::vector<int> v;
  for (int i = 0; i < 1000; i++) v.push_back(i);
  long s = 0;
  for (int x : v) s += x;
  if (s != 499500) return 1;
  std::string t = "hello";
  for (int i = 0; i < 50; i++) t += " world";
  if (t.size() != 5 + 50 * 6) return 2;
  std::map<std::string, int> m;
  for (int i = 0; i < 100; i++) m[std::to_string(i)] = i;
  if (m["42"] != 42) return 3;
  int a[10];
  for (int i = 0; i < 10; i++) a[i] = i;
  if (walk(a, a + 10) != 45) return 4;
  Node n3{3, nullptr}, n2{2, &n3}, n1{1, &n2};
  int k = 0;
  for (Node *p = &n1; p; p = p->next) k += p->v;
  if (k != 6) return 5;
  try { v.at(5000); return 6; } catch (const std::out_of_range &) {}
  char buf[32];
  std::snprintf(buf, sizeof buf, "%d-%s", 7, "x");
  if (std::strcmp(buf, "7-x") != 0) return 7;
  int *h = new int[100];
  for (int i = 0; i < 100; i++) h[i] = i;
  int *end = h + 100;
  if (end - h != 100) return 8;
  delete[] h;
  return 0;
}
