/* prototype test: boots the embedded CRuby VM, loads the original extension, and calls it through nfcx_cruby_call with
 * Marshal bytes at the boundary. The argument bytes are Marshal.dump output written out by hand. Literals are split where a
 * hex escape would otherwise take the next character as a hex digit. */
#include <stdio.h>
#include <string.h>
#include "../nfcx_cruby_vm.h"

static int failures = 0;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); failures++; } else printf("ok   %s\n", what); } while (0)

/* calls recv.meth(args...) and compares the returned Marshal bytes with want (wlen bytes) */
static int call_eq(const char *recv, const char *meth, int argc, const char *const *args, const size_t *lens,
                   const char *want, size_t wlen, char *err, size_t errlen) {
  char buf[256];
  size_t n = 0;
  if (nfcx_cruby_call(recv, meth, argc, args, lens, buf, sizeof buf, &n, err, errlen)) return 0;
  return n == wlen && memcmp(buf, want, n) == 0;
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: cf_test SO_PATH\n"); return 2; }
  char err[512] = "";
  if (nfcx_cruby_boot(argv[1], err, sizeof err)) { printf("boot failed: %s\n", err); return 1; }

  /* Marshal.dump(21) = 04 08 i 1a (21 + 5 = 26); Marshal.dump(42) = 04 08 i 2f (42 + 5 = 47) */
  const char *a = "\x04\x08i\x1a";
  size_t al = 4;
  const char *want42 = "\x04\x08i\x2f";
  CHECK(call_eq("CF", "twice", 1, &a, &al, want42, 4, err, sizeof err), "CF.twice(21) == 42");

  /* "hi" as a UTF-8 String: 04 08 I " 07 h i 06 : 06 E T (12 bytes) */
  a = "\x04\x08I\"\x07hi\x06:\x06" "ET";
  al = 12;
  CHECK(call_eq("CF", "echo", 1, &a, &al, a, al, err, sizeof err), "CF.echo(\"hi\") round-trips");

  /* nil: 04 08 0 ; true: 04 08 T */
  a = "\x04\x08" "0";
  al = 3;
  CHECK(call_eq("CF", "echo", 1, &a, &al, a, al, err, sizeof err), "CF.echo(nil) == nil");
  a = "\x04\x08" "T";
  al = 3;
  CHECK(call_eq("CF", "echo", 1, &a, &al, a, al, err, sizeof err), "CF.echo(true) == true");

  /* 3.0 / 2.0 = 1.5: Float is 04 08 f len digits (len = 3 + 5 = 8 for "1.5") */
  const char *two[2] = {"\x04\x08" "f\x06" "3", "\x04\x08" "f\x06" "2"};
  size_t twol[2] = {6, 6};
  const char *want15 = "\x04\x08" "f\x08" "1.5";
  CHECK(call_eq("CF", "div", 2, two, twol, want15, 7, err, sizeof err), "CF.div(3.0, 2.0) == 1.5");

  /* 1 / 0 raises ZeroDivisionError */
  const char *zero[2] = {"\x04\x08i\x06", "\x04\x08i\x00"};
  size_t zl[2] = {4, 4};
  char buf[256];
  size_t n = 0;
  CHECK(nfcx_cruby_call("CF", "div", 2, zero, zl, buf, sizeof buf, &n, err, sizeof err) != 0 &&
        strstr(err, "ZeroDivisionError") != NULL, "CF.div(1, 0) raises ZeroDivisionError");
  printf("error text: %s\n", err);

  /* a missing method */
  CHECK(nfcx_cruby_call("CF", "nope", 0, NULL, NULL, buf, sizeof buf, &n, err, sizeof err) != 0 &&
        strstr(err, "NoMethodError") != NULL, "CF.nope raises NoMethodError");
  /* handles: CF::Counter.new(5) keeps its state in CRuby; "#<index>" dispatches to it */
  long hid = -1;
  const char *five = "\x04\x08i\x0a";
  size_t fivel = 4;
  CHECK(nfcx_cruby_handle_new("CF::Counter", "new", 1, &five, &fivel, &hid, err, sizeof err) == 0 && hid == 0,
        "CF::Counter.new(5) makes handle 0");
  char hpath[16];
  snprintf(hpath, sizeof hpath, "#%ld", hid);
  const char *three = "\x04\x08i\x08";
  size_t threel = 4;
  const char *want8 = "\x04\x08i\x0d";
  CHECK(call_eq(hpath, "add", 1, &three, &threel, want8, 4, err, sizeof err), "handle 0 .add(3) == 8 (state kept in CRuby)");
  const char *ten = "\x04\x08i\x0f";
  size_t tenl = 4;
  const char *want18 = "\x04\x08i\x17";
  CHECK(call_eq(hpath, "add", 1, &ten, &tenl, want18, 4, err, sizeof err), "handle 0 .add(10) == 18");
  CHECK(nfcx_cruby_handle_release(hid, err, sizeof err) == 0, "handle 0 released");
  CHECK(nfcx_cruby_call(hpath, "add", 1, &three, &threel, buf, sizeof buf, &n, err, sizeof err) != 0 &&
        strstr(err, "released") != NULL, "a call on the released handle fails");
  printf(failures ? "prototype test FAILED\n" : "prototype test OK\n");
  return failures ? 1 : 0;
}
