#include "mrbrt_call.h"
#include <stdio.h>
#include <limits.h>

static NfcCallStatus read_i64(void *owner, const void *slot, int64_t *out) {
  (void)owner;
  return mrbbc_int_read(slot, out) ? NFC_CALL_OK : NFC_CALL_TYPE;
}
typedef struct IntegerWrite { MV *slot; int64_t value; } IntegerWrite;
static void write_integer(void *data) {
  IntegerWrite *write = data;
  mrbbc_int_new(write->slot, write->value);
}
static NfcCallStatus write_i64(void *owner, void *slot, int64_t value) {
  IntegerWrite write = {slot, value};
  MrbbcCallError error;
  (void)owner;
  /* This codec can be called inside a foreign C++ frame: do not longjmp over its destructors on allocation failure. */
  return mrbbc_protect(write_integer, &write, &error) ? NFC_CALL_OK : NFC_CALL_EXCEPTION;
}
static NfcCallStatus read_value(void *owner, const void *slot, NfcValue *out) {
  int64_t integer;
  const char *bytes;
  long size;
  void *payload;
  (void)owner;
  switch (mrbbc_tag(slot)) {
    case MRBBC_NIL: nfc_value_clear(out); return NFC_CALL_OK;
    case MRBBC_TRUE:
    case MRBBC_FALSE:
      nfc_value_clear(out); out->kind = NFC_VALUE_BOOL; out->as.boolean = mrbbc_tag(slot) == MRBBC_TRUE; return NFC_CALL_OK;
    case MRBBC_INT:
      mrbbc_int_read(slot, &integer); nfc_value_clear(out); out->kind = NFC_VALUE_I64; out->as.i64 = integer; return NFC_CALL_OK;
    case MRBBC_STR:
      mrbbc_str_view(slot, &bytes, &size); return nfc_value_set_data(out, NFC_VALUE_BYTES, bytes, (size_t)size);
    case MRBBC_FOREIGN:
      payload = mrbbc_foreign_data(slot, &mrbbc_call_codec);
      return payload ? nfc_value_copy(out, payload) : NFC_CALL_UNSUPPORTED;
    default: return NFC_CALL_UNSUPPORTED;
  }
}
static void release_value(void *payload) { nfc_value_clear(payload); free(payload); }
typedef struct ValueWrite { MV *slot; const NfcValue *value; NfcValue *payload; NfcCallStatus status; } ValueWrite;
static void write_value_body(void *data) {
  ValueWrite *write = data;
  const NfcValue *value = write->value;
  switch (value->kind) {
    case NFC_VALUE_NONE: mrbbc_set_nil(write->slot); break;
    case NFC_VALUE_BOOL: mrbbc_set_bool(write->slot, value->as.boolean); break;
    case NFC_VALUE_I64: mrbbc_int_new(write->slot, value->as.i64); break;
    case NFC_VALUE_TEXT:
    case NFC_VALUE_BYTES:
      if (value->as.buffer.size > LONG_MAX) { write->status = NFC_CALL_TYPE; break; }
      mrbbc_str_new(write->slot, (const char *)value->as.buffer.data, (long)value->as.buffer.size); break;
    case NFC_VALUE_HANDLE:
      mrbbc_foreign_new(write->slot, &mrbbc_call_codec, write->payload, release_value);
      write->payload = NULL; break;
    default: write->status = NFC_CALL_UNSUPPORTED; break;
  }
}
static NfcCallStatus write_value(void *owner, void *slot, const NfcValue *value) {
  ValueWrite write = {slot, value, NULL, NFC_CALL_OK};
  MrbbcCallError error;
  NfcCallStatus status;
  (void)owner;
  if (value->kind == NFC_VALUE_HANDLE) {
    write.payload = calloc(1, sizeof *write.payload);
    if (!write.payload) return NFC_CALL_EXCEPTION;
    status = nfc_value_copy(write.payload, value);
    if (status != NFC_CALL_OK) { release_value(write.payload); return status; }
  }
  status = mrbbc_protect(write_value_body, &write, &error) ? write.status : NFC_CALL_EXCEPTION;
  if (write.payload) release_value(write.payload);
  return status;
}
const NfcCallCodec mrbbc_call_codec = {read_i64, write_i64, read_value, write_value};

typedef struct Invocation {
  NfcI64Target *target;
  NfcCallFrame *frame;
  NfcCallStatus status;
} Invocation;
static void invoke(void *data) {
  Invocation *call = data;
  call->status = nfc_call_i64_entry(call->target, call->frame);
}
NfcCallStatus mrbbc_call_entry(void *target, NfcCallFrame *frame) {
  Invocation call = {target, frame, NFC_CALL_INVALID};
  MrbbcCallError error;
  if (!mrbbc_protect(invoke, &call, &error)) {
    char message[sizeof frame->error];
    snprintf(message, sizeof message, "%.80s: %.170s", error.kind, error.message);
    return nfc_call_error(frame, NFC_CALL_EXCEPTION, message);
  }
  return call.status;
}

typedef struct ValueInvocation {
  const MrbbcValueTarget *target;
  const NfcValue *args;
  NfcValue out;
  NfcCallStatus status;
} ValueInvocation;
static void invoke_value(void *data) {
  ValueInvocation *call = data;
  MV values[NFC_CALL_I64_MAX_ARGS + 3];
  MrbbcGCFrame roots;
  size_t i, argc = call->target->arity;
  int id;
  mrbbc_gc_enter(&roots, values, (long)argc + 3);
  for (i = 0; i < argc; i++) {
    call->status = write_value(NULL, &values[i + 1], &call->args[i]);
    if (call->status != NFC_CALL_OK) { mrbbc_gc_leave(&roots); return; }
  }
  id = mrbbc_find(&values[0], call->target->name, (long)argc, 0);
  mrbbc_user_call(id, &values[argc + 1], values, &values[argc + 2], (long)argc);
  if (call->target->utf8_result) {
    const char *bytes; long size;
    call->status = mrbbc_str_view(&values[argc + 1], &bytes, &size) ?
      nfc_value_set_data(&call->out, NFC_VALUE_TEXT, bytes, (size_t)size) : NFC_CALL_TYPE;
  } else call->status = read_value(NULL, &values[argc + 1], &call->out);
  mrbbc_gc_leave(&roots);
}
NfcCallStatus mrbbc_value_call_entry(void *target, NfcCallFrame *frame) {
  NfcValue args[NFC_CALL_I64_MAX_ARGS] = {{NFC_VALUE_NONE, {0}}};
  ValueInvocation call = {target, args, {NFC_VALUE_NONE, {0}}, NFC_CALL_INVALID};
  MrbbcCallError error;
  NfcCallStatus status;
  if (!call.target || !call.target->name) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid Ruby value target");
  status = nfc_call_read_values(frame, call.target->arity, args, NFC_CALL_I64_MAX_ARGS);
  if (status == NFC_CALL_OK) {
    if (!mrbbc_protect(invoke_value, &call, &error)) {
      char message[sizeof frame->error];
      snprintf(message, sizeof message, "%.80s: %.170s", error.kind, error.message);
      status = nfc_call_error(frame, NFC_CALL_EXCEPTION, message);
    } else if (call.status == NFC_CALL_OK) status = nfc_call_write_value_result(frame, &call.out);
    else status = nfc_call_error(frame, call.status, "unsupported Ruby argument or result");
  }
  nfc_values_clear(args, NFC_CALL_I64_MAX_ARGS); nfc_value_clear(&call.out); return status;
}
