/* Optional adapter for nfcast's public embedding API. State access remains owner-thread confined. */
#ifndef NFCXX_PATHB_CALL_NFCAST_HPP
#define NFCXX_PATHB_CALL_NFCAST_HPP
#include "call_value.hpp"
#include "../ast/nfcast.hpp"
#include <vector>

namespace nfc::pathb::ast {
using Runtime = std::shared_ptr<::nfcast::State>;
inline int pin_value(const Runtime &state, ::nfcast::Value value) {
  if (!state) throw std::invalid_argument("nfcast runtime is null");
  return state->pin(value);
}
inline void unpin(const Runtime &state, int id) noexcept {
  // nfcast clears the pin before growing its free-index vector; a release must not throw on that allocation.
  try { state->unpin(id); } catch (...) {}
}
class RootedSlot {
  Runtime state_;
  ::nfcast::Value value_;
  int pin_;
public:
  RootedSlot(Runtime state, ::nfcast::Value value = {}) : state_(std::move(state)), value_(value), pin_(pin_value(state_, value)) {}
  ~RootedSlot() { unpin(state_, pin_); }
  RootedSlot(const RootedSlot &) = delete;
  RootedSlot &operator=(const RootedSlot &) = delete;
  const Runtime &state() const { return state_; }
  const ::nfcast::Value &get() const { return value_; }
  void assign(::nfcast::Value value) {
    int next = state_->pin(value), previous = pin_;
    value_ = value; pin_ = next; unpin(state_, previous);
  }
};
struct Pinned {
  static constexpr const char *type_name = "nfcast.PinnedValue";
  std::weak_ptr<::nfcast::State> state;
  int id;
  Pinned(const Runtime &runtime, ::nfcast::Value value) : state(runtime), id(pin_value(runtime, value)) {}
  Pinned(const Pinned &) = delete;
  Pinned(Pinned &&other) noexcept : state(std::move(other.state)), id(std::exchange(other.id, -1)) {}
  ~Pinned() { if (id >= 0) if (auto runtime = state.lock()) unpin(runtime, id); }
};
class Foreign final : public ::nfcast::HostObject {
public:
  Value value;
  explicit Foreign(const NfcValue &input) {
    if (nfc_value_copy(&value.value, &input) != NFC_CALL_OK) throw std::runtime_error("cannot retain foreign value");
  }
  static const void *key() { static const int type = 0; return &type; }
  const void *type_key() const override { return key(); }
  ::nfcast::HostMember *member(::nfcast::State &, ::nfcast::String *) override { return nullptr; }
};
inline NfcCallStatus read_i64(void *, const void *slot, int64_t *out) {
  const auto &value = *static_cast<const ::nfcast::Value *>(slot);
  if (value.t != ::nfcast::T_INT) return NFC_CALL_TYPE;
  *out = value.i; return NFC_CALL_OK;
}
inline NfcCallStatus write_i64(void *owner, void *, int64_t value) noexcept {
  try { static_cast<RootedSlot *>(owner)->assign(::nfcast::Value::integer(value)); return NFC_CALL_OK; }
  catch (...) { return NFC_CALL_EXCEPTION; }
}
inline NfcCallStatus read_value(void *owner, const void *slot, NfcValue *out) noexcept {
  try {
    auto *root = static_cast<RootedSlot *>(owner);
    const auto &value = *static_cast<const ::nfcast::Value *>(slot);
    if (value.t == ::nfcast::T_STR) return nfc_value_set_data(out, NFC_VALUE_BYTES, value.s()->data(), value.s()->len);
    if (value.t == ::nfcast::T_HOST && value.hostobj()->type_key() == Foreign::key())
      return nfc_value_copy(out, &static_cast<const Foreign *>(value.hostobj())->value.value);
    if (value.t == ::nfcast::T_TAB || value.t == ::nfcast::T_FUN || value.t == ::nfcast::T_HOST) return owned_handle(out, Pinned(root->state(), value));
    nfc_value_clear(out);
    switch (value.t) {
      case ::nfcast::T_NIL: break;
      case ::nfcast::T_FALSE:
      case ::nfcast::T_TRUE: out->kind = NFC_VALUE_BOOL; out->as.boolean = value.t == ::nfcast::T_TRUE; break;
      case ::nfcast::T_INT: out->kind = NFC_VALUE_I64; out->as.i64 = value.i; break;
      case ::nfcast::T_FLT: out->kind = NFC_VALUE_F64; out->as.f64 = value.d; break;
      default: return NFC_CALL_UNSUPPORTED;
    }
    return NFC_CALL_OK;
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
inline NfcCallStatus write_value(void *owner, void *, const NfcValue *value) noexcept {
  try {
    auto &root = *static_cast<RootedSlot *>(owner);
    auto &state = *root.state();
    ::nfcast::Value result;
    switch (value->kind) {
      case NFC_VALUE_NONE: break;
      case NFC_VALUE_BOOL: result = ::nfcast::Value::boolean(value->as.boolean); break;
      case NFC_VALUE_I64: result = ::nfcast::Value::integer(value->as.i64); break;
      case NFC_VALUE_F64: result = ::nfcast::Value::number(value->as.f64); break;
      case NFC_VALUE_TEXT:
      case NFC_VALUE_BYTES:
        if (value->as.buffer.size > UINT32_MAX) return NFC_CALL_TYPE;
        result = state.strv({reinterpret_cast<const char *>(value->as.buffer.data), value->as.buffer.size}); break;
      case NFC_VALUE_HANDLE:
        if (auto *pin = get_handle<Pinned>(*value)) {
          auto original = pin->state.lock();
          if (!original) return NFC_CALL_INVALID;
          if (original == root.state()) { result = original->pinned(pin->id); break; }
        }
        result = ::nfcast::Value::host(state.new_host<Foreign>(*value)); break;
      default: return NFC_CALL_TYPE;
    }
    root.assign(result); return NFC_CALL_OK;
  } catch (...) { return NFC_CALL_EXCEPTION; }
}
inline const NfcCallCodec codec{read_i64, write_i64, read_value, write_value};
inline NfcCallSlot slot(RootedSlot &value) { return {&codec, &value, const_cast<::nfcast::Value *>(&value.get())}; }

struct Target {
  static constexpr const char *type_name = "nfcast.CallTarget";
  Pinned function;
  size_t arity;
  bool utf8_result;
  Target(const Runtime &state, ::nfcast::Value fn, size_t nargs, bool text = false) : function(state, fn), arity(nargs), utf8_result(text) {}
};
inline NfcCallStatus entry(void *closure, NfcCallFrame *frame) noexcept {
  auto *target = static_cast<Target *>(closure);
  if (!target) return nfc_call_error(frame, NFC_CALL_INVALID, "invalid nfcast target");
  auto state = target->function.state.lock();
  if (!state) return nfc_call_error(frame, NFC_CALL_INVALID, "nfcast runtime has closed");
  try {
    Values values;
    auto status = nfc_call_read_values(frame, target->arity, values.values, NFC_CALL_I64_MAX_ARGS);
    if (status != NFC_CALL_OK) return status;
    std::vector<std::unique_ptr<RootedSlot>> roots;
    std::vector<::nfcast::Value> args;
    roots.reserve(frame->nargs); args.reserve(frame->nargs);
    for (size_t i = 0; i < frame->nargs; i++) {
      auto value = std::make_unique<RootedSlot>(state);
      status = write_value(value.get(), nullptr, &values.values[i]);
      if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported nfcast argument");
      args.push_back(value->get()); roots.push_back(std::move(value));
    }
    ::nfcast::Rets results;
    state->call(state->pinned(target->function.id), args.data(), static_cast<int>(args.size()), results);
    if (results.n > 1) return nfc_call_error(frame, NFC_CALL_UNSUPPORTED, "nfcast adapter requires at most one result");
    RootedSlot returned(state, results.first());
    Value result;
    status = read_value(&returned, &returned.get(), &result.value);
    if (status != NFC_CALL_OK) return nfc_call_error(frame, status, "unsupported nfcast result");
    if (target->utf8_result) {
      if (result.value.kind != NFC_VALUE_BYTES || !nfc_utf8_valid(result.value.as.buffer.data, result.value.as.buffer.size))
        return nfc_call_error(frame, NFC_CALL_TYPE, "nfcast result is not UTF-8 text");
      result.value.kind = NFC_VALUE_TEXT;
    }
    return nfc_call_write_value_result(frame, &result.value);
  } catch (const ::nfcast::Thrown &error) {
    try { RootedSlot pin(state, error.v); return nfc_call_error(frame, NFC_CALL_EXCEPTION, state->tostring(pin.get()).c_str()); }
    catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "nfcast error (formatting failed)"); }
  } catch (const std::exception &error) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, error.what()); }
  catch (...) { return nfc_call_error(frame, NFC_CALL_EXCEPTION, "foreign exception in nfcast call"); }
}

