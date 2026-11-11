// STD: c++11
// PAPER: N2659
// EXPECT: 0
#include <pthread.h>
thread_local int local=5;
int observed=0;
void* worker(void*) { observed=local; local=11; return 0; }
int main() { local=7; pthread_t t; if (pthread_create(&t,0,worker,0)) return 2; if (pthread_join(t,0)) return 3; return observed!=5 || local!=7; }
