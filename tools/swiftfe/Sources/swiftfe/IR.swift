// Typed IR produced by Lower.swift and printed as C by CEmit.swift.
//
// M2 subset: Int, Bool, Void, structs with Int/Bool/struct/optional
// properties, reference-counted classes with stored properties and deinit,
// Optional types, global functions, and top-level statements.
//
// Ownership: an Expr with `owned == false` is a place (a local, or a field of
// a place) and does not carry a reference count. `owned == true` means the
// expression produces +1 on a class-like value. Lower.swift inserts the
// retains and releases; CEmit prints them.

indirect enum Ty: Equatable {
  case int
  case bool
  case void
  /// The type of the `nil` literal before a context gives it an Optional type.
  case nilLiteral
  case structure(String)
  case cls(String)
  case enumeration(String)
  case optional(Ty)
  /// A non-capturing function (closure or named function), as a C function pointer.
  case function([Ty], Ty)

  var swiftName: String {
    switch self {
    case .int: return "Int"
    case .bool: return "Bool"
    case .void: return "Void"
    case .nilLiteral: return "nil"
    case .structure(let name), .cls(let name), .enumeration(let name): return name
    case .optional(let inner): return inner.swiftName + "?"
    case .function(let params, let ret):
      return "(" + params.map { $0.swiftName }.joined(separator: ", ") + ") -> " + ret.swiftName
    }
  }

  /// Name fragment used to build C identifiers for this type.
  var mangled: String {
    switch self {
    case .int: return "Int"
    case .bool: return "Bool"
    case .void: return "Void"
    case .nilLiteral: return "Nil"
    case .structure(let name): return "S_" + name
    case .cls(let name): return "C_" + name
    case .enumeration(let name): return "E_" + name
    case .optional(let inner): return "O_" + inner.mangled
    case .function(let params, let ret):
      return "F_" + params.map { $0.mangled }.joined(separator: "_") + "_R_" + ret.mangled
    }
  }

  /// C spelling of values of this type. Optionals are named structs
  /// (`opt_<inner>`), and class values are pointers.
  var cName: String {
    switch self {
    case .int: return "int64_t"
    case .bool: return "bool"
    case .void, .nilLiteral: return "void"
    case .structure(let name): return "s_" + name
    case .cls(let name): return "s_" + name + " *"
    case .enumeration(let name): return "s_" + name
    case .optional(let inner): return "opt_" + inner.mangled
    case .function: return "fn_" + mangled
    }
  }

  var isClass: Bool {
    if case .cls = self { return true }
    return false
  }

  /// True for types whose values hold a reference count: a class, or an
  /// Optional wrapping one.
  var isClassLike: Bool {
    switch self {
    case .cls: return true
    case .optional(let inner): return inner.isClass
    default: return false
    }
  }

  /// True when the type is, or directly wraps, a class. Structs may not hold
  /// these in M2 because copying a struct would need its own retains.
  var containsClass: Bool {
    switch self {
    case .cls: return true
    case .optional(let inner): return inner.containsClass
    default: return false
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
}

final class ClassInfo {
  let name: String
  var fields: [Field] = []
  var deinitializer: FuncInfo?

  init(name: String) { self.name = name }
}

struct EnumCase {
  let name: String
  let tag: Int
  let payload: [Field]
}

final class EnumInfo {
  let name: String
  var cases: [EnumCase] = []

  init(name: String) { self.name = name }
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
  /// False for deinitializers, whose `self` is borrowed from the destroy path.
  let ownsParams: Bool
  var body: [Stmt] = []

  init(name: String, cName: String, params: [Param], ret: Ty, ownsParams: Bool = true) {
    self.name = name
    self.cName = cName
    self.params = params
    self.ret = ret
    self.ownsParams = ownsParams
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
  case construct(ClassInfo, [Expr])
  case prefix(String, Expr)
  case binary(String, Expr, Expr)
  case logical(String, Expr, Expr)
  /// +1 on a place's class-like value.
  case retain(Expr)
  /// Wraps a value of type T as T?.
  case wrap(Expr)
  /// `nil` of the expression's Optional type.
  case nilValue
  case isSome(Expr)
  /// Force unwrap; traps on nil.
  case unwrap(Expr)
  case enumCase(EnumInfo, Int, [Expr])
  /// True when the enum value has the given tag.
  case isCase(Expr, Int)
  /// A named function or closure used as a value.
  case funcRef(FuncInfo)
  case callPtr(Expr, [Expr])
}

struct Expr {
  let kind: ExprKind
  let ty: Ty
  let owned: Bool

  init(kind: ExprKind, ty: Ty, owned: Bool = false) {
    self.kind = kind
    self.ty = ty
    self.owned = owned
  }
}

indirect enum LValue {
  case local(String)
  /// `arrow` is true when the base is a class pointer.
  case field(LValue, String, arrow: Bool)
}

indirect enum Stmt {
  case decl(String, Ty, Expr)
  /// Assigns to a place; for class-like types the old value is released.
  case assign(LValue, Expr, Ty)
  case expr(Expr)
  case ret(Expr?)
  case ifs(Expr, [Stmt], [Stmt])
  case whiles(Expr, [Stmt])
  /// Leaves the innermost loop. Only `while let` lowering emits it.
  case brk
  /// Drops the reference held by an owned local at scope exit.
  case release(String, Ty)
}

/// A top-level variable. It is a zero-initialized C static, so it stays reachable
/// until exit, as a Swift global does.
struct Global {
  let cName: String
  let ty: Ty
}

struct Program {
  let structs: [StructInfo]
  let classes: [ClassInfo]
  let enums: [EnumInfo]
  let funcs: [FuncInfo]
  let globals: [Global]
  let main: [Stmt]
  /// Every Optional type that appears in the program, so CEmit can define it.
  let optionals: [Ty]
  /// Every function type that appears in the program, so CEmit can typedef it.
  let functionTypes: [Ty]
}
