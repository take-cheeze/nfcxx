// EXPECT: 3
// A switch whose arms return: the selector matches a case, not the default.
int main() {
  int x = 2;
  switch (x) { case 2: return 3; default: return 4; }
}
