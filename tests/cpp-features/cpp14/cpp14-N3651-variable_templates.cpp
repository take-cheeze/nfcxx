// STD: c++14
// PAPER: N3651
// EXPECT: 0
template<class T> constexpr T answer=T(79);
int main() { return answer<int>!=79 || answer<long>!=79; }
