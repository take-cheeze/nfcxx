// EXPECT: 212
// String literals as data: buf is a global array copied from "hello" (bytes items), msg points at a literal.
// buf[1] + msg[4] is 'e' + 'o' = 101 + 111.
static char buf[6] = "hello";
static const char *msg = "hello";
int main(void) { return buf[1] + msg[4]; }
