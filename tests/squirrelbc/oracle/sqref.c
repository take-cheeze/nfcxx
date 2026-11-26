/* sqref: the reference result of a Squirrel 3.2 program, from the reference VM (libsquirrel_static).
 *
 *   sqref FILE.nut | FILE.cnut
 *
 * A .cnut (the stream of `sq -c`, tag 0xFAFA) is loaded with sq_readclosure, a .nut is compiled with sq_compilebuffer.
 * The closure runs with the root table as `this`. The result is printed the way the lowered programs print theirs
 * (tests/squirrelbc/runtime/driver.c): an integer as %lld, a boolean as true or false, null as null, one line. A runtime
 * error prints `error: MESSAGE` with the message alone and exits 1. Exit 2: the file cannot be read or compiled. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "squirrel.h"

static SQInteger read_file(SQUserPointer up, SQUserPointer buf, SQInteger size) {
  return (SQInteger)fread(buf, 1, (size_t)size, (FILE *)up);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s FILE.nut|FILE.cnut\n", argv[0]);
    return 2;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 2;
  }
  unsigned char head[2] = {0, 0};
  size_t got = fread(head, 1, 2, f);
  int is_stream = got == 2 && head[0] == 0xFA && head[1] == 0xFA;
  fseek(f, 0, SEEK_SET);

  HSQUIRRELVM v = sq_open(1024);
  sq_pushroottable(v);
  if (is_stream) {
    if (SQ_FAILED(sq_readclosure(v, read_file, f))) {
      fprintf(stderr, "%s: sq_readclosure refused the stream\n", argv[1]);
      return 2;
    }
  } else {
    /* Compile from memory: the buffer is the whole file. */
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
      fprintf(stderr, "%s: cannot read\n", argv[1]);
      return 2;
    }
    buf[n] = 0;
    if (SQ_FAILED(sq_compilebuffer(v, buf, (SQInteger)n, argv[1], SQTrue))) {
      fprintf(stderr, "%s: compile error\n", argv[1]);
      return 2;
    }
    free(buf);
  }
  fclose(f);
  /* Stack: the closure, then the root table, which becomes the `this` argument. */
  sq_pushroottable(v);
  if (SQ_FAILED(sq_call(v, 1, SQTrue, SQTrue))) {
    const SQChar *msg = "unknown error";
    sq_getlasterror(v);
    if (SQ_SUCCEEDED(sq_tostring(v, -1))) sq_getstring(v, -1, &msg);
    printf("error: %s\n", msg);
    sq_close(v);
    return 1;
  }
  switch (sq_gettype(v, -1)) {
    case OT_INTEGER: {
      SQInteger i = 0;
      sq_getinteger(v, -1, &i);
      printf("%lld\n", (long long)i);
      break;
    }
    case OT_BOOL: {
      SQBool b = SQFalse;
      sq_getbool(v, -1, &b);
      printf("%s\n", b ? "true" : "false");
      break;
    }
    case OT_NULL:
      printf("null\n");
      break;
    default:
      printf("(not printed: type %d)\n", (int)sq_gettype(v, -1));
      break;
  }
  sq_close(v);
  return 0;
}
