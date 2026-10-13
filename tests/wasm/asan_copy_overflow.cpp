// ASAN: stack-buffer-overflow
// An 8-byte struct copied to offset 4 of an 8-byte array: the copy (memory.copy) writes 4 bytes past the array.
struct P {
  int x;
  int y;
};
int main() {
  char buf[8];
  P v;
  v.x = 1;
  v.y = 2;
  P* d = (P*)(buf + 4);
  *d = v;
  return 0;
}
