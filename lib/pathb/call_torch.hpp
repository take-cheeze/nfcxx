/* Optional libtorch IValue/dispatcher bridge. Compile against the matching libtorch C++ ABI. */
#ifndef NFCXX_PATHB_CALL_TORCH_HPP
#define NFCXX_PATHB_CALL_TORCH_HPP
#include "call.h"
#include <torch/library.h>
#include <ATen/core/dispatch/Dispatcher.h>
#include <stdexcept>

namespace nfc::pathb::libtorch {
inline NfcCallStatus read_i64(void *, const void *slot, int64_t *out) {
  const auto &value = *static_cast<const c10::IValue *>(slot);
  if (!value.isInt()) return NFC_CALL_TYPE;
  *out = value.toInt(); return NFC_CALL_OK;
}
inline NfcCallStatus write_i64(void *, void *slot, int64_t value) {
  *static_cast<c10::IValue *>(slot) = c10::IValue(value); return NFC_CALL_OK;
}
inline const NfcCallCodec codec = {read_i64, write_i64};
inline NfcCallSlot slot(c10::IValue &value) { return {&codec, nullptr, &value}; }

inline bool integer_schema(const c10::OperatorHandle &op, size_t arity) {
  const auto &schema = op.schema();
  if (schema.is_vararg() || schema.is_varret() || schema.arguments().size() != arity || schema.returns().size() != 1 ||
      schema.returns()[0].type()->kind() != c10::TypeKind::IntType) return false;
  for (const auto &arg : schema.arguments()) if (arg.type()->kind() != c10::TypeKind::IntType) return false;
  return true;
}

class BoxedKernel final : public c10::OperatorKernel {
  NfcCallable callable_;
  size_t arity_;
public:
  BoxedKernel(NfcCallable callable, size_t arity) : callable_(callable), arity_(arity) {}
  void operator()(const c10::OperatorHandle &op, c10::DispatchKeySet, c10::Stack *stack) {
    if (!stack || arity_ > NFC_CALL_I64_MAX_ARGS || stack->size() < arity_ || !integer_schema(op, arity_))
      throw std::runtime_error("boxed kernel requires a fixed i64 signature");
    const size_t base = stack->size() - arity_;
    NfcCallSlot inputs[NFC_CALL_I64_MAX_ARGS];
    for (size_t i = 0; i < arity_; i++) inputs[i] = slot((*stack)[base + i]);
    c10::IValue output;
    NfcCallSlot result = slot(output);
    NfcCallFrame frame = {NFC_CALL_VERSION, inputs, arity_, &result, 1, 0, nullptr, {0}};
    auto status = nfc_call_invoke(&callable_, &frame);
    if (status != NFC_CALL_OK) throw std::runtime_error(frame.error);
    if (frame.nresults != 1 || !output.isInt()) throw std::runtime_error("one i64 result is required");
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
    if (!integer_schema(target->op, arity)) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "operator requires a fixed i64 signature");
    int64_t values[NFC_CALL_I64_MAX_ARGS];
    auto status = nfc_call_read_i64_args(frame, arity, values, NFC_CALL_I64_MAX_ARGS);
    if (status != NFC_CALL_OK) return status;
    c10::Stack stack;
    stack.reserve(arity);
    for (size_t i = 0; i < arity; i++) stack.emplace_back(values[i]);
    target->op.callBoxed(&stack);
    if (stack.size() != 1 || !stack[0].isInt()) return nfc_call_error(frame, NFC_CALL_TYPE, "libtorch result is not one i64");
    return nfc_call_write_i64_result(frame, stack[0].toInt());
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in libtorch call"); }
}
} // namespace nfc::pathb::libtorch
#endif
