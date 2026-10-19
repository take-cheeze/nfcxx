// STD: c++14
// PAPER: N3778
// EXPECT: 0
#include <stddef.h>
#include <stdlib.h>
size_t released=0;
struct A { int x; static void* operator new(size_t n) { return malloc(n); } static void operator delete(void* p,size_t n) noexcept { released=n; free(p); } };
int main() { A* p=new A; p->x=89; int n=p->x; delete p; return n!=89 || released!=sizeof(A); }
