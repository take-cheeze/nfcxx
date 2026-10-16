// Lowers the operator-folded swift-syntax tree into the typed IR.
//
// This is where names are resolved, types are checked, and reference counts
// are inserted. The first error stops compilation.
//
// Ownership rules (M2):
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
  private var funcs: [String: FuncInfo] = [:]
  private var allFuncs: [FuncInfo] = []
  private var optionals: [Ty] = []
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
      }
    }

    // Pass 2: stored properties and deinitializers.
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
    try checkRecursion(structDecls.map { $0.0 })

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
        if decl.is(FunctionDeclSyntax.self) || decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self) {
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
      funcs: allFuncs,
      main: main,
      optionals: optionals
    )
  }

  // MARK: - Declarations

  private func checkNewType(_ name: String, _ node: some SyntaxProtocol) throws {
    if structs[name] != nil || classes[name] != nil {
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

  /// Rejects a struct that contains itself by value, which Swift also rejects.
  /// Classes are references, so they may refer to themselves.
  private func checkRecursion(_ decls: [StructDeclSyntax]) throws {
    var nodes: [String: StructDeclSyntax] = [:]
    for d in decls { nodes[d.name.text] = d }
    var finished = Set<String>()

    func visit(_ name: String, _ active: [String]) throws {
      if finished.contains(name) { return }
      guard let info = structs[name], let node = nodes[name] else { return }
      if active.contains(name) {
        throw error("value type '\(name)' has infinite size", node)
      }
      for field in info.fields {
        if let child = valueStructName(field.ty) {
          try visit(child, active + [name])
        }
      }
      finished.insert(name)
    }

    for d in decls {
      try visit(d.name.text, [])
    }
  }

  private func valueStructName(_ ty: Ty) -> String? {
    switch ty {
    case .structure(let name), .optional(.structure(let name)): return name
    default: return nil
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
      var value = try lowerExpr(initializer)
      var ty = value.ty
      if let annotation = binding.typeAnnotation {
        ty = try resolveType(annotation.type)
        value = try coerce(value, to: ty, initializer)
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
      out.append(.decl(cName, ty, value))
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

  private func lowerStmt(_ stmt: StmtSyntax) throws -> [Stmt] {
    if let ret = stmt.as(ReturnStmtSyntax.self) {
      guard let want = returnType else {
        throw error("'return' is not supported at top level in M2", ret)
      }
      if let value = ret.expression {
        if want == .void {
          throw error("unexpected non-void return value in void function", value)
        }
        let v = try own(coerce(lowerExpr(value), to: want, value))
        let drops = releasesForReturn()
        if drops.isEmpty { return [.ret(v)] }
        // Evaluate the value before releasing locals, which may release it.
        let tmp = "r\(nextID())"
        return [.decl(tmp, want, v)] + drops + [.ret(Expr(kind: .local(tmp), ty: want))]
      }
      if want != .void {
        throw error("non-void function should return a value", ret)
      }
      return releasesForReturn() + [.ret(nil)]
    }
    if let loop = stmt.as(WhileStmtSyntax.self) {
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
    if let infix = expr.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) {
      let (target, ty, mutable) = try lowerTarget(infix.leftOperand)
      if !mutable {
        throw error("cannot assign to value: '\(infix.leftOperand.trimmedDescription)' is a 'let' constant", infix.leftOperand)
      }
      let value = try own(coerce(lowerExpr(infix.rightOperand), to: ty, infix.rightOperand))
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

  private func lowerExpr(_ expr: ExprSyntax) throws -> Expr {
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
      guard let local = lookup(name) else { throw error("cannot find '\(name)' in scope", ref) }
      return Expr(kind: .local(local.cName), ty: local.ty)
    }
    if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil {
      // Swift parses `(x)` as a one-element tuple expression.
      return try lowerExpr(only.expression)
    }
    if let member = expr.as(MemberAccessExprSyntax.self) {
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
      return try lowerCall(call)
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

  private func lowerCall(_ call: FunctionCallExprSyntax) throws -> Expr {
    guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else {
      throw error("trailing closures are not supported in M2", call)
    }
    guard let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else {
      throw error("only calls to named functions are supported in M2", call)
    }
    let name = callee.baseName.text

    var args: [ArgInput] = []
    for arg in call.arguments {
      args.append(ArgInput(label: arg.label?.text, value: try lowerExpr(arg.expression), node: arg))
    }

    if let f = funcs[name] {
      let values = try matchArguments(name, f.params.map { ($0.label, $0.ty) }, args, call)
      return Expr(kind: .call(f, values), ty: f.ret, owned: true)
    }

    if name == "print" {
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
      let values = try matchArguments(name, s.fields.map { (Optional($0.name), $0.ty) }, args, call)
      return Expr(kind: .structLit(s, values), ty: .structure(name))
    }

    if let c = classes[name] {
      let values = try matchArguments(name, c.fields.map { (Optional($0.name), $0.ty) }, args, call)
      return Expr(kind: .construct(c, values), ty: .cls(name), owned: true)
    }

    throw error("cannot find '\(name)' in scope", callee)
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
    guard let id = type.as(IdentifierTypeSyntax.self) else {
      throw error("this type is not supported in M2", type)
    }
    let name = id.name.text
    switch name {
    case "Int": return .int
    case "Bool": return .bool
    default:
      if structs[name] != nil { return .structure(name) }
      if classes[name] != nil { return .cls(name) }
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
