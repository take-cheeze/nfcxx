#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/mrbrt_call.h"

extern void mrb_irep_0(MV *ret);
extern int64_t mrbbc_i64_sum(int64_t, int64_t);
extern int64_t mrbbc_i64_answer(void);
extern int64_t mrbbc_i64v_sum(void *, const int64_t *);
extern int64_t mrbbc_i64v_divide(void *, const int64_t *);
extern int64_t mrbbc_i64v_answer(void *, const int64_t *);
extern int64_t mrbbc_i64v_wrong_result(void *, const int64_t *);
extern int64_t mrbbc_i64v_failed_join(void *, const int64_t *);
extern int64_t mrbbc_i64v_failed_inspect(void *, const int64_t *);
extern int64_t mrbbc_i64v_after_error(void *, const int64_t *);
static int checks;
static void check(int ok, const char *message) {
  if (!ok) { fprintf(stderr, "call ABI: %s\n", message); exit(2); }
  checks++;
}
static NfcCallStatus call(NfcI64Target *target, NfcCallFrame *frame) {
  NfcCallable fn = {mrbbc_call_entry, target};
  return nfc_call_invoke(&fn, frame);
}

/* A second representation, deliberately unrelated to MV and native int64 slots. */
typedef struct OtherValue { int64_t complemented; } OtherValue;
static NfcCallStatus other_read(void *owner, const void *slot, int64_t *out) {
  (void)owner; *out = ~((const OtherValue *)slot)->complemented; return NFC_CALL_OK;
}
static NfcCallStatus other_write(void *owner, void *slot, int64_t value) {
  (void)owner; ((OtherValue *)slot)->complemented = ~value; return NFC_CALL_OK;
}
static const NfcCallCodec other_codec = {other_read, other_write};
static const NfcCallCodec no_codec = {NULL, NULL};
static int native_calls;
static int64_t native_add(int64_t a, int64_t b) { return a + b; }
static int64_t native_vector(void *unused, const int64_t *args) {
  (void)unused; native_calls++; return native_add(args[0], args[1]);
}
static NfcCallStatus bad_count(void *closure, NfcCallFrame *frame) {
  (void)closure; frame->nresults = frame->capacity + 1; return NFC_CALL_OK;
}

/* Nested boxed calls: recover from a Ruby error, then call Ruby again inside the enclosing boundary. */
static int64_t nested(void *unused, const int64_t *args) {
  int64_t out = -1, zero = 0;
  NfcCallSlot inputs[2] = {nfc_call_i64_slot((int64_t *)&args[0]), nfc_call_i64_slot(&zero)};
  NfcCallSlot result = nfc_call_i64_slot(&out);
  NfcCallFrame frame = {NFC_CALL_VERSION, inputs, 2, &result, 1, 0, NULL, {0}};
  NfcI64Target div = {2, mrbbc_i64v_divide, NULL}, sum = {2, mrbbc_i64v_sum, NULL};
  (void)unused;
  check(call(&div, &frame) == NFC_CALL_EXCEPTION, "nested exception status");
  inputs[1] = nfc_call_i64_slot((int64_t *)&args[1]);
  check(call(&sum, &frame) == NFC_CALL_OK, "nested call recovers");
  return out;
}

