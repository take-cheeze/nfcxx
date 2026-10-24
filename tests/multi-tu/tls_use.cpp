// extern thread_local across translation units (tls_def.cpp), on two threads: each thread starts from the initial
// values. Exits 0 when every value is the expected one.
#include <cstdio>
#include <string>
#include <thread>
struct Pod { int a, b; };
extern thread_local int counter;
extern thread_local Pod pod;
extern thread_local std::string name;
extern thread_local std::string folded;
int bump_counter();
static int check(int id) {
  counter += id;
  pod.a += id;
  name += std::to_string(id);
  folded += std::to_string(id);
  int b = bump_counter();
  bool good = b == 101 + id && counter == 101 + id && pod.a == 1 + id && pod.b == 2 && name == "tl-name" + std::to_string(id) &&
              folded == "folded" + std::to_string(id);
  std::printf("t%d counter %d pod %d/%d name %s %s%s\n", id, counter, pod.a, pod.b, name.c_str(), folded.c_str(), good ? "" : " BAD");
  return good ? 0 : 1;
}
int main() {
  int r1 = 0, r2 = 0;
  std::thread t1([&] { r1 = check(1); });
  t1.join();
  std::thread t2([&] { r2 = check(2); });
  t2.join();
  return r1 | r2 | check(0);
}
