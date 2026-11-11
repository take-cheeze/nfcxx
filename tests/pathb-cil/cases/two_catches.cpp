// EXPECT-REFUSED: several catch clauses
// Several catch clauses need typeinfo matching, which the spike does not have.
static int k(void) { try { throw 5; } catch (char c) { return 1; } catch (int e) { return e; } }
int main(void) { return k(); }
