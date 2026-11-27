#include "external_common.hpp"
#include "../../../lib/pathb/call_tvm.hpp"
namespace bridge = nfc::pathb::tvm;
struct Function {
  TVMFFIObjectHandle value = nullptr;
  ~Function() { if (value) TVMFFIObjectDecRef(value); }
};
static TVMFFIAny integer(int64_t value) {
  TVMFFIAny out{}; out.type_index = kTVMFFIInt; out.v_int64 = value; return out;
}
static std::string take_error() {
  Function error;
  TVMFFIErrorMoveFromRaised(&error.value);
  check(error.value != nullptr, "TVM error object");
  auto *cell = TVMFFIErrorGetCellPtr(error.value);
  return std::string(cell->kind.data, cell->kind.size) + ": " + std::string(cell->message.data, cell->message.size);
}
static int multiply(void *, const TVMFFIAny *args, int32_t count, TVMFFIAny *out) {
  if (count != 2 || args[0].type_index != kTVMFFIInt || args[1].type_index != kTVMFFIInt)
    return bridge::fail("TypeError", "two integers required");
  if (args[0].v_int64 < 0) return bridge::fail("ValueError", "negative input");
  *out = integer(args[0].v_int64 * args[1].v_int64); return 0;
}
static int string_result(void *, const TVMFFIAny *, int32_t, TVMFFIAny *out) {
  const char bytes[] = "owned string result beyond small-string storage";
  TVMFFIByteArray text{bytes, sizeof bytes - 1};
  return TVMFFIStringFromByteArray(&text, out);
}
static void body(MV *ret) {
  mrb_irep_0(ret);
  Function sum, div, native, text;
  check(bridge::create_function(sum_callable, &sum.value) == 0, "create TVM function from Ruby");
  check(bridge::create_function(divide_callable, &div.value) == 0, "create TVM divide");
  TVMFFIAny args[2] = {integer(20), integer(22)}, result{};
  check(TVMFFIFunctionCall(sum.value, args, 2, &result) == 0 && result.v_int64 == 42, "TVM function calls Ruby");
  args[0] = integer(INT64_MAX); args[1] = integer(0); result = {};
  check(TVMFFIFunctionCall(sum.value, args, 2, &result) == 0 && result.v_int64 == INT64_MAX, "TVM full-width integer");
  result = {};
  check(TVMFFIFunctionCall(div.value, args, 2, &result) != 0, "Ruby error to TVM");
  check(take_error().find("ZeroDivisionError") != std::string::npos, "Ruby diagnostic through TVM TLS");
  args[0].type_index = kTVMFFIBool;
  check(TVMFFIFunctionCall(sum.value, args, 2, &result) != 0 && take_error().find("TypeError") != std::string::npos, "TVM bool is not integer");
  args[0] = integer(20); args[1] = integer(22);
  check(TVMFFIFunctionCall(sum.value, args, 1, &result) != 0 && take_error().find("TypeError") != std::string::npos, "TVM argument count");
  check(TVMFFIFunctionCall(sum.value, args, 2, &result) == 0 && result.v_int64 == 42, "TVM call recovers");
  check(TVMFFIFunctionCreate(nullptr, multiply, nullptr, &native.value) == 0, "create independent TVM function");
  check(TVMFFIFunctionCreate(nullptr, string_result, nullptr, &text.value) == 0, "create owned-result TVM function");
  MV values[3]; MrbbcGCFrame roots; mrbbc_gc_enter(&roots, values, 3);
  mrbbc_int_new(&values[0], 6); mrbbc_int_new(&values[1], 7);
  NfcCallSlot inputs[2] = {mrbbc_call_slot(&values[0]), mrbbc_call_slot(&values[1])};
  NfcCallSlot output = mrbbc_call_slot(&values[2]);
  NfcCallFrame frame{NFC_CALL_VERSION, inputs, 2, &output, 1, 0, nullptr, {0}};
  bridge::Target target{native.value, 2}; NfcCallable callable{bridge::entry, &target};
  int64_t number = 0;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == 42, "Ruby boxed values call TVM");
  mrbbc_int_new(&values[0], -1);
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_EXCEPTION && std::strstr(frame.error, "negative input"), "TVM error to frame");
  target = {text.value, 0}; frame.nargs = 0;
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_tag(&values[2]) == MRBBC_STR, "owned TVM string result converted and released");
  target = {sum.value, 2}; frame.nargs = 2;
  mrbbc_int_new(&values[0], INT64_MIN); mrbbc_int_new(&values[1], 0);
  check(nfc_call_invoke(&callable, &frame) == NFC_CALL_OK && mrbbc_int_read(&values[2], &number) && number == INT64_MIN, "Ruby boxes round trip through TVM function");
  {
    NfcValueTarget echo{1, copy_value, nullptr}; NfcCallable generic{nfc_call_value_entry, &echo};
    Function echo_function;
    check(bridge::create_function(generic, &echo_function.value) == 0, "create generic TVM function");
    nfc::pathb::Values samples;
    samples.values[1].kind = NFC_VALUE_BOOL; samples.values[1].as.boolean = 1;
    samples.values[2].kind = NFC_VALUE_I64; samples.values[2].as.i64 = INT64_MIN;
    samples.values[3].kind = NFC_VALUE_F64; samples.values[3].as.f64 = -0.0;
    nfc_value_set_data(&samples.values[4], NFC_VALUE_TEXT, "日本語\0text", sizeof("日本語\0text") - 1);
    nfc_value_set_data(&samples.values[5], NFC_VALUE_BYTES, "\xff\0bytes", 7);
    for (size_t i = 0; i < 6; i++) {
      bridge::AnyResult input, output;
      nfc::pathb::Value decoded;
      check(bridge::write_value(nullptr, &input.value, &samples.values[i]) == NFC_CALL_OK, "encode TVM generic value");
      check(TVMFFIFunctionCall(echo_function.value, &input.value, 1, &output.value) == 0, "TVM generic safe call");
      check(bridge::read_value(nullptr, &output.value, &decoded.value) == NFC_CALL_OK && same_value(decoded.value, samples.values[i]), "TVM primitive/text/binary round trip");
    }
    MrbbcValueTarget ruby_echo{"allocate_echo", 1, 0}; NfcCallable ruby_generic{mrbbc_value_call_entry, &ruby_echo};
    bridge::AnyResult function_value;
    function_value.value.type_index = kTVMFFIFunction;
    TVMFFIObjectIncRef(echo_function.value);
    function_value.value.v_obj = static_cast<TVMFFIObject *>(echo_function.value);
    nfc::pathb::Value captured, returned;
    check(bridge::read_value(nullptr, &function_value.value, &captured.value) == NFC_CALL_OK && captured.value.kind == NFC_VALUE_HANDLE, "retain TVM object handle");
    NfcCallSlot input_slot = nfc_call_value_slot(&captured.value), output_slot = nfc_call_value_slot(&returned.value);
    NfcCallFrame object_frame{NFC_CALL_VERSION, &input_slot, 1, &output_slot, 1, 0, nullptr, {0}};
    check(nfc_call_invoke(&ruby_generic, &object_frame) == NFC_CALL_OK, "TVM function handle through compiled Ruby");
    nfc_value_clear(&captured.value); mrbbc_gc_collect();
    auto *retained = nfc::pathb::get_handle<bridge::ObjectRef>(returned.value);
    check(retained && retained->value == echo_function.value, "TVM handle identity/lifetime preserved");
  }
  auto released = std::make_shared<int>(0);
  {
    nfc::pathb::Value owner;
    nfc::pathb::owned_handle(&owner.value, OwnedTarget(released));
    auto *provider = nfc::pathb::get_handle<OwnedTarget>(owner.value);
    NfcCallable fn{nfc_call_value_entry, const_cast<NfcValueTarget *>(&provider->target)};
    Function owned;
    check(bridge::create_function(fn, &owned.value, &owner.value) == 0, "TVM Function retains callable owner");
    nfc_value_clear(&owner.value);
    check(*released == 0, "provider survives caller releasing owner");
    TVMFFIAny input = integer(7), output{};
    check(TVMFFIFunctionCall(owned.value, &input, 1, &output) == 0 && output.v_int64 == 7, "owned TVM closure remains callable");
  }
  check(*released == 1, "TVM Function releases closure owner exactly once");
  mrbbc_gc_leave(&roots);
}
int main() { MV ret{}; mrbbc_run(body, &ret); std::printf("tvm-ffi: %d checks passed\n", checks); }
