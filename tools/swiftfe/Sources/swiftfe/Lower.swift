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

final class Lowerer {
  private let converter: SourceLocationConverter
  private var structs: [String: StructInfo] = [:]
  private var classes: [String: ClassInfo] = [:]
  private var enums: [String: EnumInfo] = [:]
  private var funcs: [String: FuncInfo] = [:]
  private var allFuncs: [FuncInfo] = []
  private var optionals: [Ty] = []
  private var functionTypes: [Ty] = []
  private var globals: [Global] = []
  private var scopes: [Scope] = []
  private var returnType: Ty? = nil
  private var counter = 0

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
        let info = StructInfo(name: name)
        structs[name] = info
        structDecls.append((s, info))
      } else if let c = decl.as(ClassDeclSyntax.self) {
        let name = c.name.text
        if c.inheritanceClause != nil {
          throw error("class inheritance is not supported yet", c)
        }
        try checkNewType(name, c)
        let info = ClassInfo(name: name)
        classes[name] = info
        classDecls.append((c, info))
      } else if let e = decl.as(EnumDeclSyntax.self) {
        let name = e.name.text
        if e.inheritanceClause != nil {
          throw error("enum inheritance and raw values are not supported yet", e)
        }
        try checkNewType(name, e)
        let info = EnumInfo(name: name)
        enums[name] = info
        enumDecls.append((e, info))
      }
    }

    // Pass 2: stored properties, enum payloads and deinitializers.
    var deinitDecls: [(DeinitializerDeclSyntax, ClassInfo)] = []
    for (decl, info) in structDecls {
      info.fields = try lowerMembers(decl.memberBlock, isClass: false).fields
    }
    for (decl, info) in classDecls {
      let members = try lowerMembers(decl.memberBlock, isClass: true)
      info.fields = members.fields
      if let d = members.deinitializer {
        deinitDecls.append((d, info))
      }
    }
    for (decl, info) in enumDecls {
      info.cases = try lowerEnumCases(decl)
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
      if funcs[name] != nil { throw error("invalid redeclaration of '\(name)'", f) }
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

    // Pass 4: bodies.
    for (decl, info) in funcDecls {
      guard let body = decl.body else { throw error("function without a body", decl) }
      info.body = try lowerBody(info, body, decl)
    }
    for (d, info) in deinitBodies {
      guard let body = d.body else { throw error("deinit without a body", d) }
      info.body = try lowerBody(info, body, d)
    }

    // Pass 5: top-level statements. Their variables are visible only here, and
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

    return Program(
      structs: structDecls.map { $0.1 },
      classes: classDecls.map { $0.1 },
      enums: enumDecls.map { $0.1 },
      funcs: allFuncs,
      globals: globals,
      main: main,
      optionals: optionals,
      functionTypes: functionTypes
    )
  }

  // MARK: - Declarations

  private func checkNewType(_ name: String, _ node: some SyntaxProtocol) throws {
    if structs[name] != nil || classes[name] != nil || enums[name] != nil {
      throw error("invalid redeclaration of '\(name)'", node)
    }
  }

  private func lowerMembers(
    _ block: MemberBlockSyntax,
    isClass: Bool
  ) throws -> (fields: [Field], deinitializer: DeinitializerDeclSyntax?) {
    var fields: [Field] = []
    var deinitializer: DeinitializerDeclSyntax? = nil
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
          if !isClass && ty.containsClass {
            throw error("structs with class-typed properties are not supported yet", binding)
          }
          fields.append(Field(name: name, cName: "m_" + name, ty: ty, mutable: mutable))
        }
      } else if isClass, let d = member.decl.as(DeinitializerDeclSyntax.self) {
        if deinitializer != nil { throw error("invalid redeclaration of 'deinit'", d) }
        deinitializer = d
      } else {
        throw error("this member is not supported in M2", member)
      }
    }
    if !isClass && fields.isEmpty {
      throw error("structs without stored properties are not supported yet", block)
    }
    return (fields, deinitializer)
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
            if ty.containsClass {
              throw error("enums with class-typed payloads are not supported yet", p)
            }
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

  private func valueName(_ ty: Ty) -> String? {
    switch ty {
    case .structure(let name), .enumeration(let name), .optional(.structure(let name)), .optional(.enumeration(let name)):
      return name
    default:
      return nil
    }
  }

  private func declareFunction(_ f: FunctionDeclSyntax) throws -> FuncInfo {
    let name = f.name.text
    var params: [Param] = []
    for p in f.signature.parameterClause.parameters {
      // `func f(_ x: Int)` has no label; `func f(x: Int)` uses x as both.
      let first = p.firstName.text
      let label: String? = first == "_" ? nil : first
      let internalName = p.secondName?.text ?? first
      let cName = "p\(nextID())_" + internalName
      params.append(Param(label: label, name: internalName, cName: cName, ty: try resolveType(p.type)))
    }
    let ret: Ty
    if let clause = f.signature.returnClause {
      ret = try resolveType(clause.type)
    } else {
      ret = .void
    }
    return FuncInfo(name: name, cName: "f_" + name, params: params, ret: ret)
  }

  private func lowerBody(_ info: FuncInfo, _ body: CodeBlockSyntax, _ node: some SyntaxProtocol) throws -> [Stmt] {
    var root = Scope()
    for p in info.params {
      root.vars[p.name] = Local(cName: p.cName, ty: p.ty, mutable: false)
      if info.ownsParams && p.ty.isClassLike {
        root.owned.append((cName: p.cName, ty: p.ty))
      }
    }
    scopes = [root]
    returnType = info.ret
    var stmts = try lowerBlock(body.statements)
    stmts += releases(of: scopes[0])
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
    out += releases(of: scopes.removeLast())
    return out
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
      return [.whiles(cond, try lowerBlock(loop.body.statements))]
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
    let list = node.conditions
    guard list.count == 1, let first = list.first else {
      throw error("only a single condition is supported in M2", node)
    }

    var prelude: [Stmt] = []
    let cond: Expr
    let then: [Stmt]
    if case .optionalBinding(let binding) = first.condition {
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
        // The condition and the binding both read the value, so evaluate it once.
        let tmp = "t\(nextID())"
        prelude.append(.decl(tmp, opt.ty, opt))
        opt = Expr(kind: .local(tmp), ty: opt.ty)
      }
      cond = Expr(kind: .isSome(opt), ty: .bool)
      scopes.append(Scope())
      let name = id.identifier.text
      let cName = "l\(nextID())_" + name
      try declare(name, cName: cName, ty: inner, mutable: false, owned: inner.isClassLike, binding)
      let body = try lowerBlock(node.body.statements)
      let bound = own(Expr(kind: .unwrap(opt), ty: inner))
      then = [.decl(cName, inner, bound)] + body + releases(of: scopes.removeLast())
    } else {
      cond = try lowerCondition(list, node)
      then = try lowerBlock(node.body.statements)
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
    return prelude + [.ifs(cond, then, otherwise)]
  }

  /// `while let x = opt { body }`. The optional is read again on every iteration:
  /// each iteration copies it into a temporary, breaks when it is nil, and binds
  /// the payload in a scope that is released like an `if let` binding.
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
    guard case .enumeration(let enumName) = subject.ty, let info = enums[enumName] else {
      throw error("switch is supported only over enums in M2, not '\(subject.ty.swiftName)'", node.subject)
    }
    let tmp = "t\(nextID())"
    let prelude: [Stmt] = [.decl(tmp, subject.ty, subject)]
    let subj = Expr(kind: .local(tmp), ty: subject.ty)

    var covered = Set<Int>()
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
        guard label.caseItems.count == 1, let caseItem = label.caseItems.first else {
          throw error("multiple patterns in one case are not supported yet", label)
        }
        let (c, bindings) = try enumPattern(caseItem.pattern, info)
        if covered.contains(c.tag) {
          throw error("case '\(c.name)' is already handled by a previous case", caseItem)
        }
        covered.insert(c.tag)

        scopes.append(Scope())
        var decls: [Stmt] = []
        for (index, name) in bindings.enumerated() {
          guard let name else { continue }
          let field = c.payload[index]
          let cName = "l\(nextID())_" + name
          try declare(name, cName: cName, ty: field.ty, mutable: false, owned: false, caseItem)
          decls.append(.decl(cName, field.ty, Expr(kind: .field(subj, field.cName), ty: field.ty)))
        }
        let body = try lowerBlock(sc.statements)
        scopes.removeLast()
        arms.append((Expr(kind: .isCase(subj, c.tag), ty: .bool), decls + body))
      }
    }

    if defaultBody == nil && covered.count < info.cases.count {
      throw error("switch must be exhaustive", node)
    }
    // With no `default`, the switch is exhaustive, so the last case needs no test.
    var tail: [Stmt] = defaultBody ?? []
    if defaultBody == nil, let last = arms.popLast() {
      tail = last.body
    }
    for arm in arms.reversed() {
      tail = [.ifs(arm.cond, arm.body, tail)]
    }
    return prelude + tail
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
    let v = try lowerExpr(expr)
    guard v.ty == .bool else {
      throw error("condition must be of type 'Bool', but is of type '\(v.ty.swiftName)'", expr)
    }
    return v
  }

  /// Returns the target of an assignment, its type, and whether it may be assigned.
  private func lowerTarget(_ expr: ExprSyntax) throws -> (LValue, Ty, Bool) {
    if let ref = expr.as(DeclReferenceExprSyntax.self) {
      let name = ref.baseName.text
      guard let local = lookup(name) else { throw error("cannot find '\(name)' in scope", ref) }
      return (.local(local.cName), local.ty, local.mutable)
    }
    if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
      let (baseTarget, baseTy, baseMutable) = try lowerTarget(base)
      let field = try fieldOf(baseTy, member.declName.baseName.text, member)
      if baseTy.isClass {
        // Assigning through a class reference does not need the reference itself to be `var`.
        guard field.mutable else { throw error("cannot assign to 'let' property '\(field.name)'", member) }
        return (.field(baseTarget, field.cName, arrow: true), field.ty, true)
      }
      guard baseMutable else {
        throw error("cannot assign to property '\(field.name)': '\(base.trimmedDescription)' is a 'let' constant", member)
      }
      guard field.mutable else { throw error("cannot assign to 'let' property '\(field.name)'", member) }
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
      guard let base = member.base else {
        throw error("implicit member access is not supported in M2", member)
      }
      let b = try lowerExpr(base)
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
      guard l.ty == .int && r.ty == .int else { throw badOperands() }
      return Expr(kind: .binary(op, l, r), ty: .int)
    case "<", "<=", ">", ">=":
      guard l.ty == .int && r.ty == .int else { throw badOperands() }
      return Expr(kind: .binary(op, l, r), ty: .bool)
    case "==", "!=":
      guard l.ty == r.ty && (l.ty == .int || l.ty == .bool) else { throw badOperands() }
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

    if let ref = callee.as(DeclReferenceExprSyntax.self) {
      let name = ref.baseName.text
      if let local = lookup(name) {
        guard case .function(let params, let ret) = local.ty else {
          throw error("cannot call value of non-function type '\(local.ty.swiftName)'", ref)
        }
        return try callValue(Expr(kind: .local(local.cName), ty: local.ty), params, ret, call)
      }
      if let f = funcs[name] {
        let args = try lowerArgs(call, f.params.map { $0.ty })
        let values = try matchArguments(name, f.params.map { ($0.label, $0.ty) }, args, call)
        return Expr(kind: .call(f, values), ty: f.ret, owned: true)
      }
      if name == "print" {
        let args = try lowerArgs(call, nil)
        guard args.count == 1, args[0].label == nil else {
          throw error("print takes exactly one unlabeled argument in M2", call)
        }
        let v = args[0].value
        guard v.ty == .int || v.ty == .bool else {
          throw error("print is supported for Int and Bool only in M2", args[0].node.expression)
        }
        return Expr(kind: .print(v), ty: .void)
      }
      if let s = structs[name] {
        let args = try lowerArgs(call, s.fields.map { $0.ty })
        let values = try matchArguments(name, s.fields.map { (Optional($0.name), $0.ty) }, args, call)
        return Expr(kind: .structLit(s, values), ty: .structure(name))
      }
      if let c = classes[name] {
        let args = try lowerArgs(call, c.fields.map { $0.ty })
        let values = try matchArguments(name, c.fields.map { (Optional($0.name), $0.ty) }, args, call)
        return Expr(kind: .construct(c, values), ty: .cls(name), owned: true)
      }
      throw error("cannot find '\(name)' in scope", ref)
    }

    if let member = callee.as(MemberAccessExprSyntax.self), let info = try enumForMember(member, expected) {
      return try enumCase(info, member.declName.baseName.text, call, member)
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
    if case .enumeration(let name)? = expected, let info = enums[name] {
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
    return Expr(kind: .enumCase(info, c.tag, values), ty: .enumeration(info.name))
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
    case .structure(let n): fields = structs[n]?.fields ?? []
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
    switch name {
    case "Int": return .int
    case "Bool": return .bool
    case "Void": return .void
    default:
      if structs[name] != nil { return .structure(name) }
      if classes[name] != nil { return .cls(name) }
      if enums[name] != nil { return .enumeration(name) }
      throw error("cannot find type '\(name)' in scope", type)
    }
  }

  // MARK: - Scopes and releases

  private func lookup(_ name: String) -> Local? {
    for scope in scopes.reversed() {
      if let local = scope.vars[name] { return local }
    }
    return nil
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
