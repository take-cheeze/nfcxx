// Prints the typed IR as C11. The output is compiled by the system C compiler.
//
// Integer arithmetic goes through checked helpers that trap on overflow and
// division by zero, as Swift does. Class instances start with an `sw_obj`
// header holding the reference count and destroy function. Every expression
// is fully parenthesized, so the emitter never has to reason about C precedence.

enum CEmit {
  static let prelude = """
    #include <math.h>
    #include <stdbool.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

    static void sw_trap(const char *msg) {
      fflush(stdout);
      fprintf(stderr, "Fatal error: %s\\n", msg);
      abort();
    }
    static int64_t sw_add(int64_t a, int64_t b) {
      int64_t r;
      if (__builtin_add_overflow(a, b, &r)) sw_trap("arithmetic overflow");
      return r;
    }
    static int64_t sw_sub(int64_t a, int64_t b) {
      int64_t r;
      if (__builtin_sub_overflow(a, b, &r)) sw_trap("arithmetic overflow");
      return r;
    }
    static int64_t sw_mul(int64_t a, int64_t b) {
      int64_t r;
      if (__builtin_mul_overflow(a, b, &r)) sw_trap("arithmetic overflow");
      return r;
    }
    static int64_t sw_div(int64_t a, int64_t b) {
      if (b == 0) sw_trap("division by zero");
      if (a == INT64_MIN && b == -1) sw_trap("arithmetic overflow");
      return a / b;
    }
    static int64_t sw_rem(int64_t a, int64_t b) {
      if (b == 0) sw_trap("division by zero");
      if (a == INT64_MIN && b == -1) sw_trap("arithmetic overflow");
      return a % b;
    }
    /// Shifts by a magnitude m. Counts of 64 or more shift every bit out, as Swift's
    /// smart shifts do: `<<` gives 0, and `>>` gives 0 or -1 by the sign.
    static int64_t sw_shift_left(int64_t a, uint64_t m) {
      return m >= 64 ? 0 : (int64_t)((uint64_t)a << m);
    }
    static int64_t sw_shift_right(int64_t a, uint64_t m) {
      if (m >= 64) return a < 0 ? -1 : 0;
      if (a >= 0) return (int64_t)((uint64_t)a >> m);
      return ~(int64_t)((uint64_t)~a >> m);
    }
    /// Swift's `a << n` and `a >> n` on Int: a negative count shifts the other way.
    static int64_t sw_shl(int64_t a, int64_t n) {
      uint64_t m = n < 0 ? (uint64_t)0 - (uint64_t)n : (uint64_t)n;
      return n < 0 ? sw_shift_right(a, m) : sw_shift_left(a, m);
    }
    static int64_t sw_shr(int64_t a, int64_t n) {
      uint64_t m = n < 0 ? (uint64_t)0 - (uint64_t)n : (uint64_t)n;
      return n < 0 ? sw_shift_left(a, m) : sw_shift_right(a, m);
    }
    static void sw_print_int(int64_t v) {
      printf("%lld\\n", (long long)v);
    }
    static void sw_fmt_double(double v, char *out, size_t n) {
      // Swift prints the shortest digits that read back to the same value.
      if (isnan(v)) { snprintf(out, n, "nan"); return; }
      if (isinf(v)) { snprintf(out, n, v < 0 ? "-inf" : "inf"); return; }
      char buf[64];
      int digits;
      for (digits = 1; digits <= 17; digits++) {
        snprintf(buf, sizeof buf, "%.*e", digits - 1, v);
        if (strtod(buf, NULL) == v) break;
      }
      int exp10 = atoi(strchr(buf, 'e') + 1);
      if (exp10 < -4 || exp10 >= 16) {
        snprintf(out, n, "%s", buf);
        return;
      }
      int frac = digits - 1 - exp10;
      if (frac < 1) frac = 1;
      snprintf(out, n, "%.*f", frac, v);
    }
    static void sw_print_double(double v) {
      char buf[64];
      sw_fmt_double(v, buf, sizeof buf);
      printf("%s\\n", buf);
    }
    static void sw_print_bool(bool v) {
      printf("%s\\n", v ? "true" : "false");
    }

    typedef struct sw_obj {
      int64_t rc;
      void (*destroy)(void *);
    } sw_obj;
    static void *sw_retain(void *p) {
      if (p) ((sw_obj *)p)->rc++;
      return p;
    }
    static void sw_release(void *p) {
      if (!p) return;
      sw_obj *o = p;
      if (--o->rc == 0) {
        o->rc = 1;  // deinit may retain and release self; the count must not reach 0 again
        o->destroy(p);
      }
    }
    """

