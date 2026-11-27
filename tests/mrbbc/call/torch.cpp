#include "external_common.hpp"
#include "../../../lib/pathb/call_torch.hpp"
namespace bridge = nfc::pathb::libtorch;
static void body(MV *ret) {
  mrb_irep_0(ret);
  auto library = MAKE_TORCH_LIBRARY(nfcxx_call);
  library.def("sum(int a, int b) -> int", torch::CppFunction::makeFromBoxedFunctor(std::make_unique<bridge::BoxedKernel>(sum_callable, 2)));
  library.def("divide(int a, int b) -> int", torch::CppFunction::makeFromBoxedFunctor(std::make_unique<bridge::BoxedKernel>(divide_callable, 2)));
  library.def("failure(int a) -> int", [](int64_t) -> int64_t { throw std::runtime_error("libtorch failure"); });
  library.def("native_add(int a, int b) -> int", [](int64_t a, int64_t b) { return a + b; });
  library.def("text(str a) -> str", [](const std::string &a) { return a; });
  auto sum = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_call::sum", "");
  auto divide = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_call::divide", "");
  c10::Stack stack{c10::IValue("prefix"), c10::IValue(int64_t(20)), c10::IValue(int64_t(22))};
  sum.callBoxed(&stack);
  check(stack.size() == 2 && stack[0].toStringRef() == "prefix" && stack[1].toInt() == 42, "dispatcher calls Ruby and preserves stack prefix");
  stack = {c10::IValue(INT64_MAX), c10::IValue(int64_t(0))};
  sum.callBoxed(&stack);
  check(stack[0].toInt() == INT64_MAX, "IValue full-width integer");
  stack = {c10::IValue(int64_t(1)), c10::IValue(int64_t(0))};
  try { divide.callBoxed(&stack); check(false, "divide must fail"); }
  catch (const std::exception &error) { check(std::strstr(error.what(), "ZeroDivisionError") != nullptr, "Ruby error to libtorch exception"); }
  check(stack.size() == 2, "failed kernel preserves argument stack");
  stack = {c10::IValue(true), c10::IValue(int64_t(1))};
  try { sum.callBoxed(&stack); check(false, "bool must fail"); }
  catch (const std::exception &) { check(stack.size() == 2, "bool is not an integer"); }
  MV values[3]; MrbbcGCFrame roots; mrbbc_gc_enter(&roots, values, 3);
  mrbbc_int_new(&values[0], 20); mrbbc_int_new(&values[1], 22);
  NfcCallSlot args[2] = {mrbbc_call_slot(&values[0]), mrbbc_call_slot(&values[1])}, result = mrbbc_call_slot(&values[2]);
  NfcCallFrame frame{NFC_CALL_VERSION, args, 2, &result, 1, 0, nullptr, {0}};
  bridge::Target target{sum}; NfcCallable callable{bridge::entry, &target};
  int64_t number;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == 42, "Ruby boxed values round trip through dispatcher");
  target.op = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_call::native_add", "");
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == 42, "frame calls independent libtorch boxed operator");
  target.op = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_call::failure", ""); frame.nargs = 1;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_EXCEPTION && std::strstr(frame.error, "libtorch failure"), "libtorch exception to frame status");
  target.op = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_call::text", "");
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_UNSUPPORTED, "noninteger operator schema refused");
  target.op = sum; frame.nargs = 2;
  mrbbc_int_new(&values[0], INT64_MIN); mrbbc_int_new(&values[1], 0);
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == INT64_MIN, "boxed full-width result after failure");
  mrbbc_gc_leave(&roots);
}
int main() { MV ret{}; mrbbc_run(body, &ret); std::printf("libtorch boxed: %d checks passed\n", checks); }
