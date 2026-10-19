// STD: c++11
// PAPER: N2347
// EXPECT: 0
enum E : unsigned;
struct A { E value; };
enum E : unsigned { answer=41 };
int main() { A a={answer}; return a.value!=41; }