  static func emit(_ program: Program) -> String {
    var out = prelude + "\n\n"

    // Forward declarations first, so that any type can name any other. Function
    // typedefs may use incomplete types; complete definitions come after them.
    for c in program.classes { out += "typedef struct s_\(cIdent(c.name)) s_\(cIdent(c.name));\n" }
    for s in program.structs { out += "typedef struct s_\(cIdent(s.name)) s_\(cIdent(s.name));\n" }
    for e in program.enums { out += "typedef struct s_\(cIdent(e.name)) s_\(cIdent(e.name));\n" }
    for o in program.optionals { out += "typedef struct \(o.cName) \(o.cName);\n" }
    for a in program.arrays { out += "typedef struct \(a.cName) \(a.cName);\n" }
    for fn in program.functionTypes { out += "typedef struct \(fn.cName) \(fn.cName);\n" }
    out += "\n"
    // A function value is { fn, ctx }. Every function of the type takes the context
    // pointer first, so a named function is called through a thunk (see below).
    // Retaining or releasing a function value retains or releases its context.
    for fn in program.functionTypes {
      guard case .function(let params, let ret) = fn else { continue }
      let list = (["void *"] + params.map { $0.cName }).joined(separator: ", ")
      out += "struct \(fn.cName) {\n  \(ret.cName) (*fn)(\(list));\n  void *ctx;\n};\n"
      out += "static \(fn.cName) ret_\(fn.cName)(\(fn.cName) v) {\n  sw_retain(v.ctx);\n  return v;\n}\n"
      out += "static void rel_\(fn.cName)(\(fn.cName) v) {\n  sw_release(v.ctx);\n}\n"
    }
    out += "\n"

    // Value types (structs, enums, Optionals and arrays), dependencies first. The output has
    // three parts, in order: the type bodies, the prototypes of the copy and release helpers,
    // and the helper bodies. A helper may then use any type and call any other helper, which
    // a type that holds an array of itself needs.
    var defined = Set<String>()
    var bodies = ""
    var protos = ""
    var helpers = ""
    func needsDefinition(_ ty: Ty) -> Bool {
      switch ty {
      case .structure, .enumeration, .optional, .array: return true
      default: return false
      }
    }
    /// Declares `ret_cn` (adds one reference to each class-like part) and `rel_cn` (drops
    /// them) for a value type `cn`. `copy` and `drop` are the statements for its parts.
    func addCopyHelpers(_ cn: String, copy: String, drop: String) {
      protos += "static \(cn) ret_\(cn)(\(cn) v);\nstatic void rel_\(cn)(\(cn) v);\n"
      helpers += "static \(cn) ret_\(cn)(\(cn) v) {\n\(copy)  return v;\n}\n"
      helpers += "static void rel_\(cn)(\(cn) v) {\n\(drop)}\n\n"
    }
    func defineValue(_ ty: Ty) {
      guard !defined.contains(ty.mangled) else { return }
      defined.insert(ty.mangled)
      switch ty {
      case .structure(let name):
        guard let info = program.structs.first(where: { $0.name == name }) else { return }
        for field in info.fields where needsDefinition(field.ty) { defineValue(field.ty) }
        let cn = ty.cName
        bodies += "struct \(cn) {\n"
        for field in info.fields {
          bodies += "  \(field.ty.cName) \(field.cName);\n"
        }
        bodies += "};\n\n"
        if ty.isClassLike {
          // A struct with a reference-counted field is copied like an enum with a class
          // payload: copies retain each such field, and drops release it.
          var copy = "", drop = ""
          for field in info.fields where field.ty.isClassLike {
            copy += "  " + retainCode("v.\(field.cName)", field.ty) + "\n"
            drop += "  " + releaseCode("v.\(field.cName)", field.ty) + "\n"
          }
          addCopyHelpers(cn, copy: copy, drop: drop)
        }
      case .enumeration(let info):
        for c in info.cases {
          for field in c.payload where needsDefinition(field.ty) { defineValue(field.ty) }
        }
        let cn = ty.cName
        bodies += "struct \(cn) {\n  int64_t tag;\n"
        for c in info.cases {
          for field in c.payload {
            bodies += "  \(field.ty.cName) \(field.cName);\n"
          }
        }
        bodies += "};\n"
        if info.holdsRef {
          // Copies retain, and drops release, every class-like payload field. A value
          // leaves the fields of its other cases zero (a compound literal zeroes the
          // fields it does not name), and retaining or releasing a null pointer, an
          // empty Optional or an empty array does nothing, so no switch on the tag is needed.
          var copy = "", drop = ""
          for c in info.cases {
            for field in c.payload where field.ty.isClassLike {
              copy += "  " + retainCode("v.\(field.cName)", field.ty) + "\n"
              drop += "  " + releaseCode("v.\(field.cName)", field.ty) + "\n"
            }
          }
          addCopyHelpers(cn, copy: copy, drop: drop)
        }
        bodies += "\n"
      case .array(let elem):
        if needsDefinition(elem) { defineValue(elem) }
        bodies += arrayStruct(ty, elem)
        protos += arrayPrototypes(ty, elem)
        helpers += arrayHelpers(ty, elem)
      case .optional(let inner):
        if needsDefinition(inner) { defineValue(inner) }
        let opt = ty.cName
        bodies += "struct \(opt) {\n  bool some;\n  \(inner.cName) value;\n};\n"
        bodies += "static \(inner.cName) unw_\(opt)(\(opt) v) {\n"
        bodies += "  if (!v.some) sw_trap(\"Unexpectedly found nil while unwrapping an Optional value\");\n"
        bodies += "  return v.value;\n}\n"
        bodies += "\n"
        if inner.isClassLike {
          addCopyHelpers(opt,
            copy: "  if (v.some) \(retainCode("v.value", inner))\n",
            drop: "  if (v.some) \(releaseCode("v.value", inner))\n")
        }
      default:
        break
      }
    }
    for s in program.structs { defineValue(.structure(s.name)) }
    for e in program.enums { defineValue(.enumeration(e)) }
    for o in program.optionals { defineValue(o) }
    for a in program.arrays { defineValue(a) }
    // A box holds its value by value, so the value's type is defined first.
    for b in program.boxes {
      guard case .box(let inner) = b else { continue }
      if needsDefinition(inner) { defineValue(inner) }
      let tag = "bx_" + inner.mangled
      bodies += "struct \(tag) {\n  sw_obj hdr;\n  \(inner.cName) v;\n};\n"
      helpers += "static void d_\(tag)(void *p) {\n  struct \(tag) *b = p;\n"
      if inner.isClassLike {
        helpers += "  " + releaseCode("b->v", inner) + "\n"
      }
      helpers += "  free(p);\n}\n"
      helpers += "static struct \(tag) * bxn_\(inner.mangled)(\(inner.cName) v) {\n"
      helpers += "  struct \(tag) *b = calloc(1, sizeof *b);\n  if (!b) sw_trap(\"out of memory\");\n"
      helpers += "  b->hdr.rc = 1;\n  b->hdr.destroy = d_\(tag);\n  b->v = v;\n  return b;\n}\n\n"
    }
    out += bodies + protos + helpers

    // Call helpers for each function type. They need the complete parameter types,
    // so they come after the value definitions. An owned callee is released after the
    // call, since nothing else holds it.
    for fn in program.functionTypes {
      guard case .function(let params, let ret) = fn else { continue }
      let decl = ([fn.cName + " f"] + params.enumerated().map { "\($0.element.cName) a\($0.offset)" }).joined(separator: ", ")
      let args = (["f.ctx"] + params.indices.map { "a\($0)" }).joined(separator: ", ")
      let call = "f.fn(\(args))"
      if ret == .void {
        out += "static void call_\(fn.cName)(\(decl)) {\n  \(call);\n}\n"
        out += "static void callo_\(fn.cName)(\(decl)) {\n  \(call);\n  sw_release(f.ctx);\n}\n\n"
      } else {
        out += "static \(ret.cName) call_\(fn.cName)(\(decl)) {\n  return \(call);\n}\n"
        out += "static \(ret.cName) callo_\(fn.cName)(\(decl)) {\n  \(ret.cName) r = \(call);\n  sw_release(f.ctx);\n  return r;\n}\n\n"
      }
    }

    // Class layout: the header first, then the stored properties.
    for c in program.classes {
      out += "struct s_\(cIdent(c.name)) {\n  sw_obj hdr;\n"
      for f in c.fields {
        out += "  \(f.ty.cName) \(f.cName);\n"
      }
      out += "};\n\n"
    }

    for g in program.globals {
      out += "static \(g.ty.cName) \(g.cName);\n"
    }
    if !program.globals.isEmpty { out += "\n" }

    for f in program.funcs {
      out += "static \(f.ret.cName) \(f.cName)(\(paramList(f)));\n"
    }
    out += "static void swift_main(void);\n\n"
    for f in program.consumingMethods {
      out += consumingWrapper(f)
    }

    // A named function used as a value is called through a thunk with the context
    // parameter, which it ignores.
    for f in program.funcs where f.asValue && !f.isClosure {
      let params = (["void *ctx_"] + f.params.map { "\($0.ty.cName) \($0.cName)" }).joined(separator: ", ")
      let args = f.params.map { $0.cName }.joined(separator: ", ")
      let body = f.ret == .void ? "  \(f.cName)(\(args));\n" : "  return \(f.cName)(\(args));\n"
      out += "static \(f.ret.cName) thk_\(f.cName)(\(params)) {\n  (void)ctx_;\n\(body)}\n\n"
    }

    // The context of each closure that captures: its layout, its destroy function
    // (which releases the captured values), and the constructor that makes the closure
    // value from them. The constructor takes ownership of its arguments.
    for f in program.funcs {
      guard let ctx = f.context else { continue }
      let name = ctx.cName
      out += "struct \(name) {\n  sw_obj hdr;\n"
      for field in ctx.fields {
        out += "  \(field.ty.cName) \(field.cName);\n"
      }
      out += "};\n"
      out += "static void d_\(name)(void *p) {\n  struct \(name) *c = p;\n"
      for field in ctx.fields where field.ty.isClassLike {
        out += "  " + releaseCode("c->\(field.cName)", field.ty) + "\n"
      }
      out += "  free(p);\n}\n"
      let fnTy = Ty.function(f.params.map { $0.ty }, f.ret)
      let params = ctx.fields.enumerated().map { "\($0.element.ty.cName) v\($0.offset)" }.joined(separator: ", ")
      out += "static \(fnTy.cName) mk_\(ctx.id)(\(params)) {\n"
      out += "  struct \(name) *c = calloc(1, sizeof *c);\n  if (!c) sw_trap(\"out of memory\");\n"
      out += "  c->hdr.rc = 1;\n  c->hdr.destroy = d_\(name);\n"
      for (index, field) in ctx.fields.enumerated() {
        out += "  c->\(field.cName) = v\(index);\n"
      }
      out += "  return (\(fnTy.cName)){ .fn = \(f.cName), .ctx = c };\n}\n\n"
    }

    // Destroy and constructor for each class. Destroy runs the deinitializer,
    // then releases the stored references, then frees the object.
    for c in program.classes {
      let name = cIdent(c.name)
      out += "static void d_\(name)(void *p) {\n  s_\(name) *self = p;\n"
      if let d = c.deinitializer {
        out += "  \(d.cName)(self);\n"
      }
      for f in c.fields where f.ty.isClassLike {
        out += "  " + releaseCode("self->\(f.cName)", f.ty) + "\n"
      }
      out += "  free(p);\n}\n\n"

      let params = c.fields.isEmpty ? "void" : c.fields.map { "\($0.ty.cName) \($0.cName)" }.joined(separator: ", ")
      out += "static s_\(name) * a_\(name)(void) {\n"
      out += "  s_\(name) *o = calloc(1, sizeof *o);\n"
      out += "  if (!o) sw_trap(\"out of memory\");\n"
      out += "  o->hdr.rc = 1;\n  o->hdr.destroy = d_\(name);\n  return o;\n}\n\n"
      out += "static s_\(name) * n_\(name)(\(params)) {\n"
      out += "  s_\(name) *o = calloc(1, sizeof *o);\n"
      out += "  if (!o) sw_trap(\"out of memory\");\n"
      out += "  o->hdr.rc = 1;\n  o->hdr.destroy = d_\(name);\n"
      for f in c.fields {
        out += "  o->\(f.cName) = \(f.cName);\n"
      }
      out += "  return o;\n}\n\n"
    }

    for f in program.funcs {
      out += "static \(f.ret.cName) \(f.cName)(\(paramList(f))) {\n"
      if f.isClosure {
        out += "  (void)ctx_;\n"
        if let ctx = f.context {
          // Captured values are read through the context, named `cx` in the body.
          out += "  struct \(ctx.cName) *cx = ctx_;\n"
        }
      }
      out += block(f.body, "  ")
      out += "}\n\n"
    }

    out += "static void swift_main(void) {\n"
    out += block(program.main, "  ")
    out += "}\n\n"
    out += "int main(void) {\n  swift_main();\n  return 0;\n}\n"
    return out
  }

