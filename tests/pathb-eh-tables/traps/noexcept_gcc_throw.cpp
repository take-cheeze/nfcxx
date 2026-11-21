// A throw from g++-compiled code (the helper) that reaches a noexcept function: std::terminate.
int ext_throw(int x);
struct D { ~D() {} };
void noex(int x) noexcept { D d; ext_throw(x); }
int main() { noex(3); return 0; }
