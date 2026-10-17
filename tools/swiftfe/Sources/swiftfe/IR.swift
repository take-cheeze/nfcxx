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
  case double
  case bool
  /// A growable array of value elements. It is owned like a class reference:
  /// copying it copies the buffer, and it is freed when its owner goes away.
  case array(Ty)
  case void
  /// The type of the `nil` literal before a context gives it an Optional type.
  case nilLiteral
  case structure(StructInfo)
  case cls(String)
  case enumeration(EnumInfo)
  case optional(Ty)
  /// A non-capturing function (closure or named function), as a C function pointer.
  case function([Ty], Ty)

  var swiftName: String {
    switch self {
    case .int: return "Int"
    case .double: return "Double"
    case .bool: return "Bool"
    case .void: return "Void"
    case .nilLiteral: return "nil"
    case .array(let elem): return "[" + elem.swiftName + "]"
    case .structure(let info): return info.name
    case .cls(let name): return name
    case .enumeration(let info): return info.name
    case .optional(let inner): return inner.swiftName + "?"
    case .function(let params, let ret):
      return "(" + params.map { $0.swiftName }.joined(separator: ", ") + ") -> " + ret.swiftName
    }
  }

  /// Name fragment used to build C identifiers for this type.
  var mangled: String {
    switch self {
    case .int: return "Int"
    case .double: return "Double"
    case .bool: return "Bool"
    case .void: return "Void"
    case .nilLiteral: return "Nil"
    case .array(let elem): return "A_" + elem.mangled
    case .structure(let info): return "S_" + cIdent(info.name)
    case .cls(let name): return "C_" + cIdent(name)
    case .enumeration(let info): return "E_" + cIdent(info.name)
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
    case .double: return "double"
    case .array(let elem): return "arr_" + elem.mangled
    case .bool: return "bool"
    case .void, .nilLiteral: return "void"
    case .structure(let info): return "s_" + cIdent(info.name)
    case .cls(let name): return "s_" + cIdent(name) + " *"
    case .enumeration(let info): return "s_" + cIdent(info.name)
    case .optional(let inner): return "opt_" + inner.mangled
    case .function: return "fn_" + mangled
    }
  }

  var isClass: Bool {
    if case .cls = self { return true }
    return false
  }

  var isStructure: Bool {
    if case .structure = self { return true }
    return false
  }

  var isArray: Bool {
    if case .array = self { return true }
    return false
  }

  /// True for types whose values hold a reference count: a class, an array, a struct
  /// or enum with such a field or payload, or an Optional wrapping one of these. Such
  /// values are retained when copied from a place and released by their owner.
  var isClassLike: Bool {
    switch self {
    case .cls, .array: return true
    case .structure(let info): return info.isClassLike
    case .enumeration(let info): return info.holdsRef
    case .optional(let inner): return inner.isClassLike
    default: return false
    }
  }

  /// True when a value of this type holds a class instance directly, or through
  /// structs, enums and Optionals. Structs may not hold such a value (a struct copy
  /// would need class retains), so this is what a struct property may not be. An
  /// array does not count: its elements are handled by the array helpers.
  var holdsClassRef: Bool {
    switch self {
    case .cls: return true
    case .optional(let inner): return inner.holdsClassRef
    case .structure(let info): return info.fields.contains { $0.ty.holdsClassRef }
    case .enumeration(let info): return info.cases.contains { $0.payload.contains { $0.ty.holdsClassRef } }
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

final class StructInfo: Equatable {
  let name: String
  var fields: [Field] = []
  var methods: [String: FuncInfo] = [:]
  var initializers: [FuncInfo] = []

  init(name: String) { self.name = name }

  /// True when a field is class-like, so a copy of the struct retains or copies it.
  var isClassLike: Bool { fields.contains { $0.ty.isClassLike } }

  static func == (a: StructInfo, b: StructInfo) -> Bool { a === b }
}

final class ClassInfo {
  let name: String
  var fields: [Field] = []
  var deinitializer: FuncInfo?
  /// Methods by name. The receiver is the first parameter, named self.
  var methods: [String: FuncInfo] = [:]
  /// Explicit initializers. When there are any, the memberwise one is not available.
  var initializers: [FuncInfo] = []

  init(name: String) { self.name = name }
}

struct EnumCase {
  let name: String
  let tag: Int
  let payload: [Field]
}

final class EnumInfo: Equatable {
  let name: String
  var cases: [EnumCase] = []
  /// True when some payload is class-like (a class, an array, or an Optional of one).
  /// Computed from the payloads, so it is right for every instance, generic or not.
  var holdsRef: Bool {
    cases.contains { $0.payload.contains { $0.ty.isClassLike } }
  }

  init(name: String) { self.name = name }

  static func == (a: EnumInfo, b: EnumInfo) -> Bool { a === b }
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
  case double(Double)
  /// Int to Double, as `Double(n)`.
  case convert(Expr)
  /// An array literal. The element type is kept for an empty literal.
  case arrayLit(Ty, [Expr])
  /// `a[i]` for reading.
  case index(Expr, Expr)
  /// `a.count`.
  case arrayCount(Expr)
  /// `a.append(v)`, where the target is an array place.
  case arrayAppend(LValue, Expr)
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
  /// A new class instance with every stored property zeroed, owned by the caller.
  case allocObject(ClassInfo)
  /// The zero value of a struct, used as `self` before an initializer assigns it.
  case zeroValue
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
  /// `a[i]` as a place. The array type is kept to name its helpers.
  case index(LValue, Expr, Ty)
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
  /// Continues the innermost loop.
  case cont
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
  /// Every array type that appears in the program.
  let arrays: [Ty]
  /// Every function type that appears in the program, so CEmit can typedef it.
  let functionTypes: [Ty]
}

/// C spelling of a type or function name. Identifier characters are kept, so the
/// names of ordinary declarations do not change. Other characters, as in an
/// instance such as `Box<Int>`, become escapes that keep distinct names apart.
func cIdent(_ name: String) -> String {
  var out = ""
  for ch in name {
    switch ch {
    case "<": out += "_L_"
    case ">": out += "_G_"
    case ",": out += "_C_"
    case "?": out += "_Q_"
    case "(": out += "_P_"
    case ")": out += "_R_"
    case "-": out += "_M_"
    case " ": break
    case "_", "a"..."z", "A"..."Z", "0"..."9": out.append(ch)
    default: out += "_u\(ch.unicodeScalars.first!.value)_"
    }
  }
  return out
}