  /// The struct and helpers of an array of `elem`. Helpers are named by the element
  /// type, so they are shared by every array of that element.
  /// The struct of an array. It holds a pointer to its elements, which need only be
  /// declared, so it can be written before the element type is complete.
  private static func arrayStruct(_ ty: Ty, _ elem: Ty) -> String {
    "struct \(ty.cName) {\n  \(elem.cName) *data;\n  int64_t count;\n  int64_t cap;\n};\n"
  }

  /// Prototypes of the helpers of an array of `elem`, which other helpers may call.
  private static func arrayPrototypes(_ ty: Ty, _ elem: Ty) -> String {
    let e = elem.cName
    let m = elem.mangled
    let arr = ty.cName
    var text = ""
    text += "static \(arr) arr_lit_\(m)(int64_t n, \(e) *vals);\n"
    text += "static \(arr) arr_copy_\(m)(\(arr) a);\n"
    text += "static void arr_free_\(m)(\(arr) a);\n"
    text += "static void arr_check_\(m)(\(arr) a, int64_t i);\n"
    text += "static \(e) arr_get_\(m)(\(arr) a, int64_t i);\n"
    text += "static \(e) *arr_at_\(m)(\(arr) *a, int64_t i);\n"
    text += "static void arr_append_\(m)(\(arr) *a, \(e) v);\n"
    return text
  }

