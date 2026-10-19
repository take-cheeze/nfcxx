// STD: c++11
// PAPER: N2660
// EXPECT: 0
#include <pthread.h>
int constructions=0;
struct A { int value; A():value(73) { ++constructions; } };
A& instance() { static A a; return a; }
void* worker(void*) { return &instance(); }
int main() { pthread_t a,b; void *x=0,*y=0; if(pthread_create(&a,0,worker,0)) return 2; if(pthread_create(&b,0,worker,0)) { pthread_join(a,0); return 3; } if(pthread_join(a,&x)||pthread_join(b,&y)) return 4; return x!=y || constructions!=1 || instance().value!=73; }
