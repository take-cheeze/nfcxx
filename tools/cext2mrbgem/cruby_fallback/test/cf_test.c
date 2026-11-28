/* prototype test: boots the embedded CRuby VM, loads the original extension, and calls it through nfcx_cruby_call */
#include <stdio.h>
#include <string.h>
#include "../nfcx_cruby_vm.h"

static int failures = 0;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); failures++; } else printf("ok   %s\n", what); } while (0)

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: cf_test SO_PATH\n"); return 2; }
  char err[512] = "";
  if (nfcx_cruby_boot(argv[1], err, sizeof err)) { printf("boot failed: %s\n", err); return 1; }

  char buf[256];
  nfcx_val ret, in;
  /* integer in, integer out */
  in.tag = NFCX_INT; in.i = 21;
  CHECK(nfcx_cruby_call("CF", "twice", 1, &in, &ret, buf, sizeof buf, err, sizeof err) == 0 && ret.tag == NFCX_INT && ret.i == 42,
        "CF.twice(21) == 42");
  /* string round trip */
  in.tag = NFCX_STR; in.s = "hi"; in.len = 2;
  CHECK(nfcx_cruby_call("CF", "echo", 1, &in, &ret, buf, sizeof buf, err, sizeof err) == 0 && ret.tag == NFCX_STR &&
        ret.len == 2 && memcmp(ret.s, "hi", 2) == 0, "CF.echo(\"hi\") round-trips");
  /* nil and boolean */
  in.tag = NFCX_NIL;
  CHECK(nfcx_cruby_call("CF", "echo", 1, &in, &ret, buf, sizeof buf, err, sizeof err) == 0 && ret.tag == NFCX_NIL,
        "CF.echo(nil) == nil");
  in.tag = NFCX_TRUE;
  CHECK(nfcx_cruby_call("CF", "echo", 1, &in, &ret, buf, sizeof buf, err, sizeof err) == 0 && ret.tag == NFCX_TRUE,
        "CF.echo(true) == true");
  /* two arguments and a float */
  nfcx_val two[2];
  two[0].tag = NFCX_FLOAT; two[0].f = 3.0;
  two[1].tag = NFCX_FLOAT; two[1].f = 2.0;
  CHECK(nfcx_cruby_call("CF", "div", 2, two, &ret, buf, sizeof buf, err, sizeof err) == 0 && ret.tag == NFCX_FLOAT &&
        ret.f == 1.5, "CF.div(3.0, 2.0) == 1.5");
  /* a Ruby exception comes back as an error with its class and message */
  two[0].tag = NFCX_INT; two[0].i = 1;
  two[1].tag = NFCX_INT; two[1].i = 0;
  CHECK(nfcx_cruby_call("CF", "div", 2, two, &ret, buf, sizeof buf, err, sizeof err) != 0 &&
        strstr(err, "ZeroDivisionError") != NULL, "CF.div(1, 0) raises ZeroDivisionError");
  printf("error text: %s\n", err);
  /* a missing method */
  CHECK(nfcx_cruby_call("CF", "nope", 0, NULL, &ret, buf, sizeof buf, err, sizeof err) != 0 &&
        strstr(err, "NoMethodError") != NULL, "CF.nope raises NoMethodError");
  printf(failures ? "prototype test FAILED\n" : "prototype test OK\n");
  return failures ? 1 : 0;
}
