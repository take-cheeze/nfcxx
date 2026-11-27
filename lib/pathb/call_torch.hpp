/* Optional libtorch IValue/dispatcher bridge. Compile against the matching libtorch C++ ABI. */
#ifndef NFCXX_PATHB_CALL_TORCH_HPP
#define NFCXX_PATHB_CALL_TORCH_HPP
#include "call_value.hpp"
#include <torch/library.h>
#include <ATen/core/dispatch/Dispatcher.h>
#include <stdexcept>

namespace nfc::pathb::libtorch {
struct ObjectRef {
  static constexpr const char *type_name = "libtorch.IValue";
  c10::IValue value;
};
inline NfcCallStatus read_i64(void *, const void *slot, int64_t *out) {
  const auto &value = *static_cast<const c10::IValue *>(slot);
  if (!value.isInt()) return NFC_CALL_TYPE;
  *out = value.toInt(); return NFC_CALL_OK;
}
inline NfcCallStatus write_i64(void *, void *slot, int64_t value) {
  *static_cast<c10::IValue *>(slot) = c10::IValue(value); return NFC_CALL_OK;
}
inline NfcCallStatus read_value(void *, const void *slot, NfcValue *out) noexcept {
  try {
    const auto &value = *static_cast<const c10::IValue *>(slot);
    if (value.isString()) {
      const auto &bytes = value.toStringRef();
      return nfc_value_set_data(out, nfc_utf8_valid(bytes.data(), bytes.size()) ? NFC_VALUE_TEXT : NFC_VALUE_BYTES, bytes.data(), bytes.size());
    }
    if (!value.isNone() && !value.isBool() && !value.isInt() && !value.isDouble()) return owned_handle(out, ObjectRef{value});
    nfc_value_clear(out);
    if (value.isBool()) { out->kind = NFC_VALUE_BOOL; out->as.boolean = value.toBool(); }
    else if (value.isInt()) { out->kind = NFC_VALUE_I64; out->as.i64 = value.toInt(); }
    else if (value.isDouble()) { out->kind = NFC_VALUE_F64; out->as.f64 = value.toDouble(); }
    return NFC_CALL_OK;
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
inline NfcCallStatus write_value(void *, void *slot, const NfcValue *value) noexcept {
  try {
    c10::IValue out;
    switch (value->kind) {
      case NFC_VALUE_NONE: break;
      case NFC_VALUE_BOOL: out = c10::IValue(value->as.boolean != 0); break;
      case NFC_VALUE_I64: out = c10::IValue(value->as.i64); break;
      case NFC_VALUE_F64: out = c10::IValue(value->as.f64); break;
      case NFC_VALUE_TEXT:
      case NFC_VALUE_BYTES: out = c10::IValue(std::string(reinterpret_cast<const char *>(value->as.buffer.data), value->as.buffer.size)); break;
      case NFC_VALUE_HANDLE: {
        auto *object = get_handle<ObjectRef>(*value);
        if (!object) return NFC_CALL_UNSUPPORTED;
        out = object->value; break;
      }
      default: return NFC_CALL_TYPE;
    }
    *static_cast<c10::IValue *>(slot) = std::move(out); return NFC_CALL_OK;
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
inline const NfcCallCodec codec = {read_i64, write_i64, read_value, write_value};
inline NfcCallSlot slot(c10::IValue &value) { return {&codec, nullptr, &value}; }

inline bool supported_schema(const c10::OperatorHandle &op, size_t arity) {
  const auto &schema = op.schema();
  return !schema.is_vararg() && !schema.is_varret() && schema.arguments().size() == arity && schema.returns().size() == 1;
}

class BoxedKernel final : public c10::OperatorKernel {
  NfcCallable callable_;
  Value owner_;
  size_t arity_;
public:
  BoxedKernel(NfcCallable callable, size_t arity, const NfcValue *owner = nullptr) : callable_(callable), arity_(arity) { keep_owner(owner_, owner); }
  void operator()(const c10::OperatorHandle &op, c10::DispatchKeySet, c10::Stack *stack) {
    Value lease; keep_owner(lease, &owner_.value);
    if (!stack || arity_ > NFC_CALL_I64_MAX_ARGS || stack->size() < arity_ || !supported_schema(op, arity_))
      throw std::runtime_error("boxed kernel requires a fixed single-result signature");
    const size_t base = stack->size() - arity_;
    NfcCallSlot inputs[NFC_CALL_I64_MAX_ARGS];
    for (size_t i = 0; i < arity_; i++) {
      if (!(*stack)[base + i].type()->isSubtypeOf(op.schema().arguments()[i].type())) throw std::runtime_error("boxed argument does not match schema");
      inputs[i] = slot((*stack)[base + i]);
    }
    c10::IValue output;
    NfcCallSlot result = slot(output);
    NfcCallFrame frame = {NFC_CALL_VERSION, inputs, arity_, &result, 1, 0, nullptr, {0}};
    auto status = nfc_call_invoke(&callable_, &frame);
    if (status != NFC_CALL_OK) throw std::runtime_error(frame.error);
    if (frame.nresults != 1 || !output.type()->isSubtypeOf(op.schema().returns()[0].type())) throw std::runtime_error("result does not match schema");
    // Consume only the argument suffix; retain values below the call frame.
    stack->resize(base);
    stack->push_back(std::move(output));
  }
};

struct Target { c10::OperatorHandle op; };
inline NfcCallStatus entry(void *closure, NfcCallFrame *frame) noexcept {
  try {
    auto *target = static_cast<Target *>(closure);
    if (!target) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid libtorch operator");
    const size_t arity = target->op.schema().arguments().size();
    if (!supported_schema(target->op, arity)) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "operator requires a fixed single-result signature");
    Values values;
    auto status = nfc_call_read_values(frame, arity, values.values, NFC_CALL_I64_MAX_ARGS);
    if (status != NFC_CALL_OK) return status;
    c10::Stack stack;
    stack.reserve(arity);
    for (size_t i = 0; i < arity; i++) {
      c10::IValue value;
      status = write_value(nullptr, &value, &values.values[i]);
      if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported libtorch argument");
      if (!value.type()->isSubtypeOf(target->op.schema().arguments()[i].type())) return nfc_call_error(frame, NFC_CALL_TYPE, "argument does not match libtorch schema");
      stack.push_back(std::move(value));
    }
    target->op.callBoxed(&stack);
    if (stack.size() != 1 || !stack[0].type()->isSubtypeOf(target->op.schema().returns()[0].type()))
      return nfc_call_error(frame, NFC_CALL_TYPE, "result does not match libtorch schema");
    Value result;
    status = read_value(nullptr, &stack[0], &result.value);
    if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported libtorch result");
    return nfc_call_write_value_result(frame, &result.value);
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in libtorch call"); }
}
} // namespace nfc::pathb::libtorch
#endif
