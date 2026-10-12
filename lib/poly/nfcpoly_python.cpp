// nfcpoly Python backend: CPython, embedded (python3-config). See docs/notes/poly.md.
//
// CPython reports errors through return values and the thread's error indicator, never by unwinding, so a C++ exception
// must not cross a CPython frame and none does: the trampolines catch what bound code throws and set the indicator.
// A host exception that enters a script travels in an NfcPoly HostError exception (capsule in the attribute _host).
//
// One interpreter per process: it is started on first use and never finalized. Each Context gets its own globals dict.
#include "nfcpoly_python.hpp"

#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <map>
#include <set>

#include "nfcpoly_lang.hpp"

namespace nfcpoly {
namespace detail {

namespace {

struct PyLang;

// An owned reference, dropped on every path.
struct Ref {
  PyObject* o;
  Ref() : o(nullptr) {}
  explicit Ref(PyObject* p) : o(p) {}  // takes the reference
  Ref(const Ref&) = delete;
  Ref& operator=(const Ref&) = delete;
  ~Ref() { Py_XDECREF(o); }
  PyObject* get() const { return o; }
  PyObject* release() {
    PyObject* p = o;
    o = nullptr;
    return p;
  }
  explicit operator bool() const { return o != nullptr; }
};

struct PyNfcObj {  // the instance layout of a bound class
  PyObject_HEAD
  PyLang* lang;  // checked against live_py(): an instance can outlive its context
  ClassInfo* ci;
  void* p;
  Owned* own;
};

struct PHandle : Handle {
  PyObject* o;
  PHandle(Lang* l, Impl* i, PyObject* obj) : Handle(l, i), o(obj) { Py_INCREF(o); }
  ~PHandle() override { Py_XDECREF(o); }  // the interpreter is never finalized, so this is safe after the context is gone
  void orphan() override {}
};

struct Bound {  // what a bound function or method needs when Python calls it
  PyLang* lang;
  Callable* c;
  PyObject* self;  // the receiver of a method (a strong reference), else null
};

struct LiveVar {
  Callable* get;
  Callable* set;
};

std::set<PyLang*>& live_py() {
  static std::set<PyLang*> s;
  return s;
}
PyLang* live_lang(PyLang* l) { return live_py().count(l) ? l : nullptr; }
std::map<PyTypeObject*, std::pair<PyLang*, ClassInfo*>>& g_types() {  // the types of all contexts
  static std::map<PyTypeObject*, std::pair<PyLang*, ClassInfo*>> m;
  return m;
}

PyObject* fn_tramp(PyObject* capsule, PyObject* args);
PyObject* live_get(PyObject* capsule, PyObject* key);
PyObject* live_set(PyObject* capsule, PyObject* args);
void obj_dealloc(PyObject* self);
PyObject* obj_getattro(PyObject* self, PyObject* name);
int obj_setattro(PyObject* self, PyObject* name, PyObject* value);
PyObject* obj_new(PyTypeObject* type, PyObject* args, PyObject* kwds);
int obj_init(PyObject* self, PyObject* args, PyObject* kwds);
PyObject* obj_repr(PyObject* self);
PyObject* obj_str(PyObject* self);
PyObject* obj_richcompare(PyObject* self, PyObject* other, int op);
PyObject* obj_getitem(PyObject* self, PyObject* key);
PyObject* obj_neg(PyObject* self);
PyObject* obj_abs(PyObject* self);
PyObject* obj_add(PyObject* a, PyObject* b);
PyObject* obj_sub(PyObject* a, PyObject* b);
PyObject* obj_mul(PyObject* a, PyObject* b);
PyObject* obj_mod(PyObject* a, PyObject* b);
PyObject* obj_truediv(PyObject* a, PyObject* b);
PyObject* obj_floordiv(PyObject* a, PyObject* b);
PyObject* obj_matmul(PyObject* a, PyObject* b);
PyObject* obj_and(PyObject* a, PyObject* b);
PyObject* obj_or(PyObject* a, PyObject* b);
PyObject* obj_xor(PyObject* a, PyObject* b);
Py_hash_t obj_hash(PyObject* self);

PyMethodDef g_fn_def = {"nfcpoly_function", fn_tramp, METH_VARARGS, nullptr};
PyMethodDef g_live_get_def = {"_live_get", live_get, METH_O, nullptr};
PyMethodDef g_live_set_def = {"_live_set", live_set, METH_VARARGS, nullptr};

const char* const kHelperSource =
    "import ast, sys, traceback\n"
    "class HostError(RuntimeError):\n"
    "    pass\n"
    "class Globals(dict):\n"
    "    def __missing__(self, k):\n"
    "        return _live_get(k)\n"
    "    def __setitem__(self, k, v):\n"
    "        if not _live_set(k, v):\n"
    "            dict.__setitem__(self, k, v)\n"
    "def run(code, g):\n"
    "    try:\n"
    "        tree = ast.parse(code, 'snippet', 'exec')\n"
    "        last = None\n"
    "        if tree.body and isinstance(tree.body[-1], ast.Expr):\n"
    "            last = ast.Expression(tree.body.pop().value)\n"
    "        exec(compile(tree, 'snippet', 'exec'), g)\n"
    "        if last is not None:\n"
    "            return eval(compile(last, 'snippet', 'eval'), g)\n"
    "        return None\n"
    "    finally:\n"
    "        try:\n"
    "            sys.stdout.flush()\n"
    "        except Exception:\n"
    "            pass\n"
    "def format_exc(e):\n"
    "    return traceback.format_exception(type(e), e, e.__traceback__)\n";

PyObject* exc_class(const std::string& n) {
  if (n == "TypeError") return PyExc_TypeError;
  if (n == "AttributeError") return PyExc_AttributeError;
  if (n == "NameError") return PyExc_NameError;
  return PyExc_RuntimeError;
}

void host_capsule_free(PyObject* cap) { delete static_cast<std::exception_ptr*>(PyCapsule_GetPointer(cap, "nfcpoly.host")); }
void bound_capsule_free(PyObject* cap) {
  Bound* b = static_cast<Bound*>(PyCapsule_GetPointer(cap, "nfcpoly.bound"));
  Py_XDECREF(b->self);
  delete b;
}

// The exception the thread's error indicator holds, as a normalized instance with its traceback attached (new reference);
// clears the indicator.
PyObject* take_exception() {
#if PY_VERSION_HEX >= 0x030c0000
  return PyErr_GetRaisedException();
#else
  PyObject *t = nullptr, *v = nullptr, *tb = nullptr;
  PyErr_Fetch(&t, &v, &tb);
  PyErr_NormalizeException(&t, &v, &tb);
  if (tb && v) PyException_SetTraceback(v, tb);
  Py_XDECREF(t);
  Py_XDECREF(tb);
  return v;
#endif
}

std::string utf8_of(PyObject* s) {
  Py_ssize_t n = 0;
  const char* c = PyUnicode_AsUTF8AndSize(s, &n);
  if (!c) {
    PyErr_Clear();
    return std::string();
  }
  return std::string(c, static_cast<std::size_t>(n));
}

struct PyLang : Lang {
  PyObject* globals = nullptr;
  PyObject* helpers = nullptr;  // the namespace of the helper source
  PyObject* run_fn = nullptr;
  PyObject* format_fn = nullptr;
  PyObject* host_error = nullptr;
  PyObject* last_exc = nullptr;  // the script error last handed to the host (strong)
  std::map<ClassInfo*, PyTypeObject*> types;
  std::vector<std::unique_ptr<Bound>> bounds;
  std::vector<std::unique_ptr<std::string>> names;  // type names, which must outlive the types
  std::map<std::string, LiveVar> live;

