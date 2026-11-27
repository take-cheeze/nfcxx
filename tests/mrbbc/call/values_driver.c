#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/mrbrt_call.h"
extern void mrb_irep_0(MV *);
static int checks, released, called, partial_releases;
static void check(int ok, const char *message) {
  if (!ok) { fprintf(stderr, "shared values: %s\n", message); exit(2); }
  checks++;
}
typedef struct Object { int refs; } Object;
static NfcCallStatus retain(void *object) { ((Object *)object)->refs++; return NFC_CALL_OK; }
static void release(void *object) { if (--((Object *)object)->refs == 0) { free(object); released++; } }
static const NfcHandleOps object_ops = {"test.Object", retain, release};
static NfcCallStatus echo(void *closure, const NfcValue *args, size_t nargs, NfcValue *out) {
  (void)closure; (void)nargs; called++; return nfc_value_copy(out, &args[0]);
}
static void partial_free(void *data) { partial_releases++; free(data); }
static NfcCallStatus partial_read(void *owner, const void *slot, NfcValue *out) {
  (void)owner; (void)slot;
  if (nfc_value_set_data(out, NFC_VALUE_BYTES, "partial", 7) != NFC_CALL_OK) return NFC_CALL_EXCEPTION;
  out->as.buffer.release = partial_free; return NFC_CALL_TYPE;
}
static const NfcCallCodec partial_codec = {NULL, NULL, partial_read, NULL};
static int bytes_equal(const NfcValue *value, NfcValueKind kind, const char *bytes, size_t size) {
  return value->kind == kind && value->as.buffer.size == size && (!size || !memcmp(value->as.buffer.data, bytes, size));
}
static void body(MV *ret) {
  NfcValue values[3] = {{NFC_VALUE_NONE, {0}}}, out = {NFC_VALUE_NONE, {0}};
  NfcCallSlot args[2] = {nfc_call_value_slot(&values[0]), nfc_call_value_slot(&values[1])};
  NfcCallSlot result = nfc_call_value_slot(&out);
  NfcCallFrame frame = {NFC_CALL_VERSION, args, 1, &result, 1, 0, NULL, {0}};
  NfcValueTarget identity = {1, echo, NULL}, two = {2, echo, NULL};
  NfcCallable native = {nfc_call_value_entry, &identity};
  MrbbcValueTarget ruby = {"echo_value", 1, 0};
  NfcCallable compiled = {mrbbc_value_call_entry, &ruby};
  MV roots[2]; MrbbcGCFrame gc;
  char binary[] = {'a', 0, (char)0xff, 'b'};
  Object *object;
  mrb_irep_0(ret);
  mrbbc_gc_enter(&gc, roots, 2);
  check(nfc_value_set_data(&values[0], NFC_VALUE_BYTES, binary, sizeof binary) == NFC_CALL_OK, "create binary buffer");
  check(nfc_value_copy(&values[1], &values[0]) == NFC_CALL_OK && values[1].as.buffer.data != values[0].as.buffer.data, "buffers copy independently");
  binary[0] = 'z';
  check(values[0].as.buffer.data[0] == 'a', "source storage is not borrowed");
  check(nfc_value_set_data(&values[1], NFC_VALUE_TEXT, binary, sizeof binary) == NFC_CALL_TYPE && values[1].kind == NFC_VALUE_BYTES, "UTF-8 failure preserves destination");
  check(nfc_value_set_data(&values[1], NFC_VALUE_BYTES, NULL, SIZE_MAX) == NFC_CALL_INVALID, "oversized buffer rejected");
  check(!nfc_utf8_valid("\xc0\x80", 2) && !nfc_utf8_valid("\xed\xa0\x80", 3) && !nfc_utf8_valid("\xf4\x90\x80\x80", 4), "overlong/surrogate/out-of-range UTF-8 rejected");
  check(nfc_utf8_valid("日本語\0", sizeof("日本語\0") - 1), "Unicode and embedded NUL accepted");
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_OK && bytes_equal(&out, NFC_VALUE_BYTES, "a\0\xff" "b", 4), "binary Ruby round trip");
  ruby.utf8_result = 1;
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_TYPE && frame.nresults == 0, "Ruby text projection validates UTF-8");
  check(nfc_value_set_data(&values[0], NFC_VALUE_TEXT, "日本語\0text", sizeof("日本語\0text") - 1) == NFC_CALL_OK, "create UTF-8 text");
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_OK && bytes_equal(&out, NFC_VALUE_TEXT, "日本語\0text", sizeof("日本語\0text") - 1), "typed Ruby text result");
  ruby.utf8_result = 0;
  ruby.name = "append_value"; ruby.arity = 2; frame.nargs = 2;
  nfc_value_set_data(&values[0], NFC_VALUE_BYTES, "left", 4); nfc_value_set_data(&values[1], NFC_VALUE_BYTES, "\0right", 6);
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_OK && bytes_equal(&out, NFC_VALUE_BYTES, "left\0right", 10), "boxed Ruby call with two buffers");
  check(bytes_equal(&values[0], NFC_VALUE_BYTES, "left", 4), "Ruby mutation does not modify transport input");
  frame.nargs = 1; ruby.arity = 1; ruby.name = "flip_value";
  nfc_value_clear(&values[0]); values[0].kind = NFC_VALUE_BOOL; values[0].as.boolean = 1;
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_OK && out.kind == NFC_VALUE_BOOL && !out.as.boolean, "boolean Ruby result");
  ruby.name = "echo_value"; nfc_value_clear(&values[0]);
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_OK && out.kind == NFC_VALUE_NONE && frame.nresults == 1, "None is a successful result");
  values[0].kind = NFC_VALUE_F64; values[0].as.f64 = -0.0;
  check(nfc_call_invoke(&native, &frame) == NFC_CALL_OK && out.kind == NFC_VALUE_F64 && signbit(out.as.f64), "double signed zero survives generic calls");
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_UNSUPPORTED, "Ruby runtime refuses unsupported Float explicitly");
  nfc_value_clear(&values[0]); values[0].kind = NFC_VALUE_I64; values[0].as.i64 = INT64_MIN;
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_OK && out.kind == NFC_VALUE_I64 && out.as.i64 == INT64_MIN, "generic full-width Ruby integer");
  values[2].kind = NFC_VALUE_I64; values[2].as.i64 = 17;
  {
    NfcCallSlot alias = nfc_call_i64_slot(&values[2].as.i64);
    check(alias.codec->read_value(alias.owner, alias.data, &values[2]) == NFC_CALL_OK && values[2].as.i64 == 17, "native scalar codec snapshots an aliased destination");
  }
  nfc_value_set_data(&values[0], NFC_VALUE_TEXT, "alias", 5); result = nfc_call_value_slot(&values[0]);
  check(nfc_call_invoke(&native, &frame) == NFC_CALL_OK && bytes_equal(&values[0], NFC_VALUE_TEXT, "alias", 5), "owned argument/result alias");
  result = nfc_call_value_slot(&out);
  object = malloc(sizeof *object); check(object != NULL, "allocate host object"); object->refs = 1;
  check(nfc_value_set_handle(&values[0], &object_ops, object) == NFC_CALL_OK && object->refs == 2, "handle retained");
  release(object);
  ruby.name = "allocate_echo";
  check(nfc_call_invoke(&compiled, &frame) == NFC_CALL_OK && out.kind == NFC_VALUE_HANDLE && out.as.handle.object == object, "foreign handle through allocating Ruby method");
  nfc_value_clear(&values[0]); mrbbc_gc_collect();
  check(object->refs == 1 && !released, "Ruby GC releases its reference but keeps external result alive");
  check(nfc_value_copy(&values[2], &out) == NFC_CALL_OK && object->refs == 2, "copy retains opaque result");
  nfc_value_move(&values[0], &values[2]);
  check(values[2].kind == NFC_VALUE_NONE && object->refs == 2, "move transfers ownership");
  {
    NfcCallable failed = {nfc_call_value_entry, &two};
    int before = called;
    args[1].codec = &partial_codec; args[1].data = &values[1]; frame.nargs = 2;
    check(nfc_call_invoke(&failed, &frame) == NFC_CALL_TYPE && called == before && object->refs == 2 && partial_releases == 1, "partial conversions release buffers and references");
  }
  nfc_value_clear(&values[0]); nfc_value_clear(&out);
  check(released == 1, "final reference releases object exactly once");
  frame.version = 1; frame.nargs = 0;
  check(nfc_call_invoke(&native, &frame) == NFC_CALL_INVALID, "old binary call ABI rejected");
  check(nfc_call_value_entry(&identity, &frame) == NFC_CALL_INVALID, "callee rejects old ABI independently of caller-side validation");
  nfc_values_clear(values, 3); nfc_value_clear(&out);
  mrbbc_gc_leave(&gc);
}
int main(void) { MV ret = {0}; mrbbc_run(body, &ret); printf("shared values: %d checks passed\n", checks); return 0; }
