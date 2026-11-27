#include "call_qt.hpp"
#include <QMetaProperty>
#include <QThread>
#include <exception>
#include <limits>
#include <QStringDecoder>

namespace nfc::pathb::qt {
static NfcCallStatus decode_text(const char *data, size_t size, QString &out) {
  if (size > static_cast<size_t>(std::numeric_limits<qsizetype>::max()) || !nfc_utf8_valid(data, size)) return NFC_CALL_TYPE;
  QStringDecoder decoder(QStringDecoder::Utf8, QStringConverter::Flag::ConvertInitialBom);
  out = decoder(QByteArrayView(data, static_cast<qsizetype>(size)));
  return decoder.hasError() ? NFC_CALL_TYPE : NFC_CALL_OK;
}
static NfcCallStatus read_i64(void *, const void *slot, int64_t *out) {
  const auto &value = *static_cast<const QVariant *>(slot);
  if (value.metaType().id() != QMetaType::LongLong && value.metaType().id() != QMetaType::Int) return NFC_CALL_TYPE;
  *out = value.toLongLong(); return NFC_CALL_OK;
}
static NfcCallStatus write_i64(void *, void *slot, int64_t value) {
  *static_cast<QVariant *>(slot) = QVariant::fromValue<qlonglong>(value); return NFC_CALL_OK;
}
static NfcCallStatus read_value(void *, const void *slot, NfcValue *out) noexcept {
  try {
    const auto &value = *static_cast<const QVariant *>(slot);
    int type = value.metaType().id();
    if (type == QMetaType::QString) {
      auto text = value.toString(); auto bytes = text.toUtf8();
      QString decoded;
      if (decode_text(bytes.data(), static_cast<size_t>(bytes.size()), decoded) != NFC_CALL_OK || decoded != text) return NFC_CALL_TYPE;
      return nfc_value_set_data(out, NFC_VALUE_TEXT, bytes.data(), static_cast<size_t>(bytes.size()));
    }
    if (type == QMetaType::QByteArray) {
      auto bytes = value.toByteArray();
      return nfc_value_set_data(out, NFC_VALUE_BYTES, bytes.data(), static_cast<size_t>(bytes.size()));
    }
    if (value.metaType().flags().testFlag(QMetaType::PointerToQObject)) {
      auto *object = value.value<QObject *>();
      if (object) return owned_handle(out, ObjectRef{object});
      nfc_value_clear(out); return NFC_CALL_OK;
    }
    if (value.isValid() && type != QMetaType::Bool && type != QMetaType::Int && type != QMetaType::LongLong && type != QMetaType::Double)
      return NFC_CALL_UNSUPPORTED;
    nfc_value_clear(out);
    if (type == QMetaType::Bool) { out->kind = NFC_VALUE_BOOL; out->as.boolean = value.toBool(); }
    else if (type == QMetaType::Int || type == QMetaType::LongLong) { out->kind = NFC_VALUE_I64; out->as.i64 = value.toLongLong(); }
    else if (type == QMetaType::Double) { out->kind = NFC_VALUE_F64; out->as.f64 = value.toDouble(); }
    return NFC_CALL_OK;
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
static NfcCallStatus write_value(void *, void *slot, const NfcValue *value) noexcept {
  try {
    QVariant out;
    switch (value->kind) {
      case NFC_VALUE_NONE: break;
      case NFC_VALUE_BOOL: out = QVariant(value->as.boolean != 0); break;
      case NFC_VALUE_I64: out = QVariant::fromValue<qlonglong>(value->as.i64); break;
      case NFC_VALUE_F64: out = QVariant(value->as.f64); break;
      case NFC_VALUE_TEXT:
      case NFC_VALUE_BYTES:
        if (value->as.buffer.size > static_cast<size_t>(std::numeric_limits<qsizetype>::max())) return NFC_CALL_TYPE;
        if (value->kind == NFC_VALUE_TEXT) {
          QString decoded;
          auto status = decode_text(reinterpret_cast<const char *>(value->as.buffer.data), value->as.buffer.size, decoded);
          if (status != NFC_CALL_OK) return status;
          out = decoded;
        } else out = QByteArray(reinterpret_cast<const char *>(value->as.buffer.data), static_cast<qsizetype>(value->as.buffer.size));
        break;
      case NFC_VALUE_HANDLE: {
        auto *object = get_handle<ObjectRef>(*value);
        if (!object) return NFC_CALL_UNSUPPORTED;
        if (!object->value) return NFC_CALL_INVALID;
        out = QVariant::fromValue<QObject *>(object->value); break;
      }
      default: return NFC_CALL_TYPE;
    }
    *static_cast<QVariant *>(slot) = std::move(out); return NFC_CALL_OK;
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
const NfcCallCodec codec = {read_i64, write_i64, read_value, write_value};

CallableObject::CallableObject(NfcCallable callable, QObject *parent, const NfcValue *owner)
    : QObject(parent), callable_(callable), runtime_thread_(QThread::currentThread()) { keep_owner(owner_, owner); }
QVariant CallableObject::call(QVariantList args) {
  QPointer<CallableObject> alive(this);
  QVariant output;
  NfcCallStatus status = NFC_CALL_OK;
  char message[256] = {0};
  try {
    Value lease; keep_owner(lease, &owner_.value);
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
      if (status == NFC_CALL_OK && frame.nresults != 1) {
        status = NFC_CALL_TYPE;
        qstrncpy(message, "one result is required", sizeof message);
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
  Q_EMIT valueReady(output);
  if (!alive) return {};
  if (output.metaType().id() == QMetaType::LongLong || output.metaType().id() == QMetaType::Int) Q_EMIT resultReady(output.toLongLong());
  return output;
}

static NfcCallStatus check_object(QObject *object, NfcCallFrame *frame) {
  if (!object) return nfc_call_error(frame, NFC_CALL_INVALID, "QObject has been destroyed");
  if (object->thread() != QThread::currentThread())
    return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "QObject calls require its owning thread");
  return NFC_CALL_OK;
}
static bool fits_int(int64_t value) { return value >= std::numeric_limits<int>::min() && value <= std::numeric_limits<int>::max(); }

static NfcCallStatus prepare(const NfcValue &value, QMetaType type, QVariant &out) {
  int id = type.id();
  if (id == QMetaType::Int) {
    if (value.kind != NFC_VALUE_I64 || !fits_int(value.as.i64)) return NFC_CALL_TYPE;
    out = QVariant(static_cast<int>(value.as.i64)); return NFC_CALL_OK;
  }
  if ((id == QMetaType::LongLong && value.kind != NFC_VALUE_I64) ||
      (id == QMetaType::Bool && value.kind != NFC_VALUE_BOOL) ||
      (id == QMetaType::Double && value.kind != NFC_VALUE_F64)) return NFC_CALL_TYPE;
  if (id == QMetaType::QString && value.kind == NFC_VALUE_BYTES) {
    if (!nfc_utf8_valid(value.as.buffer.data, value.as.buffer.size)) return NFC_CALL_TYPE;
    NfcValue text = value; text.kind = NFC_VALUE_TEXT; // A borrowed projection; do not clear it.
    return write_value(nullptr, &out, &text);
  }
  if (type.flags().testFlag(QMetaType::PointerToQObject) && value.kind == NFC_VALUE_NONE) {
    out = QVariant::fromValue<QObject *>(nullptr);
    return out.convert(type) ? NFC_CALL_OK : NFC_CALL_TYPE;
  }
  if (id != QMetaType::LongLong && id != QMetaType::Bool && id != QMetaType::Double && id != QMetaType::QString &&
      id != QMetaType::QByteArray && id != QMetaType::QVariant && !type.flags().testFlag(QMetaType::PointerToQObject)) return NFC_CALL_UNSUPPORTED;
  auto status = write_value(nullptr, &out, &value);
  if (status != NFC_CALL_OK) return status;
  if (id == QMetaType::QVariant) return NFC_CALL_OK;
  if (id == QMetaType::QByteArray && value.kind == NFC_VALUE_TEXT) { out = out.toString().toUtf8(); return NFC_CALL_OK; }
  if (out.metaType() == type) return NFC_CALL_OK;
  if (type.flags().testFlag(QMetaType::PointerToQObject) && value.kind == NFC_VALUE_HANDLE)
    return out.convert(type) ? NFC_CALL_OK : NFC_CALL_TYPE;
  return NFC_CALL_TYPE;
}

NfcCallStatus method_entry(void *closure, NfcCallFrame *frame) noexcept {
  try {
    auto *target = static_cast<MethodTarget *>(closure);
    if (!target) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid Qt method target");
    auto status = check_object(target->object, frame);
    if (status != NFC_CALL_OK) return status;
    const auto &method = target->method;
    if (!method.isValid() || !target->object->metaObject()->inherits(method.enclosingMetaObject()))
      return nfc_call_error(frame, NFC_CALL_INVALID, "method does not belong to QObject");
    Values values;
    status = nfc_call_read_values(frame, static_cast<size_t>(method.parameterCount()), values.values, 10);
    if (status != NFC_CALL_OK) return status;
    auto names = method.parameterTypes();
    QVariant arguments[10];
    QMetaType result_type = method.returnMetaType();
    int result_id = result_type.id();
    if (result_id != QMetaType::Void && result_id != QMetaType::Int && result_id != QMetaType::LongLong && result_id != QMetaType::Bool &&
        result_id != QMetaType::Double && result_id != QMetaType::QString && result_id != QMetaType::QByteArray && result_id != QMetaType::QVariant &&
        !result_type.flags().testFlag(QMetaType::PointerToQObject))
      return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "unsupported Qt result type");
    QVariant result;
    if (result_id != QMetaType::Void && result_id != QMetaType::QVariant) result = QVariant(result_type);
    QGenericArgument packed[10];
    for (int i = 0; i < method.parameterCount(); i++) {
      status = prepare(values.values[i], method.parameterMetaType(i), arguments[i]);
      if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported Qt argument or narrowing conversion");
      packed[i] = QGenericArgument(names[i].constData(), method.parameterMetaType(i).id() == QMetaType::QVariant ? &arguments[i] : arguments[i].constData());
    }
    bool is_void = result_type.id() == QMetaType::Void;
    QGenericReturnArgument returned = is_void ? QGenericReturnArgument{} :
      QGenericReturnArgument(method.typeName(), result_type.id() == QMetaType::QVariant ? &result : result.data());
    if (!method.invoke(target->object, Qt::DirectConnection, returned,
          packed[0], packed[1], packed[2], packed[3], packed[4], packed[5], packed[6], packed[7], packed[8], packed[9]))
      return nfc_call_error(frame, NFC_CALL_EXCEPTION, "Qt meta-method invocation failed");
    Value out;
    status = is_void ? NFC_CALL_OK : read_value(nullptr, &result, &out.value);
    if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported Qt method result");
    return nfc_call_write_value_result(frame, &out.value);
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in Qt method"); }
}

NfcCallStatus property_entry(void *closure, NfcCallFrame *frame) noexcept {
  try {
    auto *target = static_cast<PropertyTarget *>(closure);
    if (!target) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid Qt property target");
    auto status = check_object(target->object, frame);
    if (status != NFC_CALL_OK) return status;
    Values values;
    status = nfc_call_read_values(frame, target->write ? 1 : 0, values.values, 1);
    if (status != NFC_CALL_OK) return status;
    int index = target->object->metaObject()->indexOfProperty(target->name.constData());
    if (index < 0) return nfc_call_error(frame, NFC_CALL_INVALID, "Qt property not found");
    auto property = target->object->metaObject()->property(index);
    QVariant result;
    if (target->write) {
      QVariant input;
      status = prepare(values.values[0], property.metaType(), input);
      if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported Qt property conversion");
      if (!property.isWritable() || !property.write(target->object, input))
        return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "Qt property is not writable");
      result = input;
    } else {
      if (!property.isReadable()) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "Qt property is not readable");
      result = property.read(target->object);
    }
    Value out;
    status = read_value(nullptr, &result, &out.value);
    if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported Qt property result");
    return nfc_call_write_value_result(frame, &out.value);
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in Qt property"); }
}
} // namespace nfc::pathb::qt
