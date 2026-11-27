/* Language-neutral, versioned boxed call boundary. C99/C++; no libuv or language runtime dependency.
 * Slots are borrowed and use their owner's representation. The caller keeps every slot live/rooted until return.
 * Codec callbacks must return a status; foreign exceptions/longjmp must be caught by the owning adapter. */
#ifndef NFCXX_PATHB_CALL_H
#define NFCXX_PATHB_CALL_H
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NFC_CALL_VERSION 2u
#define NFC_CALL_I64_MAX_ARGS 64u
typedef enum NfcCallStatus {
  NFC_CALL_OK = 0, NFC_CALL_INVALID, NFC_CALL_ARITY, NFC_CALL_TYPE,
  NFC_CALL_UNSUPPORTED, NFC_CALL_EXCEPTION, NFC_CALL_SUSPENDED
} NfcCallStatus;

typedef enum NfcValueKind {
  NFC_VALUE_NONE = 0, NFC_VALUE_BOOL, NFC_VALUE_I64, NFC_VALUE_F64,
  NFC_VALUE_TEXT, NFC_VALUE_BYTES, NFC_VALUE_HANDLE
} NfcValueKind;
typedef struct NfcHandleOps {
  const char *name;
  NfcCallStatus (*retain)(void *object);
  void (*release)(void *object);
} NfcHandleOps;
typedef struct NfcHandle { const NfcHandleOps *ops; void *object; } NfcHandle;
typedef struct NfcBuffer {
  const unsigned char *data;
  size_t size;
  void *owner;
  void (*release)(void *owner);
} NfcBuffer;
typedef struct NfcValue {
  NfcValueKind kind;
  union { int boolean; int64_t i64; double f64; NfcBuffer buffer; NfcHandle handle; } as;
} NfcValue;

/* Transport values own their buffers/references. Never shallow-copy a live value: use copy/move/clear.
 * Buffer release stays in the allocating module, including across distinct C runtime libraries. */
static inline void nfc_value_clear(NfcValue *value) {
  if ((value->kind == NFC_VALUE_TEXT || value->kind == NFC_VALUE_BYTES) && value->as.buffer.release)
    value->as.buffer.release(value->as.buffer.owner);
  else if (value->kind == NFC_VALUE_HANDLE && value->as.handle.ops && value->as.handle.ops->release)
    value->as.handle.ops->release(value->as.handle.object);
  memset(value, 0, sizeof *value);
}
static inline void nfc_value_free(void *owner) { free(owner); }
static inline int nfc_utf8_valid(const void *data, size_t size) {
  const unsigned char *p = (const unsigned char *)data;
  size_t i = 0;
  if (size && !p) return 0;
  while (i < size) {
    unsigned c = p[i++], code, count, minimum;
    if (c < 128) continue;
    if (c >= 0xc2 && c <= 0xdf) { code = c & 31; count = 1; minimum = 0x80; }
    else if (c >= 0xe0 && c <= 0xef) { code = c & 15; count = 2; minimum = 0x800; }
    else if (c >= 0xf0 && c <= 0xf4) { code = c & 7; count = 3; minimum = 0x10000; }
    else return 0;
    if (size - i < count) return 0;
    while (count--) { c = p[i++]; if ((c & 0xc0) != 0x80) return 0; code = (code << 6) | (c & 63); }
    if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return 0;
  }
  return 1;
}
static inline NfcCallStatus nfc_value_set_data(NfcValue *out, NfcValueKind kind, const void *data, size_t size) {
  unsigned char *copy;
  if ((kind != NFC_VALUE_TEXT && kind != NFC_VALUE_BYTES) || size == SIZE_MAX || (size && !data)) return NFC_CALL_INVALID;
  if (kind == NFC_VALUE_TEXT && !nfc_utf8_valid(data, size)) return NFC_CALL_TYPE;
  copy = (unsigned char *)malloc(size + 1);
  if (!copy) return NFC_CALL_EXCEPTION;
  if (size) memcpy(copy, data, size);
  copy[size] = 0;
  nfc_value_clear(out);
  out->kind = kind;
  out->as.buffer.data = copy; out->as.buffer.size = size;
  out->as.buffer.owner = copy; out->as.buffer.release = nfc_value_free;
  return NFC_CALL_OK;
}
static inline NfcCallStatus nfc_value_set_handle(NfcValue *out, const NfcHandleOps *ops, void *object) {
  NfcCallStatus status;
  if (!ops || !ops->retain || !ops->release || !object) return NFC_CALL_INVALID;
  status = ops->retain(object);
  if (status != NFC_CALL_OK) return status;
  nfc_value_clear(out); out->kind = NFC_VALUE_HANDLE;
  out->as.handle.ops = ops; out->as.handle.object = object;
  return NFC_CALL_OK;
}
static inline NfcCallStatus nfc_value_copy(NfcValue *out, const NfcValue *value) {
  if (out == value) return NFC_CALL_OK;
  if (value->kind == NFC_VALUE_TEXT || value->kind == NFC_VALUE_BYTES)
    return nfc_value_set_data(out, value->kind, value->as.buffer.data, value->as.buffer.size);
  if (value->kind == NFC_VALUE_HANDLE) return nfc_value_set_handle(out, value->as.handle.ops, value->as.handle.object);
  if (value->kind < NFC_VALUE_NONE || value->kind > NFC_VALUE_F64 ||
      (value->kind == NFC_VALUE_BOOL && value->as.boolean != 0 && value->as.boolean != 1)) return NFC_CALL_TYPE;
  nfc_value_clear(out); *out = *value; return NFC_CALL_OK;
}
static inline void nfc_value_move(NfcValue *out, NfcValue *value) {
  if (out == value) return;
  nfc_value_clear(out); *out = *value; memset(value, 0, sizeof *value);
}
static inline void nfc_values_clear(NfcValue *values, size_t count) {
  size_t i; for (i = 0; i < count; i++) nfc_value_clear(&values[i]);
}

