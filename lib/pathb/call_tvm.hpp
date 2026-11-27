/* Optional tvm-ffi C ABI bridge: scalar/buffer values and retained native objects; optional callable owner leases. */
#ifndef NFCXX_PATHB_CALL_TVM_HPP
#define NFCXX_PATHB_CALL_TVM_HPP
#include "call_value.hpp"
#include <tvm/ffi/c_api.h>
#include <exception>
#include <memory>
#include <string>
#include <stdexcept>
#include <cstring>

namespace nfc::pathb::tvm {
struct AnyResult {
  TVMFFIAny value{};
  ~AnyResult() { if (value.type_index >= kTVMFFIStaticObjectBegin && value.v_obj) TVMFFIObjectDecRef(value.v_obj); }
};
struct ObjectRef {
  static constexpr const char *type_name = "tvm-ffi.Object";
  TVMFFIObjectHandle value;
  explicit ObjectRef(TVMFFIObjectHandle object) : value(object) {
    if (TVMFFIObjectIncRef(value) != 0) throw std::runtime_error("cannot retain tvm-ffi object");
  }
  ObjectRef(const ObjectRef &) = delete;
  ObjectRef(ObjectRef &&other) noexcept : value(std::exchange(other.value, nullptr)) {}
  ~ObjectRef() { if (value) TVMFFIObjectDecRef(value); }
};
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
inline NfcCallStatus read_value(void *, const void *slot, NfcValue *out) noexcept {
  try {
    const auto &value = *static_cast<const TVMFFIAny *>(slot);
    switch (value.type_index) {
      case kTVMFFINone: nfc_value_clear(out); return NFC_CALL_OK;
      case kTVMFFIInt: nfc_value_clear(out); out->kind = NFC_VALUE_I64; out->as.i64 = value.v_int64; return NFC_CALL_OK;
      case kTVMFFIBool: nfc_value_clear(out); out->kind = NFC_VALUE_BOOL; out->as.boolean = value.v_int64 != 0; return NFC_CALL_OK;
      case kTVMFFIFloat: nfc_value_clear(out); out->kind = NFC_VALUE_F64; out->as.f64 = value.v_float64; return NFC_CALL_OK;
      case kTVMFFISmallStr:
      case kTVMFFISmallBytes:
        if (value.small_str_len > 7) return NFC_CALL_INVALID;
        return nfc_value_set_data(out, value.type_index == kTVMFFISmallStr ? NFC_VALUE_TEXT : NFC_VALUE_BYTES,
                                  value.v_bytes, value.small_str_len);
      case kTVMFFIRawStr:
        return value.v_c_str ? nfc_value_set_data(out, NFC_VALUE_TEXT, value.v_c_str, std::strlen(value.v_c_str)) : NFC_CALL_INVALID;
      case kTVMFFIByteArrayPtr: {
        auto *bytes = static_cast<const TVMFFIByteArray *>(value.v_ptr);
        return bytes ? nfc_value_set_data(out, NFC_VALUE_BYTES, bytes->data, bytes->size) : NFC_CALL_INVALID;
      }
      case kTVMFFIStr:
      case kTVMFFIBytes: {
        auto *bytes = TVMFFIBytesGetByteArrayPtr(value.v_obj);
        return nfc_value_set_data(out, value.type_index == kTVMFFIStr ? NFC_VALUE_TEXT : NFC_VALUE_BYTES, bytes->data, bytes->size);
      }
      default:
        if (value.type_index >= kTVMFFIStaticObjectBegin && value.v_obj)
          return owned_handle(out, ObjectRef(value.v_obj));
        return NFC_CALL_UNSUPPORTED;
    }
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
inline NfcCallStatus write_value(void *, void *slot, const NfcValue *value) noexcept {
  try {
    AnyResult fresh;
    int status = 0;
    switch (value->kind) {
      case NFC_VALUE_NONE: break;
      case NFC_VALUE_I64: fresh.value.type_index = kTVMFFIInt; fresh.value.v_int64 = value->as.i64; break;
      case NFC_VALUE_BOOL: fresh.value.type_index = kTVMFFIBool; fresh.value.v_int64 = value->as.boolean; break;
      case NFC_VALUE_F64: fresh.value.type_index = kTVMFFIFloat; fresh.value.v_float64 = value->as.f64; break;
      case NFC_VALUE_TEXT:
      case NFC_VALUE_BYTES: {
        TVMFFIByteArray bytes{reinterpret_cast<const char *>(value->as.buffer.data), value->as.buffer.size};
        status = value->kind == NFC_VALUE_TEXT ? TVMFFIStringFromByteArray(&bytes, &fresh.value) : TVMFFIBytesFromByteArray(&bytes, &fresh.value);
        break;
      }
      case NFC_VALUE_HANDLE: {
        auto *object = get_handle<ObjectRef>(*value);
        if (!object) return NFC_CALL_UNSUPPORTED;
        TVMFFIAny view{}; view.type_index = TVMFFIObjectGetTypeIndex(object->value);
        view.v_obj = static_cast<TVMFFIObject *>(object->value);
        status = TVMFFIAnyViewToOwnedAny(&view, &fresh.value); break;
      }
      default: return NFC_CALL_TYPE;
    }
    if (status != 0) {
      TVMFFIObjectHandle error = nullptr; TVMFFIErrorMoveFromRaised(&error);
      if (error) TVMFFIObjectDecRef(error);
      return NFC_CALL_EXCEPTION;
    }
    auto &out = *static_cast<TVMFFIAny *>(slot);
    if (out.type_index >= kTVMFFIStaticObjectBegin && out.v_obj) TVMFFIObjectDecRef(out.v_obj);
    out = fresh.value; fresh.value = {}; return NFC_CALL_OK;
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
inline const NfcCallCodec codec = {read_i64, write_i64, read_value, write_value};
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
    AnyResult output;
    NfcCallSlot out = slot(output.value);
    NfcCallFrame frame = {NFC_CALL_VERSION, inputs, static_cast<size_t>(nargs), &out, 1, 0, nullptr, {0}};
    auto status = nfc_call_invoke(static_cast<const NfcCallable *>(self), &frame);
    if (status != NFC_CALL_OK) return fail(status == NFC_CALL_TYPE || status == NFC_CALL_ARITY ? "TypeError" : "RuntimeError", frame.error);
    if (frame.nresults != 1) return fail("TypeError", "one result is required");
    *result = output.value;
    output.value = {};
    return 0;
  } catch (const std::exception &error) { return fail("RuntimeError", error.what()); }
  catch (...) { return fail("RuntimeError", "foreign exception in boxed call"); }
}
struct FunctionState {
  NfcCallable callable;
  Value owner;
  FunctionState(NfcCallable fn, const NfcValue *lease) : callable(fn) { keep_owner(owner, lease); }
};
inline int create_function(const NfcCallable &callable, TVMFFIObjectHandle *out, const NfcValue *owner = nullptr) noexcept {
  try {
    if (!callable.entry || !out) return fail("ValueError", "invalid callable");
    auto state = std::make_unique<FunctionState>(callable, owner);
    int status = TVMFFIFunctionCreate(state.get(),
        [](void *self, const TVMFFIAny *args, int32_t count, TVMFFIAny *out) -> int {
          auto *state = static_cast<FunctionState *>(self);
          try { Value lease; keep_owner(lease, &state->owner.value); return safe_call(&state->callable, args, count, out); }
          catch (...) { return fail("RuntimeError", "cannot retain callable owner"); }
        }, [](void *self) { delete static_cast<FunctionState *>(self); }, out);
    if (status == 0) state.release();
    return status;
  } catch (const std::exception &error) { return fail("RuntimeError", error.what()); }
  catch (...) { return fail("RuntimeError", "cannot create boxed function"); }
}

struct Target { TVMFFIObjectHandle function; size_t arity; };
inline NfcCallStatus entry(void *closure, NfcCallFrame *frame) noexcept {
  try {
    auto *target = static_cast<Target *>(closure);
    if (!target || !target->function) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid tvm-ffi function");
    Values values;
    auto status = nfc_call_read_values(frame, target->arity, values.values, NFC_CALL_I64_MAX_ARGS);
    if (status != NFC_CALL_OK) return status;
    AnyResult args[NFC_CALL_I64_MAX_ARGS];
    TVMFFIAny views[NFC_CALL_I64_MAX_ARGS]{};
    for (size_t i = 0; i < frame->nargs; i++) {
      status = write_value(nullptr, &args[i].value, &values.values[i]);
      if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported tvm-ffi argument");
      views[i] = args[i].value; // Borrow the owned arguments through the native call.
    }
    AnyResult out;
    if (TVMFFIFunctionCall(target->function, views, static_cast<int32_t>(frame->nargs), &out.value) != 0) {
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
    Value result;
    status = read_value(nullptr, &out.value, &result.value);
    if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported tvm-ffi result");
    return nfc_call_write_value_result(frame, &result.value);
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in tvm-ffi call"); }
}
} // namespace nfc::pathb::tvm
#endif
