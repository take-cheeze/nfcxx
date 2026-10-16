// Prints the typed IR as C11. The output is compiled by the system C compiler.
//
// Integer arithmetic goes through checked helpers that trap on overflow and
// division by zero, as Swift does. Class instances start with an `sw_obj`
// header holding the reference count and destroy function. Every expression
// is fully parenthesized, so the emitter never has to reason about C precedence.

enum CEmit {
  static let prelude = """
    #include <stdbool.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>

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
    static void sw_print_int(int64_t v) {
      printf("%lld\\n", (long long)v);
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
    out += "\n"
    for fn in program.functionTypes {
      guard case .function(let params, let ret) = fn else { continue }
      let list = params.isEmpty ? "void" : params.map { $0.cName }.joined(separator: ", ")
      out += "typedef \(ret.cName) (*\(fn.cName))(\(list));\n"
    }
    out += "\n"

    // Value types (structs, enums and optionals), dependencies first.
    var defined = Set<String>()
    var values = ""
    func needsDefinition(_ ty: Ty) -> Bool {
      switch ty {
      case .structure, .enumeration, .optional: return true
      default: return false
      }
    }
    func defineValue(_ ty: Ty) {
      guard !defined.contains(ty.mangled) else { return }
      defined.insert(ty.mangled)
      switch ty {
      case .structure(let name):
        guard let info = program.structs.first(where: { $0.name == name }) else { return }
        for field in info.fields where needsDefinition(field.ty) { defineValue(field.ty) }
        values += "struct s_\(cIdent(name)) {\n"
        for field in info.fields {
          values += "  \(field.ty.cName) \(field.cName);\n"
        }
        values += "};\n\n"
      case .enumeration(let info):
        for c in info.cases {
          for field in c.payload where needsDefinition(field.ty) { defineValue(field.ty) }
        }
        let cn = ty.cName
        values += "struct \(cn) {\n  int64_t tag;\n"
        for c in info.cases {
          for field in c.payload {
            values += "  \(field.ty.cName) \(field.cName);\n"
          }
        }
        values += "};\n"
        if info.holdsRef {
          // Copies retain, and drops release, every class-like payload field. A value
          // leaves the fields of its other cases zero (a compound literal zeroes the
          // fields it does not name), and retaining or releasing a null pointer or an
          // empty Optional does nothing, so no switch on the tag is needed.
          values += "static \(cn) ret_\(cn)(\(cn) v) {\n"
          for c in info.cases {
            for field in c.payload where field.ty.isClassLike {
              values += "  " + retainCode("v.\(field.cName)", field.ty) + "\n"
            }
          }
          values += "  return v;\n}\n"
          values += "static void rel_\(cn)(\(cn) v) {\n"
          for c in info.cases {
            for field in c.payload where field.ty.isClassLike {
              values += "  " + releaseCode("v.\(field.cName)", field.ty) + "\n"
            }
          }
          values += "}\n"
        }
        values += "\n"
      case .optional(let inner):
        if needsDefinition(inner) { defineValue(inner) }
        let opt = ty.cName
        values += "struct \(opt) {\n  bool some;\n  \(inner.cName) value;\n};\n"
        values += "static \(inner.cName) unw_\(opt)(\(opt) v) {\n"
        values += "  if (!v.some) sw_trap(\"Unexpectedly found nil while unwrapping an Optional value\");\n"
        values += "  return v.value;\n}\n"
        if inner.isClassLike {
          values += "static \(opt) ret_\(opt)(\(opt) v) {\n  if (v.some) \(retainCode("v.value", inner))\n  return v;\n}\n"
          values += "static void rel_\(opt)(\(opt) v) {\n  if (v.some) \(releaseCode("v.value", inner))\n}\n"
        }
        values += "\n"
      default:
        break
      }
    }
    for s in program.structs { defineValue(.structure(s.name)) }
    for e in program.enums { defineValue(.enumeration(e)) }
    for o in program.optionals { defineValue(o) }
    out += values

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
      out += "static \(f.ret.cName) \(f.cName)(\(paramList(f.params)));\n"
    }
    out += "static void swift_main(void);\n\n"

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
      out += "static \(f.ret.cName) \(f.cName)(\(paramList(f.params))) {\n"
      out += block(f.body, "  ")
      out += "}\n\n"
    }

    out += "static void swift_main(void) {\n"
    out += block(program.main, "  ")
    out += "}\n\n"
    out += "int main(void) {\n  swift_main();\n  return 0;\n}\n"
    return out
  }

  private static func paramList(_ params: [Param]) -> String {
    if params.isEmpty { return "void" }
    return params.map { "\($0.ty.cName) \($0.cName)" }.joined(separator: ", ")
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
        // Retain-then-release order: the new value is stored before the old one is dropped.
        let lhs = lvalue(target)
        return "\(indent){\n\(indent)  \(ty.cName) assign_new = \(expr(value));\n"
          + "\(indent)  \(releaseCode(lhs, ty))\n"
          + "\(indent)  \(lhs) = assign_new;\n\(indent)}\n"
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
    case .release(let name, let ty):
      return "\(indent)\(releaseCode(name, ty))\n"
    }
  }

  /// Drops one reference to a class-like value held in `expr`.
  private static func releaseCode(_ expr: String, _ ty: Ty) -> String {
    if ty.isClass { return "sw_release(\(expr));" }
    return "rel_\(ty.cName)(\(expr));"
  }

  /// Adds one reference to a class-like value held in `expr`.
  private static func retainCode(_ expr: String, _ ty: Ty) -> String {
    if ty.isClass { return "sw_retain(\(expr));" }
    return "ret_\(ty.cName)(\(expr));"
  }

  private static func lvalue(_ target: LValue) -> String {
    switch target {
    case .local(let name):
      return name
    case .field(let base, let name, let arrow):
      return arrow ? "(\(lvalue(base)))->\(name)" : "(\(lvalue(base))).\(name)"
    }
  }

  private static func expr(_ e: Expr) -> String {
    switch e.kind {
    case .int(let v):
      return "INT64_C(\(v))"
    case .bool(let v):
      return v ? "true" : "false"
    case .local(let name):
      return name
    case .field(let base, let name):
      if base.ty.isClass { return "(\(expr(base)))->\(name)" }
      return "(\(expr(base))).\(name)"
    case .call(let f, let args):
      return "\(f.cName)(\(args.map(expr).joined(separator: ", ")))"
    case .print(let v):
      return (v.ty == .bool ? "sw_print_bool(" : "sw_print_int(") + expr(v) + ")"
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
      return "sw_sub(INT64_C(0), \(expr(v)))"
    case .prefix(_, let v):
      return "(!\(expr(v)))"
    case .binary(let op, let l, let r):
      let a = expr(l), b = expr(r)
      switch op {
      case "+": return "sw_add(\(a), \(b))"
      case "-": return "sw_sub(\(a), \(b))"
      case "*": return "sw_mul(\(a), \(b))"
      case "/": return "sw_div(\(a), \(b))"
      case "%": return "sw_rem(\(a), \(b))"
      default: return "(\(a) \(op) \(b))"
      }
    case .logical(let op, let l, let r):
      return "(\(expr(l)) \(op) \(expr(r)))"
    case .retain(let inner):
      if e.ty.isClass { return "((\(e.ty.cName))sw_retain(\(expr(inner))))" }
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
    case .isCase(let inner, let tag):
      return "((\(expr(inner))).tag == \(tag))"
    case .funcRef(let f):
      return f.cName
    case .callPtr(let callee, let args):
      return "(\(expr(callee)))(\(args.map(expr).joined(separator: ", ")))"
    case .unwrap(let inner):
      return "unw_\(inner.ty.cName)(\(expr(inner)))"
    }
  }
}
