// Lowers the operator-folded swift-syntax tree into the typed IR.
//
// This is where names are resolved, types are checked, and reference counts
// are inserted. The first error stops compilation.
//
// Ownership rules:
// - A class-like value in an owned position (a local's initializer, an
//   assignment's right side, a call argument, a constructor argument, a
//   return value) is +1. Places are retained when read into such a position.
// - Function parameters are owned by the callee and released at its exit.
//   Deinitializers borrow `self`.
// - Owned locals are released at the end of their block, and before any
//   `return` that leaves the block.
// - Class-typed temporaries that are not stored are released after their
//   statement.
// - Top-level variables are never released (they live until exit, as in Swift).
//
// Closures do not capture: a closure body sees only its own parameters and
// top-level names, and an outer local is reported as not in scope.

import SwiftParser
import SwiftSyntax

struct CompileError: Error {
  let message: String
  let line: Int
  let column: Int
}

private struct Local {
  let cName: String
  let ty: Ty
  let mutable: Bool
}

/// Names declared in one block, and the owned references to drop when it ends.
private struct Scope {
  var vars: [String: Local] = [:]
  var owned: [(cName: String, ty: Ty)] = []
}

private struct ArgInput {
  let label: String?
  let value: Expr
  let node: LabeledExprSyntax
}

/// A generic declaration and its type parameter names, kept until a use supplies arguments.
private struct GenericDecl<Decl> {
  let decl: Decl
  let names: [String]
}

/// A parameter of a generic declaration as written: its label and its type syntax.
private struct GenericParam {
  let label: String?
  let type: TypeSyntax
}

/// A deinitializer of a generic class instance. It is lowered after the pass that
/// created the instance, so that the functions it calls have been declared.
/// An initializer whose body is lowered after the rest of the program, under the
/// type environment of the instance it belongs to.
private struct PendingInit {
  let info: FuncInfo
  let decl: InitializerDeclSyntax
  let env: [String: Ty]
  let owner: Ty
}

private struct PendingMethod {
  let info: FuncInfo
  let decl: FunctionDeclSyntax
  let env: [String: Ty]
}

private struct PendingDeinit {
  let info: FuncInfo
  let decl: DeinitializerDeclSyntax
  let env: [String: Ty]
}

final class Lowerer {
  private let converter: SourceLocationConverter
  private var structs: [String: StructInfo] = [:]
  private var classes: [String: ClassInfo] = [:]
  private var enums: [String: EnumInfo] = [:]
  private var funcs: [String: FuncInfo] = [:]
  private var allFuncs: [FuncInfo] = []
  private var optionals: [Ty] = []
  private var functionTypes: [Ty] = []
  private var arrays: [Ty] = []
  private var globals: [Global] = []
  /// Top-level variables. Function bodies and closures see them as globals.
  private var globalVars: [String: Local] = [:]
  private var scopes: [Scope] = []
  private var returnType: Ty? = nil
  private var counter = 0

  // Generics (M3, by monomorphization). A generic declaration is kept until a use
  // supplies type arguments. Each distinct list of arguments is lowered once, into
  // an instance named like the Swift type (`Box<Int>`). `typeEnv` binds the type
  // parameters while an instance is lowered.
  private var genericFuncs: [String: GenericDecl<FunctionDeclSyntax>] = [:]
  private var genericStructs: [String: GenericDecl<StructDeclSyntax>] = [:]
  private var genericClasses: [String: GenericDecl<ClassDeclSyntax>] = [:]
  private var genericEnums: [String: GenericDecl<EnumDeclSyntax>] = [:]
  private var instanceFuncs: [String: FuncInfo] = [:]
  /// The generic declaration and arguments that each type instance came from.
  private var instanceArgs: [String: (base: String, args: [Ty])] = [:]
  private var instanceNodes: [String: Syntax] = [:]
  private var instStructs: [StructInfo] = []
  private var instClasses: [ClassInfo] = []
  private var instEnums: [EnumInfo] = []
  private var pendingDeinits: [PendingDeinit] = []
  private var pendingInits: [PendingInit] = []
  /// Enclosing loops and switches, innermost last, with the scope depth each one starts at.
  private var loops: [(depth: Int, isSwitch: Bool)] = []
  private var pendingMethods: [PendingMethod] = []
  /// The stored properties of structs, with their declarations, checked at the end of lowering.
  private var structFieldChecks: [(node: Syntax, ty: Ty)] = []
  /// True while lowering an initializer body, where `self` may be assigned.
  private var initializingSelf = false
  private var typeEnv: [String: Ty] = [:]
  private var instantiationDepth = 0

  init(converter: SourceLocationConverter) {
    self.converter = converter
  }

  func lower(_ file: SourceFileSyntax) throws -> Program {
    let items = Array(file.statements)

    // Pass 1: declare every type so fields and bodies can refer to them in any order.
    var structDecls: [(StructDeclSyntax, StructInfo)] = []
    var classDecls: [(ClassDeclSyntax, ClassInfo)] = []
    var enumDecls: [(EnumDeclSyntax, EnumInfo)] = []
    for item in items {
      guard case .decl(let decl) = item.item else { continue }
      if let s = decl.as(StructDeclSyntax.self) {
        let name = s.name.text
        try checkNewType(name, s)
        if let clause = s.genericParameterClause {
          genericStructs[name] = GenericDecl<StructDeclSyntax>(decl: s, names: try genericNames(clause, s.genericWhereClause))
          continue
        }
        let info = StructInfo(name: name)
        structs[name] = info
        structDecls.append((s, info))
      } else if let c = decl.as(ClassDeclSyntax.self) {
        let name = c.name.text
        if c.inheritanceClause != nil {
          throw error("class inheritance is not supported yet", c)
        }
        try checkNewType(name, c)
        if let clause = c.genericParameterClause {
          genericClasses[name] = GenericDecl<ClassDeclSyntax>(decl: c, names: try genericNames(clause, c.genericWhereClause))
          continue
        }
        let info = ClassInfo(name: name)
        classes[name] = info
        classDecls.append((c, info))
      } else if let e = decl.as(EnumDeclSyntax.self) {
        let name = e.name.text
        if e.inheritanceClause != nil {
          throw error("enum inheritance and raw values are not supported yet", e)
        }
        try checkNewType(name, e)
        if let clause = e.genericParameterClause {
          genericEnums[name] = GenericDecl<EnumDeclSyntax>(decl: e, names: try genericNames(clause, e.genericWhereClause))
          continue
        }
        let info = EnumInfo(name: name)
        enums[name] = info
        enumDecls.append((e, info))
      }
    }

    // Pass 2: enum payloads first, because whether an enum holds a class decides
    // how struct properties may be typed. Then stored properties and deinitializers.
    for (decl, info) in enumDecls {
      info.cases = try lowerEnumCases(decl)
    }
    var deinitDecls: [(DeinitializerDeclSyntax, ClassInfo)] = []
    for (decl, info) in structDecls {
      let members = try lowerMembers(decl.memberBlock, isClass: false)
      info.fields = members.fields
      info.initializers = try declareInitializers(members.initializers, owner: .structure(info), env: [:], name: info.name)
      info.methods = try declareMethods(members.methods, owner: .structure(info), env: [:], name: info.name)
    }
    for (decl, info) in classDecls {
      let members = try lowerMembers(decl.memberBlock, isClass: true)
      info.fields = members.fields
      info.initializers = try declareInitializers(members.initializers, owner: .cls(info.name), env: [:], name: info.name)
      info.methods = try declareMethods(members.methods, owner: .cls(info.name), env: [:], name: info.name)
      if let d = members.deinitializer {
        deinitDecls.append((d, info))
      }
    }
    var recursionNodes: [(name: String, node: Syntax, types: [Ty])] = []
    for (decl, info) in structDecls {
      recursionNodes.append((info.name, Syntax(decl), info.fields.map { $0.ty }))
    }
    for (decl, info) in enumDecls {
      recursionNodes.append((info.name, Syntax(decl), info.cases.flatMap { $0.payload.map { $0.ty } }))
    }
    try checkRecursion(recursionNodes)

    // Pass 3: function and deinitializer signatures.
    var funcDecls: [(FunctionDeclSyntax, FuncInfo)] = []
    for item in items {
      guard case .decl(let decl) = item.item, let f = decl.as(FunctionDeclSyntax.self) else { continue }
      let name = f.name.text
      if funcs[name] != nil || genericFuncs[name] != nil { throw error("invalid redeclaration of '\(name)'", f) }
      if let clause = f.genericParameterClause {
        genericFuncs[name] = GenericDecl<FunctionDeclSyntax>(decl: f, names: try genericNames(clause, f.genericWhereClause))
        continue
      }
      let info = try declareFunction(f)
      funcs[name] = info
      allFuncs.append(info)
      funcDecls.append((f, info))
    }
    var deinitBodies: [(DeinitializerDeclSyntax, FuncInfo)] = []
    for (d, cls) in deinitDecls {
      let info = FuncInfo(
        name: "deinit_" + cls.name,
        cName: "deinit_" + cls.name,
        params: [Param(label: nil, name: "self", cName: "self", ty: .cls(cls.name))],
        ret: .void,
        ownsParams: false
      )
      cls.deinitializer = info
      allFuncs.append(info)
      deinitBodies.append((d, info))
    }

    // Pass 4: top-level statements. They run before function bodies so that the
    // global variables they declare are visible to functions. Their variables are visible only here, and
    // they are never released.
    scopes = [Scope()]
    returnType = nil
    var main: [Stmt] = []
    for item in items {
      switch item.item {
      case .decl(let decl):
        if decl.is(FunctionDeclSyntax.self) || decl.is(StructDeclSyntax.self)
          || decl.is(ClassDeclSyntax.self) || decl.is(EnumDeclSyntax.self) {
          continue
        }
        main += try lowerDecl(decl)
      case .stmt(let stmt):
        main += try lowerStmt(stmt)
      case .expr(let expr):
        main += try lowerExprStmt(expr)
      }
    }

    // Instances can make a value type contain itself, so check the sizes again.
    try lowerPendingDeinits()
    var sizeNodes = recursionNodes
    for s in instStructs {
      sizeNodes.append((s.name, instanceNodes[s.name]!, s.fields.map { $0.ty }))
    }
    for e in instEnums {
      sizeNodes.append((e.name, instanceNodes[e.name]!, e.cases.flatMap { $0.payload.map { $0.ty } }))
    }
    try checkRecursion(sizeNodes)

    // Pass 5: bodies.
    for (decl, info) in funcDecls {
      guard let body = decl.body else { throw error("function without a body", decl) }
      info.body = try lowerBody(info, body, decl)
    }
    for (d, info) in deinitBodies {
      guard let body = d.body else { throw error("deinit without a body", d) }
      info.body = try lowerBody(info, body, d)
    }

    try lowerPendingDeinits()

    for check in structFieldChecks where check.ty.holdsClassRef {
      throw error("structs with class-typed or array properties are not supported yet", check.node)
    }
    return Program(
      structs: structDecls.map { $0.1 } + instStructs,
      classes: classDecls.map { $0.1 } + instClasses,
      enums: enumDecls.map { $0.1 } + instEnums,
      funcs: allFuncs,
      globals: globals,
      main: main,
      optionals: optionals,
      arrays: arrays,
      functionTypes: functionTypes
    )
  }

  // MARK: - Declarations

  private func checkNewType(_ name: String, _ node: some SyntaxProtocol) throws {
    if structs[name] != nil || classes[name] != nil || enums[name] != nil || isGenericName(name) {
      throw error("invalid redeclaration of '\(name)'", node)
    }
  }

