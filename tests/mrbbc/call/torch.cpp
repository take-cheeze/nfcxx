#include "external_common.hpp"
#include "../../../lib/pathb/call_torch.hpp"
#include <ATen/ops/ones.h>
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
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_TYPE, "schema rejects mismatched argument kind");
  target.op = sum; frame.nargs = 2;
  mrbbc_int_new(&values[0], INT64_MIN); mrbbc_int_new(&values[1], 0);
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == INT64_MIN, "boxed full-width result after failure");
  {
    MrbbcValueTarget echo{"allocate_echo", 1, 0}; NfcCallable generic{mrbbc_value_call_entry, &echo};
    auto values_library = MAKE_TORCH_LIBRARY(nfcxx_call_values);
    values_library.def("echo_tensor(Tensor value) -> Tensor", torch::CppFunction::makeFromBoxedFunctor(std::make_unique<bridge::BoxedKernel>(generic, 1)));
    values_library.def("echo_text(str value) -> str", torch::CppFunction::makeFromBoxedFunctor(std::make_unique<bridge::BoxedKernel>(generic, 1)));
    auto tensor_op = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_call_values::echo_tensor", "");
    auto tensor = at::ones({2}, at::TensorOptions().dtype(at::kDouble));
    c10::Stack tensors{c10::IValue(tensor)};
    tensor_op.callBoxed(&tensors);
    check(tensors.size() == 1 && tensors[0].isTensor() && tensors[0].toTensor().is_same(tensor), "Tensor handle round trip through allocating Ruby call");
    mrbbc_gc_collect();
    check(tensors[0].toTensor().sum().item<double>() == 2.0, "Tensor survives Ruby GC");
    nfc::pathb::Values owned;
    c10::IValue boxed(tensor);
    check(bridge::read_value(nullptr, &boxed, &owned.values[0]) == NFC_CALL_OK, "capture Tensor as owned handle");
    nfc_value_copy(&owned.values[1], &owned.values[0]);
    owned.values[2].kind = NFC_VALUE_I64; owned.values[2].as.i64 = 1;
    NfcCallSlot tensor_args[3] = {nfc_call_value_slot(&owned.values[0]), nfc_call_value_slot(&owned.values[1]), nfc_call_value_slot(&owned.values[2])};
    nfc::pathb::Value added;
    NfcCallSlot tensor_result = nfc_call_value_slot(&added.value);
    NfcCallFrame tensor_frame{NFC_CALL_VERSION, tensor_args, 3, &tensor_result, 1, 0, nullptr, {0}};
    bridge::Target add{c10::Dispatcher::singleton().findSchemaOrThrow("aten::add", "Tensor")};
    NfcCallable add_call{bridge::entry, &add};
    check(nfc_call_invoke(&add_call, &tensor_frame) == NFC_CALL_OK, "shared handles call native aten::add.Tensor");
    auto *sum = nfc::pathb::get_handle<bridge::ObjectRef>(added.value);
    check(sum && sum->value.isTensor() && sum->value.toTensor().sum().item<double>() == 4.0, "native Tensor result retained");
    auto text_op = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_call_values::echo_text", "");
    std::string bytes("a\0\xff", 3); c10::Stack strings{c10::IValue(bytes)};
    text_op.callBoxed(&strings);
    check(strings[0].toStringRef() == bytes, "binary libtorch string through compiled Ruby");
    c10::IValue double_value(-0.0), bool_value(true);
    nfc::pathb::Value decoded;
    check(bridge::read_value(nullptr, &double_value, &decoded.value) == NFC_CALL_OK && decoded.value.kind == NFC_VALUE_F64 && std::signbit(decoded.value.as.f64), "libtorch signed double zero");
    check(bridge::read_value(nullptr, &bool_value, &decoded.value) == NFC_CALL_OK && decoded.value.kind == NFC_VALUE_BOOL, "libtorch bool remains distinct from int");
  }
  auto released = std::make_shared<int>(0);
  {
    nfc::pathb::Value owner; nfc::pathb::owned_handle(&owner.value, OwnedTarget(released));
    auto *provider = nfc::pathb::get_handle<OwnedTarget>(owner.value);
    auto owned_library = MAKE_TORCH_LIBRARY(nfcxx_owned);
    owned_library.def("echo(int value) -> int", torch::CppFunction::makeFromBoxedFunctor(std::make_unique<bridge::BoxedKernel>(
      NfcCallable{nfc_call_value_entry, const_cast<NfcValueTarget *>(&provider->target)}, 1, &owner.value)));
    nfc_value_clear(&owner.value);
    check(*released == 0, "libtorch registration retains callable owner");
    auto op = c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_owned::echo", "");
    c10::Stack arguments{c10::IValue(int64_t(9))}; op.callBoxed(&arguments);
    check(arguments[0].toInt() == 9, "owned libtorch closure remains callable");
  }
  check(*released == 1, "libtorch unregister releases callable owner exactly once");
  mrbbc_gc_leave(&roots);
}
int main() { MV ret{}; mrbbc_run(body, &ret); std::printf("libtorch boxed: %d checks passed\n", checks); }