  /// The helper bodies of an array of `elem`.
  private static func arrayHelpers(_ ty: Ty, _ elem: Ty) -> String {
    let e = elem.cName
    let m = elem.mangled
    let arr = ty.cName
    var text = ""
    text += "static \(arr) arr_lit_\(m)(int64_t n, \(e) *vals) {\n"
    text += "  \(arr) a = { NULL, 0, 0 };\n"
    text += "  if (n > 0) {\n"
    text += "    a.data = malloc(sizeof(\(e)) * (size_t)n);\n"
    text += "    if (!a.data) sw_trap(\"out of memory\");\n"
    text += "    memcpy(a.data, vals, sizeof(\(e)) * (size_t)n);\n"
    text += "    a.count = n;\n    a.cap = n;\n  }\n  return a;\n}\n"
    // Elements that hold a reference count (a struct with a function value, say) are
    // retained by each copy and released when the array is freed.
    text += "static \(arr) arr_copy_\(m)(\(arr) a) {\n  \(arr) r = arr_lit_\(m)(a.count, a.data);\n"
    if elem.isClassLike {
      text += "  for (int64_t i = 0; i < r.count; i++) { \(retainCode("r.data[i]", elem)) }\n"
    }
    text += "  return r;\n}\n"
    text += "static void arr_free_\(m)(\(arr) a) {\n"
    if elem.isClassLike {
      text += "  for (int64_t i = 0; i < a.count; i++) { \(releaseCode("a.data[i]", elem)) }\n"
    }
    text += "  free(a.data);\n}\n"
    text += "static void arr_check_\(m)(\(arr) a, int64_t i) {\n"
    text += "  if (i < 0 || i >= a.count) sw_trap(\"Index out of range\");\n}\n"
    text += "static \(e) arr_get_\(m)(\(arr) a, int64_t i) { arr_check_\(m)(a, i); return a.data[i]; }\n"
    // Reading or counting a temporary array frees it. The element is copied out first, so
    // a class-like element keeps its own reference when the buffer's references are dropped.
    text += "static \(e) arr_get_tmp_\(m)(\(arr) a, int64_t i) {\n"
    text += "  \(e) v = arr_get_\(m)(a, i);\n"
    if elem.isClassLike { text += "  \(retainCode("v", elem))\n" }
    text += "  arr_free_\(m)(a);\n  return v;\n}\n"
    text += "static int64_t arr_count_tmp_\(m)(\(arr) a) {\n"
    text += "  int64_t n = a.count;\n  arr_free_\(m)(a);\n  return n;\n}\n"
    text += "static \(e) *arr_at_\(m)(\(arr) *a, int64_t i) { arr_check_\(m)(*a, i); return &a->data[i]; }\n"
    text += "static void arr_append_\(m)(\(arr) *a, \(e) v) {\n"
    text += "  if (a->count == a->cap) {\n"
    text += "    int64_t cap = a->cap ? a->cap * 2 : 4;\n"
    text += "    \(e) *d = realloc(a->data, sizeof(\(e)) * (size_t)cap);\n"
    text += "    if (!d) sw_trap(\"out of memory\");\n"
    text += "    a->data = d;\n    a->cap = cap;\n  }\n"
    text += "  a->data[a->count++] = v;\n}\n"
    // print() of an array of Int, Bool or Double. Other elements are not printed.
    switch elem {
    case .int, .bool, .double:
      var element = ""
      switch elem {
      case .int: element = "printf(\"%lld\", (long long)a.data[i]);"
      case .bool: element = "printf(\"%s\", a.data[i] ? \"true\" : \"false\");"
      default: element = "char buf[64]; sw_fmt_double(a.data[i], buf, sizeof buf); printf(\"%s\", buf);"
      }
      text += "static void pr_arr_\(m)(\(arr) a) {\n"
      text += "  printf(\"[\");\n"
      text += "  for (int64_t i = 0; i < a.count; i++) {\n"
      text += "    if (i) printf(\", \");\n    \(element)\n  }\n"
      text += "  printf(\"]\\n\");\n}\n"
      // An owned temporary is freed after printing, since print does not keep it.
      text += "static void prf_arr_\(m)(\(arr) a) { pr_arr_\(m)(a); arr_free_\(m)(a); }\n\n"
    default:
      break
    }
    return text
  }