static void body(MV *ret) {
  MV values[4];
  MrbbcGCFrame roots;
  int64_t out = -1, integer;
  OtherValue other = {~(int64_t)22};
  NfcI64Target sum = {2, mrbbc_i64v_sum, NULL}, div = {2, mrbbc_i64v_divide, NULL};
  NfcI64Target answer = {0, mrbbc_i64v_answer, NULL};
  NfcI64Target native = {2, native_vector, NULL}, bridge = {2, nested, NULL};
  NfcCallSlot args[2], result = nfc_call_i64_slot(&out);
  NfcCallFrame frame = {NFC_CALL_VERSION, args, 2, &result, 1, 0, NULL, {0}};
  NfcCallable native_fn = {nfc_call_i64_entry, &native};
  frame.nargs = 0;
  check(call(&answer, &frame) == NFC_CALL_EXCEPTION, "uninitialized export is not callable");
  frame.nargs = 2;
  mrb_irep_0(ret);
  mrbbc_gc_enter(&roots, values, 4);
  mrbbc_int_new(&values[0], 20);
  mrbbc_int_new(&values[1], 22);
  args[0] = mrbbc_call_slot(&values[0]);
  args[1].codec = &other_codec; args[1].owner = NULL; args[1].data = &other;
  check(mrbbc_i64_sum(20, 22) == 42 && mrbbc_i64_answer() == 42, "typed native exports");
  check(native_add(20, 22) == 42, "direct native C");
  check(call(&sum, &frame) == NFC_CALL_OK && out == 42 && frame.nresults == 1, "mixed representations to Ruby");
  check(nfc_call_invoke(&native_fn, &frame) == NFC_CALL_OK && out == 42, "same frame to native C");
  {
    int before = native_calls;
    result.codec = &no_codec;
    check(nfc_call_invoke(&native_fn, &frame) == NFC_CALL_UNSUPPORTED && native_calls == before, "unsupported result fails before execution");
    result = nfc_call_i64_slot(&out);
    args[1].codec = &no_codec;
    check(nfc_call_invoke(&native_fn, &frame) == NFC_CALL_UNSUPPORTED && native_calls == before, "unsupported input fails before execution");
    args[1].codec = &other_codec;
  }
  check(call(&bridge, &frame) == NFC_CALL_OK && out == 42, "nested C to Ruby calls");
  result = mrbbc_call_slot(&values[2]);
  check(call(&sum, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &integer) && integer == 42, "Ruby boxed result");
  result = args[0];
  check(call(&sum, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[0], &integer) && integer == 42, "aliased result");
  result = nfc_call_i64_slot(&out);
  mrbbc_int_new(&values[0], INT64_MAX);
  other.complemented = ~INT64_C(0);
  check(call(&sum, &frame) == NFC_CALL_OK && out == INT64_MAX, "full-width boxed integer");
  mrbbc_int_new(&values[0], INT64_MIN);
  result = mrbbc_call_slot(&values[2]);
  check(call(&sum, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &integer) && integer == INT64_MIN, "boxed integer result under GC");
  result = nfc_call_i64_slot(&out);
  check(call(&div, &frame) == NFC_CALL_EXCEPTION && frame.nresults == 0 && strstr(frame.error, "ZeroDivisionError"), "Ruby exception returned");
  mrbbc_str_new(&values[0], "bad", 3);
  check(call(&sum, &frame) == NFC_CALL_TYPE && frame.nresults == 0, "wrong boxed input type");
  frame.nargs = 0;
  {
    int i;
    int64_t (*failures[])(void *, const int64_t *) = {mrbbc_i64v_wrong_result, mrbbc_i64v_failed_join, mrbbc_i64v_failed_inspect};
    for (i = 0; i < 3; i++) {
      NfcI64Target fail = {0, failures[i], NULL};
      check(call(&fail, &frame) == NFC_CALL_EXCEPTION && frame.nresults == 0, "error through buffered callback");
      check(call(&answer, &frame) == NFC_CALL_OK && out == 42 && frame.error[0] == '\0', "call after an exception");
      mrbbc_gc_collect();
    }
    NfcI64Target inspect = {0, mrbbc_i64v_after_error, NULL};
    check(call(&inspect, &frame) == NFC_CALL_OK && out > 0, "inspect state restored");
  }
  check(call(&sum, &frame) == NFC_CALL_ARITY, "argument count");
  frame.capacity = 0;
  check(call(&answer, &frame) == NFC_CALL_ARITY, "result capacity");
  frame.capacity = 1; frame.version = 0;
  check(call(&answer, &frame) == NFC_CALL_INVALID, "ABI version");
  frame.version = NFC_CALL_VERSION;
  {
    NfcCallable bad = {bad_count, NULL};
    check(nfc_call_invoke(&bad, &frame) == NFC_CALL_INVALID && frame.nresults == 0, "invalid callee result count");
  }
  result.data = NULL;
  check(call(&answer, &frame) == NFC_CALL_INVALID, "invalid result pointer");
  check(nfc_call_invoke(NULL, &frame) == NFC_CALL_INVALID, "invalid callable");
  check(nfc_call_invoke(&native_fn, NULL) == NFC_CALL_INVALID, "null frame");
  mrbbc_gc_leave(&roots);
}
int main(void) {
  MV ret = {0};
  mrbbc_run(body, &ret);
  printf("boxed/direct call ABI: %d checks passed\n", checks);
  return 0;
}
