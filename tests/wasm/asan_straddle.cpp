// ASAN: stack-buffer-overflow
// A 4-byte store that starts inside a 16-byte stack array and ends past it: the check looks at both granules.
int main() {
  char c[16];
  char* p = c;
  *(int*)(p + 14) = 5;
  return 0;
}