  explicit PyLang(Impl* i) : Lang(i) {
    live_py().insert(this);
    if (!Py_IsInitialized()) Py_InitializeEx(0);  // one interpreter per process, never finalized
    helpers = PyDict_New();
    PyDict_SetItemString(helpers, "__builtins__", PyEval_GetBuiltins());
    Ref cap(PyCapsule_New(this, "nfcpoly.lang", nullptr));
    Ref lg(PyCFunction_NewEx(&g_live_get_def, cap.get(), nullptr));
    Ref ls(PyCFunction_NewEx(&g_live_set_def, cap.get(), nullptr));
    PyDict_SetItemString(helpers, "_live_get", lg.get());
    PyDict_SetItemString(helpers, "_live_set", ls.get());
    Ref ok(PyRun_String(kHelperSource, Py_file_input, helpers, helpers));
    if (!ok) throw_error();
    run_fn = PyDict_GetItemString(helpers, "run");  // borrowed from the helpers dict, which this keeps
    format_fn = PyDict_GetItemString(helpers, "format_exc");
    host_error = PyDict_GetItemString(helpers, "HostError");
    PyObject* gcls = PyDict_GetItemString(helpers, "Globals");
    globals = PyObject_CallObject(gcls, nullptr);
    if (!globals) throw_error();
    PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
    Ref name(PyUnicode_FromString("__nfcpoly__"));
    PyDict_SetItemString(globals, "__name__", name.get());
  }
  ~PyLang() override {
    live_py().erase(this);
    for (auto& t : types) {
      g_types().erase(t.second);
      Py_XDECREF(reinterpret_cast<PyObject*>(t.second));
    }
    Py_XDECREF(last_exc);
    Py_XDECREF(globals);  // the objects the script made live on while something still references them
    Py_XDECREF(helpers);
  }
  const char* name() const override { return "python"; }