  /// The wrapper for a method called on a temporary class value. The receiver is the
  /// first parameter, owned by the wrapper. The method returns an owned value, so the
  /// receiver can be released once the method has returned.
  private static func consumingWrapper(_ f: FuncInfo) -> String {
    let params = f.params.indices.map { "\(f.params[$0].ty.cName) p\($0)" }
    let args = f.params.indices.map { "p\($0)" }.joined(separator: ", ")
    var text = "static \(f.ret.cName) cs_\(f.cName)(\(params.isEmpty ? "void" : params.joined(separator: ", "))) {\n"
    if f.ret == .void {
      text += "  \(f.cName)(\(args));\n  sw_release(p0);\n}\n\n"
    } else {
      text += "  \(f.ret.cName) r = \(f.cName)(\(args));\n  sw_release(p0);\n  return r;\n}\n\n"
    }
    return text
  }

  private static func paramList(_ params: [Param]) -> String {
    if params.isEmpty { return "void" }
    return params.map { "\($0.ty.cName) \($0.cName)" }.joined(separator: ", ")
  }

  /// The C parameter list of a function. A closure takes its context pointer first.
  private static func paramList(_ f: FuncInfo) -> String {
    var items: [String] = f.isClosure ? ["void *ctx_"] : []
    items += f.params.map { "\($0.ty.cName) \($0.cName)" }
    return items.isEmpty ? "void" : items.joined(separator: ", ")
  }

