// A thread-local in a module without --threads: the module is one thread, so the object is an ordinary static (one copy).
// EXPECT: 3
thread_local int t = 3;
int main() { return t; }
