#include "call_qt.hpp"
#include <QMetaProperty>
#include <QThread>
#include <exception>
#include <limits>

namespace nfc::pathb::qt {
static NfcCallStatus read_i64(void *, const void *slot, int64_t *out) {
  const auto &value = *static_cast<const QVariant *>(slot);
  if (value.metaType().id() != QMetaType::LongLong && value.metaType().id() != QMetaType::Int) return NFC_CALL_TYPE;
  *out = value.toLongLong(); return NFC_CALL_OK;
}
static NfcCallStatus write_i64(void *, void *slot, int64_t value) {
  *static_cast<QVariant *>(slot) = QVariant::fromValue<qlonglong>(value); return NFC_CALL_OK;
}
const NfcCallCodec codec = {read_i64, write_i64};

CallableObject::CallableObject(NfcCallable callable, QObject *parent)
    : QObject(parent), callable_(callable), runtime_thread_(QThread::currentThread()) {}
QVariant CallableObject::call(QVariantList args) {
  QPointer<CallableObject> alive(this);
  QVariant output;
  NfcCallStatus status = NFC_CALL_OK;
  char message[256] = {0};
  try {
    if (QThread::currentThread() != thread() || QThread::currentThread() != runtime_thread_) {
      status = NFC_CALL_UNSUPPORTED;
      qstrncpy(message, "QObject calls require its owning thread", sizeof message);
    } else if (args.size() > NFC_CALL_I64_MAX_ARGS) {
      status = NFC_CALL_UNSUPPORTED;
      qstrncpy(message, "too many boxed arguments", sizeof message);
    } else {
      NfcCallSlot inputs[NFC_CALL_I64_MAX_ARGS];
      for (qsizetype i = 0; i < args.size(); i++) inputs[i] = slot(args[i]);
      NfcCallSlot result = slot(output);
      NfcCallFrame frame = {NFC_CALL_VERSION, inputs, static_cast<size_t>(args.size()), &result, 1, 0, nullptr, {0}};
      status = nfc_call_invoke(&callable_, &frame);
      qstrncpy(message, frame.error, sizeof message);
      if (status == NFC_CALL_OK && (frame.nresults != 1 || output.metaType().id() != QMetaType::LongLong)) {
        status = NFC_CALL_TYPE;
        qstrncpy(message, "one i64 result is required", sizeof message);
      }
    }
  } catch (const std::exception &error) {
    status = NFC_CALL_EXCEPTION; qstrncpy(message, error.what(), sizeof message);
  } catch (...) {
    status = NFC_CALL_EXCEPTION; qstrncpy(message, "foreign exception in QObject call", sizeof message);
  }
  if (!alive) return {};
  // A foreign direct call on the wrong thread must not mutate this QObject or emit signals on that thread.
  if (QThread::currentThread() != thread()) return {};
  status_ = status;
  error_ = QString::fromUtf8(message);
  Q_EMIT errorChanged();
  if (!alive) return {};
  if (status != NFC_CALL_OK) { Q_EMIT callFailed(error_); return {}; }
  Q_EMIT resultReady(output.toLongLong());
  return output;
}

static NfcCallStatus check_object(QObject *object, NfcCallFrame *frame) {
  if (!object) return nfc_call_error(frame, NFC_CALL_INVALID, "QObject has been destroyed");
  if (object->thread() != QThread::currentThread())
    return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "QObject calls require its owning thread");
  return NFC_CALL_OK;
}
static bool integer_type(int id) { return id == QMetaType::LongLong || id == QMetaType::Int; }
static bool fits_int(int64_t value) { return value >= std::numeric_limits<int>::min() && value <= std::numeric_limits<int>::max(); }

NfcCallStatus method_entry(void *closure, NfcCallFrame *frame) noexcept {
  try {
    auto *target = static_cast<MethodTarget *>(closure);
    if (!target) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid Qt method target");
    auto status = check_object(target->object, frame);
    if (status != NFC_CALL_OK) return status;
    const auto &method = target->method;
    if (!method.isValid() || !target->object->metaObject()->inherits(method.enclosingMetaObject()))
      return nfc_call_error(frame, NFC_CALL_INVALID, "method does not belong to QObject");
    if (!integer_type(method.returnMetaType().id()))
      return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "Qt method must return int or qlonglong");
    int64_t values[10];
    status = nfc_call_read_i64_args(frame, static_cast<size_t>(method.parameterCount()), values, 10);
    if (status != NFC_CALL_OK) return status;
    auto names = method.parameterTypes();
    int int_args[10] = {0}, int_result = 0;
    qlonglong wide_args[10] = {0}, wide_result = 0;
    QGenericArgument packed[10];
    for (int i = 0; i < method.parameterCount(); i++) {
      int type = method.parameterMetaType(i).id();
      if (!integer_type(type)) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "Qt arguments must be int or qlonglong");
      if (type == QMetaType::Int) {
        if (!fits_int(values[i])) return nfc_call_error(frame, NFC_CALL_TYPE, "Qt int argument is out of range");
        int_args[i] = static_cast<int>(values[i]);
      } else wide_args[i] = values[i];
      packed[i] = QGenericArgument(names[i].constData(), type == QMetaType::Int ? static_cast<void *>(&int_args[i]) : &wide_args[i]);
    }
    void *result = method.returnMetaType().id() == QMetaType::Int ? static_cast<void *>(&int_result) : &wide_result;
    if (!method.invoke(target->object, Qt::DirectConnection, QGenericReturnArgument(method.typeName(), result),
          packed[0], packed[1], packed[2], packed[3], packed[4], packed[5], packed[6], packed[7], packed[8], packed[9]))
      return nfc_call_error(frame, NFC_CALL_EXCEPTION, "Qt meta-method invocation failed");
    return nfc_call_write_i64_result(frame, method.returnMetaType().id() == QMetaType::Int ? int_result : wide_result);
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in Qt method"); }
}

NfcCallStatus property_entry(void *closure, NfcCallFrame *frame) noexcept {
  try {
    auto *target = static_cast<PropertyTarget *>(closure);
    if (!target) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid Qt property target");
    auto status = check_object(target->object, frame);
    if (status != NFC_CALL_OK) return status;
    int64_t value[1] = {0};
    status = nfc_call_read_i64_args(frame, target->write ? 1 : 0, value, 1);
    if (status != NFC_CALL_OK) return status;
    int index = target->object->metaObject()->indexOfProperty(target->name.constData());
    if (index < 0) return nfc_call_error(frame, NFC_CALL_INVALID, "Qt property not found");
    auto property = target->object->metaObject()->property(index);
    if (!integer_type(property.metaType().id()))
      return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "Qt property must be int or qlonglong");
    if (target->write) {
      QVariant input;
      if (property.metaType().id() == QMetaType::Int) {
        if (!fits_int(value[0])) return nfc_call_error(frame, NFC_CALL_TYPE, "Qt int property is out of range");
        input = QVariant::fromValue<int>(static_cast<int>(value[0]));
      } else input = QVariant::fromValue<qlonglong>(value[0]);
      if (!property.isWritable() || !property.write(target->object, input))
        return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "Qt property is not writable");
    } else {
      if (!property.isReadable()) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "Qt property is not readable");
      QVariant out = property.read(target->object);
      status = read_i64(nullptr, &out, &value[0]);
      if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "Qt property did not return an integer");
    }
    return nfc_call_write_i64_result(frame, value[0]);
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in Qt property"); }
}
} // namespace nfc::pathb::qt