  // ---- values ----
  static PyNfcObj* object_of(PyObject* o) {  // a bound class instance, else null
    PyTypeObject* t = Py_TYPE(o);
    return t->tp_dealloc == obj_dealloc ? reinterpret_cast<PyNfcObj*>(o) : nullptr;
  }

  Var decode(PyObject* o) {  // shallow; o is borrowed
    Var r;
    if (o == Py_None) {
    } else if (PyBool_Check(o)) {
      r = Var::boolean(o == Py_True);
    } else if (PyLong_Check(o)) {
      int overflow = 0;
      long long v = PyLong_AsLongLongAndOverflow(o, &overflow);
      if (overflow) r = Var::script(new PHandle(this, impl, o));  // a big integer stays in Python
      else r = Var::integer(v);
    } else if (PyFloat_Check(o)) {
      r = Var::real(PyFloat_AsDouble(o));
    } else if (PyUnicode_Check(o)) {
      Py_ssize_t n = 0;
      const char* c = PyUnicode_AsUTF8AndSize(o, &n);
      if (c) r = Var::string(std::string(c, static_cast<std::size_t>(n)));
      else {
        PyErr_Clear();  // lone surrogates: not representable
        r = Var::script(new PHandle(this, impl, o));
      }
    } else if (PyBytes_Check(o)) {
      r = Var::string(std::string(PyBytes_AS_STRING(o), static_cast<std::size_t>(PyBytes_GET_SIZE(o))));
    } else if (PyNfcObj* n = object_of(o)) {
      if (n->p) r = Var::object(n->ci, n->p, n->own);
      else r = Var::script(new PHandle(this, impl, o));
    } else {
      r = Var::script(new PHandle(this, impl, o));
    }
    r.set_src(this);
    return r;
  }

  PyObject* encode(const Var& v) {  // a new reference; on failure a C++ exception
    switch (v.kind()) {
      case Var::Nil: Py_RETURN_NONE;
      case Var::Bool: return PyBool_FromLong(v.b() ? 1 : 0);
      case Var::Int: return check(PyLong_FromLongLong(v.i()));
      case Var::Float: return check(PyFloat_FromDouble(v.d()));
      case Var::Str: {
        PyObject* s = PyUnicode_DecodeUTF8(v.s().data(), static_cast<Py_ssize_t>(v.s().size()), "strict");
        if (!s) {  // not UTF-8: Python gets bytes
          PyErr_Clear();
          s = PyBytes_FromStringAndSize(v.s().data(), static_cast<Py_ssize_t>(v.s().size()));
        }
        return check(s);
      }
      case Var::Arr: {
        Ref list(check(PyList_New(static_cast<Py_ssize_t>(v.a().size()))));
        Py_ssize_t k = 0;
        for (const Var& e : v.a()) {
          PyObject* x = encode(e);
          PyList_SET_ITEM(list.get(), k++, x);  // steals
        }
        return list.release();
      }
      case Var::Obj: {
        auto it = types.find(v.ci());
        if (it == types.end()) throw ConversionError("nfcpoly: class " + v.ci()->name + " is not defined in python");
        PyTypeObject* t = it->second;
        PyNfcObj* o = reinterpret_cast<PyNfcObj*>(check(t->tp_alloc(t, 0)));
        o->lang = this;
        o->ci = v.ci();
        o->p = v.ptr();
        o->own = v.owned();
        if (o->own) owned_ref(o->own);
        return reinterpret_cast<PyObject*>(o);
      }
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang) throw ConversionError("nfcpoly: a script value whose interpreter is gone");
        if (h->lang == this) {
          PyObject* o = static_cast<PHandle*>(h)->o;
          Py_INCREF(o);
          return o;
        }
        Var d = h->lang->to_var(v);  // from another language: by copy where it can be
        if (d.kind() == Var::Script)
          throw ConversionError(std::string("nfcpoly: a ") + h->lang->name() + " value cannot be passed to python");
        return encode(d);
      }
    }
    Py_RETURN_NONE;
  }

  PyObject* check(PyObject* o) {  // a failed allocation becomes a C++ exception
    if (!o) throw_error();
    return o;
  }

