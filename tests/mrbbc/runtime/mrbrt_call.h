#ifndef NFCXX_MRBRT_CALL_H
#define NFCXX_MRBRT_CALL_H
#include "mrbrt.h"
#include "../../../lib/pathb/call.h"
#ifdef __cplusplus
extern "C" {
#endif

/* mrbbc's i64 export vector thunk is compatible with NfcI64Target. It boxes into the existing Ruby body.
 * Run module initialization first, under mrbbc_run. All MV argument/result slots must be registered GC roots. */
extern const NfcCallCodec mrbbc_call_codec;
NfcCallStatus mrbbc_call_entry(void *target, NfcCallFrame *frame);
static inline NfcCallSlot mrbbc_call_slot(MV *value) {
  NfcCallSlot slot = {&mrbbc_call_codec, NULL, value};
  return slot;
}
#ifdef __cplusplus
}
#endif
#endif
