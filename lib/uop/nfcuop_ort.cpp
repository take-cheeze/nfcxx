// nfcuop ONNX Runtime backend (nfcuop_ort.hpp). The library is opened with dlopen at first use, like the C back end's
// modules (nfcuop_cgen.cpp), so nothing is linked against ONNX Runtime.
//
// The C API declarations below are a subset of ONNX Runtime's include/onnxruntime/core/session/onnxruntime_c_api.h,
// release 1.29.0 (ORT_API_VERSION 29). The header is (c) Microsoft Corporation and MIT licensed:
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files, to deal in the Software without restriction, ... THE SOFTWARE IS PROVIDED "AS IS" ...
// The OrtApi table is a struct of function pointers in a fixed order, and the release only appends to it. So each member
// that is called is declared with its type at its index in the header, and the members that are not called are reserved
// slots of the same size; the index of each one is in the comment. Only the first 101 members are declared (the last one
// called is ReleaseSessionOptions, index 100). The types of the enums are plain ints (the C ABI passes them so).
#include "nfcuop_ort.hpp"

#include <dlfcn.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace nfcuop {
namespace ort {
namespace {

namespace abi {
struct OrtStatus;
struct OrtEnv;
struct OrtSession;
struct OrtSessionOptions;
struct OrtRunOptions;
struct OrtValue;
struct OrtMemoryInfo;
struct OrtTensorTypeAndShapeInfo;

struct OrtApi {
  void* reserved_0;                                                                                  // 0 CreateStatus
  int (*GetErrorCode)(const OrtStatus* status);                                                       // 1
  const char* (*GetErrorMessage)(const OrtStatus* status);                                            // 2
  OrtStatus* (*CreateEnv)(int log_severity_level, const char* logid, OrtEnv** out);                   // 3
  void* reserved_4_6[3];                                                                             // 4 .. 6
  void* reserved_7;                                                                                  // 7 CreateSession
  OrtStatus* (*CreateSessionFromArray)(const OrtEnv* env, const void* model_data, size_t model_data_length,
                                       const OrtSessionOptions* options, OrtSession** out);          // 8
  OrtStatus* (*Run)(OrtSession* session, const OrtRunOptions* run_options, const char* const* input_names,
                    const OrtValue* const* inputs, size_t input_len, const char* const* output_names,
                    size_t output_names_len, OrtValue** outputs);                                    // 9
  OrtStatus* (*CreateSessionOptions)(OrtSessionOptions** options);                                   // 10
  void* reserved_11_48[38];                                                                          // 11 .. 48
  OrtStatus* (*CreateTensorWithDataAsOrtValue)(const OrtMemoryInfo* info, void* p_data, size_t p_data_len,
                                               const int64_t* shape, size_t shape_len, int type,
                                               OrtValue** out);                                      // 49
  void* reserved_50;                                                                                 // 50 IsTensor
  OrtStatus* (*GetTensorMutableData)(OrtValue* value, void** out);                                   // 51
  void* reserved_52_59[8];                                                                           // 52 .. 59
  OrtStatus* (*GetTensorElementType)(const OrtTensorTypeAndShapeInfo* info, int* out);               // 60
  OrtStatus* (*GetDimensionsCount)(const OrtTensorTypeAndShapeInfo* info, size_t* out);              // 61
  OrtStatus* (*GetDimensions)(const OrtTensorTypeAndShapeInfo* info, int64_t* dim_values,
                              size_t dim_values_length);                                           // 62
  void* reserved_63_64[2];                                                                           // 63, 64
  OrtStatus* (*GetTensorTypeAndShape)(const OrtValue* value, OrtTensorTypeAndShapeInfo** out);       // 65
  void* reserved_66_68[3];                                                                           // 66 .. 68
  OrtStatus* (*CreateCpuMemoryInfo)(int type, int mem_type, OrtMemoryInfo** out);                    // 69
  void* reserved_70_91[22];                                                                          // 70 .. 91
  void (*ReleaseEnv)(OrtEnv* input);                                                                 // 92
  void (*ReleaseStatus)(OrtStatus* input);                                                           // 93
  void (*ReleaseMemoryInfo)(OrtMemoryInfo* input);                                                   // 94
  void (*ReleaseSession)(OrtSession* input);                                                         // 95
  void (*ReleaseValue)(OrtValue* input);                                                             // 96
  void* reserved_97_98[2];                                                                           // 97, 98
  void (*ReleaseTensorTypeAndShapeInfo)(OrtTensorTypeAndShapeInfo* input);                          // 99
  void (*ReleaseSessionOptions)(OrtSessionOptions* input);                                           // 100
};

struct OrtApiBase {
  const OrtApi* (*GetApi)(uint32_t version);
  const char* (*GetVersionString)();
};
}  // namespace abi

// The header's values used here.
const uint32_t kApiVersion = 29;          // ORT_API_VERSION of the header
const int kLoggingWarning = 2;            // ORT_LOGGING_LEVEL_WARNING
const int kAllocatorDevice = 0;           // OrtDeviceAllocator
const int kMemTypeDefault = 0;            // OrtMemTypeDefault
const int kFloat = 1, kInt32 = 6, kInt64 = 7, kBool = 9, kDouble = 11;  // ONNXTensorElementDataType

struct Runtime {
  void* lib = nullptr;
  const abi::OrtApi* api = nullptr;
  abi::OrtEnv* env = nullptr;
};
// Set once the library is loaded. A failed load throws and leaves this null, so the next call tries again (with the
// environment as it is then).
Runtime* g_runtime = nullptr;
std::map<std::string, abi::OrtSession*> g_sessions;  // by model bytes

std::string dl_error() {
  const char* e = dlerror();
  return e ? e : "unknown error";
}

// Throws the status's message (and frees the status) when it is not null.
void check(const abi::OrtApi* api, abi::OrtStatus* st, const char* what) {
  if (!st) return;
  std::string msg = api->GetErrorMessage(st);
  api->ReleaseStatus(st);
  throw Error(std::string("nfcuop ort: ") + what + " failed: " + msg);
}

Runtime* load() {
  void* lib = nullptr;
  const char* path = std::getenv("NFCUOP_ORT_LIB");
  if (path && *path) {
    lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) throw Error("nfcuop ort: cannot load NFCUOP_ORT_LIB=" + std::string(path) + ": " + dl_error());
  } else {
    const char* const names[] = {"libonnxruntime.so.1", "libonnxruntime.so", "libonnxruntime.dylib"};
    std::string err;
    for (const char* n : names) {
      lib = dlopen(n, RTLD_NOW | RTLD_LOCAL);
      if (lib) break;
      err += "; " + dl_error();  // dlerror names the file
    }
    if (!lib) throw Error("nfcuop ort: ONNX Runtime not found; set NFCUOP_ORT_LIB to the path of libonnxruntime" + err);
  }
  auto get_base = reinterpret_cast<const abi::OrtApiBase* (*)()>(dlsym(lib, "OrtGetApiBase"));
  if (!get_base) throw Error("nfcuop ort: no OrtGetApiBase in " + std::string(path ? path : "libonnxruntime") + ": not ONNX Runtime");
  const abi::OrtApiBase* base = get_base();
  const abi::OrtApi* api = base ? base->GetApi(kApiVersion) : nullptr;
  if (!api) throw Error("nfcuop ort: the library has no C API version " + std::to_string(kApiVersion) + " (ONNX Runtime 1.29 or newer is needed)");
  abi::OrtEnv* env = nullptr;
  check(api, api->CreateEnv(kLoggingWarning, "nfcuop", &env), "CreateEnv");
  Runtime* rt = new Runtime();
  rt->lib = lib;
  rt->api = api;
  rt->env = env;
  return rt;
}

const Runtime& runtime() {
  if (!g_runtime) g_runtime = load();
  return *g_runtime;
}

abi::OrtSession* session_for(const Runtime& rt, const std::string& model) {
  auto it = g_sessions.find(model);
  if (it != g_sessions.end()) return it->second;
  abi::OrtSessionOptions* opts = nullptr;
  check(rt.api, rt.api->CreateSessionOptions(&opts), "CreateSessionOptions");
  abi::OrtSession* s = nullptr;
  abi::OrtStatus* st = rt.api->CreateSessionFromArray(rt.env, model.data(), model.size(), opts, &s);
  rt.api->ReleaseSessionOptions(opts);
  check(rt.api, st, "CreateSessionFromArray");
  g_sessions[model] = s;
  return s;
}

size_t elem_size(DType d) {
  switch (d) {
    case DType::Bool: return 1;
    case DType::Int32: case DType::Float32: return 4;
    case DType::Int64: case DType::Float64: return 8;
  }
  return 0;
}

// The elements of an array in ONNX's layout (little endian, Bool one byte).
std::vector<unsigned char> to_bytes(const Array& a) {
  std::vector<unsigned char> out(a.data.size() * elem_size(a.dtype));
  unsigned char* p = out.data();
  for (const Scalar& s : a.data) {
    switch (a.dtype) {
      case DType::Bool: { *p = s.i ? 1 : 0; break; }
      case DType::Int32: { int32_t v = static_cast<int32_t>(s.i); std::memcpy(p, &v, 4); break; }
      case DType::Int64: { int64_t v = s.i; std::memcpy(p, &v, 8); break; }
      case DType::Float32: { float v = static_cast<float>(s.f); std::memcpy(p, &v, 4); break; }
      case DType::Float64: { double v = s.f; std::memcpy(p, &v, 8); break; }
    }
    p += elem_size(a.dtype);
  }
  return out;
}

Array from_bytes(DType d, const Shape& shape, const unsigned char* p) {
  std::vector<Scalar> v;
  v.reserve(static_cast<size_t>(numel(shape)));
  for (int64_t k = 0; k < numel(shape); k++, p += elem_size(d)) {
    switch (d) {
      case DType::Bool: v.push_back(Scalar::from_int(d, *p)); break;
      case DType::Int32: { int32_t x; std::memcpy(&x, p, 4); v.push_back(Scalar::from_int(d, x)); break; }
      case DType::Int64: { int64_t x; std::memcpy(&x, p, 8); v.push_back(Scalar::from_int(d, x)); break; }
      case DType::Float32: { float x; std::memcpy(&x, p, 4); v.push_back(Scalar::from_double(d, x)); break; }
      case DType::Float64: { double x; std::memcpy(&x, p, 8); v.push_back(Scalar::from_double(d, x)); break; }
    }
  }
  return Array(d, shape, std::move(v));
}

DType dtype_of_onnx(int t) {
  switch (t) {
    case kFloat: return DType::Float32;
    case kDouble: return DType::Float64;
    case kInt32: return DType::Int32;
    case kInt64: return DType::Int64;
    case kBool: return DType::Bool;
  }
  throw Error("nfcuop ort: an output has ONNX element type " + std::to_string(t) + ", which the backend does not read");
}

// The ORT values of a run, released when the run ends (also on an error).
struct Held {
  const abi::OrtApi* api;
  std::vector<abi::OrtValue*> values;
  abi::OrtMemoryInfo* mem = nullptr;
  explicit Held(const abi::OrtApi* a) : api(a) {}
  ~Held() {
    for (abi::OrtValue* v : values) if (v) api->ReleaseValue(v);
    if (mem) api->ReleaseMemoryInfo(mem);
  }
  Held(const Held&) = delete;
  Held& operator=(const Held&) = delete;
};

// The feed of graph input `id`: its dtype and rank must be the graph's, its static dimensions equal, and each symbol bound to
// one size (the first feed that has it fixes it).
void check_feed(const hir::Graph& g, int id, const Array& a, std::map<std::string, int64_t>& syms) {
  const hir::Value& v = g.value(id);
  if (a.dtype != v.dtype) throw Error("nfcuop ort: feed " + v.name + " is " + name(a.dtype) + ", the graph has " + name(v.dtype));
  if (a.shape.size() != v.shape.size()) throw Error("nfcuop ort: feed " + v.name + " has rank " + std::to_string(a.shape.size()) + ", the graph " + std::to_string(v.shape.size()));
  for (size_t k = 0; k < v.shape.size(); k++) {
    const std::string sym = v.syms.empty() ? "" : v.syms[k];
    if (sym.empty()) {
      if (a.shape[k] != v.shape[k]) throw Error("nfcuop ort: feed " + v.name + " has shape " + to_string(a.shape) + ", the graph " + to_string(v.shape));
      continue;
    }
    auto it = syms.find(sym);
    if (it == syms.end()) syms[sym] = a.shape[k];
    else if (it->second != a.shape[k]) throw Error("nfcuop ort: symbol " + sym + " is " + std::to_string(it->second) + " in one feed and " + std::to_string(a.shape[k]) + " in another");
  }
}

}  // namespace