  // ---- errors ----
  // The error in the thread's error indicator becomes the host's exception: the original C++ exception when the script
  // carried one out unrescued, else ScriptError (SyntaxError for a parse failure). Never returns.
  [[noreturn]] void throw_error() {
    Ref exc(take_exception());
    if (!exc) raise_script_error(this, "SystemError", "a Python call failed without an exception", std::vector<std::string>(), false);
    if (PyObject_HasAttrString(exc.get(), "_host")) {
      Ref cap(PyObject_GetAttrString(exc.get(), "_host"));
      if (cap && PyCapsule_CheckExact(cap.get())) {
        std::exception_ptr ep = *static_cast<std::exception_ptr*>(PyCapsule_GetPointer(cap.get(), "nfcpoly.host"));
        std::rethrow_exception(ep);
      }
      PyErr_Clear();
    }
    std::string cls = Py_TYPE(exc.get())->tp_name;
    std::size_t dot = cls.rfind('.');
    if (dot != std::string::npos) cls = cls.substr(dot + 1);
    std::string msg;
    {
      Ref s(PyObject_Str(exc.get()));
      if (s) msg = utf8_of(s.get());
      else PyErr_Clear();
    }
    std::vector<std::string> bt;
    {
      Ref lines(PyObject_CallFunctionObjArgs(format_fn, exc.get(), nullptr));
      if (lines && PyList_Check(lines.get())) {
        for (Py_ssize_t k = 0; k < PyList_GET_SIZE(lines.get()); ++k) {
          std::string chunk = utf8_of(PyList_GET_ITEM(lines.get(), k));
          std::size_t pos = 0;
          while (pos < chunk.size()) {
            std::size_t e = chunk.find('\n', pos);
            if (e == std::string::npos) e = chunk.size();
            std::string line = chunk.substr(pos, e - pos);
            std::size_t b = line.find_first_not_of(" \t");
            if (b != std::string::npos) bt.push_back(line.substr(b));
            pos = e + 1;
          }
        }
      } else {
        PyErr_Clear();
      }
    }
    bool syntax = PyErr_GivenExceptionMatches(reinterpret_cast<PyObject*>(Py_TYPE(exc.get())), PyExc_SyntaxError) != 0;
    Py_INCREF(exc.get());
    Py_XSETREF(last_exc, exc.get());  // so that a trampoline can raise this very object again
    raise_script_error(this, cls, msg, std::move(bt), syntax);
  }

  // ---- Lang ----
  Var eval(std::string_view code) override {
    Ref src(PyUnicode_DecodeUTF8(code.data(), static_cast<Py_ssize_t>(code.size()), "strict"));
    if (!src) throw_error();
    Ref r(PyObject_CallFunctionObjArgs(run_fn, src.get(), globals, nullptr));
    if (!r) throw_error();
    return decode(r.get());
  }

  Var to_var(const Var& v) override { return deep_var(v, 0); }

  Var deep_var(const Var& v, int depth) {
    if (v.kind() != Var::Script || v.handle()->lang != this) return v;
    PyObject* o = static_cast<PHandle*>(v.handle())->o;
    if (!PyList_Check(o) && !PyTuple_Check(o)) return v;
    if (depth > 100) throw ConversionError("nfcpoly: array nested too deeply (or cyclic)");
    Ref seq(check(PySequence_Fast(o, "array")));
    std::vector<Var> out;
    Py_ssize_t n = PySequence_Fast_GET_SIZE(seq.get());
    out.reserve(static_cast<std::size_t>(n));
    for (Py_ssize_t k = 0; k < n; ++k) out.push_back(deep_var(decode(PySequence_Fast_GET_ITEM(seq.get(), k)), depth + 1));
    Var r = Var::array(std::move(out));
    r.set_src(this);
    return r;
  }

  Var call(const Var& target, const std::string& method, const std::vector<Var>& args) override {
    Ref self(encode(target));
    Ref fn;
    if (method.empty()) {  // the value itself is the callable
      Py_INCREF(self.get());
      fn.o = self.get();
    } else {
      fn.o = PyObject_GetAttrString(self.get(), method.c_str());
      if (!fn) throw_error();
    }
    Ref tuple(check(PyTuple_New(static_cast<Py_ssize_t>(args.size()))));
    Py_ssize_t k = 0;
    for (const Var& a : args) PyTuple_SET_ITEM(tuple.get(), k++, encode(a));  // steals
    Ref r(PyObject_Call(fn.get(), tuple.get(), nullptr));
    if (!r) throw_error();
    return decode(r.get());
  }

  std::string inspect(const Var& v) override {
    Ref o(encode(v));
    Ref s(PyObject_Repr(o.get()));
    if (!s) {
      PyErr_Clear();
      return type_name(v);
    }
    return utf8_of(s.get());
  }
  std::string type_name(const Var& v) override {
    Ref o(encode(v));
    return Py_TYPE(o.get())->tp_name;
  }
  bool is_array(const Var& v) override {
    if (v.kind() != Var::Script || v.handle()->lang != this) return false;
    PyObject* o = static_cast<PHandle*>(v.handle())->o;
    return PyList_Check(o) || PyTuple_Check(o);
  }