  private static func block(_ stmts: [Stmt], _ indent: String) -> String {
    stmts.map { stmt($0, indent) }.joined()
  }

  private static func stmt(_ s: Stmt, _ indent: String) -> String {
    switch s {
    case .decl(let name, let ty, let value):
      return "\(indent)\(ty.cName) \(name) = \(expr(value));\n"
    case .assign(let target, let value, let ty):
      if ty.isClassLike {
        // The new value is stored before the old one is dropped. The place is evaluated
        // once, through a pointer, so an index expression runs once.
        return "\(indent){\n\(indent)  \(ty.cName) assign_new = \(expr(value));\n"
          + "\(indent)  \(ty.cName) *assign_slot = &(\(lvalue(target)));\n"
          + "\(indent)  \(ty.cName) assign_old = *assign_slot;\n"
          + "\(indent)  *assign_slot = assign_new;\n"
          + "\(indent)  \(releaseCode("assign_old", ty))\n\(indent)}\n"
      }
      return "\(indent)\(lvalue(target)) = \(expr(value));\n"
    case .expr(let value):
      return "\(indent)(void)(\(expr(value)));\n"
    case .ret(let value):
      if let value {
        return "\(indent)return \(expr(value));\n"
      }
      return "\(indent)return;\n"
    case .ifs(let cond, let then, let otherwise):
      var text = "\(indent)if (\(expr(cond))) {\n" + block(then, indent + "  ") + "\(indent)}"
      if !otherwise.isEmpty {
        text += " else {\n" + block(otherwise, indent + "  ") + "\(indent)}"
      }
      return text + "\n"
    case .whiles(let cond, let body):
      return "\(indent)while (\(expr(cond))) {\n" + block(body, indent + "  ") + "\(indent)}\n"
    case .brk:
      return "\(indent)break;\n"
    case .cont:
      return "\(indent)continue;\n"
    case .goto(let name):
      return "\(indent)goto \(name);\n"
    case .label(let name):
      return "\(indent)\(name): ;\n"
    case .release(let name, let ty):
      return "\(indent)\(releaseCode(name, ty))\n"
    }
  }

