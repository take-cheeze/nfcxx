template <class T> struct Box { T v; T get() const { return v; } };
template <class T> T id(T x) { return x; }
Box<int> bi;
int use() { return id(3); }
