// STD: c++11
// PAPER: N2535
// EXPECT: 0
namespace API { inline namespace V { int value() { return 31; } } }
int main() { return API::value()!=31; }
