/* Optional tvm-ffi C ABI bridge. Only signed i64 signatures; borrowed closure/handle lifetimes are caller-owned. */
#ifndef NFCXX_PATHB_CALL_TVM_HPP
#define NFCXX_PATHB_CALL_TVM_HPP
#include "call.h"
#include <tvm/ffi/c_api.h>
#include <exception>
#include <memory>
#include <string>

namespace nfc::pathb::tvm {
inline NfcCallStatus read_i64(void *, const void *slot, int64_t *out) {
  const auto &value = *static_cast<const TVMFFIAny *>(slot);
  if (value.type_index != kTVMFFIInt) return NFC_CALL_TYPE;
  *out = value.v_int64;
  return NFC_CALL_OK;
}
inline NfcCallStatus write_i64(void *, void *slot, int64_t value) {
  auto &out = *static_cast<TVMFFIAny *>(slot);
  // Refuse replacement of owned objects; the caller must release/reset those first.
  if (out.type_index != kTVMFFINone && out.type_index != kTVMFFIInt) return NFC_CALL_TYPE;
  out = TVMFFIAny{};
  out.type_index = kTVMFFIInt;
  out.v_int64 = value;
  return NFC_CALL_OK;
}
inline const NfcCallCodec codec = {read_i64, write_i64};
inline NfcCallSlot slot(TVMFFIAny &value) { return {&codec, nullptr, &value}; }

inline int fail(const char *kind, const char *message) {
  TVMFFIErrorSetRaisedFromCStr(kind, message);
  return -1;
}
inline int safe_call(void *self, const TVMFFIAny *args, int32_t nargs, TVMFFIAny *result) noexcept {
  try {
    if (!self || !result || nargs < 0 || (nargs && !args)) return fail("ValueError", "invalid boxed call");
    if (nargs > static_cast<int32_t>(NFC_CALL_I64_MAX_ARGS)) return fail("TypeError", "too many boxed arguments");
    if (result->type_index != kTVMFFINone) return fail("ValueError", "result must be None before calling");
    NfcCallSlot inputs[NFC_CALL_I64_MAX_ARGS];
    for (int32_t i = 0; i < nargs; i++) inputs[i] = {&codec, nullptr, const_cast<TVMFFIAny *>(&args[i])};
    TVMFFIAny output{};
    NfcCallSlot out = slot(output);
    NfcCallFrame frame = {NFC_CALL_VERSION, inputs, static_cast<size_t>(nargs), &out, 1, 0, nullptr, {0}};
    auto status = nfc_call_invoke(static_cast<const NfcCallable *>(self), &frame);
    if (status != NFC_CALL_OK) return fail(status == NFC_CALL_TYPE || status == NFC_CALL_ARITY ? "TypeError" : "RuntimeError", frame.error);
    if (frame.nresults != 1 || output.type_index != kTVMFFIInt) return fail("TypeError", "one i64 result is required");
    *result = output;
    return 0;
  } catch (const std::exception &error) { return fail("RuntimeError", error.what()); }
  catch (...) { return fail("RuntimeError", "foreign exception in boxed call"); }
}
inline int create_function(const NfcCallable &callable, TVMFFIObjectHandle *out) noexcept {
  try {
    if (!callable.entry || !out) return fail("ValueError", "invalid callable");
    auto state = std::make_unique<NfcCallable>(callable);
    int status = TVMFFIFunctionCreate(state.get(), safe_call,
        [](void *self) { delete static_cast<NfcCallable *>(self); }, out);
    if (status == 0) state.release(); // Function owns its descriptor; the descriptor's closure remains borrowed.
    return status;
  } catch (const std::exception &error) { return fail("RuntimeError", error.what()); }
  catch (...) { return fail("RuntimeError", "cannot create boxed function"); }
}

struct AnyResult {
  TVMFFIAny value{};
  ~AnyResult() {
    if (value.type_index >= kTVMFFIStaticObjectBegin && value.v_obj) TVMFFIObjectDecRef(value.v_obj);
  }
};
struct Target { TVMFFIObjectHandle function; size_t arity; };
inline NfcCallStatus entry(void *closure, NfcCallFrame *frame) noexcept {
  try {
    auto *target = static_cast<Target *>(closure);
    if (!target || !target->function) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid tvm-ffi function");
    int64_t values[NFC_CALL_I64_MAX_ARGS];
    auto status = nfc_call_read_i64_args(frame, target->arity, values, NFC_CALL_I64_MAX_ARGS);
    if (status != NFC_CALL_OK) return status;
    TVMFFIAny args[NFC_CALL_I64_MAX_ARGS]{};
    for (size_t i = 0; i < frame->nargs; i++) { args[i].type_index = kTVMFFIInt; args[i].v_int64 = values[i]; }
    AnyResult out;
    if (TVMFFIFunctionCall(target->function, args, static_cast<int32_t>(frame->nargs), &out.value) != 0) {
      TVMFFIObjectHandle error = nullptr;
      TVMFFIErrorMoveFromRaised(&error);
      // Own the moved error even if formatting allocates or throws.
      auto release = [](void *obj) { if (obj) TVMFFIObjectDecRef(obj); };
      std::unique_ptr<void, decltype(release)> owned(error, release);
      if (!error) return nfc_call_error(frame, NFC_CALL_EXCEPTION, "tvm-ffi call failed without an error object");
      auto *cell = TVMFFIErrorGetCellPtr(error);
      std::string message(cell->kind.data, cell->kind.size);
      message += ": "; message.append(cell->message.data, cell->message.size);
      return nfc_call_error(frame, NFC_CALL_EXCEPTION, message.c_str());
    }
    if (out.value.type_index != kTVMFFIInt) return nfc_call_error(frame, NFC_CALL_TYPE, "tvm-ffi result is not an i64");
    return nfc_call_write_i64_result(frame, out.value.v_int64);
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in tvm-ffi call"); }
}
} // namespace nfc::pathb::tvm
#endif
