// EXPECT-REFUSED: a section global is not supported
static const int a __attribute__((used, section("tab"))) = 40;
int main(void) { return a; }
