/* Optional Qt 6 Core bridge. Synchronous calls on the QObject's owning thread only. */
#ifndef NFCXX_PATHB_CALL_QT_HPP
#define NFCXX_PATHB_CALL_QT_HPP
#include "call_value.hpp"
#include <QObject>
#include <QMetaMethod>
#include <QPointer>
#include <QVariant>

namespace nfc::pathb::qt {
struct ObjectRef {
  static constexpr const char *type_name = "Qt.QPointer";
  QPointer<QObject> value;
};
extern const NfcCallCodec codec;
inline NfcCallSlot slot(QVariant &value) { return {&codec, nullptr, &value}; }

class CallableObject final : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString lastError READ lastError NOTIFY errorChanged)
  Q_PROPERTY(int lastStatus READ lastStatus NOTIFY errorChanged)
public:
  explicit CallableObject(NfcCallable callable, QObject *parent = nullptr, const NfcValue *owner = nullptr);
  QString lastError() const { return error_; }
  int lastStatus() const { return status_; }
public Q_SLOTS:
  QVariant call(QVariantList args);
Q_SIGNALS:
  void resultReady(qlonglong value);
  void valueReady(QVariant value);
  void callFailed(QString message);
  void errorChanged();
private:
  NfcCallable callable_;
  Value owner_;
  QThread *runtime_thread_;
  QString error_;
  int status_ = NFC_CALL_OK;
};

struct MethodTarget {
  QPointer<QObject> object;
  QMetaMethod method;
};
struct PropertyTarget {
  QPointer<QObject> object;
  QByteArray name;
  bool write;
};
NfcCallStatus method_entry(void *closure, NfcCallFrame *frame) noexcept;
NfcCallStatus property_entry(void *closure, NfcCallFrame *frame) noexcept;
} // namespace nfc::pathb::qt
#endif
