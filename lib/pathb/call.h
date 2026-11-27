/* Language-neutral, versioned boxed call boundary. C99/C++; no libuv or language runtime dependency.
 * Slots are borrowed and use their owner's representation. The caller keeps every slot live/rooted until return.
 * Codec callbacks must return a status; foreign exceptions/longjmp must be caught by the owning adapter. */
#ifndef NFCXX_PATHB_CALL_H
#define NFCXX_PATHB_CALL_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NFC_CALL_VERSION 1u
#define NFC_CALL_I64_MAX_ARGS 64u
typedef enum NfcCallStatus {
  NFC_CALL_OK = 0, NFC_CALL_INVALID, NFC_CALL_ARITY, NFC_CALL_TYPE,
  NFC_CALL_UNSUPPORTED, NFC_CALL_EXCEPTION, NFC_CALL_SUSPENDED
} NfcCallStatus;

typedef struct NfcCallCodec {
  NfcCallStatus (*read_i64)(void *owner, const void *slot, int64_t *out);
  NfcCallStatus (*write_i64)(void *owner, void *slot, int64_t value);
} NfcCallCodec;
typedef struct NfcCallSlot {
  const NfcCallCodec *codec;
  void *owner;
  void *data;
} NfcCallSlot;
typedef struct NfcCallFrame {
  unsigned version;
  const NfcCallSlot *args;
  size_t nargs;
  NfcCallSlot *results;
  size_t capacity, nresults;
  void *context;
  char error[256];
} NfcCallFrame;
typedef NfcCallStatus (*NfcCallEntry)(void *closure, NfcCallFrame *frame);
typedef struct NfcCallable {
  NfcCallEntry entry;
  void *closure;
} NfcCallable;

static inline NfcCallStatus nfc_call_error(NfcCallFrame *frame, NfcCallStatus status, const char *message) {
  if (frame) {
    size_t i = 0;
    frame->nresults = 0;
    if (message) for (; message[i] && i + 1 < sizeof frame->error; i++) frame->error[i] = message[i];
    frame->error[i] = '\0';
  }
  return status;
}

static inline NfcCallStatus nfc_call_invoke(const NfcCallable *fn, NfcCallFrame *frame) {
  size_t i;
  NfcCallStatus status;
  if (!frame) return NFC_CALL_INVALID;
  frame->nresults = 0;
  frame->error[0] = '\0';
  if (!fn || !fn->entry || frame->version != NFC_CALL_VERSION ||
      (frame->nargs && !frame->args) || (frame->capacity && !frame->results))
    return nfc_call_error(frame, NFC_CALL_INVALID, "invalid call frame");
  for (i = 0; i < frame->nargs; i++)
    if (!frame->args[i].codec || !frame->args[i].data)
      return nfc_call_error(frame, NFC_CALL_INVALID, "invalid argument slot");
  for (i = 0; i < frame->capacity; i++)
    if (!frame->results[i].codec || !frame->results[i].data)
      return nfc_call_error(frame, NFC_CALL_INVALID, "invalid result slot");
  status = fn->entry(fn->closure, frame);
  if (status != NFC_CALL_OK) { frame->nresults = 0; return status; }
  if (frame->nresults > frame->capacity)
    return nfc_call_error(frame, NFC_CALL_INVALID, "callee exceeded result capacity");
  return NFC_CALL_OK;
}

/* A typed implementation can have an ordinary native signature. Its generated vector thunk has this signature. */
typedef struct NfcI64Target {
  size_t arity;
  int64_t (*invoke)(void *closure, const int64_t *args);
  void *closure;
} NfcI64Target;

/* Adapter helpers: use a frame validated by nfc_call_invoke; write only after read_i64_args succeeds. */
static inline NfcCallStatus nfc_call_read_i64_args(NfcCallFrame *frame, size_t arity, int64_t *args, size_t limit) {
  size_t i;
  NfcCallStatus status;
  if (frame->nargs != arity) return nfc_call_error(frame, NFC_CALL_ARITY, "wrong argument count");
  if (arity > limit) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "too many i64 arguments");
  if (frame->capacity < 1) return nfc_call_error(frame, NFC_CALL_ARITY, "one result slot is required");
  /* Read all inputs before writing: arguments and results may alias. */
  for (i = 0; i < frame->nargs; i++) {
    if (!frame->args[i].codec->read_i64) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "slot cannot read i64");
    status = frame->args[i].codec->read_i64(frame->args[i].owner, frame->args[i].data, &args[i]);
    if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "argument is not an i64");
  }
  if (!frame->results[0].codec->write_i64) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "slot cannot write i64");
  return NFC_CALL_OK;
}

static inline NfcCallStatus nfc_call_write_i64_result(NfcCallFrame *frame, int64_t result) {
  NfcCallStatus status = frame->results[0].codec->write_i64(frame->results[0].owner, frame->results[0].data, result);
  if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "cannot write i64 result");
  frame->nresults = 1;
  return NFC_CALL_OK;
}

static inline NfcCallStatus nfc_call_i64_entry(void *closure, NfcCallFrame *frame) {
  const NfcI64Target *target = (const NfcI64Target *)closure;
  int64_t args[NFC_CALL_I64_MAX_ARGS];
  NfcCallStatus status;
  if (!target || !target->invoke) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid i64 target");
  status = nfc_call_read_i64_args(frame, target->arity, args, NFC_CALL_I64_MAX_ARGS);
  if (status != NFC_CALL_OK) return status;
  return nfc_call_write_i64_result(frame, target->invoke(target->closure, args));
}

static inline NfcCallStatus nfc_native_read_i64(void *owner, const void *slot, int64_t *out) {
  (void)owner; *out = *(const int64_t *)slot; return NFC_CALL_OK;
}
static inline NfcCallStatus nfc_native_write_i64(void *owner, void *slot, int64_t value) {
  (void)owner; *(int64_t *)slot = value; return NFC_CALL_OK;
}
static inline NfcCallSlot nfc_call_i64_slot(int64_t *value) {
  static const NfcCallCodec codec = {nfc_native_read_i64, nfc_native_write_i64};
  NfcCallSlot slot = {&codec, NULL, value};
  return slot;
}
#ifdef __cplusplus
}
#endif
#endif
