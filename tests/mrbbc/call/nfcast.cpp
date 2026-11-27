#include "external_common.hpp"
#include "../../../lib/pathb/call_nfcast.hpp"
namespace bridge = nfc::pathb::ast;
static std::unique_ptr<bridge::RootedSlot> load_function(const bridge::Runtime &state, const char *code) {
  std::string error;
  auto *chunk = state->load(code, "shared-call", &error);
  check(chunk != nullptr, error.c_str());
  bridge::RootedSlot pinned(state, ::nfcast::Value::function(chunk));
  ::nfcast::Rets results;
  state->call(pinned.get(), nullptr, 0, results);
  check(results.n == 1 && results.first().t == ::nfcast::T_FUN, "load nfcast function");
  return std::make_unique<bridge::RootedSlot>(state, results.first());
}
static void install(const bridge::Runtime &state, const char *name, bridge::RootedSlot &value) {
  state->globals->set_str(*state, state->str(name), value.get());
}
static void body(MV *ret) {
  mrb_irep_0(ret);
  auto state = std::make_shared<::nfcast::State>(); state->open_libs(); state->gc_stress = true;
  auto sum = bridge::import_callable(state, sum_callable, "shared_sum"); install(state, "shared_sum", *sum);
  auto div = bridge::import_callable(state, divide_callable, "shared_divide"); install(state, "shared_divide", *div);
  auto function = load_function(state, "return function(a,b) return shared_sum(a,b) end");
  bridge::Target target(state, function->get(), 2);
  NfcCallable callable{bridge::entry, &target};
  int64_t x = 20, y = 22, answer = 0;
  NfcCallSlot inputs[2] = {nfc_call_i64_slot(&x), nfc_call_i64_slot(&y)}, result = nfc_call_i64_slot(&answer);
  NfcCallFrame frame{NFC_CALL_VERSION, inputs, 2, &result, 1, 0, nullptr, {0}};
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && answer == 42, "shared frame to nfcast script to compiled Ruby and back");
  auto failing = load_function(state, "return function(a,b) return shared_divide(a,b) end");
  bridge::Target failure(state, failing->get(), 2); callable.closure = &failure; x = 1; y = 0;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_EXCEPTION && std::strstr(frame.error, "ZeroDivisionError"), "Ruby error propagates through nfcast native call");
  x = 6; y = 2;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && answer == 3, "nfcast call state recovers after foreign error");
  MrbbcValueTarget ruby_echo{"allocate_echo", 1, 0};
  auto echo = bridge::import_callable(state, {mrbbc_value_call_entry, &ruby_echo}, "shared_echo"); install(state, "shared_echo", *echo);
  auto text_fn = load_function(state, "return function(v) local t={v}; return shared_echo(t[1]) end");
  bridge::Target text_target(state, text_fn->get(), 1); callable.closure = &text_target;
  nfc::pathb::Value input, output;
  nfc_value_set_data(&input.value, NFC_VALUE_BYTES, "a\0\xff", 3);
  inputs[0] = nfc_call_value_slot(&input.value); result = nfc_call_value_slot(&output.value); frame.nargs = 1;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && same_value(input.value, output.value), "binary nfcast/Ruby round trip with both GCs active");
  input.value.kind = NFC_VALUE_BYTES;
  nfc_value_set_data(&input.value, NFC_VALUE_TEXT, "日本語\0text", sizeof("日本語\0text") - 1);
  text_target.utf8_result = true;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && same_value(input.value, output.value), "strict UTF-8 nfcast export result");
  text_target.utf8_result = false;
  auto float_fn = load_function(state, "return function(v) return v + 0.5 end");
  bridge::Target float_target(state, float_fn->get(), 1); callable.closure = &float_target;
  nfc_value_clear(&input.value); input.value.kind = NFC_VALUE_F64; input.value.as.f64 = 1.25;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && output.value.kind == NFC_VALUE_F64 && output.value.as.f64 == 1.75, "nfcast floating boxed function");
  {
    bridge::RootedSlot rooted(state, state->strv("pinned across collect"));
    NfcCallSlot native = bridge::slot(rooted);
    state->collect();
    check(native.codec->read_value(native.owner, native.data, &output.value) == NFC_CALL_OK && output.value.kind == NFC_VALUE_BYTES, "nfcast native slots are pinned");
    auto *table = state->new_table();
    rooted.assign(::nfcast::Value::table(table));
    check(native.codec->read_value(native.owner, native.data, &input.value) == NFC_CALL_OK && input.value.kind == NFC_VALUE_HANDLE, "pin nfcast object in opaque handle");
    rooted.assign({}); state->collect();
    check(native.codec->write_value(native.owner, native.data, &input.value) == NFC_CALL_OK && rooted.get().tab() == table, "nfcast handle keeps object alive across collection");
    NfcCallable ruby{mrbbc_value_call_entry, &ruby_echo};
    check(nfc_call_invoke(&ruby, &frame) == NFC_CALL_OK && output.value.kind == NFC_VALUE_HANDLE, "nfcast table handle crosses compiled Ruby opaquely");
  }
  {
    auto count = std::make_shared<int>(0);
    nfc::pathb::Value owner; nfc::pathb::owned_handle(&owner.value, OwnedTarget(count));
    auto *provider = nfc::pathb::get_handle<OwnedTarget>(owner.value);
    auto imported = bridge::import_callable(state, {nfc_call_value_entry, const_cast<NfcValueTarget *>(&provider->target)}, "owned", &owner.value);
    nfc_value_clear(&owner.value); check(*count == 0, "nfcast native binding retains provider");
    imported.reset(); state->collect(); check(*count == 1, "nfcast collector releases unreferenced native binding owner");
  }
  std::unique_ptr<bridge::Target> expired;
  {
    auto temporary = std::make_shared<::nfcast::State>();
    auto fn = load_function(temporary, "return function() return 1 end");
    expired = std::make_unique<bridge::Target>(temporary, fn->get(), 0);
  }
  callable.closure = expired.get(); frame.nargs = 0;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_INVALID, "closed nfcast runtime is rejected without dangling pin access");
}
int main() { MV ret{}; mrbbc_run(body, &ret); std::printf("nfcast shared calls: %d checks passed\n", checks); }