  /// Drops one reference to a class-like value held in `expr`.
  private static func releaseCode(_ expr: String, _ ty: Ty) -> String {
    if ty.isClass || ty.isBox { return "sw_release(\(expr));" }
    if case .array(let elem) = ty { return "arr_free_\(elem.mangled)(\(expr));" }
    return "rel_\(ty.cName)(\(expr));"
  }

  /// Adds one reference to a class-like value held in `expr`. A value that holds an array
  /// (directly, or in a struct, enum or Optional) is copied, so the place takes the copy;
  /// the copy is a new buffer, not a count.
  private static func retainCode(_ expr: String, _ ty: Ty) -> String {
    if ty.isClass || ty.isBox { return "sw_retain(\(expr));" }
    if case .array(let elem) = ty { return "\(expr) = arr_copy_\(elem.mangled)(\(expr));" }
    return "\(expr) = ret_\(ty.cName)(\(expr));"
  }

  private static func lvalue(_ target: LValue) -> String {
    switch target {
    case .local(let name):
      return name
    case .field(let base, let name, let arrow):
      return arrow ? "(\(lvalue(base)))->\(name)" : "(\(lvalue(base))).\(name)"
    case .index(let base, let idx, let arrTy):
      guard case .array(let elem) = arrTy else { return "(*(&(\(lvalue(base)))))" }
      return "(*arr_at_\(elem.mangled)(&\(lvalue(base)), \(expr(idx))))"
    }
  }

