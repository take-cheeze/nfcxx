// STD: c++17
// PAPER: N4266
// EXPECT: 7
// The namespace attribute only: attributes on enumerators are rejected by the front end (not yet a passing probe).
namespace [[deprecated]] ns { enum E { a = 7 }; }
int main() { return ns::a; }
