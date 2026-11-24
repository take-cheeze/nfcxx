/* Calls the lowered main function (lua54_fn_0) and prints its single result the way Lua's tostring does for numbers. */
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

void lua54_fn_0(LV *ret, LV *base);

int main(void) {
  LV ret, base[4096];
  memset(&ret, 0, sizeof ret);
  memset(base, 0, sizeof base);
  lua54_fn_0(&ret, base);
  if (ret.tag == 0x03) {
    printf("%lld\n", (long long)ret.v.i);
  } else if (ret.tag == 0x13) {
    char buf[64];
    snprintf(buf, sizeof buf, "%.14g", ret.v.n);
    if (strspn(buf, "-0123456789") == strlen(buf)) strcat(buf, ".0");
    printf("%s\n", buf);
  } else if (ret.tag == 0x00) {
    printf("nil\n");
  } else if (ret.tag == 0x01) {
    printf("false\n");
  } else if (ret.tag == 0x11) {
    printf("true\n");
  } else {
    printf("tag %d\n", ret.tag);
  }
  return 0;
}
