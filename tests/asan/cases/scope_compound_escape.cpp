// ASAN: stack-use-after-scope
// A compound literal lives as long as its enclosing block, like a local: a pointer kept past the block reads it after
// the block's end.
int *p;
int main(int argc, char **) {
  {
    p = (int[]){1 + argc, 2, 3};
  }
  return p[0];
}
