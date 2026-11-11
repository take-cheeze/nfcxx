// Standard output: puts, putchar, write to fd 1 and fd 2, and fflush. The page binds them to its Console tab (fd 2 is
// marked [stderr]). The declarations are written out, so the freestanding emscripten mode builds this too. printf is
// not here: the emitter refuses variadic calls (docs/notes/wasm-explorer.md).
extern "C" {
int putchar(int c);
int puts(const char* s);
int write(int fd, const void* buf, unsigned long n);
int fflush(void* stream);
}

int main() {
  puts("hello from puts");
  for (const char* p = "putchar: abc"; *p; ++p)
    putchar(*p);
  putchar('\n');
  const char msg[] = "write to fd 1\n";
  write(1, msg, sizeof(msg) - 1);
  write(2, "to stderr\n", 10);
  fflush(0);
  return 0;
}
