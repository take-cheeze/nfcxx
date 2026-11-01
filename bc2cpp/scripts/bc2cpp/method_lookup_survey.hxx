// Native-only diagnostic storage: observers cannot allocate mruby objects.
#pragma once

#include <execinfo.h>
#include <map>
#include <string>
#include <tuple>

namespace lookup_survey {
using Key = std::pair<uintptr_t, mrb_sym>;
struct Counts {
  unsigned long long phase[3]{};
};
struct Entry {
  Key key;
  std::string owner;
  std::string name;
  const char* kind;
  uintptr_t address;
};
struct Stack {
  Key key;
  unsigned phase;
  std::vector<void*> frames;
  bool operator<(const Stack& other) const {
    return std::tie(key, phase, frames) <
           std::tie(other.key, other.phase, other.frames);
  }
};
std::map<Key, Counts> counts;
std::map<mrb_sym, std::string> names;
std::map<Stack, unsigned long long> stacks;
std::vector<Entry> entries;
bool gameplay = false;
const char* output_path = nullptr;

std::string symbol_bytes(mrb_state* M, mrb_sym sym) {
  mrb_int length = 0;
  const char* bytes = mrb_sym_name_len(M, sym, &length);
  return bytes ? std::string(bytes, length) : std::string();
}

void observe(mrb_state* M,
             RClass*,
             RClass* owner,
             mrb_sym sym,
             const mrb_method_t*) {
  const Key key{owner ? reinterpret_cast<uintptr_t>(owner->mt) : 0, sym};
  const unsigned phase = gameplay ? 2 : M->bootstrapping ? 0 : 1;
  auto& count = counts[key].phase[phase];
  ++count;
  if (!names.count(sym))
    names.emplace(sym, symbol_bytes(M, sym));
  // First hit gives an example; periodic samples expose repeated lookup sites.
  if (count == 1 || count % 4096 == 0) {
    void* frames[20];
    const int size = backtrace(frames, 20);
    ++stacks[Stack{key, phase, std::vector<void*>(frames, frames + size)}];
  }
}

std::string owner_name(mrb_state* M, RClass* klass, unsigned depth = 0) {
  if (depth > 8)
    return "<nested-singleton>";
  if (klass->tt == MRB_TT_SCLASS) {
    mrb_value attached = mrb_obj_iv_get(M, reinterpret_cast<RObject*>(klass),
                                        mrb_intern_lit(M, "__attached__"));
    if (mrb_class_p(attached) || mrb_module_p(attached) ||
        mrb_type(attached) == MRB_TT_SCLASS)
      return owner_name(M, mrb_class_ptr(attached), depth + 1) + ".singleton";
    return std::string("<") + mrb_obj_classname(M, attached) +
           "-object>.singleton";
  }
  const char* name = mrb_class_name(M, klass);
  return name ? name : "<anonymous-class>";
}

int collect_class(mrb_state*, RBasic* object, void* data) {
  if (object->tt == MRB_TT_CLASS || object->tt == MRB_TT_MODULE ||
      object->tt == MRB_TT_SCLASS)
    static_cast<std::vector<RClass*>*>(data)->push_back(
        reinterpret_cast<RClass*>(object));
  return MRB_EACH_OBJ_OK;
}
struct Context {
  RClass* klass;
  std::string owner;
};
int collect_entry(mrb_state* M, mrb_sym sym, mrb_method_t method, void* data) {
  const auto& context = *static_cast<Context*>(data);
  const char* kind = "undefined";
  uintptr_t address = 0;
  if (!MRB_METHOD_UNDEF_P(method)) {
    kind = MRB_METHOD_CFUNC_P(method) ? "native-callable" : "bytecode";
    if (MRB_METHOD_CFUNC_P(method))
      address = reinterpret_cast<uintptr_t>(MRB_METHOD_CFUNC(method));
  }
  entries.push_back({{reinterpret_cast<uintptr_t>(context.klass->mt), sym},
                     context.owner,
                     symbol_bytes(M, sym),
                     kind,
                     address});
  return 0;
}

void snapshot(mrb_state* M) {
  auto hook = M->method_lookup_hook;
  M->method_lookup_hook = nullptr;
  const auto disabled = M->gc.disabled;
  M->gc.disabled = TRUE;
  std::vector<RClass*> classes;
  mrb_objspace_each_objects(M, collect_class, &classes);
  for (RClass* klass : classes) {
    Context context{klass, owner_name(M, klass)};
    mrb_mt_foreach(M, klass, collect_entry, &context);
  }
  M->gc.disabled = disabled;
  M->method_lookup_hook = hook;
  gameplay = true;
}

std::string hex(const std::string& bytes) {
  static const char digits[] = "0123456789abcdef";
  std::string result;
  for (unsigned char byte : bytes) {
    result += digits[byte >> 4];
    result += digits[byte & 15];
  }
  return result;
}

void finish_file(FILE* file) {
  const bool error = ferror(file);
  const int closed = fclose(file);
  if (error || closed != 0) {
    perror("TRACE_HOST writing survey");
    abort();
  }
}
FILE* open_file(const std::string& path) {
  FILE* file = fopen(path.c_str(), "w");
  if (!file) {
    perror("TRACE_HOST opening survey");
    abort();
  }
  return file;
}

void dump() {
  FILE* file = open_file(output_path);
  fprintf(file, "owner_hex\tname_hex\tkind\taddress\tcore\tgems\tgameplay\n");
  auto remaining = counts;
  for (const Entry& entry : entries) {
    const Counts count = counts[entry.key];
    fprintf(file, "%s\t%s\t%s\t0x%llx\t%llu\t%llu\t%llu\n",
            hex(entry.owner).c_str(), hex(entry.name).c_str(), entry.kind,
            static_cast<unsigned long long>(entry.address), count.phase[0],
            count.phase[1], count.phase[2]);
    remaining.erase(entry.key);
  }
  for (const auto& item : remaining) {
    fprintf(file, "%s\t%s\t%s\t0x0\t%llu\t%llu\t%llu\n",
            hex("<outside-final-table>").c_str(),
            hex(names[item.first.second]).c_str(),
            item.first.first ? "transient" : "missing", item.second.phase[0],
            item.second.phase[1], item.second.phase[2]);
  }
  finish_file(file);
  file = open_file(std::string(output_path) + ".stacks");
  fprintf(file, "name_hex\tphase\tsamples\tframes\n");
  for (const auto& item : stacks) {
    fprintf(file, "%s\t%u\t%llu\t", hex(names[item.first.key.second]).c_str(),
            item.first.phase, item.second);
    for (void* frame : item.first.frames)
      fprintf(file, "%p,", frame);
    fprintf(file, "\n");
  }
  finish_file(file);
}
}  // namespace lookup_survey
