// Prints the typed IR as C11. The output is compiled by the system C compiler.
//
// Integer arithmetic goes through checked helpers that trap on overflow and
// division by zero, as Swift does. Every expression is fully parenthesized, so
// the emitter never has to reason about C precedence.

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
    """

  static func emit(_ program: Program) -> String {
    var out = prelude + "\n\n"

    // Struct definitions, dependencies first. Recursion has already been rejected.
    var emitted = Set<String>()
    func emitStruct(_ s: StructInfo) {
      if emitted.contains(s.name) { return }
      emitted.insert(s.name)
      for field in s.fields {
        if case .structure(let dep) = field.ty,
           let depInfo = program.structs.first(where: { $0.name == dep }) {
          emitStruct(depInfo)
        }
      }
      out += "typedef struct \(s.cName) {\n"
      for field in s.fields {
        out += "  \(field.ty.cName) \(field.cName);\n"
      }
      out += "} \(s.cName);\n\n"
    }
    for s in program.structs { emitStruct(s) }

    for f in program.funcs {
      out += "static \(f.ret.cName) \(f.cName)(\(paramList(f.params)));\n"
    }
    out += "static void swift_main(void);\n\n"

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
    case .assign(let target, let value):
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
    }
  }

  private static func lvalue(_ target: LValue) -> String {
    switch target {
    case .local(let name): return name
    case .field(let base, let name): return "(\(lvalue(base))).\(name)"
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
      return "(\(expr(base))).\(name)"
    case .call(let f, let args):
      return "\(f.cName)(\(args.map(expr).joined(separator: ", ")))"
    case .print(let v):
      return (v.ty == .bool ? "sw_print_bool(" : "sw_print_int(") + expr(v) + ")"
    case .structLit(let s, let args):
      let inits = zip(s.fields, args).map { ".\($0.0.cName) = \(expr($0.1))" }
      return "((\(s.cName)){ " + inits.joined(separator: ", ") + " })"
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
    }
  }
}
