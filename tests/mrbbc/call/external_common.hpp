#ifndef NFCXX_EXTERNAL_CALL_TEST_HPP
#define NFCXX_EXTERNAL_CALL_TEST_HPP
#include "../runtime/mrbrt_call.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

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
#endif
