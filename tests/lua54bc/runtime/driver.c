/* Runs the lowered main function (lua54_fn_0) and prints its results the way Lua's print does: tab-separated, with
 * integers as %lld, floats as %.14g (with ".0" when integral), strings as their bytes, and booleans and nil by name. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct LV {
  uint8_t tag;
  uint8_t pad[7];
  union {
    int64_t i;
    double n;
    void *p;
  } v;
} LV;

/* The header of a collected object, then the string (lua54rt.c's LString). */
typedef struct GCObj {
  struct GCObj *next;
  size_t size;
  uint8_t kind;
  uint8_t marked;
} GCObj;

typedef struct LString {
  GCObj gc;
  size_t len;
  char bytes[1];
} LString;

void lua54_fn_0(LV *ret, LV *base, void *cl);
void *lua54rt_make_main(void *fn, int nupvals);
int lua54rt_run_main(void *cl, LV *out, int outsize);
void lua54rt_close_state(void);

/* The main chunk of luac has one upvalue, _ENV. */
#define MAIN_UPVALUES 1

static void print_value(const LV *v) {
  switch (v->tag) {
    case 0x03: printf("%lld", (long long)v->v.i); break;
    case 0x13: {
      char buf[64];
      snprintf(buf, sizeof buf, "%.14g", v->v.n);
      if (strspn(buf, "-0123456789") == strlen(buf)) strcat(buf, ".0");
      printf("%s", buf);
      break;
    }
    case 0x04: {
      const LString *s = (const LString *)v->v.p;
      fwrite(s->bytes, 1, s->len, stdout);
      break;
    }
    case 0x00: printf("nil"); break;
    case 0x01: printf("false"); break;
    case 0x11: printf("true"); break;
    default: printf("(not printed: tag %d)", v->tag); break;
  }
}

int main(void) {
  LV out[256];
  void *cl = lua54rt_make_main((void *)lua54_fn_0, MAIN_UPVALUES);
  int n = lua54rt_run_main(cl, out, 256);
  for (int k = 0; k < n; ++k) {
    if (k > 0) printf("\t");
    print_value(&out[k]);
  }
  printf("\n");
  lua54rt_close_state();   /* lua.c's lua_close: the finalizers of the objects still alive run now */
  return 0;
}
