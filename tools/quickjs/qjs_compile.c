/* qjs_compile: compiles a JavaScript file to QuickJS bytecode the way `qjsc -c` does (JS_WRITE_OBJ_BYTECODE, source
 * stripped, debug information kept), and writes the bytes to the output file. It is built against the quickjs library of
 * the same source tree as the reference qjs, so the bytecode version is the one the reader checks.
 *
 *   qjs_compile input.js output.qjsbc
 */
#include <stdio.h>
#include <stdlib.h>

#include "quickjs.h"

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.js output.qjsbc\n", argv[0]);
    return 2;
  }
  FILE *in = fopen(argv[1], "rb");
  if (!in) {
    fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  fseek(in, 0, SEEK_END);
  long n = ftell(in);
  fseek(in, 0, SEEK_SET);
  char *src = malloc((size_t)n + 1);
  if (!src || fread(src, 1, (size_t)n, in) != (size_t)n) {
    fprintf(stderr, "%s: read failed\n", argv[1]);
    return 1;
  }
  src[n] = '\0';
  fclose(in);

  JSRuntime *rt = JS_NewRuntime();
  JSContext *ctx = JS_NewContext(rt);
  JS_SetStripInfo(rt, JS_STRIP_SOURCE);
  JSValue obj = JS_Eval(ctx, src, (size_t)n, argv[1], JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(obj)) {
    JSValue exc = JS_GetException(ctx);
    const char *msg = JS_ToCString(ctx, exc);
    fprintf(stderr, "%s\n", msg ? msg : "compile error");
    return 1;
  }
  size_t len = 0;
  uint8_t *buf = JS_WriteObject(ctx, &len, obj, JS_WRITE_OBJ_BYTECODE);
  if (!buf) {
    fprintf(stderr, "JS_WriteObject failed\n");
    return 1;
  }
  FILE *out = fopen(argv[2], "wb");
  if (!out || fwrite(buf, 1, len, out) != len) {
    fprintf(stderr, "%s: write failed\n", argv[2]);
    return 1;
  }
  fclose(out);
  js_free(ctx, buf);
  JS_FreeValue(ctx, obj);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  free(src);
  return 0;
}
