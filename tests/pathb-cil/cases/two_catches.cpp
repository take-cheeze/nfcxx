// EXPECT: 5
// Several catch clauses: the pad's selector compares the thrown typeinfo with each clause's (zero-cost exception tables).
static int k(void) { try { throw 5; } catch (char c) { return 1; } catch (int e) { return e; } }
int main(void) { return k(); }