typedef struct NfcCallCodec {
  NfcCallStatus (*read_i64)(void *owner, const void *slot, int64_t *out);
  NfcCallStatus (*write_i64)(void *owner, void *slot, int64_t value);
  NfcCallStatus (*read_value)(void *owner, const void *slot, NfcValue *out);
  NfcCallStatus (*write_value)(void *owner, void *slot, const NfcValue *value);
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
  if (frame->version != NFC_CALL_VERSION) return nfc_call_error(frame, NFC_CALL_INVALID, "incompatible call ABI version");
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
static inline NfcCallStatus nfc_native_read_value(void *owner, const void *slot, NfcValue *out) {
  int64_t value = *(const int64_t *)slot;
  (void)owner; nfc_value_clear(out); out->kind = NFC_VALUE_I64; out->as.i64 = value; return NFC_CALL_OK;
}
static inline NfcCallStatus nfc_native_write_value(void *owner, void *slot, const NfcValue *value) {
  (void)owner; if (value->kind != NFC_VALUE_I64) return NFC_CALL_TYPE;
  *(int64_t *)slot = value->as.i64; return NFC_CALL_OK;
}
static inline NfcCallSlot nfc_call_i64_slot(int64_t *value) {
  static const NfcCallCodec codec = {nfc_native_read_i64, nfc_native_write_i64, nfc_native_read_value, nfc_native_write_value};
  NfcCallSlot slot = {&codec, NULL, value};
  return slot;
}

static inline NfcCallStatus nfc_owned_read_i64(void *owner, const void *slot, int64_t *out) {
  const NfcValue *value = (const NfcValue *)slot; (void)owner;
  if (value->kind != NFC_VALUE_I64) return NFC_CALL_TYPE;
  *out = value->as.i64; return NFC_CALL_OK;
}
static inline NfcCallStatus nfc_owned_write_i64(void *owner, void *slot, int64_t value) {
  NfcValue *out = (NfcValue *)slot; (void)owner;
  nfc_value_clear(out); out->kind = NFC_VALUE_I64; out->as.i64 = value; return NFC_CALL_OK;
}
static inline NfcCallStatus nfc_owned_read(void *owner, const void *slot, NfcValue *out) {
  (void)owner; return nfc_value_copy(out, (const NfcValue *)slot);
}
static inline NfcCallStatus nfc_owned_write(void *owner, void *slot, const NfcValue *value) {
  (void)owner; return nfc_value_copy((NfcValue *)slot, value);
}
static inline NfcCallSlot nfc_call_value_slot(NfcValue *value) {
  static const NfcCallCodec codec = {nfc_owned_read_i64, nfc_owned_write_i64, nfc_owned_read, nfc_owned_write};
  NfcCallSlot slot = {&codec, NULL, value}; return slot;
}

/* Output elements must start at None. On every exit the caller clears all `limit` elements, including partial reads. */
static inline NfcCallStatus nfc_call_read_values(NfcCallFrame *frame, size_t arity, NfcValue *values, size_t limit) {
  size_t i; NfcCallStatus status;
  if (frame->version != NFC_CALL_VERSION) return nfc_call_error(frame, NFC_CALL_INVALID, "incompatible call ABI version");
  if (frame->nargs != arity) return nfc_call_error(frame, NFC_CALL_ARITY, "wrong argument count");
  if (arity > limit) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "too many arguments");
  if (!frame->capacity) return nfc_call_error(frame, NFC_CALL_ARITY, "one result slot is required");
  if (!frame->results[0].codec->write_value) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "slot cannot write a value");
  for (i = 0; i < arity; i++) {
    if (!frame->args[i].codec->read_value) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "slot cannot read a value");
    status = frame->args[i].codec->read_value(frame->args[i].owner, frame->args[i].data, &values[i]);
    if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "cannot convert argument");
  }
  return NFC_CALL_OK;
}
static inline NfcCallStatus nfc_call_write_value_result(NfcCallFrame *frame, const NfcValue *value) {
  NfcCallStatus status = frame->results[0].codec->write_value(frame->results[0].owner, frame->results[0].data, value);
  if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "cannot convert result");
  frame->nresults = 1; return NFC_CALL_OK;
}
typedef struct NfcValueTarget {
  size_t arity;
  NfcCallStatus (*invoke)(void *closure, const NfcValue *args, size_t nargs, NfcValue *out);
  void *closure;
} NfcValueTarget;
static inline NfcCallStatus nfc_call_value_entry(void *closure, NfcCallFrame *frame) {
  const NfcValueTarget *target = (const NfcValueTarget *)closure;
  NfcValue args[NFC_CALL_I64_MAX_ARGS] = {{NFC_VALUE_NONE, {0}}}, out = {NFC_VALUE_NONE, {0}};
  NfcCallStatus status;
  if (!target || !target->invoke) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid value target");
  status = nfc_call_read_values(frame, target->arity, args, NFC_CALL_I64_MAX_ARGS);
  if (status == NFC_CALL_OK) {
    status = target->invoke(target->closure, args, frame->nargs, &out);
    if (status == NFC_CALL_OK) status = nfc_call_write_value_result(frame, &out);
    else nfc_call_error(frame, status, "value target failed");
  }
  nfc_values_clear(args, NFC_CALL_I64_MAX_ARGS); nfc_value_clear(&out); return status;
}
#ifdef __cplusplus
}
#endif
#endif
