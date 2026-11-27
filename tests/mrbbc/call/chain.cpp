// Actual cross-framework nesting: Qt -> libtorch dispatcher -> tvm-ffi Function -> compiled Ruby, and back.
#include "external_common.hpp"
#include "../../../lib/pathb/call_qt.hpp"
#include "../../../lib/pathb/call_torch.hpp"
#include "../../../lib/pathb/call_tvm.hpp"
#include <QCoreApplication>
namespace qt = nfc::pathb::qt;
namespace torch_bridge = nfc::pathb::libtorch;
namespace tvm = nfc::pathb::tvm;
struct Function {
  TVMFFIObjectHandle value = nullptr;
  ~Function() { if (value) TVMFFIObjectDecRef(value); }
};
static void body(MV *ret) {
  mrb_irep_0(ret);
  Function sum, div;
  check(tvm::create_function(sum_callable, &sum.value) == 0, "chain sum TVM function");
  check(tvm::create_function(divide_callable, &div.value) == 0, "chain divide TVM function");
  tvm::Target tvm_sum{sum.value, 2}, tvm_div{div.value, 2};
  NfcCallable sum_tvm{tvm::entry, &tvm_sum}, div_tvm{tvm::entry, &tvm_div};
  auto library = MAKE_TORCH_LIBRARY(nfcxx_chain);
  library.def("sum(int a, int b) -> int", torch::CppFunction::makeFromBoxedFunctor(std::make_unique<torch_bridge::BoxedKernel>(sum_tvm, 2)));
  library.def("divide(int a, int b) -> int", torch::CppFunction::makeFromBoxedFunctor(std::make_unique<torch_bridge::BoxedKernel>(div_tvm, 2)));
  torch_bridge::Target torch_sum{c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_chain::sum", "")};
  torch_bridge::Target torch_div{c10::Dispatcher::singleton().findSchemaOrThrow("nfcxx_chain::divide", "")};
  qt::CallableObject sum_object({torch_bridge::entry, &torch_sum}), div_object({torch_bridge::entry, &torch_div});
  qlonglong observed = 0;
  QObject::connect(&sum_object, &qt::CallableObject::resultReady, &sum_object, [&](qlonglong value) { observed = value; });
  QVariantList args{20, 22}; QVariant result;
  check(QMetaObject::invokeMethod(&sum_object, "call", Qt::DirectConnection, Q_RETURN_ARG(QVariant, result), Q_ARG(QVariantList, args)), "chain Qt reflected invocation");
  check(result.toLongLong() == 42 && observed == 42, "Qt to torch to TVM to Ruby result and signal");
  check(!div_object.call({1, 0}).isValid() && div_object.lastStatus() == NFC_CALL_EXCEPTION && div_object.lastError().contains("ZeroDivisionError"), "Ruby error crosses all three boundaries");
  check(div_object.call({9, 3}).toLongLong() == 3 && div_object.lastError().isEmpty(), "all three boundaries recover");
  result = sum_object.call({QVariant::fromValue<qlonglong>(INT64_MIN), 0});
  check(result.toLongLong() == INT64_MIN, "full-width integer through all three boundaries");
}
int main(int argc, char **argv) {
  QCoreApplication app(argc, argv); MV ret{}; mrbbc_run(body, &ret);
  std::printf("Qt/libtorch/tvm-ffi chain: %d checks passed\n", checks);
}
