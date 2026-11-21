// EXPECT: 42
// A destructor runs while the exception unwinds through its frame (a landing pad), then the caller's handler sees it:
// 40 from the destructor plus the thrown 2.
static int logged = 0;
struct Guard { int v; ~Guard() { logged += v; } };
static void thrower(int x) { Guard g{40}; if (x) throw x; }
static int f(void) { try { thrower(2); } catch (int e) { return logged + e; } return 0; }
int main(void) { return f(); }
