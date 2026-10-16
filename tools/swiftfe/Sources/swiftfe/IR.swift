// Typed IR produced by Lower.swift and printed as C by CEmit.swift.
//
// M1 subset: Int, Bool, Void, structs with stored Int/Bool/struct fields,
// global functions, top-level statements, let/var, if, while, return,
// assignment to locals and fields, and print() for Int and Bool.

enum Ty: Equatable {
  case int
  case bool
  case void
  case structure(String)

  var swiftName: String {
    switch self {
    case .int: return "Int"
    case .bool: return "Bool"
    case .void: return "Void"
    case .structure(let name): return name
    }
  }

  /// C spelling for values of this type.
  var cName: String {
    switch self {
    case .int: return "int64_t"
    case .bool: return "bool"
    case .void: return "void"
    case .structure(let name): return "s_" + name
    }
  }
}

struct Field {
  let name: String
  let cName: String
  let ty: Ty
  let mutable: Bool
}

final class StructInfo {
  let name: String
  var fields: [Field] = []

  init(name: String) { self.name = name }

  var cName: String { "s_" + name }
}

struct Param {
  let label: String?
  let name: String
  let cName: String
  let ty: Ty
}

final class FuncInfo {
  let name: String
  let cName: String
  let params: [Param]
  let ret: Ty
  var body: [Stmt] = []

  init(name: String, cName: String, params: [Param], ret: Ty) {
    self.name = name
    self.cName = cName
    self.params = params
    self.ret = ret
  }
}

indirect enum ExprKind {
  case int(Int64)
  case bool(Bool)
  case local(String)
  case field(Expr, String)
  case call(FuncInfo, [Expr])
  case print(Expr)
  case structLit(StructInfo, [Expr])
  case prefix(String, Expr)
  case binary(String, Expr, Expr)
  case logical(String, Expr, Expr)
}

struct Expr {
  let kind: ExprKind
  let ty: Ty
}

indirect enum LValue {
  case local(String)
  case field(LValue, String)
}

indirect enum Stmt {
  case decl(String, Ty, Expr)
  case assign(LValue, Expr)
  case expr(Expr)
  case ret(Expr?)
  case ifs(Expr, [Stmt], [Stmt])
  case whiles(Expr, [Stmt])
}

struct Program {
  let structs: [StructInfo]
  let funcs: [FuncInfo]
  let main: [Stmt]
}
