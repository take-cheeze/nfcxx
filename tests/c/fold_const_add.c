// EXPECT: 42
// A constant plus a sum with a constant, C + (x + C1), as EDG writes nlohmann/json's concat_length: the fold to
// x + (C + C1) wrote into the expression's operand that is the inner sum, and cproc crashed (or lost x)
unsigned long size(void) { return 41; }
unsigned long len(void) { return 1UL + ((size()) + 0UL); }
unsigned long len2(void) { return 2UL + (size() + 3UL) - 4UL; }
int main(void) { return len() == 42 && len2() == 42 ? 42 : 1; }
