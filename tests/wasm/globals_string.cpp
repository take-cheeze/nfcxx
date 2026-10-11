// EXPECT: 212
// A global char array initialized from a string literal (a bytes item), read through a pointer to another global.
char buf[6] = "hello";
char *q = buf;
int main() {
  return q[1] + q[4];   // 'e' + 'o' = 101 + 111 = 212
}
