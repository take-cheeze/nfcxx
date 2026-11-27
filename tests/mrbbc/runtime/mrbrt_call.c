#include "mrbrt_call.h"
#include <stdio.h>

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
const NfcCallCodec mrbbc_call_codec = {read_i64, write_i64};

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