  private func lowerMembers(
    _ block: MemberBlockSyntax,
    isClass: Bool
  ) throws -> (fields: [Field], deinitializer: DeinitializerDeclSyntax?, initializers: [InitializerDeclSyntax], methods: [FunctionDeclSyntax]) {
    var fields: [Field] = []
    var deinitializer: DeinitializerDeclSyntax? = nil
    var initializers: [InitializerDeclSyntax] = []
    var methods: [FunctionDeclSyntax] = []
    for member in block.members {
      if let v = member.decl.as(VariableDeclSyntax.self) {
        let mutable = v.bindingSpecifier.tokenKind == .keyword(.var)
        for binding in v.bindings {
          guard let id = binding.pattern.as(IdentifierPatternSyntax.self), let annotation = binding.typeAnnotation else {
            throw error("stored property needs a name and a type", binding)
          }
          if binding.initializer != nil {
            throw error("default property values are not supported yet", binding)
          }
          let name = id.identifier.text
          if fields.contains(where: { $0.name == name }) {
            throw error("invalid redeclaration of '\(name)'", binding)
          }
          let ty = try resolveType(annotation.type)
          // Checked after every type is declared, since the field's type may be a struct not yet lowered.
          if !isClass { structFieldChecks.append((Syntax(binding), ty)) }
          fields.append(Field(name: name, cName: "m_" + name, ty: ty, mutable: mutable))
        }
      } else if isClass, let d = member.decl.as(DeinitializerDeclSyntax.self) {
        if deinitializer != nil { throw error("invalid redeclaration of 'deinit'", d) }
        deinitializer = d
      } else if let i = member.decl.as(InitializerDeclSyntax.self) {
        initializers.append(i)
      } else if let m = member.decl.as(FunctionDeclSyntax.self) {
        methods.append(m)
      } else {
        throw error("this member is not supported in M2", member)
      }
    }
    if !isClass && fields.isEmpty {
      throw error("structs without stored properties are not supported yet", block)
    }
    return (fields, deinitializer, initializers, methods)
  }