bool available(std::string* why) {
  try {
    runtime();
    return true;
  } catch (const Error& e) {
    if (why) *why = e.what();
    return false;
  }
}

std::vector<Array> run(const hir::Graph& g, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds) {
  const Runtime& rt = runtime();
  std::vector<Array> result(outputs.size());
  // Outputs that are inputs or initializers are returned directly; the others are computed by the exported model.
  std::vector<int> computed;
  std::vector<size_t> slot;
  for (size_t k = 0; k < outputs.size(); k++) {
    int o = outputs[k];
    if (g.producer(o) >= 0) {
      computed.push_back(o);
      slot.push_back(k);
    } else if (const Array* a = g.initializer(o)) {
      result[k] = *a;
    } else {
      auto f = feeds.find(g.value(o).name);
      if (f == feeds.end()) throw Error("nfcuop ort: no feed for input " + g.value(o).name);
      std::map<std::string, int64_t> syms;
      check_feed(g, o, f->second, syms);
      result[k] = f->second;
    }
  }
  if (computed.empty()) return result;

  // The inputs the computed outputs depend on (Graph::to_onnx writes exactly these).
  std::set<int> seen, inputs;
  std::vector<int> stack = computed;
  while (!stack.empty()) {
    int v = stack.back();
    stack.pop_back();
    if (!seen.insert(v).second) continue;
    int p = g.producer(v);
    if (p < 0) {
      if (!g.initializer(v)) inputs.insert(v);
      continue;
    }
    for (int in : g.nodes()[static_cast<size_t>(p)].inputs)
      if (in >= 0) stack.push_back(in);
  }
  std::map<std::string, int64_t> syms;
  std::vector<std::string> in_names;
  std::vector<std::vector<unsigned char>> in_bytes;
  std::vector<std::vector<int64_t>> in_dims;
  for (int id : inputs) {
    const std::string& nm = g.value(id).name;
    auto f = feeds.find(nm);
    if (f == feeds.end()) throw Error("nfcuop ort: no feed for input " + nm);
    check_feed(g, id, f->second, syms);
    in_names.push_back(nm);
    in_bytes.push_back(to_bytes(f->second));
    in_dims.push_back(f->second.shape);
  }

  std::string model = g.to_onnx(computed);
  abi::OrtSession* session = session_for(rt, model);
  const abi::OrtApi* api = rt.api;
  Held held(api);
  check(api, api->CreateCpuMemoryInfo(kAllocatorDevice, kMemTypeDefault, &held.mem), "CreateCpuMemoryInfo");
  std::vector<const char*> in_c;
  std::vector<const abi::OrtValue*> in_v;
  for (size_t k = 0; k < in_names.size(); k++) {
    abi::OrtValue* val = nullptr;
    const Array& feed = feeds.at(in_names[k]);
    check(api, api->CreateTensorWithDataAsOrtValue(held.mem, in_bytes[k].data(), in_bytes[k].size(), in_dims[k].data(),
                                                   in_dims[k].size(), hir::onnx_dtype(feed.dtype), &val),
          "CreateTensorWithDataAsOrtValue");
    held.values.push_back(val);
    in_c.push_back(in_names[k].c_str());
    in_v.push_back(val);
  }
  std::vector<const char*> out_c;
  for (int o : computed) out_c.push_back(g.value(o).name.c_str());
  std::vector<abi::OrtValue*> outs(computed.size(), nullptr);
  check(api, api->Run(session, nullptr, in_c.data(), in_v.data(), in_v.size(), out_c.data(), out_c.size(), outs.data()), "Run");
  for (abi::OrtValue* o : outs) held.values.push_back(o);  // released with the inputs when this run ends

  for (size_t k = 0; k < computed.size(); k++) {
    const hir::Value& v = g.value(computed[k]);
    abi::OrtTensorTypeAndShapeInfo* info = nullptr;
    check(api, api->GetTensorTypeAndShape(outs[k], &info), "GetTensorTypeAndShape");
    int et = 0;
    size_t nd = 0;
    check(api, api->GetTensorElementType(info, &et), "GetTensorElementType");
    check(api, api->GetDimensionsCount(info, &nd), "GetDimensionsCount");
    std::vector<int64_t> dims(nd);
    if (nd) check(api, api->GetDimensions(info, dims.data(), nd), "GetDimensions");
    api->ReleaseTensorTypeAndShapeInfo(info);
    DType d = dtype_of_onnx(et);
    if (d != v.dtype || nd != v.shape.size())
      throw Error("nfcuop ort: output " + v.name + " is " + name(d) + " of rank " + std::to_string(nd) + ", the graph has " + name(v.dtype) + " of rank " + std::to_string(v.shape.size()));
    void* data = nullptr;
    check(api, api->GetTensorMutableData(outs[k], &data), "GetTensorMutableData");
    Shape shape(dims.begin(), dims.end());
    result[slot[k]] = from_bytes(d, shape, static_cast<const unsigned char*>(data));
  }
  return result;
}

}  // namespace ort
}  // namespace nfcuop
