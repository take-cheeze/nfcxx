#ifndef NFCXX_PATHB_CALL_VALUE_HPP
#define NFCXX_PATHB_CALL_VALUE_HPP
#include "call.h"
#include <atomic>
#include <memory>
#include <utility>
#include <stdexcept>

namespace nfc::pathb {
struct Value {
  NfcValue value{};
  Value() = default;
  Value(const Value &) = delete;
  Value &operator=(const Value &) = delete;
  ~Value() { nfc_value_clear(&value); }
};
struct Values {
  NfcValue values[NFC_CALL_I64_MAX_ARGS]{};
  ~Values() { nfc_values_clear(values, NFC_CALL_I64_MAX_ARGS); }
  Values() = default;
  Values(const Values &) = delete;
  Values &operator=(const Values &) = delete;
};
inline void keep_owner(Value &lease, const NfcValue *owner) {
  if (!owner || owner->kind == NFC_VALUE_NONE) return;
  if (owner->kind != NFC_VALUE_HANDLE) throw std::invalid_argument("callable owner must be a retained handle");
  if (nfc_value_copy(&lease.value, owner) != NFC_CALL_OK) throw std::runtime_error("cannot retain callable owner");
}
template<class T> struct HandleCell {
  std::atomic<size_t> refs{1};
  T value;
  explicit HandleCell(T value) : value(std::move(value)) {}
};
template<class T> inline const NfcHandleOps *handle_ops() {
  static const NfcHandleOps ops = {
    T::type_name,
    [](void *object) -> NfcCallStatus { static_cast<HandleCell<T> *>(object)->refs.fetch_add(1, std::memory_order_relaxed); return NFC_CALL_OK; },
    [](void *object) { auto *cell = static_cast<HandleCell<T> *>(object); if (cell->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) delete cell; }
  };
  return &ops;
}
template<class T> inline NfcCallStatus owned_handle(NfcValue *out, T value) {
  auto cell = std::make_unique<HandleCell<T>>(std::move(value));
  auto status = nfc_value_set_handle(out, handle_ops<T>(), cell.get());
  if (status == NFC_CALL_OK) handle_ops<T>()->release(cell.release());
  return status;
}
template<class T> inline const T *get_handle(const NfcValue &value) {
  if (value.kind != NFC_VALUE_HANDLE || value.as.handle.ops != handle_ops<T>()) return nullptr;
  return &static_cast<const HandleCell<T> *>(value.as.handle.object)->value;
}
} // namespace nfc::pathb
#endif
