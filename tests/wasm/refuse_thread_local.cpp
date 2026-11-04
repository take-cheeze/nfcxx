// REFUSE: thread-local global
// Without --threads the module is one thread with one memory: a thread-local object is refused where it is used.
thread_local int t = 3;
int main() { return t; }