class Binding final : public ::nfcast::HostObject {
public:
  std::weak_ptr<::nfcast::State> state;
  NfcCallable callable;
  Value owner;
  Binding(const Runtime &runtime, NfcCallable fn, const NfcValue *lease) : state(runtime), callable(fn) { keep_owner(owner, lease); }
  const void *type_key() const override { static const int type = 0; return &type; }
  ::nfcast::HostMember *member(::nfcast::State &, ::nfcast::String *) override { return nullptr; }
};
inline void native_call(::nfcast::State &state, ::nfcast::Args args, ::nfcast::Rets &out, ::nfcast::Native &self) {
  auto *binding = static_cast<Binding *>(self.data);
  auto runtime = binding->state.lock();
  if (!runtime) state.rt_error("shared callable runtime has closed");
  try {
    if (args.n < 0 || static_cast<unsigned>(args.n) > NFC_CALL_I64_MAX_ARGS) state.rt_error("too many shared-call arguments");
    RootedSlot result(runtime);
    Value owner; keep_owner(owner, &binding->owner.value);
    NfcCallable callable = binding->callable;
    std::vector<std::unique_ptr<RootedSlot>> roots;
    NfcCallSlot inputs[NFC_CALL_I64_MAX_ARGS], returned = slot(result);
    for (int i = 0; i < args.n; i++) {
      auto value = std::make_unique<RootedSlot>(runtime, args[i]);
      inputs[i] = slot(*value); roots.push_back(std::move(value));
    }
    NfcCallFrame frame{NFC_CALL_VERSION, inputs, static_cast<size_t>(args.n), &returned, 1, 0, nullptr, {0}};
    auto status = nfc_call_invoke(&callable, &frame);
    if (status != NFC_CALL_OK) state.rt_error(frame.error);
    if (frame.nresults != 1) state.rt_error("shared callable must return one value");
    out.push(result.get());
  } catch (const std::exception &error) { state.rt_error(error.what()); }
}
inline std::unique_ptr<RootedSlot> import_callable(const Runtime &state, NfcCallable callable, const char *name, const NfcValue *owner = nullptr) {
  auto *binding = state->new_host<Binding>(state, callable, owner);
  RootedSlot pin(state, ::nfcast::Value::host(binding));
  auto fn = state->new_native(native_call, state->keep_name(name), binding, pin.get());
  return std::make_unique<RootedSlot>(state, ::nfcast::Value::function(fn));
}
} // namespace nfc::pathb::ast
#endif
