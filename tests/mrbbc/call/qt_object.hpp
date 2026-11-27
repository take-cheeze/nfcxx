#ifndef NFCXX_CALL_QT_TEST_OBJECT_HPP
#define NFCXX_CALL_QT_TEST_OBJECT_HPP
#include <QObject>
#include <QVariant>
#include <stdexcept>
class CallCounter final : public QObject {
  Q_OBJECT
  Q_PROPERTY(qlonglong count READ count WRITE setCount NOTIFY countChanged)
  Q_PROPERTY(qlonglong frozen READ count)
  Q_PROPERTY(int level MEMBER level_)
public:
  qlonglong count() const { return count_; }
  void setCount(qlonglong value) { count_ = value; Q_EMIT countChanged(value); }
  Q_INVOKABLE qlonglong add(qlonglong a, qlonglong b) { return a + b; }
  Q_INVOKABLE qlonglong fail() { throw std::runtime_error("Qt method failure"); }
  Q_INVOKABLE int increment(int value) { return value + 1; }
  Q_INVOKABLE QString text() { return QStringLiteral("text"); }
Q_SIGNALS:
  void countChanged(qlonglong value);
  void requested(QVariantList args);
private:
  qlonglong count_ = 0;
  int level_ = 0;
};
#endif
