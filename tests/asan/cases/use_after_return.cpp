// ASAN: stack-use-after-scope
int *leak_ptr;
int main(int argc, char **) {
  {
    int local = 5;
    leak_ptr = &local;
  }
  return *leak_ptr + argc;
}
