// EXPECT: 5
// Path B CIL spike: a throw of an int caught in the same function.
static int f(void) { try { throw 5; } catch (int e) { return e; } }
int main(void) { return f(); }