  // ---- declarations ----
  Bound* new_bound(Callable* c) {
    bounds.push_back(std::unique_ptr<Bound>(new Bound{this, c, nullptr}));
    return bounds.back().get();
  }
  void define_fn(const std::string& name, Callable* c) override {
    Ref cap(PyCapsule_New(new_bound(c), "nfcpoly.bound", nullptr));  // the bounds list owns the Bound
    Ref f(PyCFunction_NewEx(&g_fn_def, cap.get(), nullptr));
    PyDict_SetItemString(globals, name.c_str(), f.get());
  }
  void define_value(const std::string& name, const Var& v) override {
    Ref o(encode(v));
    PyDict_SetItemString(globals, name.c_str(), o.get());
  }
  void define_variable(const std::string& name, Callable* get, Callable* set) override { live[name] = LiveVar{get, set}; }
  void class_define(ClassInfo* ci) override {
    names.push_back(std::unique_ptr<std::string>(new std::string(ci->name)));
    // Operators: the slots look the Python special method up in the class (__add__, __radd__, ..., "Operators" in poly.md)
    // and answer NotImplemented for a class that has none, so a class without operators behaves as before.
    static PyType_Slot slots[24];
    int n = 0;
    slots[n++] = {Py_tp_dealloc, reinterpret_cast<void*>(obj_dealloc)};
    slots[n++] = {Py_tp_getattro, reinterpret_cast<void*>(obj_getattro)};
    slots[n++] = {Py_tp_setattro, reinterpret_cast<void*>(obj_setattro)};
    slots[n++] = {Py_tp_new, reinterpret_cast<void*>(obj_new)};
    slots[n++] = {Py_tp_init, reinterpret_cast<void*>(obj_init)};
    slots[n++] = {Py_tp_repr, reinterpret_cast<void*>(obj_repr)};
    slots[n++] = {Py_tp_str, reinterpret_cast<void*>(obj_str)};
    slots[n++] = {Py_tp_richcompare, reinterpret_cast<void*>(obj_richcompare)};
    slots[n++] = {Py_tp_hash, reinterpret_cast<void*>(obj_hash)};  // a type with richcompare and no hash is unhashable
    slots[n++] = {Py_mp_subscript, reinterpret_cast<void*>(obj_getitem)};
    slots[n++] = {Py_nb_add, reinterpret_cast<void*>(obj_add)};
    slots[n++] = {Py_nb_subtract, reinterpret_cast<void*>(obj_sub)};
    slots[n++] = {Py_nb_multiply, reinterpret_cast<void*>(obj_mul)};
    slots[n++] = {Py_nb_remainder, reinterpret_cast<void*>(obj_mod)};
    slots[n++] = {Py_nb_true_divide, reinterpret_cast<void*>(obj_truediv)};
    slots[n++] = {Py_nb_floor_divide, reinterpret_cast<void*>(obj_floordiv)};
    slots[n++] = {Py_nb_matrix_multiply, reinterpret_cast<void*>(obj_matmul)};
    slots[n++] = {Py_nb_and, reinterpret_cast<void*>(obj_and)};
    slots[n++] = {Py_nb_or, reinterpret_cast<void*>(obj_or)};
    slots[n++] = {Py_nb_xor, reinterpret_cast<void*>(obj_xor)};
    slots[n++] = {Py_nb_negative, reinterpret_cast<void*>(obj_neg)};
    slots[n++] = {Py_nb_absolute, reinterpret_cast<void*>(obj_abs)};
    slots[n++] = {0, nullptr};
    PyType_Spec spec;
    spec.name = names.back()->c_str();
    spec.basicsize = static_cast<int>(sizeof(PyNfcObj));
    spec.itemsize = 0;
    spec.flags = Py_TPFLAGS_DEFAULT;
    spec.slots = slots;
    PyTypeObject* t = reinterpret_cast<PyTypeObject*>(check(PyType_FromSpec(&spec)));
    types[ci] = t;
    g_types()[t] = std::make_pair(this, ci);
    PyDict_SetItemString(globals, ci->name.c_str(), reinterpret_cast<PyObject*>(t));
  }
  void class_method(ClassInfo*, const std::string&, Callable*) override {}  // looked up in ClassInfo on each access
  void class_prop(ClassInfo*, const std::string&, Callable*, Callable*) override {}
  void class_ctor(ClassInfo*, Callable*) override {}
};

// What the trampoline sets once the C++ handlers have finished.
struct Pending {
  enum Kind { None, Existing, Plain, Host } kind = None;
  std::string cls, msg;
  std::exception_ptr host;
};

void set_pending(PyLang* L, Pending& p) {
  if (p.kind == Pending::Existing) {
    Py_INCREF(L->last_exc);
    PyErr_SetObject(reinterpret_cast<PyObject*>(Py_TYPE(L->last_exc)), L->last_exc);
    Py_DECREF(L->last_exc);
    return;
  }
  if (p.kind == Pending::Host) {
    Ref exc(PyObject_CallFunction(L->host_error, "s", p.msg.c_str()));
    if (exc) {
      Ref cap(PyCapsule_New(new std::exception_ptr(p.host), "nfcpoly.host", host_capsule_free));
      PyObject_SetAttrString(exc.get(), "_host", cap.get());
      PyErr_SetObject(L->host_error, exc.get());
    }
    return;
  }
  PyErr_SetString(exc_class(p.cls), p.msg.c_str());
}

// Runs c for Python. mode 0: a function, mode 1: a method (self is the receiver), mode 2: a constructor (returns the new
// Var through *made). Returns a new reference, or null with the error indicator set.
PyObject* run_callable(PyLang* L, Callable* c, PyObject* self, PyObject* args, Var* made) {
  Py_ssize_t argc = PyTuple_GET_SIZE(args);
  if (!arity_fits(c, argc)) {
    PyErr_SetString(PyExc_TypeError, arity_message(c, argc).c_str());
    return nullptr;
  }
  Pending pend;
  try {
    std::vector<Var> av;
    av.reserve(static_cast<std::size_t>(argc));
    for (Py_ssize_t k = 0; k < argc; ++k) av.push_back(L->decode(PyTuple_GET_ITEM(args, k)));
    arity_pad(c, av);
    Var selfv;
    const Var* sp = nullptr;
    if (c->wants_self()) {
      selfv = L->decode(self);
      sp = &selfv;
    }
    Var r = c->invoke(sp, av.data());
    if (made) {
      *made = r;
      Py_RETURN_NONE;
    }
    return L->encode(r);
  } catch (const ScriptError& e) {
    if (e.owner() == L && e.serial() == L->exc_serial) {
      pend.kind = Pending::Existing;  // the script error this came from: raise that very object again
    } else {
      pend.kind = Pending::Plain;
      pend.cls = "RuntimeError";
      pend.msg = e.what();
    }
  } catch (const ConversionError& e) {
    pend.kind = Pending::Plain;
    pend.cls = "TypeError";
    pend.msg = e.what();
  } catch (const std::exception& e) {
    pend.kind = Pending::Host;
    pend.host = std::current_exception();
    pend.msg = e.what();
  } catch (...) {
    pend.kind = Pending::Host;
    pend.host = std::current_exception();
    pend.msg = "unknown C++ exception";
  }
  set_pending(L, pend);
  return nullptr;
}

PyObject* fn_tramp(PyObject* capsule, PyObject* args) {
  Bound* b = static_cast<Bound*>(PyCapsule_GetPointer(capsule, "nfcpoly.bound"));
  if (!live_lang(b->lang)) {
    PyErr_SetString(PyExc_RuntimeError, "nfcpoly: the context of this function is gone");
    return nullptr;
  }
  return run_callable(b->lang, b->c, b->self, args, nullptr);
}

PyObject* live_get(PyObject* capsule, PyObject* key) {  // Globals.__missing__: a bound variable reads live
  PyLang* L = static_cast<PyLang*>(PyCapsule_GetPointer(capsule, "nfcpoly.lang"));
  if (PyUnicode_Check(key)) {
    auto it = L->live.find(utf8_of(key));
    if (it != L->live.end()) {
      Ref none(PyTuple_New(0));
      return run_callable(L, it->second.get, nullptr, none.get(), nullptr);
    }
  }
  PyErr_SetObject(PyExc_KeyError, key);
  return nullptr;
}

PyObject* live_set(PyObject* capsule, PyObject* args) {  // Globals.__setitem__: true when NAME is a bound variable
  PyLang* L = static_cast<PyLang*>(PyCapsule_GetPointer(capsule, "nfcpoly.lang"));
  PyObject *key = nullptr, *value = nullptr;
  if (!PyArg_ParseTuple(args, "OO", &key, &value)) return nullptr;
  if (PyUnicode_Check(key)) {
    auto it = L->live.find(utf8_of(key));
    if (it != L->live.end()) {
      if (!it->second.set) {
        PyErr_SetString(PyExc_NameError, ("variable " + it->first + " is read-only").c_str());
        return nullptr;
      }
      Ref one(PyTuple_Pack(1, value));
      Ref r(run_callable(L, it->second.set, nullptr, one.get(), nullptr));
      if (!r) return nullptr;
      Py_RETURN_TRUE;
    }
  }
  Py_RETURN_FALSE;
}

// ---- bound class instances ------------------------------------------------------------------------------------------
PyObject* make_method(PyLang* L, Callable* c, PyObject* self) {  // a bound method: a builtin function whose "self" is a capsule
  Bound* b = new Bound{L, c, self};
  Py_INCREF(self);
  Ref cap(PyCapsule_New(b, "nfcpoly.bound", bound_capsule_free));
  if (!cap) {
    Py_DECREF(self);
    delete b;
    return nullptr;
  }
  return PyCFunction_NewEx(&g_fn_def, cap.get(), nullptr);
}

void obj_dealloc(PyObject* self) {
  PyNfcObj* o = reinterpret_cast<PyNfcObj*>(self);
  if (o->own) owned_unref(o->own);
  PyTypeObject* tp = Py_TYPE(self);
  tp->tp_free(self);
  Py_DECREF(tp);
}

PyObject* obj_new(PyTypeObject* type, PyObject*, PyObject*) {
  auto it = g_types().find(type);
  if (it == g_types().end() || !live_lang(it->second.first)) {
    PyErr_SetString(PyExc_RuntimeError, "nfcpoly: the context of this class is gone");
    return nullptr;
  }
  PyNfcObj* o = reinterpret_cast<PyNfcObj*>(type->tp_alloc(type, 0));
  if (!o) return nullptr;
  o->lang = it->second.first;
  o->ci = it->second.second;
  o->p = nullptr;
  o->own = nullptr;
  return reinterpret_cast<PyObject*>(o);
}

int obj_init(PyObject* self, PyObject* args, PyObject* kwds) {
  PyNfcObj* o = reinterpret_cast<PyNfcObj*>(self);
  PyLang* L = live_lang(o->lang);
  if (!L) {
    PyErr_SetString(PyExc_RuntimeError, "nfcpoly: the context of this object is gone");
    return -1;
  }
  if (kwds && PyDict_Size(kwds) > 0) {
    PyErr_SetString(PyExc_TypeError, "bound classes take no keyword arguments");
    return -1;
  }
  if (o->p) {
    PyErr_SetString(PyExc_TypeError, "the object is already initialised");
    return -1;
  }
  if (!o->ci->ctor) {
    PyErr_SetString(PyExc_TypeError, (o->ci->name + " has no constructor (ClassBuilder::ctor)").c_str());
    return -1;
  }
  Var made;
  Ref r(run_callable(L, o->ci->ctor, nullptr, args, &made));  // a new object the script owns
  if (!r) return -1;
  o->p = made.ptr();
  o->own = made.owned();
  if (o->own) owned_ref(o->own);
  return 0;
}

PyObject* obj_getattro(PyObject* self, PyObject* name) {
  PyNfcObj* o = reinterpret_cast<PyNfcObj*>(self);
  if (PyUnicode_Check(name) && o->p) {
    if (PyLang* L = live_lang(o->lang)) {
      std::string key = utf8_of(name);
      for (const ClassInfo::Prop& p : o->ci->props) {
        if (p.name == key) {
          Ref none(PyTuple_New(0));
          return run_callable(L, p.get, self, none.get(), nullptr);
        }
      }
      for (auto& m : o->ci->methods)
        if (m.first == key) return make_method(L, m.second, self);
    }
  }
  return PyObject_GenericGetAttr(self, name);
}

int obj_setattro(PyObject* self, PyObject* name, PyObject* value) {
  PyNfcObj* o = reinterpret_cast<PyNfcObj*>(self);
  if (value && PyUnicode_Check(name) && o->p) {
    if (PyLang* L = live_lang(o->lang)) {
      std::string key = utf8_of(name);
      for (const ClassInfo::Prop& p : o->ci->props) {
        if (p.name != key) continue;
        if (!p.set) {
          PyErr_SetString(PyExc_AttributeError, ("field " + key + " of " + o->ci->name + " is read-only").c_str());
          return -1;
        }
        Ref one(PyTuple_Pack(1, value));
        Ref r(run_callable(L, p.set, self, one.get(), nullptr));
        return r ? 0 : -1;
      }
    }
  }
  return PyObject_GenericSetAttr(self, name, value);
}

// The method NAME of a bound object's class, null when X is not one (or not initialised, or its context is gone).
Callable* find_method(PyObject* x, const char* name, PyLang** lang) {
  PyNfcObj* o = PyLang::object_of(x);
  if (!o || !o->p) return nullptr;
  PyLang* L = live_lang(o->lang);
  if (!L) return nullptr;
  for (auto& m : o->ci->methods)
    if (m.first == name) {
      *lang = L;
      return m.second;
    }
  return nullptr;
}

// self.NAME(args...) through the trampoline, or NotImplemented when the class has no such method.
PyObject* call_special(PyObject* self, const char* name, std::initializer_list<PyObject*> args) {
  PyLang* L = nullptr;
  Callable* c = find_method(self, name, &L);
  if (!c) Py_RETURN_NOTIMPLEMENTED;
  Ref tuple(PyTuple_New(static_cast<Py_ssize_t>(args.size())));
  if (!tuple) return nullptr;
  Py_ssize_t k = 0;
  for (PyObject* a : args) {
    Py_INCREF(a);
    PyTuple_SET_ITEM(tuple.get(), k++, a);
  }
  return run_callable(L, c, self, tuple.get(), nullptr);
}

// a OP b: a's method FWD, else (a is not ours, or has none) b's method REV with the operands swapped.
PyObject* binary_special(PyObject* a, PyObject* b, const char* fwd, const char* rev) {
  PyLang* L = nullptr;
  if (find_method(a, fwd, &L)) return call_special(a, fwd, {b});
  if (find_method(b, rev, &L)) return call_special(b, rev, {a});
  Py_RETURN_NOTIMPLEMENTED;
}
PyObject* obj_add(PyObject* a, PyObject* b) { return binary_special(a, b, "__add__", "__radd__"); }
PyObject* obj_sub(PyObject* a, PyObject* b) { return binary_special(a, b, "__sub__", "__rsub__"); }
PyObject* obj_mul(PyObject* a, PyObject* b) { return binary_special(a, b, "__mul__", "__rmul__"); }
PyObject* obj_mod(PyObject* a, PyObject* b) { return binary_special(a, b, "__mod__", "__rmod__"); }
PyObject* obj_truediv(PyObject* a, PyObject* b) { return binary_special(a, b, "__truediv__", "__rtruediv__"); }
PyObject* obj_floordiv(PyObject* a, PyObject* b) { return binary_special(a, b, "__floordiv__", "__rfloordiv__"); }
PyObject* obj_matmul(PyObject* a, PyObject* b) { return binary_special(a, b, "__matmul__", "__rmatmul__"); }
PyObject* obj_and(PyObject* a, PyObject* b) { return binary_special(a, b, "__and__", "__rand__"); }
PyObject* obj_or(PyObject* a, PyObject* b) { return binary_special(a, b, "__or__", "__ror__"); }
PyObject* obj_xor(PyObject* a, PyObject* b) { return binary_special(a, b, "__xor__", "__rxor__"); }
PyObject* obj_neg(PyObject* self) { return call_special(self, "__neg__", {}); }
PyObject* obj_abs(PyObject* self) { return call_special(self, "__abs__", {}); }
PyObject* obj_getitem(PyObject* self, PyObject* key) { return call_special(self, "__getitem__", {key}); }

PyObject* obj_richcompare(PyObject* self, PyObject* other, int op) {
  static const char* const names[] = {"__lt__", "__le__", "__eq__", "__ne__", "__gt__", "__ge__"};  // Py_LT .. Py_GE
  if (op < 0 || op > 5) Py_RETURN_NOTIMPLEMENTED;
  PyLang* L = nullptr;
  if (!find_method(self, names[op], &L)) {
    if (op == Py_EQ || op == Py_NE) {  // a class without the method compares by identity, as object does
      bool same = self == other;
      return PyBool_FromLong((op == Py_EQ) == same);
    }
    Py_RETURN_NOTIMPLEMENTED;
  }
  return call_special(self, names[op], {other});
}

Py_hash_t obj_hash(PyObject* self) {  // by identity, as object does
  Py_uhash_t h = reinterpret_cast<Py_uhash_t>(self);
  h = (h >> 4) | (h << (8 * sizeof(h) - 4));
  return h == static_cast<Py_uhash_t>(-1) ? static_cast<Py_hash_t>(-2) : static_cast<Py_hash_t>(h);
}

PyObject* obj_repr(PyObject* self) {
  PyLang* L = nullptr;
  if (find_method(self, "__repr__", &L)) return call_special(self, "__repr__", {});
  PyNfcObj* o = reinterpret_cast<PyNfcObj*>(self);
  return PyUnicode_FromFormat("<%s object>", o->ci->name.c_str());
}
PyObject* obj_str(PyObject* self) {
  PyLang* L = nullptr;
  if (find_method(self, "__str__", &L)) return call_special(self, "__str__", {});
  return obj_repr(self);
}

std::unique_ptr<Lang> make_python(Impl* impl) { return std::unique_ptr<Lang>(new PyLang(impl)); }
LangRegistrar registrar("python", "python3", "py", &make_python);

}  // namespace
}  // namespace detail

PyObject* python_globals(Context& ctx) { return static_cast<detail::PyLang*>(detail::get_lang(ctx.impl(), "python"))->globals; }

PyObject* python_object(const Value& v) {
  const detail::Var& var = v.var();
  detail::Lang* l = var.kind() == detail::Var::Script ? var.handle()->lang : var.src();
  if (!l) throw Error("nfcpoly: the Value has no live interpreter");
  if (std::strcmp(l->name(), "python") != 0) throw Error("nfcpoly: python_object of a value from another language");
  return static_cast<detail::PyLang*>(l)->encode(var);
}

}  // namespace nfcpoly