  private func lowerEnumCases(_ decl: EnumDeclSyntax) throws -> [EnumCase] {
    var cases: [EnumCase] = []
    for member in decl.memberBlock.members {
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
        throw error("only cases are supported in enums in M2", member)
      }
      for element in caseDecl.elements {
        let name = element.name.text
        if cases.contains(where: { $0.name == name }) {
          throw error("invalid redeclaration of '\(name)'", element)
        }
        if element.rawValue != nil {
          throw error("raw values are not supported yet", element)
        }
        let tag = cases.count
        var payload: [Field] = []
        if let params = element.parameterClause?.parameters {
          for p in params {
            if p.firstName != nil {
              throw error("labeled enum payloads are not supported yet", p)
            }
            let ty = try resolveType(p.type)
            payload.append(Field(name: "_\(payload.count)", cName: "c\(tag)_\(payload.count)", ty: ty, mutable: true))
          }
        }
        cases.append(EnumCase(name: name, tag: tag, payload: payload))
      }
    }
    return cases
  }

  /// Rejects a value type that contains itself by value, which Swift also rejects.
  /// Classes are references, so they may refer to themselves.
  private func checkRecursion(_ decls: [(name: String, node: Syntax, types: [Ty])]) throws {
    var table: [String: (node: Syntax, types: [Ty])] = [:]
    for d in decls { table[d.name] = (d.node, d.types) }
    var finished = Set<String>()

    func visit(_ name: String, _ active: [String]) throws {
      if finished.contains(name) { return }
      guard let entry = table[name] else { return }
      if active.contains(name) {
        throw error("value type '\(name)' has infinite size", entry.node)
      }
      for ty in entry.types {
        if let child = valueName(ty) {
          try visit(child, active + [name])
        }
      }
      finished.insert(name)
    }

    for d in decls {
      try visit(d.name, [])
    }
  }

  /// Array elements may be any value, class-like or not. Copying an array copies or
  /// retains each element, and freeing it releases each one (see CEmit.arrayHelpers).
  /// Whether an element is class-like is read when the C is emitted, so an enum
  /// whose payloads are still being lowered is accepted here.
  private func checkArrayElement(_ ty: Ty, _ node: some SyntaxProtocol) throws {
    switch ty {
    case .void, .nilLiteral:
      throw error("arrays of \(ty.swiftName) are not supported yet", node)
    default:
      return
    }
  }

  private func arrayOf(_ elem: Ty, _ node: some SyntaxProtocol) throws -> Ty {
    try checkArrayElement(elem, node)
    let ty = Ty.array(elem)
    if !arrays.contains(ty) { arrays.append(ty) }
    return ty
  }

  private func valueName(_ ty: Ty) -> String? {
    switch ty {
    case .structure(let info), .optional(.structure(let info)):
      return info.name
    case .enumeration(let info), .optional(.enumeration(let info)):
      return info.name
    default:
      return nil
    }
  }

  private func declareParams(_ parameters: FunctionParameterListSyntax) throws -> [Param] {
    var params: [Param] = []
    for p in parameters {
      // `func f(_ x: Int)` has no label; `func f(x: Int)` uses x as both.
      let first = p.firstName.text
      let label: String? = first == "_" ? nil : first
      let internalName = p.secondName?.text ?? first
      let cName = "p\(nextID())_" + internalName
      params.append(Param(label: label, name: internalName, cName: cName, ty: try resolveType(p.type)))
    }
    return params
  }

  private func declareFunction(_ f: FunctionDeclSyntax, instanceName: String? = nil) throws -> FuncInfo {
    let name = instanceName ?? f.name.text
    let params = try declareParams(f.signature.parameterClause.parameters)
    let ret: Ty
    if let clause = f.signature.returnClause {
      ret = try resolveType(clause.type)
    } else {
      ret = .void
    }
    return FuncInfo(name: name, cName: "f_" + cIdent(name), params: params, ret: ret)
  }

  private func lowerBody(_ info: FuncInfo, _ body: CodeBlockSyntax, _ node: some SyntaxProtocol) throws -> [Stmt] {
    var root = Scope()
    for p in info.params {
      root.vars[p.name] = Local(cName: p.cName, ty: p.ty, mutable: false)
      if info.ownsParams && p.ty.isClassLike && p.name != "self" {
        root.owned.append((cName: p.cName, ty: p.ty))
      }
    }
    scopes = [root]
    returnType = info.ret
    var stmts = try lowerBlock(body.statements)
    if !endsInJump(stmts) {
      stmts += releases(of: scopes[0])
    }
    if info.ret != .void && !alwaysReturns(stmts) {
      throw error("missing return in global function expected to return '\(info.ret.swiftName)'", node)
    }
    return stmts
  }

  private func lowerDecl(_ decl: DeclSyntax) throws -> [Stmt] {
    guard let v = decl.as(VariableDeclSyntax.self) else {
      throw error("this declaration is not supported in M2", decl)
    }
    let mutable = v.bindingSpecifier.tokenKind == .keyword(.var)
    var out: [Stmt] = []
    for binding in v.bindings {
      guard let id = binding.pattern.as(IdentifierPatternSyntax.self) else {
        throw error("only simple names are supported in M2", binding.pattern)
      }
      guard let initializer = binding.initializer?.value else {
        throw error("variables need an initial value in M2", binding)
      }
      var declared: Ty? = nil
      if let annotation = binding.typeAnnotation {
        declared = try resolveType(annotation.type)
      }
      var value = try lowerExpr(initializer, expected: declared)
      var ty = value.ty
      if let declared {
        ty = declared
        value = try coerce(value, to: declared, initializer)
      }
      if ty == .void {
        throw error("cannot initialize a variable with a value of type 'Void'", initializer)
      }
      if ty == .nilLiteral {
        throw error("'nil' requires a contextual type", initializer)
      }
      value = own(value)
      let name = id.identifier.text
      let cName = "l\(nextID())_" + name
      try declare(name, cName: cName, ty: ty, mutable: mutable, owned: ty.isClassLike, binding)
      if scopes.count == 1 {
        // Top-level code: the variable is a global, assigned where its declaration
        // runs. The global is still zero here, so the assignment releases nothing.
        globals.append(Global(cName: cName, ty: ty))
        globalVars[name] = Local(cName: cName, ty: ty, mutable: mutable)
        out.append(.assign(.local(cName), value, ty))
      } else {
        out.append(.decl(cName, ty, value))
      }
    }
    return out
  }

  private func declare(
    _ name: String,
    cName: String,
    ty: Ty,
    mutable: Bool,
    owned: Bool,
    _ node: some SyntaxProtocol
  ) throws {
    let depth = scopes.count - 1
    if scopes[depth].vars[name] != nil {
      throw error("invalid redeclaration of '\(name)'", node)
    }
    scopes[depth].vars[name] = Local(cName: cName, ty: ty, mutable: mutable)
    if owned {
      scopes[depth].owned.append((cName: cName, ty: ty))
    }
  }

  // MARK: - Statements

  private func lowerBlock(_ items: CodeBlockItemListSyntax) throws -> [Stmt] {
    scopes.append(Scope())
    var out: [Stmt] = []
    for item in items {
      switch item.item {
      case .decl(let decl): out += try lowerDecl(decl)
      case .stmt(let stmt): out += try lowerStmt(stmt)
      case .expr(let expr): out += try lowerExprStmt(expr)
      }
    }
    let scope = scopes.removeLast()
    // A block that ends in a jump has already released what the jump leaves.
    if !endsInJump(out) {
      out += releases(of: scope)
    }
    return out
  }

  private func endsInJump(_ stmts: [Stmt]) -> Bool {
    switch stmts.last {
    case .ret, .brk, .cont: return true
    default: return false
    }
  }

  /// Returns `v` from the current function, releasing owned locals first.
  private func returnValue(_ v: Expr, _ want: Ty) -> [Stmt] {
    let drops = releasesForReturn()
    if drops.isEmpty { return [.ret(v)] }
    // Evaluate the value before releasing locals, which may release it.
    let tmp = "r\(nextID())"
    return [.decl(tmp, want, v)] + drops + [.ret(Expr(kind: .local(tmp), ty: want))]
  }

  private func lowerStmt(_ stmt: StmtSyntax) throws -> [Stmt] {
    if let ret = stmt.as(ReturnStmtSyntax.self) {
      if initializingSelf {
        throw error("'return' in an initializer is not supported yet", ret)
      }
      guard let want = returnType else {
        throw error("'return' is not supported at top level in M2", ret)
      }
      if let value = ret.expression {
        if want == .void {
          throw error("unexpected non-void return value in void function", value)
        }
        let v = try own(coerce(lowerExpr(value, expected: want), to: want, value))
        return returnValue(v, want)
      }
      if want != .void {
        throw error("non-void function should return a value", ret)
      }
      return releasesForReturn() + [.ret(nil)]
    }
    if let loop = stmt.as(WhileStmtSyntax.self) {
      if loop.conditions.count == 1, let first = loop.conditions.first,
         case .optionalBinding(let binding) = first.condition {
        return try lowerWhileLet(binding, loop)
      }
      let cond = try lowerCondition(loop.conditions, loop)
      loops.append((scopes.count, false))
      defer { loops.removeLast() }
      return [.whiles(cond, try lowerBlock(loop.body.statements))]
    }
    if let loop = stmt.as(ForStmtSyntax.self) {
      return try lowerForIn(loop)
    }
    if let g = stmt.as(GuardStmtSyntax.self) {
      return try lowerGuard(g)
    }
    if stmt.is(BreakStmtSyntax.self) {
      guard let target = loops.last else {
        throw error("'break' is only allowed inside a loop or switch", stmt)
      }
      if target.isSwitch {
        throw error("'break' inside a switch is not supported yet", stmt)
      }
      return loopExitReleases(from: target.depth) + [.brk]
    }
    if stmt.is(ContinueStmtSyntax.self) {
      guard let target = loops.last(where: { !$0.isSwitch }) else {
        throw error("'continue' is only allowed inside a loop", stmt)
      }
      return loopExitReleases(from: target.depth) + [.cont]
    }
    if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
      return try lowerExprStmt(exprStmt.expression)
    }
    throw error("this statement is not supported in M2", stmt)
  }

  private func lowerExprStmt(_ expr: ExprSyntax) throws -> [Stmt] {
    if let ifExpr = expr.as(IfExprSyntax.self) {
      return try lowerIf(ifExpr)
    }
    if let sw = expr.as(SwitchExprSyntax.self) {
      return try lowerSwitch(sw)
    }
    if let infix = expr.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) {
      let (target, ty, mutable) = try lowerTarget(infix.leftOperand)
      if !mutable {
        throw error("cannot assign to value: '\(infix.leftOperand.trimmedDescription)' is a 'let' constant", infix.leftOperand)
      }
      let value = try own(coerce(lowerExpr(infix.rightOperand, expected: ty), to: ty, infix.rightOperand))
      return [.assign(target, value, ty)]
    }
    let v = try lowerExpr(expr)
    if v.ty == .nilLiteral {
      throw error("'nil' requires a contextual type", expr)
    }
    if v.owned && v.ty.isClassLike {
      // Nothing keeps the temporary alive, so drop it after the statement.
      let tmp = "t\(nextID())"
      return [.decl(tmp, v.ty, v), .release(tmp, v.ty)]
    }
    return [.expr(v)]
  }

  private func lowerIf(_ node: IfExprSyntax) throws -> [Stmt] {
    let conds = Array(node.conditions)
    guard !conds.isEmpty else {
      throw error("a condition is required in M2", node)
    }
    var otherwise: [Stmt] = []
    if let elseBody = node.elseBody {
      switch elseBody {
      case .codeBlock(let block):
        otherwise = try lowerBlock(block.statements)
      case .ifExpr(let nested):
        otherwise = try lowerIf(nested)
      }
    }
    return try lowerIfChain(conds, 0, node.body, otherwise, node)
  }

  /// Lowers the conditions of an `if` from `index` on, nesting one test per
  /// condition. A failed test runs `otherwise`; the body runs when all pass.
  private func lowerIfChain(
    _ conds: [ConditionElementSyntax],
    _ index: Int,
    _ body: CodeBlockSyntax,
    _ otherwise: [Stmt],
    _ node: some SyntaxProtocol
  ) throws -> [Stmt] {
    if index == conds.count {
      return try lowerBlock(body.statements)
    }
    switch conds[index].condition {
    case .expression(let expr):
      let cond = try lowerBoolExpr(expr)
      let then = try lowerIfChain(conds, index + 1, body, otherwise, node)
      return [.ifs(cond, then, otherwise)]

    case .optionalBinding(let binding):
      guard let id = binding.pattern.as(IdentifierPatternSyntax.self), let initializer = binding.initializer?.value else {
        throw error("unsupported conditional binding", binding)
      }
      var prelude: [Stmt] = []
      var opt = try lowerExpr(initializer)
      guard case .optional(let inner) = opt.ty else {
        throw error("initializer for conditional binding must have Optional type, not '\(opt.ty.swiftName)'", initializer)
      }
      if opt.owned && opt.ty.isClassLike {
        throw error("binding a temporary class value is not supported yet", initializer)
      }
      if opt.owned {
        // The test and the binding both read the value, so evaluate it once.
        let tmp = "t\(nextID())"
        prelude.append(.decl(tmp, opt.ty, opt))
        opt = Expr(kind: .local(tmp), ty: opt.ty)
      }
      let cond = Expr(kind: .isSome(opt), ty: .bool)
      scopes.append(Scope())
      let name = id.identifier.text
      let cName = "l\(nextID())_" + name
      try declare(name, cName: cName, ty: inner, mutable: false, owned: inner.isClassLike, binding)
      let inside = try lowerIfChain(conds, index + 1, body, otherwise, node)
      let bound = own(Expr(kind: .unwrap(opt), ty: inner))
      let then = [Stmt.decl(cName, inner, bound)] + inside + releases(of: scopes.removeLast())
      return prelude + [.ifs(cond, then, otherwise)]

    default:
      throw error("this condition is not supported in M2", node)
    }
  }

  /// Releases the owned locals of every scope a break or continue leaves.
  private func loopExitReleases(from depth: Int) -> [Stmt] {
    var out: [Stmt] = []
    for scope in scopes[depth...].reversed() {
      out += releases(of: scope)
    }
    return out
  }

  /// `for i in a..<b` and `for i in a...b` over Int, lowered to a counting loop.
  /// The counter advances before the body, so `continue` needs no extra step.
  private func lowerForIn(_ loop: ForStmtSyntax) throws -> [Stmt] {
    if loop.whereClause != nil {
      throw error("a where clause in for-in is not supported yet", loop)
    }
    if loop.sequence.as(InfixOperatorExprSyntax.self) == nil {
      return try lowerForInArray(loop)
    }
    guard let range = loop.sequence.as(InfixOperatorExprSyntax.self),
          let op = range.operator.as(BinaryOperatorExprSyntax.self),
          op.operator.text == "..<" || op.operator.text == "..." else {
      throw error("for-in is supported only over Int ranges (a..<b and a...b) in M2", loop.sequence)
    }
    let lo = try lowerExpr(range.leftOperand)
    let hi = try lowerExpr(range.rightOperand)
    guard lo.ty == .int, hi.ty == .int else {
      throw error("range bounds must be Int, not '\(lo.ty.swiftName)' and '\(hi.ty.swiftName)'", range)
    }
    let inclusive = op.operator.text == "..."
    let cur = "t\(nextID())"
    let end = "t\(nextID())"
    let curRef = Expr(kind: .local(cur), ty: .int)
    let prelude: [Stmt] = [.decl(cur, .int, lo), .decl(end, .int, hi)]
    let cond = Expr(kind: .binary(inclusive ? "<=" : "<", curRef, Expr(kind: .local(end), ty: .int)), ty: .bool)

    loops.append((scopes.count, false))
    defer { loops.removeLast() }
    scopes.append(Scope())
    var iteration: [Stmt] = []
    if let id = loop.pattern.as(IdentifierPatternSyntax.self) {
      let name = id.identifier.text
      let cName = "l\(nextID())_" + name
      try declare(name, cName: cName, ty: .int, mutable: false, owned: false, loop.pattern)
      iteration.append(.decl(cName, .int, curRef))
    } else if !loop.pattern.is(WildcardPatternSyntax.self) {
      throw error("only a name or _ is supported in for-in in M2", loop.pattern)
    }
    let one = Expr(kind: .int(1), ty: .int)
    iteration.append(.assign(.local(cur), Expr(kind: .binary("+", curRef, one), ty: .int), .int))
    iteration += try lowerBlock(loop.body.statements)
    scopes.removeLast()
    return prelude + [.whiles(cond, iteration)]
  }

  /// `for x in array`: a counting loop over a copy of the array, which the loop owns.
  private func lowerForInArray(_ loop: ForStmtSyntax) throws -> [Stmt] {
    let seq = try lowerExpr(loop.sequence)
    guard case .array(let elem) = seq.ty else {
      throw error("for-in is supported over Int ranges and arrays in M2, not '\(seq.ty.swiftName)'", loop.sequence)
    }
    let arrName = "t\(nextID())"
    let cur = "t\(nextID())"
    let arrRef = Expr(kind: .local(arrName), ty: seq.ty)
    let curRef = Expr(kind: .local(cur), ty: .int)

    // The temporary scope owns the copy until the loop ends, including on return.
    let prelude: [Stmt] = [.decl(arrName, seq.ty, own(seq)), .decl(cur, .int, Expr(kind: .int(0), ty: .int))]
    scopes.append(Scope())
    scopes[scopes.count - 1].owned.append((cName: arrName, ty: seq.ty))
    let cond = Expr(kind: .binary("<", curRef, Expr(kind: .arrayCount(arrRef), ty: .int)), ty: .bool)

    loops.append((scopes.count, false))
    defer { loops.removeLast() }
    scopes.append(Scope())
    var iteration: [Stmt] = []
    if let id = loop.pattern.as(IdentifierPatternSyntax.self) {
      let name = id.identifier.text
      let cName = "l\(nextID())_" + name
      try declare(name, cName: cName, ty: elem, mutable: false, owned: false, loop.pattern)
      iteration.append(.decl(cName, elem, Expr(kind: .index(arrRef, curRef), ty: elem)))
    } else if !loop.pattern.is(WildcardPatternSyntax.self) {
      throw error("only a name or _ is supported in for-in in M2", loop.pattern)
    }
    iteration.append(.assign(.local(cur), Expr(kind: .binary("+", curRef, Expr(kind: .int(1), ty: .int)), ty: .int), .int))
    iteration += try lowerBlock(loop.body.statements)
    scopes.removeLast()
    let drop = releases(of: scopes.removeLast())
    return prelude + [.whiles(cond, iteration)] + drop
  }

  /// `[a, b, c]`. The element type comes from the context, or from the first element.
  private func lowerArrayLiteral(_ lit: ArrayExprSyntax, _ expected: Ty?) throws -> Expr {
    var elemTy: Ty? = nil
    if case .array(let e)? = expected { elemTy = e }
    var values: [Expr] = []
    for item in lit.elements {
      let v = try lowerExpr(item.expression, expected: elemTy)
      if elemTy == nil { elemTy = v.ty }
      // The array owns each element, so a place element is retained.
      values.append(own(try coerce(v, to: elemTy!, item.expression)))
    }
    guard let elem = elemTy else {
      throw error("an empty array literal needs a type, such as [Int]", lit)
    }
    let ty = try arrayOf(elem, lit)
    return Expr(kind: .arrayLit(ty, values), ty: ty, owned: true)
  }

  /// The single index of a subscript, as an Int.
  private func indexArgument(_ sub: SubscriptCallExprSyntax) throws -> Expr {
    let args = Array(sub.arguments)
    guard args.count == 1, args[0].label == nil else {
      throw error("an array subscript takes one index", sub)
    }
    let idx = try lowerExpr(args[0].expression, expected: .int)
    guard idx.ty == .int else {
      throw error("an array index must be Int, not '\(idx.ty.swiftName)'", args[0].expression)
    }
    return idx
  }

  /// `guard` runs its body when a condition fails, and that body must leave the
  /// enclosing scope. Bindings it makes stay in scope for the rest of the block.
  private func lowerGuard(_ g: GuardStmtSyntax) throws -> [Stmt] {
    var out: [Stmt] = []
    for condition in g.conditions {
      // Lowered where the earlier bindings are in scope, since the else body may use them.
      let elseBody = try lowerBlock(g.body.statements)
      if !exits(elseBody) {
        throw error("the body of a guard must leave the enclosing scope", g.body)
      }
      switch condition.condition {
      case .expression(let expr):
        let test = try lowerBoolExpr(expr)
        out.append(.ifs(Expr(kind: .prefix("!", test), ty: .bool), elseBody, []))
      case .optionalBinding(let binding):
        guard let id = binding.pattern.as(IdentifierPatternSyntax.self), let initializer = binding.initializer?.value else {
          throw error("unsupported conditional binding", binding)
        }
        var opt = try lowerExpr(initializer)
        guard case .optional(let inner) = opt.ty else {
          throw error("initializer for conditional binding must have Optional type, not '\(opt.ty.swiftName)'", initializer)
        }
        if opt.owned && opt.ty.isClassLike {
          throw error("binding a temporary class value is not supported yet", initializer)
        }
        if opt.owned {
          let tmp = "t\(nextID())"
          out.append(.decl(tmp, opt.ty, opt))
          opt = Expr(kind: .local(tmp), ty: opt.ty)
        }
        let isNone = Expr(kind: .prefix("!", Expr(kind: .isSome(opt), ty: .bool)), ty: .bool)
        out.append(.ifs(isNone, elseBody, []))
        let name = id.identifier.text
        let cName = "l\(nextID())_" + name
        try declare(name, cName: cName, ty: inner, mutable: false, owned: inner.isClassLike, binding)
        out.append(.decl(cName, inner, own(Expr(kind: .unwrap(opt), ty: inner))))
      default:
        throw error("this condition is not supported in M2", condition)
      }
    }
    return out
  }

  /// True when a block cannot fall through: it ends in a return, break or continue.
  private func exits(_ stmts: [Stmt]) -> Bool {
    stmts.contains { stmt in
      switch stmt {
      case .ret, .brk, .cont: return true
      case .ifs(_, let then, let otherwise): return exits(then) && exits(otherwise)
      default: return false
      }
    }
  }

  private func lowerWhileLet(_ binding: OptionalBindingConditionSyntax, _ loop: WhileStmtSyntax) throws -> [Stmt] {
    guard let id = binding.pattern.as(IdentifierPatternSyntax.self), let initializer = binding.initializer?.value else {
      throw error("unsupported conditional binding", binding)
    }
    let opt = try lowerExpr(initializer)
    guard case .optional(let inner) = opt.ty else {
      throw error("initializer for conditional binding must have Optional type, not '\(opt.ty.swiftName)'", initializer)
    }
    if opt.owned && opt.ty.isClassLike {
      throw error("binding a temporary class value is not supported yet", initializer)
    }

    let tmp = "t\(nextID())"
    let tmpRef = Expr(kind: .local(tmp), ty: opt.ty)
    loops.append((scopes.count, false))
    defer { loops.removeLast() }
    scopes.append(Scope())
    let name = id.identifier.text
    let cName = "l\(nextID())_" + name
    try declare(name, cName: cName, ty: inner, mutable: false, owned: inner.isClassLike, binding)
    let body = try lowerBlock(loop.body.statements)
    let bound = own(Expr(kind: .unwrap(tmpRef), ty: inner))
    let isNil = Expr(kind: .prefix("!", Expr(kind: .isSome(tmpRef), ty: .bool)), ty: .bool)
    let iteration: [Stmt] =
      [.decl(tmp, opt.ty, opt), .ifs(isNil, [.brk], []), .decl(cName, inner, bound)]
      + body
      + releases(of: scopes.removeLast())
    return [.whiles(Expr(kind: .bool(true), ty: .bool), iteration)]
  }

  /// `switch` over an enum. Each case tests the tag and binds payload values.
  /// Cases are lowered to a chain of tests; every case must be covered unless
  /// there is a `default`.
  private func lowerSwitch(_ node: SwitchExprSyntax) throws -> [Stmt] {
    let subject = try lowerExpr(node.subject)
    var enumInfo: EnumInfo? = nil
    switch subject.ty {
    case .enumeration(let info): enumInfo = info
    case .int, .bool: break
    default:
      throw error("switch is supported over enums, Int and Bool in M2, not '\(subject.ty.swiftName)'", node.subject)
    }
    let tmp = "t\(nextID())"
    // A temporary subject owns its references, so the switch scope releases it after
    // the switch (and on any return or break out of an arm). A place is only copied.
    scopes.append(Scope())
    if subject.owned && subject.ty.isClassLike {
      scopes[scopes.count - 1].owned.append((cName: tmp, ty: subject.ty))
    }
    let prelude: [Stmt] = [.decl(tmp, subject.ty, subject)]
    let subj = Expr(kind: .local(tmp), ty: subject.ty)

    loops.append((scopes.count - 1, true))
    defer { loops.removeLast() }

    var coveredTags = Set<Int>()
    var coveredBools = Set<Bool>()
    var arms: [(cond: Expr, body: [Stmt])] = []
    var defaultBody: [Stmt]? = nil
    for item in node.cases {
      guard case .switchCase(let sc) = item else {
        throw error("conditional compilation in switch is not supported", item)
      }
      switch sc.label {
      case .default:
        defaultBody = try lowerBlock(sc.statements)
      case .case(let label):
        var conds: [Expr] = []
        var payload: EnumCase? = nil
        var bindings: [String?] = []
        for caseItem in label.caseItems {
          if let info = enumInfo {
            let (c, names) = try enumPattern(caseItem.pattern, info)
            if coveredTags.contains(c.tag) {
              throw error("case '\(c.name)' is already handled by a previous case", caseItem)
            }
            coveredTags.insert(c.tag)
            conds.append(Expr(kind: .isCase(subj, c.tag), ty: .bool))
            if label.caseItems.count == 1 {
              payload = c
              bindings = names
            } else if names.contains(where: { $0 != nil }) {
              throw error("bindings are not supported in a case with several patterns yet", caseItem)
            }
          } else {
            conds.append(try literalCondition(caseItem.pattern, subj, &coveredBools))
          }
        }
        guard let first = conds.first else {
          throw error("a case needs a pattern", label)
        }
        let cond = conds.dropFirst().reduce(first) { Expr(kind: .logical("||", $0, $1), ty: .bool) }

        scopes.append(Scope())
        var decls: [Stmt] = []
        if let c = payload {
          for (index, name) in bindings.enumerated() {
            guard let name else { continue }
            let field = c.payload[index]
            let cName = "l\(nextID())_" + name
            try declare(name, cName: cName, ty: field.ty, mutable: false, owned: false, label)
            decls.append(.decl(cName, field.ty, Expr(kind: .field(subj, field.cName), ty: field.ty)))
          }
        }
        let body = try lowerBlock(sc.statements)
        scopes.removeLast()
        arms.append((cond, decls + body))
      }
    }

    if defaultBody == nil {
      if let info = enumInfo, coveredTags.count < info.cases.count {
        throw error("switch must be exhaustive", node)
      }
      if enumInfo == nil && subject.ty == .int {
        throw error("switch over Int must have a default case", node)
      }
      if subject.ty == .bool && coveredBools.count < 2 {
        throw error("switch over Bool must cover both true and false, or have a default", node)
      }
    }
    // With no default, the last case needs no test once every case is covered.
    var tail: [Stmt] = defaultBody ?? []
    if defaultBody == nil, let last = arms.popLast() {
      tail = last.body
    }
    for arm in arms.reversed() {
      tail = [.ifs(arm.cond, arm.body, tail)]
    }
    return prelude + tail + releases(of: scopes.removeLast())
  }

  /// A case pattern over Int or Bool: a literal, or a range of Ints.
  private func literalCondition(_ pattern: PatternSyntax, _ subj: Expr, _ coveredBools: inout Set<Bool>) throws -> Expr {
    guard let exprPattern = pattern.as(ExpressionPatternSyntax.self) else {
      throw error("this pattern is not supported in M2", pattern)
    }
    let expr = exprPattern.expression
    if let range = expr.as(InfixOperatorExprSyntax.self),
       let op = range.operator.as(BinaryOperatorExprSyntax.self),
       op.operator.text == "..<" || op.operator.text == "..." {
      guard subj.ty == .int else { throw error("ranges in a case pattern need an Int subject", expr) }
      let lo = try lowerExpr(range.leftOperand)
      let hi = try lowerExpr(range.rightOperand)
      guard lo.ty == .int, hi.ty == .int else { throw error("range bounds must be Int", expr) }
      let lower = Expr(kind: .binary("<=", lo, subj), ty: .bool)
      let upper = Expr(kind: .binary(op.operator.text == "..." ? "<=" : "<", subj, hi), ty: .bool)
      return Expr(kind: .logical("&&", lower, upper), ty: .bool)
    }
    let value = try lowerExpr(expr)
    guard value.ty == subj.ty else {
      throw mismatch(expected: subj.ty, actual: value.ty, expr)
    }
    if case .bool(let b) = value.kind {
      coveredBools.insert(b)
    }
    return Expr(kind: .binary("==", subj, value), ty: .bool)
  }

  /// Reads a `.case(let a, _)` pattern. Returns the case and one binding name per
  /// payload value (nil for `_`).
  private func enumPattern(_ pattern: PatternSyntax, _ info: EnumInfo) throws -> (EnumCase, [String?]) {
    guard let exprPattern = pattern.as(ExpressionPatternSyntax.self) else {
      throw error("this pattern is not supported in M2", pattern)
    }
    let expr = exprPattern.expression
    var caseName: String
    var args: [LabeledExprSyntax] = []
    if let call = expr.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
      caseName = member.declName.baseName.text
      args = Array(call.arguments)
    } else if let member = expr.as(MemberAccessExprSyntax.self) {
      caseName = member.declName.baseName.text
    } else {
      throw error("only enum case patterns are supported in M2", expr)
    }
    guard let c = info.cases.first(where: { $0.name == caseName }) else {
      throw error("type '\(info.name)' has no member '\(caseName)'", expr)
    }
    if args.count != c.payload.count {
      throw error("enum case '\(caseName)' has \(c.payload.count) associated values; \(args.count) patterns given", expr)
    }
    var names: [String?] = []
    for arg in args {
      // `_` parses as a discard expression inside a case pattern.
      if arg.expression.is(DiscardAssignmentExprSyntax.self) {
        names.append(nil)
        continue
      }
      guard let pe = arg.expression.as(PatternExprSyntax.self) else {
        throw error("only bindings and '_' are supported in case patterns in M2", arg)
      }
      if pe.pattern.is(WildcardPatternSyntax.self) {
        names.append(nil)
      } else if let value = pe.pattern.as(ValueBindingPatternSyntax.self),
                let id = value.pattern.as(IdentifierPatternSyntax.self) {
        names.append(id.identifier.text)
      } else {
        throw error("only simple bindings are supported in case patterns in M2", pe)
      }
    }
    return (c, names)
  }

  private func lowerCondition(_ list: ConditionElementListSyntax, _ node: some SyntaxProtocol) throws -> Expr {
    guard list.count == 1, let first = list.first, case .expression(let expr) = first.condition else {
      throw error("only a single boolean condition is supported in M2", node)
    }
    return try lowerBoolExpr(expr)
  }

  private func lowerBoolExpr(_ expr: ExprSyntax) throws -> Expr {
    let v = try lowerExpr(expr)
    guard v.ty == .bool else {
      throw error("condition must be of type 'Bool', but is of type '\(v.ty.swiftName)'", expr)
    }
    return v
  }

  /// Returns the target of an assignment, its type, and whether it may be assigned.
  private func lowerTarget(_ expr: ExprSyntax) throws -> (LValue, Ty, Bool) {
    if let sub = expr.as(SubscriptCallExprSyntax.self) {
      let (baseTarget, baseTy, baseMutable) = try lowerTarget(sub.calledExpression)
      guard case .array(let elem) = baseTy else {
        throw error("subscripts are supported on arrays only in M2", sub)
      }
      guard baseMutable else {
        throw error("cannot assign through a let array", sub)
      }
      return (.index(baseTarget, try indexArgument(sub), baseTy), elem, true)
    }
    if let ref = expr.as(DeclReferenceExprSyntax.self) {
      let name = ref.baseName.text
      if let local = lookup(name) {
        return (.local(local.cName), local.ty, local.mutable)
      }
      // A bare property name inside an initializer or deinitializer means self.name.
      if let member = implicitSelfMember(name, ref) {
        guard member.field.mutable || initializingSelf else {
          throw error("cannot assign to 'let' property '\(name)'", ref)
        }
        return (.field(.local("self"), member.field.cName, arrow: member.base.ty.isClass), member.field.ty, true)
      }
      throw error("cannot find '\(name)' in scope", ref)
    }
    if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
      let (baseTarget, baseTy, baseMutable) = try lowerTarget(base)
      let field = try fieldOf(baseTy, member.declName.baseName.text, member)
      if baseTy.isClass {
        // Assigning through a class reference does not need the reference itself to be `var`.
        guard field.mutable || isSelfInInitializer(base) else {
          throw error("cannot assign to 'let' property '\(field.name)'", member)
        }
        return (.field(baseTarget, field.cName, arrow: true), field.ty, true)
      }
      guard baseMutable else {
        throw error("cannot assign to property '\(field.name)': '\(base.trimmedDescription)' is a 'let' constant", member)
      }
      guard field.mutable || isSelfInInitializer(base) else {
        throw error("cannot assign to 'let' property '\(field.name)'", member)
      }
      return (.field(baseTarget, field.cName, arrow: false), field.ty, true)
    }
    throw error("expression is not assignable", expr)
  }

  // MARK: - Expressions

  /// `expected` is the type the context wants, when it is known. It is used for
  /// closures and for implicit enum cases such as `.empty`.
  private func lowerExpr(_ expr: ExprSyntax, expected: Ty? = nil) throws -> Expr {
    if let lit = expr.as(IntegerLiteralExprSyntax.self) {
      let digits = lit.literal.text.filter { $0 != "_" }
      guard let value = Int64(digits) else {
        throw error("integer literal is out of range or not supported in M2", lit)
      }
      return Expr(kind: .int(value), ty: .int)
    }
    if let lit = expr.as(ArrayExprSyntax.self) {
      return try lowerArrayLiteral(lit, expected)
    }
    if let sub = expr.as(SubscriptCallExprSyntax.self) {
      let base = try lowerExpr(sub.calledExpression)
      guard case .array(let elem) = base.ty else {
        throw error("subscripts are supported on arrays only in M2, not on '\(base.ty.swiftName)'", sub)
      }
      let idx = try indexArgument(sub)
      // A temporary array is freed once the element is read, so an element that is
      // class-like is returned owned (retained before the array is freed).
      return Expr(kind: .index(base, idx), ty: elem, owned: base.owned && elem.isClassLike)
    }
    if let lit = expr.as(FloatLiteralExprSyntax.self) {
      let digits = lit.literal.text.filter { $0 != "_" }
      guard let value = Double(digits) else {
        throw error("floating-point literal is not supported", lit)
      }
      return Expr(kind: .double(value), ty: .double)
    }
    if let lit = expr.as(BooleanLiteralExprSyntax.self) {
      return Expr(kind: .bool(lit.literal.tokenKind == .keyword(.true)), ty: .bool)
    }
    if expr.as(NilLiteralExprSyntax.self) != nil {
      return Expr(kind: .nilValue, ty: .nilLiteral)
    }
    if let ref = expr.as(DeclReferenceExprSyntax.self) {
      let name = ref.baseName.text
      if let local = lookup(name) {
        return Expr(kind: .local(local.cName), ty: local.ty)
      }
      if let f = funcs[name] {
        return Expr(kind: .funcRef(f), ty: functionType(f))
      }
      if genericFuncs[name] != nil {
        return try genericFunctionValue(name, explicit: [], expected: expected, ref)
      }
      if let member = implicitSelfMember(name, ref) {
        return Expr(kind: .field(member.base, member.field.cName), ty: member.field.ty)
      }
      throw error("cannot find '\(name)' in scope", ref)
    }
    if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil {
      // Swift parses `(x)` as a one-element tuple expression.
      return try lowerExpr(only.expression, expected: expected)
    }
    if let closure = expr.as(ClosureExprSyntax.self) {
      return try lowerClosure(closure, expected)
    }
    if let member = expr.as(MemberAccessExprSyntax.self) {
      if let info = try enumForMember(member, expected) {
        return try enumCase(info, member.declName.baseName.text, nil, member)
      }
      if let e = try genericEnumCase(member, nil, expected) { return e }
      guard let base = member.base else {
        throw error("implicit member access is not supported in M2", member)
      }
      let b = try lowerExpr(base)
      if b.ty.isArray {
        guard member.declName.baseName.text == "count" else {
          throw error("arrays have no member '\(member.declName.baseName.text)' in M2", member)
        }
        return Expr(kind: .arrayCount(b), ty: .int)
      }
      if b.ty.isClassLike && b.owned {
        throw error("member access on a temporary class value is not supported yet", member)
      }
      if case .optional = b.ty {
        throw error("value of optional type '\(b.ty.swiftName)' must be unwrapped to refer to a member", member)
      }
      let field = try fieldOf(b.ty, member.declName.baseName.text, member)
      return Expr(kind: .field(b, field.cName), ty: field.ty)
    }
    if let force = expr.as(ForceUnwrapExprSyntax.self) {
      let v = try lowerExpr(force.expression)
      guard case .optional(let inner) = v.ty else {
        throw error("cannot force unwrap value of non-optional type '\(v.ty.swiftName)'", force)
      }
      if v.owned && v.ty.isClassLike {
        throw error("force unwrap of a temporary class value is not supported yet", force)
      }
      return Expr(kind: .unwrap(v), ty: inner)
    }
    if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
      let v = try lowerExpr(prefix.expression)
      let op = prefix.operator.text
      switch (op, v.ty) {
      case ("-", .int):
        return Expr(kind: .prefix("-", v), ty: .int)
      case ("-", .double):
        return Expr(kind: .prefix("-", v), ty: .double)
      case ("!", .bool):
        return Expr(kind: .prefix("!", v), ty: .bool)
      default:
        throw error("unary operator '\(op)' cannot be applied to an operand of type '\(v.ty.swiftName)'", prefix)
      }
    }
    if let infix = expr.as(InfixOperatorExprSyntax.self) {
      guard let op = infix.operator.as(BinaryOperatorExprSyntax.self) else {
        throw error("assignment is not an expression in M2", infix)
      }
      let l = try lowerExpr(infix.leftOperand)
      let r = try lowerExpr(infix.rightOperand)
      return try binary(op.operator.text, l, r, infix)
    }
    if let call = expr.as(FunctionCallExprSyntax.self) {
      return try lowerCall(call, expected: expected)
    }
    if let spec = expr.as(GenericSpecializationExprSyntax.self) {
      return try specializedValue(spec, expected)
    }
    throw error("this expression is not supported in M2", expr)
  }

  private func binary(_ op: String, _ l: Expr, _ r: Expr, _ node: some SyntaxProtocol) throws -> Expr {
    if l.ty == .nilLiteral || r.ty == .nilLiteral {
      guard op == "==" || op == "!=" else {
        throw error("binary operator '\(op)' cannot be applied to operands of type '\(l.ty.swiftName)' and '\(r.ty.swiftName)'", node)
      }
      let other = l.ty == .nilLiteral ? r : l
      guard other.ty != .nilLiteral else {
        throw error("comparing two nil literals is not supported", node)
      }
      guard case .optional = other.ty else {
        throw error("binary operator '\(op)' cannot be applied to operands of type '\(l.ty.swiftName)' and '\(r.ty.swiftName)'", node)
      }
      if other.owned && other.ty.isClassLike {
        throw error("comparing a temporary class value with nil is not supported yet", node)
      }
      let test = Expr(kind: .isSome(other), ty: .bool)
      return op == "==" ? Expr(kind: .prefix("!", test), ty: .bool) : test
    }

    func badOperands() -> CompileError {
      error("binary operator '\(op)' cannot be applied to operands of type '\(l.ty.swiftName)' and '\(r.ty.swiftName)'", node)
    }
    switch op {
    case "+", "-", "*", "/", "%":
      if l.ty == .double && r.ty == .double && op != "%" {
        return Expr(kind: .binary(op, l, r), ty: .double)
      }
      guard l.ty == .int && r.ty == .int else { throw badOperands() }
      return Expr(kind: .binary(op, l, r), ty: .int)
    case "<", "<=", ">", ">=":
      guard (l.ty == .int && r.ty == .int) || (l.ty == .double && r.ty == .double) else { throw badOperands() }
      return Expr(kind: .binary(op, l, r), ty: .bool)
    case "==", "!=":
      guard l.ty == r.ty && (l.ty == .int || l.ty == .bool || l.ty == .double) else { throw badOperands() }
      return Expr(kind: .binary(op, l, r), ty: .bool)
    case "&&", "||":
      guard l.ty == .bool && r.ty == .bool else { throw badOperands() }
      return Expr(kind: .logical(op, l, r), ty: .bool)
    default:
      throw error("operator '\(op)' is not supported in M2", node)
    }
  }

  private func lowerCall(_ call: FunctionCallExprSyntax, expected: Ty?) throws -> Expr {
    guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else {
      throw error("trailing closures are not supported in M2", call)
    }
    let callee = call.calledExpression

    if let spec = callee.as(GenericSpecializationExprSyntax.self) {
      guard let ref = spec.expression.as(DeclReferenceExprSyntax.self), lookup(ref.baseName.text) == nil else {
        throw error("this call is not supported in M3", call)
      }
      let explicit = try genericArguments(spec.genericArgumentClause)
      return try lowerGenericCall(ref.baseName.text, explicit: explicit, call, expected, ref)
    }

    if let ref = callee.as(DeclReferenceExprSyntax.self) {
      let name = ref.baseName.text
      if let local = lookup(name) {
        guard case .function(let params, let ret) = local.ty else {
          throw error("cannot call value of non-function type '\(local.ty.swiftName)'", ref)
        }
        return try callValue(Expr(kind: .local(local.cName), ty: local.ty), params, ret, call)
      }
      if isGenericName(name) {
        return try lowerGenericCall(name, explicit: [], call, expected, ref)
      }
      if let selfLocal = lookup("self"), let method = methodOf(selfLocal.ty, name) {
        return try callMethod(method, Expr(kind: .local(selfLocal.cName), ty: selfLocal.ty), name, call)
      }
      if let f = funcs[name] {
        let args = try lowerArgs(call, f.params.map { $0.ty })
        let values = try matchArguments(name, f.params.map { ($0.label, $0.ty) }, args, call)
        return Expr(kind: .call(f, values), ty: f.ret, owned: true)
      }
      if name == "Double" && lookup(name) == nil && structs[name] == nil && classes[name] == nil {
        let args = try lowerArgs(call, [.int])
        guard args.count == 1, args[0].label == nil, args[0].value.ty == .int else {
          throw error("Double(...) converts one Int in M2", call)
        }
        return Expr(kind: .convert(args[0].value), ty: .double)
      }
      if name == "print" {
        let args = try lowerArgs(call, nil)
        guard args.count == 1, args[0].label == nil else {
          throw error("print takes exactly one unlabeled argument in M2", call)
        }
        let v = args[0].value
        var printable = v.ty == .int || v.ty == .bool || v.ty == .double
        if case .array(let elem) = v.ty, elem == .int || elem == .bool || elem == .double {
          printable = true
        }
        guard printable else {
          throw error("print is supported for Int, Double, Bool and arrays of them in M2", args[0].node.expression)
        }
        return Expr(kind: .print(v), ty: .void)
      }
      if let s = structs[name] {
        // A struct initializer returns a fresh value, which the caller owns.
        if !s.initializers.isEmpty {
          return try callInitializer(name, s.initializers, .structure(s), owned: true, call)
        }
        let args = try lowerArgs(call, s.fields.map { $0.ty })
        let values = try matchArguments(name, s.fields.map { (Optional($0.name), $0.ty) }, args, call)
        return Expr(kind: .structLit(s, values), ty: .structure(s), owned: s.isClassLike)
      }
      if let c = classes[name] {
        if !c.initializers.isEmpty {
          return try callInitializer(name, c.initializers, .cls(name), owned: true, call)
        }
        let args = try lowerArgs(call, c.fields.map { $0.ty })
        let values = try matchArguments(name, c.fields.map { (Optional($0.name), $0.ty) }, args, call)
        return Expr(kind: .construct(c, values), ty: .cls(name), owned: true)
      }
      throw error("cannot find '\(name)' in scope", ref)
    }

    if let member = callee.as(MemberAccessExprSyntax.self), let info = try enumForMember(member, expected) {
      return try enumCase(info, member.declName.baseName.text, call, member)
    }
    if let member = callee.as(MemberAccessExprSyntax.self), let e = try genericEnumCase(member, call, expected) {
      return e
    }

    if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base,
       member.declName.baseName.text == "append",
       let (target, targetTy, mutable) = try? lowerTarget(base),
       case .array(let elem) = targetTy {
      guard mutable else {
        throw error("cannot append to a let array", member)
      }
      let args = try lowerArgs(call, [elem])
      let values = try matchArguments("append", [(nil, elem)], args, call)
      return Expr(kind: .arrayAppend(target, values[0]), ty: .void)
    }
    if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base {
      let receiver = try lowerExpr(base)
      let name = member.declName.baseName.text
      if let method = methodOf(receiver.ty, name) {
        return try callMethod(method, receiver, name, call)
      }
      let field = try fieldOf(receiver.ty, name, member)
      guard case .function(let params, let ret) = field.ty else {
        throw error("value of type '\(receiver.ty.swiftName)' has no method '\(name)'", member)
      }
      return try callValue(Expr(kind: .field(receiver, field.cName), ty: field.ty), params, ret, call)
    }

    let value = try lowerExpr(callee)
    guard case .function(let params, let ret) = value.ty else {
      throw error("cannot call value of non-function type '\(value.ty.swiftName)'", callee)
    }
    return try callValue(value, params, ret, call)
  }

  private func callValue(_ callee: Expr, _ params: [Ty], _ ret: Ty, _ call: FunctionCallExprSyntax) throws -> Expr {
    let args = try lowerArgs(call, params)
    let values = try matchArguments("function value", params.map { (nil, $0) }, args, call)
    return Expr(kind: .callPtr(callee, values), ty: ret, owned: true)
  }

  /// Lowers call arguments, passing each parameter's type as the expected type
  /// so that closures and implicit enum cases can be written inline.
  private func lowerArgs(_ call: FunctionCallExprSyntax, _ types: [Ty]?) throws -> [ArgInput] {
    var out: [ArgInput] = []
    for (i, arg) in call.arguments.enumerated() {
      var expected: Ty? = nil
      if let types, i < types.count { expected = types[i] }
      out.append(ArgInput(label: arg.label?.text, value: try lowerExpr(arg.expression, expected: expected), node: arg))
    }
    return out
  }

  private func matchArguments(
    _ name: String,
    _ params: [(String?, Ty)],
    _ args: [ArgInput],
    _ call: FunctionCallExprSyntax
  ) throws -> [Expr] {
    guard args.count == params.count else {
      throw error("wrong number of arguments to '\(name)': expected \(params.count), got \(args.count)", call)
    }
    var values: [Expr] = []
    for (arg, param) in zip(args, params) {
      let (label, ty) = param
      guard arg.label == label else {
        throw error("incorrect argument label (have '\(arg.label ?? "_"):', expected '\(label ?? "_"):')", arg.node)
      }
      values.append(try own(coerce(arg.value, to: ty, arg.node.expression)))
    }
    return values
  }

  /// The enum named by `member`'s base (`Shape.circle`) or implied by the expected
  /// type (`.circle`), if the member refers to an enum case.
  private func enumForMember(_ member: MemberAccessExprSyntax, _ expected: Ty?) throws -> EnumInfo? {
    if let base = member.base {
      if let ref = base.as(DeclReferenceExprSyntax.self), lookup(ref.baseName.text) == nil,
         let info = enums[ref.baseName.text] {
        return info
      }
      return nil
    }
    if case .enumeration(let info)? = expected {
      return info
    }
    return nil
  }

  private func enumCase(_ info: EnumInfo, _ caseName: String, _ call: FunctionCallExprSyntax?, _ node: some SyntaxProtocol) throws -> Expr {
    guard let c = info.cases.first(where: { $0.name == caseName }) else {
      throw error("type '\(info.name)' has no member '\(caseName)'", node)
    }
    let payloadTypes = c.payload.map { $0.ty }
    var values: [Expr] = []
    if let call {
      let args = try lowerArgs(call, payloadTypes)
      values = try matchArguments(caseName, payloadTypes.map { (nil, $0) }, args, call)
    } else if !c.payload.isEmpty {
      throw error("enum case '\(caseName)' requires \(c.payload.count) associated values", node)
    }
    // The payload values were made owned above, so a value with class payloads is owned too.
    return Expr(kind: .enumCase(info, c.tag, values), ty: .enumeration(info), owned: info.holdsRef)
  }

  // MARK: - Closures

  /// Lowers a closure with no captures to a generated function. The closure's
  /// type comes from the context, so it must be known.
  private func lowerClosure(_ closure: ClosureExprSyntax, _ expected: Ty?) throws -> Expr {
    guard let expected, case .function(let paramTypes, let ret) = expected else {
      throw error("a closure needs a contextual function type in M2", closure)
    }
    let id = nextID()
    var names: [String] = []
    if let clause = closure.signature?.parameterClause {
      switch clause {
      case .simpleInput(let list):
        names = list.map { $0.name.text }
      case .parameterClause(let pc):
        names = pc.parameters.map { ($0.secondName ?? $0.firstName).text }
      }
    } else {
      names = (0..<paramTypes.count).map { "$\($0)" }
    }
    if names.count != paramTypes.count {
      throw error("closure takes \(names.count) parameters but the context expects \(paramTypes.count)", closure)
    }
    let params = names.enumerated().map { index, name in
      Param(label: nil, name: name, cName: "p\(id)_\(index)", ty: paramTypes[index])
    }
    let info = FuncInfo(name: "closure", cName: "cl\(id)", params: params, ret: ret)

    // Lower the body with only the closure's own parameters in scope.
    let savedScopes = scopes
    let savedReturn = returnType
    defer {
      scopes = savedScopes
      returnType = savedReturn
    }
    var root = Scope()
    for p in params {
      root.vars[p.name] = Local(cName: p.cName, ty: p.ty, mutable: false)
      if p.ty.isClassLike { root.owned.append((cName: p.cName, ty: p.ty)) }
    }
    scopes = [root, Scope()]
    returnType = ret

    var stmts: [Stmt] = []
    let items = Array(closure.statements)
    for (index, item) in items.enumerated() {
      if index == items.count - 1, ret != .void, case .expr(let e) = item.item {
        // A single expression in a closure with a result is its return value.
        let v = try own(coerce(lowerExpr(e, expected: ret), to: ret, e))
        stmts += returnValue(v, ret)
        continue
      }
      switch item.item {
      case .decl(let decl): stmts += try lowerDecl(decl)
      case .stmt(let stmt): stmts += try lowerStmt(stmt)
      case .expr(let expr): stmts += try lowerExprStmt(expr)
      }
    }
    stmts += releases(of: scopes[1])
    stmts += releases(of: scopes[0])
    if ret != .void && !alwaysReturns(stmts) {
      throw error("missing return in closure expected to return '\(ret.swiftName)'", closure)
    }
    info.body = stmts
    allFuncs.append(info)
    return Expr(kind: .funcRef(info), ty: expected)
  }

  // MARK: - Ownership and conversions

  /// Turns a place into an owned value by retaining it. Owned values pass through.
  private func own(_ e: Expr) -> Expr {
    guard e.ty.isClassLike && !e.owned else { return e }
    return Expr(kind: .retain(e), ty: e.ty, owned: true)
  }

  /// Converts `v` to `ty` when Swift allows it implicitly: T to T?, and nil to any Optional.
  private func coerce(_ v: Expr, to ty: Ty, _ node: some SyntaxProtocol) throws -> Expr {
    if v.ty == ty { return v }
    if v.ty == .nilLiteral, case .optional = ty {
      return Expr(kind: .nilValue, ty: ty)
    }
    if case .optional(let inner) = ty, inner == v.ty {
      return Expr(kind: .wrap(v), ty: ty, owned: v.owned)
    }
    throw mismatch(expected: ty, actual: v.ty, node)
  }

  private func fieldOf(_ ty: Ty, _ name: String, _ node: some SyntaxProtocol) throws -> Field {
    let fields: [Field]
    switch ty {
    case .structure(let info): fields = info.fields
    case .cls(let n): fields = classes[n]?.fields ?? []
    default: throw error("value of type '\(ty.swiftName)' has no member '\(name)'", node)
    }
    guard let field = fields.first(where: { $0.name == name }) else {
      throw error("value of type '\(ty.swiftName)' has no member '\(name)'", node)
    }
    return field
  }

  private func functionType(_ f: FuncInfo) -> Ty {
    let ty = Ty.function(f.params.map { $0.ty }, f.ret)
    registerFunctionType(ty)
    return ty
  }

  private func registerFunctionType(_ ty: Ty) {
    if !functionTypes.contains(ty) { functionTypes.append(ty) }
  }

  private func resolveType(_ type: TypeSyntax) throws -> Ty {
    if let arrayType = type.as(ArrayTypeSyntax.self) {
      return try arrayOf(try resolveType(arrayType.element), type)
    }
    if let opt = type.as(OptionalTypeSyntax.self) {
      let inner = try resolveType(opt.wrappedType)
      if case .optional = inner {
        throw error("nested optional types are not supported yet", type)
      }
      let ty = Ty.optional(inner)
      if !optionals.contains(ty) { optionals.append(ty) }
      return ty
    }
    if let fn = type.as(FunctionTypeSyntax.self) {
      let params = try fn.parameters.map { try resolveType($0.type) }
      let ret = try resolveType(fn.returnClause.type)
      let ty = Ty.function(params, ret)
      registerFunctionType(ty)
      return ty
    }
    guard let id = type.as(IdentifierTypeSyntax.self) else {
      throw error("this type is not supported in M2", type)
    }
    let name = id.name.text
    if let bound = typeEnv[name], id.genericArgumentClause == nil { return bound }
    if let clause = id.genericArgumentClause {
      return try instanceType(name, try genericArguments(clause), type)
    }
    switch name {
    case "Int": return .int
    case "Double": return .double
    case "Bool": return .bool
    case "Void": return .void
    default:
      if let info = structs[name] { return .structure(info) }
      if classes[name] != nil { return .cls(name) }
      if let info = enums[name] { return .enumeration(info) }
      if isGenericName(name) {
        throw error("reference to generic type '\(name)' requires arguments in <...>", type)
      }
      throw error("cannot find type '\(name)' in scope", type)
    }
  }

  // MARK: - Generics

  /// Type parameter names of a generic declaration. Constraints and `where`
  /// clauses are not supported in M3.
  private func genericNames(_ clause: GenericParameterClauseSyntax, _ whereClause: GenericWhereClauseSyntax?) throws -> [String] {
    if let whereClause {
      throw error("where clauses on generic declarations are not supported yet", whereClause)
    }
    var names: [String] = []
    for p in clause.parameters {
      if p.inheritedType != nil {
        throw error("generic parameter constraints are not supported yet", p)
      }
      let name = p.name.text
      if names.contains(name) { throw error("invalid redeclaration of '\(name)'", p) }
      names.append(name)
    }
    return names
  }

  private func genericArguments(_ clause: GenericArgumentClauseSyntax) throws -> [Ty] {
    try clause.arguments.map { (arg: GenericArgumentSyntax) throws -> Ty in
      guard case .type(let t) = arg.argument else {
        throw error("value generic arguments are not supported yet", arg)
      }
      return try resolveType(t)
    }
  }

  private func isGenericName(_ name: String) -> Bool {
    genericFuncs[name] != nil || genericStructs[name] != nil || genericClasses[name] != nil || genericEnums[name] != nil
  }

  /// The type `base<args>`, instantiating it when it is first used.
  private func instanceType(_ base: String, _ args: [Ty], _ node: some SyntaxProtocol) throws -> Ty {
    if genericStructs[base] != nil {
      let info = try instantiateStruct(base, args, node)
      return .structure(info)
    }
    if genericClasses[base] != nil {
      let info = try instantiateClass(base, args, node)
      return .cls(info.name)
    }
    if genericEnums[base] != nil {
      let info = try instantiateEnum(base, args, node)
      return .enumeration(info)
    }
    if structs[base] != nil || classes[base] != nil || enums[base] != nil {
      throw error("type '\(base)' is not generic", node)
    }
    throw error("cannot find type '\(base)' in scope", node)
  }

  /// The name of an instance, as Swift would write it, such as `Box<Int>`.
  private func instanceName(_ base: String, _ args: [Ty]) -> String {
    base + "<" + args.map { $0.swiftName }.joined(separator: ", ") + ">"
  }

  private func checkArity(_ base: String, _ names: [String], _ args: [Ty], _ node: some SyntaxProtocol) throws {
    if args.count > names.count {
      throw error("generic '\(base)' specialized with too many type parameters (got \(args.count), but expected \(names.count))", node)
    }
    if args.count < names.count {
      throw error("generic '\(base)' specialized with too few type parameters (got \(args.count), but expected \(names.count))", node)
    }
    if args.contains(.void) {
      throw error("'Void' as a generic argument is not supported yet", node)
    }
  }

  private func envFor(_ names: [String], _ args: [Ty]) -> [String: Ty] {
    Dictionary(uniqueKeysWithValues: zip(names, args))
  }

  /// Runs `body` with `env` as the type parameter bindings. An instance can be
  /// lowered while another body is being lowered, so the caller's scopes and
  /// return type are saved and restored.
  private func inEnv<T>(_ env: [String: Ty], _ body: () throws -> T) rethrows -> T {
    let saved = (typeEnv, scopes, returnType)
    typeEnv = env
    defer { (typeEnv, scopes, returnType) = saved }
    return try body()
  }

  /// Bounds the depth of nested instantiation, so that a generic that keeps
  /// instantiating itself with a larger argument is rejected instead of looping.
  private func nested<T>(_ node: some SyntaxProtocol, _ body: () throws -> T) throws -> T {
    instantiationDepth += 1
    defer { instantiationDepth -= 1 }
    if instantiationDepth > 64 {
      throw error("generic instantiation is nested too deeply", node)
    }
    return try body()
  }

  private func recordInstance(_ name: String, _ base: String, _ args: [Ty], _ decl: some SyntaxProtocol) {
    instanceArgs[name] = (base, args)
    instanceNodes[name] = Syntax(decl)
  }

  private func instantiateStruct(_ base: String, _ args: [Ty], _ node: some SyntaxProtocol) throws -> StructInfo {
    let name = instanceName(base, args)
    if let existing = structs[name] { return existing }
    guard let g = genericStructs[base] else { throw error("cannot find type '\(base)' in scope", node) }
    try checkArity(base, g.names, args, node)
    return try nested(node) {
      let info = StructInfo(name: name)
      structs[name] = info  // registered before the fields, so they can refer to it
      recordInstance(name, base, args, g.decl)
      instStructs.append(info)
      let env = envFor(g.names, args)
      let members = try inEnv(env) { try lowerMembers(g.decl.memberBlock, isClass: false) }
      info.fields = members.fields
      info.initializers = try declareInitializers(members.initializers, owner: .structure(info), env: env, name: name)
      info.methods = try declareMethods(members.methods, owner: .structure(info), env: env, name: name)
      return info
    }
  }

  private func instantiateClass(_ base: String, _ args: [Ty], _ node: some SyntaxProtocol) throws -> ClassInfo {
    let name = instanceName(base, args)
    if let existing = classes[name] { return existing }
    guard let g = genericClasses[base] else { throw error("cannot find type '\(base)' in scope", node) }
    try checkArity(base, g.names, args, node)
    return try nested(node) {
      let info = ClassInfo(name: name)
      classes[name] = info
      recordInstance(name, base, args, g.decl)
      instClasses.append(info)
      let env = envFor(g.names, args)
      let members = try inEnv(env) { try lowerMembers(g.decl.memberBlock, isClass: true) }
      info.fields = members.fields
      info.initializers = try declareInitializers(members.initializers, owner: .cls(name), env: env, name: name)
      info.methods = try declareMethods(members.methods, owner: .cls(name), env: env, name: name)
      if let d = members.deinitializer {
        let f = FuncInfo(
          name: "deinit_" + name,
          cName: "deinit_" + cIdent(name),
          params: [Param(label: nil, name: "self", cName: "self", ty: .cls(name))],
          ret: .void,
          ownsParams: false
        )
        info.deinitializer = f
        allFuncs.append(f)
        pendingDeinits.append(PendingDeinit(info: f, decl: d, env: env))
      }
      return info
    }
  }

  private func instantiateEnum(_ base: String, _ args: [Ty], _ node: some SyntaxProtocol) throws -> EnumInfo {
    let name = instanceName(base, args)
    if let existing = enums[name] { return existing }
    guard let g = genericEnums[base] else { throw error("cannot find type '\(base)' in scope", node) }
    try checkArity(base, g.names, args, node)
    return try nested(node) {
      let info = EnumInfo(name: name)
      enums[name] = info
      recordInstance(name, base, args, g.decl)
      instEnums.append(info)
      let env = envFor(g.names, args)
      info.cases = try inEnv(env) { try lowerEnumCases(g.decl) }
      return info
    }
  }

  /// Lowers one instance of a generic function. The instance is cached before its
  /// body is lowered, so a recursive call finds it.
  private func instantiateFunction(_ base: String, _ args: [Ty], _ node: some SyntaxProtocol) throws -> FuncInfo {
    let name = instanceName(base, args)
    if let existing = instanceFuncs[name] { return existing }
    guard let g = genericFuncs[base] else { throw error("cannot find '\(base)' in scope", node) }
    try checkArity(base, g.names, args, node)
    return try nested(node) {
      let env = envFor(g.names, args)
      let info = try inEnv(env) { try declareFunction(g.decl, instanceName: name) }
      instanceFuncs[name] = info
      allFuncs.append(info)
      guard let body = g.decl.body else { throw error("function without a body", g.decl) }
      info.body = try inEnv(env) { try lowerBody(info, body, g.decl) }
      return info
    }
  }

  private func lowerPendingDeinits() throws {
    while !pendingDeinits.isEmpty || !pendingInits.isEmpty || !pendingMethods.isEmpty {
      if !pendingInits.isEmpty {
        try lowerInitializer(pendingInits.removeFirst())
        continue
      }
      if !pendingMethods.isEmpty {
        let m = pendingMethods.removeFirst()
        guard let body = m.decl.body else { throw error("method without a body", m.decl) }
        m.info.body = try inEnv(m.env) { try lowerBody(m.info, body, m.decl) }
        continue
      }
      let p = pendingDeinits.removeFirst()
      guard let body = p.decl.body else { throw error("deinit without a body", p.decl) }
      p.info.body = try inEnv(p.env) { try lowerBody(p.info, body, p.decl) }
    }
  }

  /// Declares the methods of a type. The receiver is passed as the first parameter.
  private func declareMethods(
    _ decls: [FunctionDeclSyntax],
    owner: Ty,
    env: [String: Ty],
    name: String
  ) throws -> [String: FuncInfo] {
    var out: [String: FuncInfo] = [:]
    for d in decls {
      let method = d.name.text
      if out[method] != nil {
        throw error("overloaded methods are not supported yet", d)
      }
      let params = try inEnv(env) { try declareParams(d.signature.parameterClause.parameters) }
      let ret: Ty = try inEnv(env) {
        if let clause = d.signature.returnClause { return try resolveType(clause.type) }
        return .void
      }
      let receiver = Param(label: nil, name: "self", cName: "self", ty: owner)
      let info = FuncInfo(name: name + "." + method, cName: "m_\(cIdent(name))_\(method)", params: [receiver] + params, ret: ret)
      allFuncs.append(info)
      pendingMethods.append(PendingMethod(info: info, decl: d, env: env))
      out[method] = info
    }
    return out
  }

  /// Declares each explicit initializer as a function that returns the new value.
  private func declareInitializers(
    _ decls: [InitializerDeclSyntax],
    owner: Ty,
    env: [String: Ty],
    name: String
  ) throws -> [FuncInfo] {
    var out: [FuncInfo] = []
    for (index, d) in decls.enumerated() {
      let params = try inEnv(env) { try declareParams(d.signature.parameterClause.parameters) }
      let info = FuncInfo(name: "init_" + name, cName: "init_\(cIdent(name))_\(index)", params: params, ret: owner)
      allFuncs.append(info)
      pendingInits.append(PendingInit(info: info, decl: d, env: env, owner: owner))
      out.append(info)
    }
    return out
  }

  /// Lowers an initializer. The new object is allocated first, so `self` is
  /// usable from the first statement, and it is returned after the body runs.
  private func lowerInitializer(_ p: PendingInit) throws {
    guard let body = p.decl.body else { throw error("initializer without a body", p.decl) }
    let selfTy = p.owner
    let savedFlag = initializingSelf
    initializingSelf = true
    defer { initializingSelf = savedFlag }
    p.info.body = try inEnv(p.env) {
      var root = Scope()
      for param in p.info.params {
        root.vars[param.name] = Local(cName: param.cName, ty: param.ty, mutable: false)
        if param.ty.isClassLike {
          root.owned.append((cName: param.cName, ty: param.ty))
        }
      }
      root.vars["self"] = Local(cName: "self", ty: selfTy, mutable: true)
      scopes = [root]
      returnType = nil
      let allocation: Stmt
      switch selfTy {
      case .cls(let n):
        guard let c = classes[n] else { throw error("cannot find type '\(n)' in scope", p.decl) }
        allocation = .decl("self", selfTy, Expr(kind: .allocObject(c), ty: selfTy, owned: true))
      case .structure:
        allocation = .decl("self", selfTy, Expr(kind: .zeroValue, ty: selfTy))
      default:
        throw error("initializers are only supported on classes and structs", p.decl)
      }
      var stmts = [allocation]
      stmts += try lowerBlock(body.statements)
      stmts += releases(of: root)
      stmts.append(.ret(Expr(kind: .local("self"), ty: selfTy)))
      return stmts
    }
  }

  private func methodOf(_ ty: Ty, _ name: String) -> FuncInfo? {
    switch ty {
    case .structure(let info): return info.methods[name]
    case .cls(let n): return classes[n]?.methods[name]
    default: return nil
    }
  }

  /// Calls a method with `receiver` as self. The receiver is borrowed, so a
  /// temporary class value would leak; it is rejected for now.
  private func callMethod(_ method: FuncInfo, _ receiver: Expr, _ name: String, _ call: FunctionCallExprSyntax) throws -> Expr {
    if receiver.owned && receiver.ty.isClassLike {
      throw error("calling a method on a temporary class value is not supported yet", call)
    }
    let params = Array(method.params.dropFirst())
    let args = try lowerArgs(call, params.map { $0.ty })
    let values = try matchArguments(name, params.map { ($0.label, $0.ty) }, args, call)
    return Expr(kind: .call(method, [receiver] + values), ty: method.ret, owned: true)
  }

  /// Calls the initializer whose argument labels match the call.
  private func callInitializer(
    _ name: String,
    _ candidates: [FuncInfo],
    _ ty: Ty,
    owned: Bool,
    _ call: FunctionCallExprSyntax
  ) throws -> Expr {
    let labels = call.arguments.map { $0.label?.text }
    guard let chosen = candidates.first(where: { $0.params.map { $0.label } == labels }) else {
      throw error("no initializer of '\(name)' takes these argument labels", call)
    }
    let args = try lowerArgs(call, chosen.params.map { $0.ty })
    let values = try matchArguments(name, chosen.params.map { ($0.label, $0.ty) }, args, call)
    return Expr(kind: .call(chosen, values), ty: ty, owned: owned)
  }

  /// Binds the parameters in `names` by matching a parameter type, as written, against
  /// the type of an argument. Matched shapes are `T`, `T?`, `(...) -> T` and `Box<T>`.
  private func unify(
    _ type: TypeSyntax,
    _ actual: Ty,
    _ names: [String],
    _ bindings: inout [String: Ty],
    _ node: some SyntaxProtocol
  ) throws {
    if actual == .nilLiteral { return }
    if let id = type.as(IdentifierTypeSyntax.self) {
      let name = id.name.text
      if id.genericArgumentClause == nil, names.contains(name) {
        if let bound = bindings[name] {
          if bound != actual {
            throw error("conflicting types for generic parameter '\(name)' ('\(bound.swiftName)' vs. '\(actual.swiftName)')", node)
          }
        } else {
          bindings[name] = actual
        }
      } else if let clause = id.genericArgumentClause, let origin = instanceOrigin(actual), origin.base == name {
        for (argSyntax, argType) in zip(clause.arguments, origin.args) {
          guard case .type(let t) = argSyntax.argument else { continue }
          try unify(t, argType, names, &bindings, node)
        }
      }
      return
    }
    if let opt = type.as(OptionalTypeSyntax.self) {
      if case .optional(let inner) = actual {
        try unify(opt.wrappedType, inner, names, &bindings, node)
      }
      return
    }
    if let fn = type.as(FunctionTypeSyntax.self), case .function(let params, let ret) = actual, params.count == fn.parameters.count {
      for (p, t) in zip(fn.parameters, params) {
        try unify(p.type, t, names, &bindings, node)
      }
      try unify(fn.returnClause.type, ret, names, &bindings, node)
    }
  }

  private func instanceOrigin(_ ty: Ty) -> (base: String, args: [Ty])? {
    switch ty {
    case .structure(let info): return instanceArgs[info.name]
    case .cls(let n): return instanceArgs[n]
    case .enumeration(let info): return instanceArgs[info.name]
    default: return nil
    }
  }

  /// The stored properties of a generic struct or class, as memberwise initializer parameters.
  private func storedParams(_ block: MemberBlockSyntax) -> [GenericParam] {
    var out: [GenericParam] = []
    for member in block.members {
      guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
      for binding in v.bindings {
        guard let id = binding.pattern.as(IdentifierPatternSyntax.self), let annotation = binding.typeAnnotation else { continue }
        out.append(GenericParam(label: id.identifier.text, type: annotation.type))
      }
    }
    return out
  }

  /// The explicit initializer of a generic type whose argument labels match the call.
  private func genericInitializer(_ block: MemberBlockSyntax, _ call: FunctionCallExprSyntax) -> InitializerDeclSyntax? {
    let labels = call.arguments.map { $0.label?.text }
    for member in block.members {
      guard let i = member.decl.as(InitializerDeclSyntax.self) else { continue }
      if initializerLabels(i) == labels { return i }
    }
    return nil
  }

  private func initializerLabels(_ i: InitializerDeclSyntax) -> [String?] {
    i.signature.parameterClause.parameters.map { p -> String? in
      let first = p.firstName.text
      return first == "_" ? nil : first
    }
  }

  private func initializerParams(_ i: InitializerDeclSyntax) -> [GenericParam] {
    i.signature.parameterClause.parameters.map { p in
      let first = p.firstName.text
      return GenericParam(label: first == "_" ? nil : first, type: p.type)
    }
  }

  /// Calls the initializer of an instantiated type, with arguments already lowered.
  private func callInstanceInitializer(
    _ name: String,
    _ candidates: [FuncInfo],
    _ ty: Ty,
    owned: Bool,
    _ args: [ArgInput],
    _ call: FunctionCallExprSyntax
  ) throws -> Expr {
    let labels = args.map { $0.label }
    guard let chosen = candidates.first(where: { $0.params.map { $0.label } == labels }) else {
      throw error("no initializer of '\(name)' takes these argument labels", call)
    }
    let values = try matchArguments(name, chosen.params.map { ($0.label, $0.ty) }, args, call)
    return Expr(kind: .call(chosen, values), ty: ty, owned: owned)
  }

  /// The payload of a case of a generic enum, as parameters.
  private func casePayloadParams(_ decl: EnumDeclSyntax, _ caseName: String) -> [GenericParam]? {
    for member in decl.memberBlock.members {
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      for element in caseDecl.elements where element.name.text == caseName {
        guard let params = element.parameterClause?.parameters else { return [] }
        return params.map { GenericParam(label: nil, type: $0.type) }
      }
    }
    return nil
  }

  /// Arguments that need their parameter type to be lowered: closures and implicit
  /// members such as `.some(1)`.
  private func needsContext(_ e: ExprSyntax) -> Bool {
    if e.is(ClosureExprSyntax.self) { return true }
    if let member = e.as(MemberAccessExprSyntax.self) { return member.base == nil }
    if let call = e.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
      return member.base == nil
    }
    return false
  }

  /// Lowers the arguments of a call to a generic declaration and binds its type
  /// parameters `names`, from `explicit`, from the argument types, or from the
  /// expected result. Arguments that need a type are lowered last, once it is known.
  private func bindGeneric(
    _ names: [String],
    explicit: [Ty],
    params: [GenericParam],
    result: TypeSyntax?,
    expected: Ty?,
    _ call: FunctionCallExprSyntax
  ) throws -> (types: [Ty], args: [ArgInput]) {
    guard call.arguments.count == params.count else {
      throw error("wrong number of arguments: expected \(params.count), got \(call.arguments.count)", call)
    }
    var bindings: [String: Ty] = [:]
    for (name, ty) in zip(names, explicit) { bindings[name] = ty }
    let argNodes = Array(call.arguments)
    var inputs: [ArgInput?] = Array(repeating: nil, count: argNodes.count)
    var deferred: [Int] = []
    for (i, arg) in argNodes.enumerated() {
      if needsContext(arg.expression) {
        deferred.append(i)
        continue
      }
      let value = try lowerExpr(arg.expression)
      try unify(params[i].type, value.ty, names, &bindings, arg.expression)
      inputs[i] = ArgInput(label: arg.label?.text, value: value, node: arg)
    }
    if let result, let expected, names.contains(where: { bindings[$0] == nil }) {
      try unify(result, expected, names, &bindings, call)
    }
    for name in names where bindings[name] == nil {
      throw error("generic parameter '\(name)' could not be inferred", call)
    }
    for i in deferred {
      let ty = try inEnv(bindings) { try resolveType(params[i].type) }
      let value = try lowerExpr(argNodes[i].expression, expected: ty)
      inputs[i] = ArgInput(label: argNodes[i].label?.text, value: value, node: argNodes[i])
    }
    return (names.map { bindings[$0]! }, inputs.compactMap { $0 })
  }

  /// A call through a generic name: a generic function, or the memberwise
  /// initializer of a generic struct or class.
  private func lowerGenericCall(
    _ name: String,
    explicit: [Ty],
    _ call: FunctionCallExprSyntax,
    _ expected: Ty?,
    _ node: some SyntaxProtocol
  ) throws -> Expr {
    if let g = genericFuncs[name] {
      if !explicit.isEmpty { try checkArity(name, g.names, explicit, node) }
      let params = g.decl.signature.parameterClause.parameters.map { GenericParam(label: nil, type: $0.type) }
      let (types, args) = try bindGeneric(
        g.names, explicit: explicit, params: params, result: g.decl.signature.returnClause?.type, expected: expected, call)
      let f = try instantiateFunction(name, types, node)
      let values = try matchArguments(name, f.params.map { ($0.label, $0.ty) }, args, call)
      return Expr(kind: .call(f, values), ty: f.ret, owned: true)
    }
    if let g = genericStructs[name] {
      if let i = genericInitializer(g.decl.memberBlock, call) {
        let params = initializerParams(i)
        let (types, args) = try bindGeneric(g.names, explicit: explicit, params: params, result: nil, expected: nil, call)
        let s = try instantiateStruct(name, types, node)
        return try callInstanceInitializer(s.name, s.initializers, .structure(s), owned: true, args, call)
      }
      let (types, args) = try bindGeneric(g.names, explicit: explicit, params: storedParams(g.decl.memberBlock), result: nil, expected: nil, call)
      let s = try instantiateStruct(name, types, node)
      let values = try matchArguments(s.name, s.fields.map { (Optional($0.name), $0.ty) }, args, call)
      return Expr(kind: .structLit(s, values), ty: .structure(s), owned: s.isClassLike)
    }
    if let g = genericClasses[name] {
      if let i = genericInitializer(g.decl.memberBlock, call) {
        let params = initializerParams(i)
        let (types, args) = try bindGeneric(g.names, explicit: explicit, params: params, result: nil, expected: nil, call)
        let c = try instantiateClass(name, types, node)
        return try callInstanceInitializer(c.name, c.initializers, .cls(c.name), owned: true, args, call)
      }
      let (types, args) = try bindGeneric(g.names, explicit: explicit, params: storedParams(g.decl.memberBlock), result: nil, expected: nil, call)
      let c = try instantiateClass(name, types, node)
      let values = try matchArguments(c.name, c.fields.map { (Optional($0.name), $0.ty) }, args, call)
      return Expr(kind: .construct(c, values), ty: .cls(c.name), owned: true)
    }
    throw error("'\(name)' cannot be called in M3", node)
  }

  /// A generic function used as a value, with type arguments from `explicit` or
  /// from the expected function type.
  private func genericFunctionValue(_ name: String, explicit: [Ty], expected: Ty?, _ node: some SyntaxProtocol) throws -> Expr {
    guard let g = genericFuncs[name] else { throw error("cannot find '\(name)' in scope", node) }
    if !explicit.isEmpty { try checkArity(name, g.names, explicit, node) }
    var bindings: [String: Ty] = [:]
    for (n, t) in zip(g.names, explicit) { bindings[n] = t }
    let params = g.decl.signature.parameterClause.parameters
    if let expected, case .function(let paramTypes, let ret) = expected, paramTypes.count == params.count {
      for (p, t) in zip(params, paramTypes) {
        try unify(p.type, t, g.names, &bindings, node)
      }
      if let clause = g.decl.signature.returnClause {
        try unify(clause.type, ret, g.names, &bindings, node)
      }
    }
    for n in g.names where bindings[n] == nil {
      throw error("generic parameter '\(n)' could not be inferred", node)
    }
    let f = try instantiateFunction(name, g.names.map { bindings[$0]! }, node)
    return Expr(kind: .funcRef(f), ty: functionType(f))
  }

  /// `first<Int>` used as a value.
  private func specializedValue(_ spec: GenericSpecializationExprSyntax, _ expected: Ty?) throws -> Expr {
    guard let ref = spec.expression.as(DeclReferenceExprSyntax.self), genericFuncs[ref.baseName.text] != nil else {
      throw error("this generic expression is not supported in M3", spec)
    }
    let explicit = try genericArguments(spec.genericArgumentClause)
    return try genericFunctionValue(ref.baseName.text, explicit: explicit, expected: expected, spec)
  }

  /// `Maybe<Int>.some(3)`, `Maybe.some(3)` (arguments inferred from the expected
  /// type or the payload) and `Maybe<Int>.none`. Returns nil when `member` is not
  /// a case of a generic enum.
  private func genericEnumCase(_ member: MemberAccessExprSyntax, _ call: FunctionCallExprSyntax?, _ expected: Ty?) throws -> Expr? {
    guard let base = member.base else { return nil }
    let name: String
    var explicit: [Ty]? = nil
    if let spec = base.as(GenericSpecializationExprSyntax.self), let ref = spec.expression.as(DeclReferenceExprSyntax.self),
       genericEnums[ref.baseName.text] != nil {
      name = ref.baseName.text
      explicit = try genericArguments(spec.genericArgumentClause)
    } else if let ref = base.as(DeclReferenceExprSyntax.self), lookup(ref.baseName.text) == nil,
              genericEnums[ref.baseName.text] != nil {
      name = ref.baseName.text
    } else {
      return nil
    }
    guard let g = genericEnums[name] else { return nil }
    let caseName = member.declName.baseName.text
    if explicit == nil, case .enumeration(let info)? = expected, let origin = instanceOrigin(.enumeration(info)), origin.base == name {
      explicit = origin.args
    }
    guard let payload = casePayloadParams(g.decl, caseName) else {
      throw error("type '\(name)' has no member '\(caseName)'", member)
    }
    if let call {
      let (types, args) = try bindGeneric(g.names, explicit: explicit ?? [], params: payload, result: nil, expected: nil, call)
      let info = try instantiateEnum(name, types, member)
      guard let c = info.cases.first(where: { $0.name == caseName }) else {
        throw error("type '\(info.name)' has no member '\(caseName)'", member)
      }
      let values = try matchArguments(caseName, c.payload.map { (nil, $0.ty) }, args, call)
      return Expr(kind: .enumCase(info, c.tag, values), ty: .enumeration(info))
    }
    guard let explicit else {
      throw error("generic parameter '\(g.names[0])' could not be inferred", member)
    }
    let info = try instantiateEnum(name, explicit, member)
    return try enumCase(info, caseName, nil, member)
  }

  // MARK: - Scopes and releases

  /// The property `name` of the enclosing `self`, if there is one.
  private func implicitSelfMember(_ name: String, _ node: some SyntaxProtocol) -> (base: Expr, field: Field)? {
    guard let selfLocal = lookup("self"), let field = try? fieldOf(selfLocal.ty, name, node) else { return nil }
    return (Expr(kind: .local(selfLocal.cName), ty: selfLocal.ty), field)
  }

  private func isSelfInInitializer(_ base: ExprSyntax) -> Bool {
    guard initializingSelf, let ref = base.as(DeclReferenceExprSyntax.self) else { return false }
    return ref.baseName.text == "self"
  }

  private func lookup(_ name: String) -> Local? {
    for scope in scopes.reversed() {
      if let local = scope.vars[name] { return local }
    }
    return globalVars[name]
  }

  private func releases(of scope: Scope) -> [Stmt] {
    scope.owned.reversed().map { Stmt.release($0.cName, $0.ty) }
  }

  /// Releases for every owned local of the current function, innermost first.
  private func releasesForReturn() -> [Stmt] {
    scopes.reversed().flatMap { releases(of: $0) }
  }

  private func alwaysReturns(_ stmts: [Stmt]) -> Bool {
    stmts.contains { stmt in
      switch stmt {
      case .ret: return true
      case .ifs(_, let then, let otherwise): return alwaysReturns(then) && alwaysReturns(otherwise)
      default: return false
      }
    }
  }

  private func nextID() -> Int {
    counter += 1
    return counter
  }

  private func mismatch(expected: Ty, actual: Ty, _ node: some SyntaxProtocol) -> CompileError {
    error("cannot convert value of type '\(actual.swiftName)' to expected type '\(expected.swiftName)'", node)
  }

  private func error(_ message: String, _ node: some SyntaxProtocol) -> CompileError {
    let loc = node.startLocation(converter: converter)
    return CompileError(message: message, line: loc.line, column: loc.column)
  }
}