  private static func expr(_ e: Expr) -> String {
    switch e.kind {
    case .int(let v):
      return "INT64_C(\(v))"
    case .double(let v):
      return "(\(v))"
    case .convert(let inner):
      return "((double)\(expr(inner)))"
    case .bool(let v):
      return v ? "true" : "false"
    case .local(let name):
      return name
    case .field(let base, let name):
      if base.ty.isClass { return "(\(expr(base)))->\(name)" }
      return "(\(expr(base))).\(name)"
    case .call(let f, let args):
      return "\(f.cName)(\(args.map(expr).joined(separator: ", ")))"
    case .callOnTemp(let f, let args):
      return "cs_\(f.cName)(\(args.map(expr).joined(separator: ", ")))"
    case .print(let v):
      if case .array(let elem) = v.ty {
        return (v.owned ? "prf_arr_" : "pr_arr_") + elem.mangled + "(\(expr(v)))"
      }
      let printer = v.ty == .bool ? "sw_print_bool(" : (v.ty == .double ? "sw_print_double(" : "sw_print_int(")
      return printer + expr(v) + ")"
    case .structLit(let s, let args):
      let inits = zip(s.fields, args).map { ".\($0.0.cName) = \(expr($0.1))" }
      return "((s_\(cIdent(s.name))){ " + inits.joined(separator: ", ") + " })"
    case .allocObject(let c):
      return "a_\(cIdent(c.name))()"
    case .zeroValue:
      return "((\(e.ty.cName)){0})"
    case .construct(let c, let args):
      return "n_\(cIdent(c.name))(\(args.map(expr).joined(separator: ", ")))"
    case .prefix("-", let v):
      if v.ty == .double { return "(-\(expr(v)))" }
      return "sw_sub(INT64_C(0), \(expr(v)))"
    case .prefix("~", let v):
      return "(~(\(expr(v))))"
    case .prefix(_, let v):
      return "(!\(expr(v)))"
    case .binary(let op, let l, let r):
      let a = expr(l), b = expr(r)
      if l.ty == .double { return "(\(a) \(op) \(b))" }
      switch op {
      case "+": return "sw_add(\(a), \(b))"
      case "-": return "sw_sub(\(a), \(b))"
      case "*": return "sw_mul(\(a), \(b))"
      case "/": return "sw_div(\(a), \(b))"
      case "%": return "sw_rem(\(a), \(b))"
      // Wrapping: unsigned arithmetic is modulo 2^64, and the cast back is modulo too.
      case "&+": return "((int64_t)((uint64_t)(\(a)) + (uint64_t)(\(b))))"
      case "&-": return "((int64_t)((uint64_t)(\(a)) - (uint64_t)(\(b))))"
      case "&*": return "((int64_t)((uint64_t)(\(a)) * (uint64_t)(\(b))))"
      case "<<": return "sw_shl(\(a), \(b))"
      case ">>": return "sw_shr(\(a), \(b))"
      default: return "(\(a) \(op) \(b))"
      }
    case .logical(let op, let l, let r):
      return "(\(expr(l)) \(op) \(expr(r)))"
    case .retain(let inner):
      if e.ty.isClass || e.ty.isBox { return "((\(e.ty.cName))sw_retain(\(expr(inner))))" }
      if case .array(let elem) = e.ty { return "arr_copy_\(elem.mangled)(\(expr(inner)))" }
      return "ret_\(e.ty.cName)(\(expr(inner)))"
    case .wrap(let inner):
      return "((\(e.ty.cName)){ .some = true, .value = \(expr(inner)) })"
    case .nilValue:
      return "((\(e.ty.cName)){ .some = false })"
    case .isSome(let inner):
      return "((\(expr(inner))).some)"
    case .enumCase(let info, let tag, let args):
      var inits = [".tag = \(tag)"]
      let fields = info.cases.first(where: { $0.tag == tag })?.payload ?? []
      for (field, arg) in zip(fields, args) {
        inits.append(".\(field.cName) = \(expr(arg))")
      }
      return "((\(e.ty.cName)){ " + inits.joined(separator: ", ") + " })"
    case .arrayLit(let ty, let elems):
      guard case .array(let elem) = ty else { return "arr_lit_0(0, NULL)" }
      if elems.isEmpty { return "arr_lit_\(elem.mangled)(0, NULL)" }
      return "arr_lit_\(elem.mangled)(\(elems.count), (\(elem.cName)[]){\(elems.map(expr).joined(separator: ", "))})"
    case .index(let base, let idx):
      guard case .array(let elem) = base.ty else { return "0" }
      // A temporary array is freed by the `_tmp` helper, after the element is read.
      let getter = base.owned ? "arr_get_tmp_" : "arr_get_"
      return "\(getter)\(elem.mangled)(\(expr(base)), \(expr(idx)))"
    case .arrayCount(let base):
      if base.owned, case .array(let elem) = base.ty {
        return "arr_count_tmp_\(elem.mangled)(\(expr(base)))"
      }
      return "((\(expr(base))).count)"
    case .arrayAppend(let target, let value):
      return "arr_append_\(value.ty.mangled)(&\(lvalue(target)), \(expr(value)))"
    case .isCase(let inner, let tag):
      return "((\(expr(inner))).tag == \(tag))"
    case .funcRef(let f):
      let fn = f.isClosure ? f.cName : "thk_" + f.cName
      return "((\(e.ty.cName)){ .fn = \(fn), .ctx = NULL })"
    case .makeClosure(_, let ctx, let args):
      return "mk_\(ctx.id)(\(args.map(expr).joined(separator: ", ")))"
    case .boxNew(let v):
      guard case .box(let inner) = e.ty else { return "NULL" }
      return "bxn_\(inner.mangled)(\(expr(v)))"
    case .callPtr(let callee, let args):
      let helper = (callee.owned ? "callo_" : "call_") + callee.ty.cName
      return "\(helper)(\(([expr(callee)] + args.map(expr)).joined(separator: ", ")))"
    case .unwrap(let inner):
      return "unw_\(inner.ty.cName)(\(expr(inner)))"
    }
  }
}
