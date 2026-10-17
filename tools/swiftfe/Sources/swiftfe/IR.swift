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
  case structure(String)
  case cls(String)
  case enumeration(EnumInfo)
  case optional(Ty)
  /// A function value: a function and the context it is called with. A named function
  /// or a closure that captures nothing has a NULL context. Function values are
  /// reference-counted through the context (see `Ty.isClassLike`).
  case function([Ty], Ty)
  /// A heap cell holding a `var` that a closure captures, so that both the closure and
  /// the enclosing body see the same value.
  case box(Ty)

  var swiftName: String {
    switch self {
    case .int: return "Int"
    case .double: return "Double"
    case .bool: return "Bool"
    case .void: return "Void"
    case .nilLiteral: return "nil"
    case .array(let elem): return "[" + elem.swiftName + "]"
    case .structure(let name), .cls(let name): return name
    case .enumeration(let info): return info.name
    case .optional(let inner): return inner.swiftName + "?"
    case .function(let params, let ret):
      return "(" + params.map { $0.swiftName }.joined(separator: ", ") + ") -> " + ret.swiftName
    case .box(let inner): return "Box<" + inner.swiftName + ">"
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
    case .structure(let name): return "S_" + cIdent(name)
    case .cls(let name): return "C_" + cIdent(name)
    case .enumeration(let info): return "E_" + cIdent(info.name)
    case .optional(let inner): return "O_" + inner.mangled
    case .function(let params, let ret):
      return "F_" + params.map { $0.mangled }.joined(separator: "_") + "_R_" + ret.mangled
    case .box(let inner): return "B_" + inner.mangled
    }
  }

  /// C spelling of values of this type. Optionals are named structs
  /// (`opt_<inner>`), and class values are pointers. A function value is a struct
  /// `{ fn, ctx }`, and a box is a pointer to a struct with a header.
  var cName: String {
    switch self {
    case .int: return "int64_t"
    case .double: return "double"
    case .array(let elem): return "arr_" + elem.mangled
    case .bool: return "bool"
    case .void, .nilLiteral: return "void"
    case .structure(let name): return "s_" + cIdent(name)
    case .cls(let name): return "s_" + cIdent(name) + " *"
    case .enumeration(let info): return "s_" + cIdent(info.name)
    case .optional(let inner): return "opt_" + inner.mangled
    case .function: return "fn_" + mangled
    case .box(let inner): return "struct bx_" + inner.mangled + " *"
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

  var isBox: Bool {
    if case .box = self { return true }
    return false
  }

  /// True for types whose values hold a reference count: a class, an array, a function
  /// value (through its context), a box, an enum with a class-like payload, a struct
  /// with a class-like field, or an Optional wrapping one of these. Such values are
  /// retained when copied from a place and released by their owner. Only a struct
  /// that is itself reference-counted may be stored in a struct, which
  /// `refStructNames` records.
  var isClassLike: Bool {
    switch self {
    case .cls, .array, .function, .box: return true
    case .structure(let name): return refStructNames.contains(name)
    case .enumeration(let info): return info.holdsRef
    case .optional(let inner): return inner.isClassLike
    default: return false
    }
  }
}

/// Names of the structs that are reference-counted, filled in by Lowerer before any
/// type is checked against them. A struct is reference-counted when a field is.
/// Compilation handles one file per process, so a single set is enough.
var refStructNames: Set<String> = []

struct Field {
  let name: String
  let cName: String
  let ty: Ty
  let mutable: Bool
}

final class StructInfo {
  let name: String
  var fields: [Field] = []
  var methods: [String: FuncInfo] = [:]
  var initializers: [FuncInfo] = []

  init(name: String) { self.name = name }
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
  /// True when some payload holds a class reference. Set by Lowerer once every
  /// enum's payloads are known, before any type is checked against it.
  var holdsRef = false

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
  /// True for a closure body. Its C function takes the context pointer as its first
  /// argument, and it is only ever called through a function value.
  var isClosure = false
  /// The captured values of a closure, or nil when it captures nothing.
  var context: ClosureContext? = nil
  /// True when a named function is used as a value, so it needs a thunk that takes
  /// the context pointer.
  var asValue = false
  var body: [Stmt] = []

  init(name: String, cName: String, params: [Param], ret: Ty, ownsParams: Bool = true) {
    self.name = name
    self.cName = cName
    self.params = params
    self.ret = ret
    self.ownsParams = ownsParams
  }
}

/// The heap object that holds the values a closure captured. Its fields are copies of
/// the captured values (class-like ones retained), or boxes for captured `var`s.
final class ClosureContext {
  let id: Int
  let fields: [Field]

  init(id: Int, fields: [Field]) {
    self.id = id
    self.fields = fields
  }

  var cName: String { "cx_\(id)" }
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
  /// A named function or a closure that captures nothing, as a function value.
  case funcRef(FuncInfo)
  /// A closure that captures values. The arguments are the captured values, owned by
  /// the new context.
  case makeClosure(FuncInfo, ClosureContext, [Expr])
  /// A function value called through its context. An owned callee is released after
  /// the call.
  case callPtr(Expr, [Expr])
  /// A new box holding the owned value.
  case boxNew(Expr)
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
  /// Every box type (`.box`) that appears in the program.
  let boxes: [Ty]
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
