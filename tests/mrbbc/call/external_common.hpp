#ifndef NFCXX_EXTERNAL_CALL_TEST_HPP
#define NFCXX_EXTERNAL_CALL_TEST_HPP
#include "../runtime/mrbrt_call.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <memory>

extern "C" {
void mrb_irep_0(MV *ret);
int64_t mrbbc_i64v_sum(void *, const int64_t *);
int64_t mrbbc_i64v_divide(void *, const int64_t *);
}
inline int checks;
inline void check(bool ok, const char *message) {
  if (!ok) { std::fprintf(stderr, "external call: %s\n", message); std::exit(2); }
  checks++;
}
inline NfcI64Target ruby_sum = {2, mrbbc_i64v_sum, nullptr};
inline NfcI64Target ruby_divide = {2, mrbbc_i64v_divide, nullptr};
inline NfcCallable sum_callable = {mrbbc_call_entry, &ruby_sum};
inline NfcCallable divide_callable = {mrbbc_call_entry, &ruby_divide};
inline NfcCallStatus copy_value(void *, const NfcValue *args, size_t, NfcValue *out) { return nfc_value_copy(out, &args[0]); }
inline bool same_value(const NfcValue &a, const NfcValue &b) {
  if (a.kind != b.kind) return false;
  switch (a.kind) {
    case NFC_VALUE_NONE: return true;
    case NFC_VALUE_BOOL: return a.as.boolean == b.as.boolean;
    case NFC_VALUE_I64: return a.as.i64 == b.as.i64;
    case NFC_VALUE_F64: return (std::isnan(a.as.f64) && std::isnan(b.as.f64)) ||
      (a.as.f64 == b.as.f64 && std::signbit(a.as.f64) == std::signbit(b.as.f64));
    case NFC_VALUE_TEXT:
    case NFC_VALUE_BYTES: return a.as.buffer.size == b.as.buffer.size && !std::memcmp(a.as.buffer.data, b.as.buffer.data, a.as.buffer.size);
    default: return false;
  }
}
struct OwnedTarget {
  static constexpr const char *type_name = "test.CallableOwner";
  NfcValueTarget target{1, copy_value, nullptr};
  std::shared_ptr<int> released;
  void *data = nullptr;
  explicit OwnedTarget(std::shared_ptr<int> count) : released(std::move(count)) {}
  OwnedTarget(OwnedTarget &&other) noexcept : target(other.target), released(std::move(other.released)), data(other.data) {}
  ~OwnedTarget() { if (released) ++*released; }
};
#endif
