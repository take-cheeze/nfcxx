#include "external_common.hpp"
#include "qt_object.hpp"
#include "../../../lib/pathb/call_qt.hpp"
#include <QCoreApplication>
#include <thread>
namespace bridge = nfc::pathb::qt;
static void body(MV *ret) {
  mrb_irep_0(ret);
  bridge::CallableObject object(sum_callable);
  CallCounter counter;
  qlonglong observed = 0;
  int failures = 0;
  QObject::connect(&object, &bridge::CallableObject::resultReady, &counter, [&](qlonglong value) { observed = value; });
  QObject::connect(&object, &bridge::CallableObject::callFailed, &counter, [&](const QString &) { failures++; });
  QVariant result;
  QVariantList inputs{20, 22};
  check(QMetaObject::invokeMethod(&object, "call", Qt::DirectConnection, Q_RETURN_ARG(QVariant, result), Q_ARG(QVariantList, inputs)), "invoke compiled callable through Qt meta-object");
  check(result.toLongLong() == 42 && observed == 42 && object.lastStatus() == NFC_CALL_OK, "Qt method to Ruby and result signal");
  result = object.call({QStringLiteral("20"), 22});
  check(!result.isValid() && failures == 1 && object.property("lastStatus").toInt() == NFC_CALL_TYPE, "Qt type failure and reflected status");
  check(!object.property("lastError").toString().isEmpty(), "Qt reflected diagnostic");
  QObject::connect(&counter, &CallCounter::requested, &object, &bridge::CallableObject::call, Qt::DirectConnection);
  counter.requested({20, 22});
  check(observed == 42 && object.lastError().isEmpty(), "Qt signal calls compiled function slot");
  result = object.call({QVariant::fromValue<qlonglong>(INT64_MAX), 0});
  check(result.toLongLong() == INT64_MAX, "Qt full-width integer");
  bridge::CallableObject divide(divide_callable);
  check(!divide.call({1, 0}).isValid() && divide.lastStatus() == NFC_CALL_EXCEPTION && divide.lastError().contains("ZeroDivisionError"), "Ruby exception to Qt error state");
  check(divide.call({6, 2}).toLongLong() == 3, "Qt callable recovers after Ruby error");
  MV values[3]; MrbbcGCFrame roots; mrbbc_gc_enter(&roots, values, 3);
  mrbbc_int_new(&values[0], 20); mrbbc_int_new(&values[1], 22);
  NfcCallSlot args[2] = {mrbbc_call_slot(&values[0]), mrbbc_call_slot(&values[1])}, output = mrbbc_call_slot(&values[2]);
  NfcCallFrame frame{NFC_CALL_VERSION, args, 2, &output, 1, 0, nullptr, {0}};
  auto method = [&](const char *signature) { return counter.metaObject()->method(counter.metaObject()->indexOfMethod(signature)); };
  bridge::MethodTarget target{&counter, method("add(qlonglong,qlonglong)")};
  NfcCallable callable{bridge::method_entry, &target}; int64_t number;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == 42, "Ruby boxes call Qt reflected method");
  NfcCallStatus foreign_thread = NFC_CALL_OK;
  std::thread worker([&] { foreign_thread = nfc_call_invoke(&callable, &frame); }); worker.join();
  check(foreign_thread == NFC_CALL_UNSUPPORTED, "cross-thread synchronous invocation refused");
  target.method = method("fail()"); frame.nargs = 0;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_EXCEPTION && std::strstr(frame.error, "Qt method failure"), "Qt direct exception to frame");
  target.method = method("text()");
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_UNSUPPORTED, "Qt noninteger method refused");
  target.method = method("increment(int)"); frame.nargs = 1;
  mrbbc_int_new(&values[0], INT64_MAX);
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_TYPE, "Qt int argument range checked");
  mrbbc_int_new(&values[0], 20);
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == 21, "Qt int argument and return conversion");
  bridge::PropertyTarget property{&counter, "count", true};
  NfcCallable access{bridge::property_entry, &property}; frame.nargs = 1;
  QObject::connect(&counter, &CallCounter::countChanged, &object, [&](qlonglong value) { object.call({QVariant::fromValue(value), 1}); });
  mrbbc_int_new(&values[0], 11);
  check(nfc_call_invoke(&access, &frame) == NFC_CALL_OK && counter.count() == 11 && observed == 12, "property write emits signal into compiled Ruby callback");
  property.write = false; frame.nargs = 0;
  check(nfc_call_invoke(&access, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == 11, "reflected property read to Ruby box");
  property = {&counter, "frozen", true}; frame.nargs = 1;
  check(nfc_call_invoke(&access, &frame) == NFC_CALL_UNSUPPORTED, "read-only property refused");
  property.name = "absent";
  check(nfc_call_invoke(&access, &frame) == NFC_CALL_INVALID, "missing property refused");
  property.name = "level";
  mrbbc_int_new(&values[0], INT64_MAX);
  check(nfc_call_invoke(&access, &frame) == NFC_CALL_TYPE, "Qt int property range checked");
  mrbbc_int_new(&values[0], 17);
  check(nfc_call_invoke(&access, &frame) == NFC_CALL_OK && counter.property("level").toInt() == 17, "Qt int property write");
  property.write = false; frame.nargs = 0;
  check(nfc_call_invoke(&access, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == 17, "Qt int property read");
  auto *temporary = new CallCounter;
  target = {temporary, temporary->metaObject()->method(temporary->metaObject()->indexOfMethod("add(qlonglong,qlonglong)"))};
  delete temporary; frame.nargs = 2;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_INVALID, "destroyed QObject target detected");
  auto *ephemeral = new bridge::CallableObject(sum_callable);
  QPointer<bridge::CallableObject> alive(ephemeral);
  QObject::connect(ephemeral, &bridge::CallableObject::errorChanged, &counter, [ephemeral] { delete ephemeral; });
  check(!ephemeral->call({20, 22}).isValid() && !alive, "QObject deletion during notification is safe");
  mrbbc_gc_leave(&roots);
}
int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  MV ret{}; mrbbc_run(body, &ret); std::printf("Qt meta-object: %d checks passed\n", checks);
}
