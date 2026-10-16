// Lowers the operator-folded swift-syntax tree into the typed IR.
//
// This is where names are resolved and types are checked. The first error
// stops compilation; M1 does not try to recover.

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

final class Lowerer {
  private let converter: SourceLocationConverter
  private var structs: [String: StructInfo] = [:]
  private var funcs: [String: FuncInfo] = [:]
  private var scopes: [[String: Local]] = []
  /// Return type of the function being lowered; nil while lowering top-level code.
  private var returnType: Ty? = nil
  private var counter = 0

  init(converter: SourceLocationConverter) {
    self.converter = converter
  }

  func lower(_ file: SourceFileSyntax) throws -> Program {
    let items = Array(file.statements)

    // Pass 1: declare every struct and function so bodies can refer to them
    // regardless of source order.
    var structDecls: [(StructDeclSyntax, StructInfo)] = []
    for item in items {
      guard case .decl(let decl) = item.item, let s = decl.as(StructDeclSyntax.self) else { continue }
      let name = s.name.text
      if structs[name] != nil { throw error("invalid redeclaration of '\(name)'", s) }
      let info = StructInfo(name: name)
      structs[name] = info
      structDecls.append((s, info))
    }
    for (decl, info) in structDecls {
      info.fields = try lowerFields(decl)
    }
    try checkRecursion(structDecls.map { $0.0 })

    var funcDecls: [(FunctionDeclSyntax, FuncInfo)] = []
    for item in items {
      guard case .decl(let decl) = item.item, let f = decl.as(FunctionDeclSyntax.self) else { continue }
      let name = f.name.text
      if funcs[name] != nil { throw error("invalid redeclaration of '\(name)'", f) }
      let info = try declareFunction(f)
      funcs[name] = info
      funcDecls.append((f, info))
    }

    // Pass 2: function bodies.
    for (decl, info) in funcDecls {
      info.body = try lowerFunctionBody(decl, info)
    }

    // Top-level statements form the body of the program. Their variables are
    // visible only to top-level code, not to functions.
    scopes = [[:]]
    returnType = nil
    var main: [Stmt] = []
    for item in items {
      switch item.item {
      case .decl(let decl):
        if decl.is(FunctionDeclSyntax.self) || decl.is(StructDeclSyntax.self) { continue }
        main += try lowerDecl(decl)
      case .stmt(let stmt):
        main += try lowerStmt(stmt)
      case .expr(let expr):
        main += try lowerExprStmt(expr)
      }
    }

    return Program(
      structs: structDecls.map { $0.1 },
      funcs: funcDecls.map { $0.1 },
      main: main
    )
  }

  // MARK: - Declarations

  private func lowerFields(_ s: StructDeclSyntax) throws -> [Field] {
    var fields: [Field] = []
    for member in s.memberBlock.members {
      guard let v = member.decl.as(VariableDeclSyntax.self) else {
        throw error("only stored properties are supported in structs in M1", member)
      }
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
        fields.append(Field(name: name, cName: "m_" + name, ty: try resolveType(annotation.type), mutable: mutable))
      }
    }
    if fields.isEmpty {
      throw error("structs without stored properties are not supported yet", s)
    }
    return fields
  }

  /// Rejects a struct that contains itself by value, which Swift also rejects.
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
        if case .structure(let child) = field.ty {
          try visit(child, active + [name])
        }
      }
      finished.insert(name)
    }

    for d in decls {
      try visit(d.name.text, [])
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

  private func lowerFunctionBody(_ f: FunctionDeclSyntax, _ info: FuncInfo) throws -> [Stmt] {
    guard let body = f.body else { throw error("function without a body", f) }
    scopes = [[:]]
    returnType = info.ret
    for p in info.params {
      scopes[0][p.name] = Local(cName: p.cName, ty: p.ty, mutable: false)
    }
    let stmts = try lowerBlock(body.statements)
    if info.ret != .void && !alwaysReturns(stmts) {
      throw error("missing return in global function expected to return '\(info.ret.swiftName)'", f)
    }
    return stmts
  }

  private func lowerDecl(_ decl: DeclSyntax) throws -> [Stmt] {
    guard let v = decl.as(VariableDeclSyntax.self) else {
      throw error("this declaration is not supported in M1", decl)
    }
    let mutable = v.bindingSpecifier.tokenKind == .keyword(.var)
    var out: [Stmt] = []
    for binding in v.bindings {
      guard let id = binding.pattern.as(IdentifierPatternSyntax.self) else {
        throw error("only simple names are supported in M1", binding.pattern)
      }
      guard let initializer = binding.initializer?.value else {
        throw error("variables need an initial value in M1", binding)
      }
      let value = try lowerExpr(initializer)
      if value.ty == .void {
        throw error("cannot initialize a variable with a value of type 'Void'", initializer)
      }
      if let annotation = binding.typeAnnotation {
        let declared = try resolveType(annotation.type)
        guard declared == value.ty else { throw mismatch(expected: declared, actual: value.ty, initializer) }
      }
      let name = id.identifier.text
      let depth = scopes.count - 1
      if scopes[depth][name] != nil {
        throw error("invalid redeclaration of '\(name)'", binding)
      }
      let cName = "l\(nextID())_" + name
      scopes[depth][name] = Local(cName: cName, ty: value.ty, mutable: mutable)
      out.append(.decl(cName, value.ty, value))
    }
    return out
  }

  // MARK: - Statements

  private func lowerBlock(_ items: CodeBlockItemListSyntax) throws -> [Stmt] {
    scopes.append([:])
    defer { scopes.removeLast() }
    var out: [Stmt] = []
    for item in items {
      switch item.item {
      case .decl(let decl): out += try lowerDecl(decl)
      case .stmt(let stmt): out += try lowerStmt(stmt)
      case .expr(let expr): out += try lowerExprStmt(expr)
      }
    }
    return out
  }

  private func lowerStmt(_ stmt: StmtSyntax) throws -> [Stmt] {
    if let ret = stmt.as(ReturnStmtSyntax.self) {
      guard let want = returnType else {
        throw error("'return' is not supported at top level in M1", ret)
      }
      if let value = ret.expression {
        if want == .void {
          throw error("unexpected non-void return value in void function", value)
        }
        let v = try lowerExpr(value)
        guard v.ty == want else { throw mismatch(expected: want, actual: v.ty, value) }
        return [.ret(v)]
      }
      if want != .void {
        throw error("non-void function should return a value", ret)
      }
      return [.ret(nil)]
    }
    if let loop = stmt.as(WhileStmtSyntax.self) {
      let cond = try lowerCondition(loop.conditions, loop)
      return [.whiles(cond, try lowerBlock(loop.body.statements))]
    }
    if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
      return try lowerExprStmt(exprStmt.expression)
    }
    throw error("this statement is not supported in M1", stmt)
  }

  private func lowerExprStmt(_ expr: ExprSyntax) throws -> [Stmt] {
    if let ifExpr = expr.as(IfExprSyntax.self) {
      return [try lowerIf(ifExpr)]
    }
    if let infix = expr.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) {
      let (target, targetTy) = try lowerLValue(infix.leftOperand)
      let value = try lowerExpr(infix.rightOperand)
      guard value.ty == targetTy else { throw mismatch(expected: targetTy, actual: value.ty, infix.rightOperand) }
      return [.assign(target, value)]
    }
    return [.expr(try lowerExpr(expr))]
  }

  private func lowerIf(_ node: IfExprSyntax) throws -> Stmt {
    let cond = try lowerCondition(node.conditions, node)
    let then = try lowerBlock(node.body.statements)
    var otherwise: [Stmt] = []
    if let elseBody = node.elseBody {
      switch elseBody {
      case .codeBlock(let block):
        otherwise = try lowerBlock(block.statements)
      case .ifExpr(let nested):
        otherwise = [try lowerIf(nested)]
      }
    }
    return .ifs(cond, then, otherwise)
  }

  private func lowerCondition(_ list: ConditionElementListSyntax, _ node: some SyntaxProtocol) throws -> Expr {
    guard list.count == 1, let first = list.first, case .expression(let expr) = first.condition else {
      throw error("only a single boolean condition is supported in M1", node)
    }
    let v = try lowerExpr(expr)
    guard v.ty == .bool else {
      throw error("condition must be of type 'Bool', but is of type '\(v.ty.swiftName)'", expr)
    }
    return v
  }

  // MARK: - Expressions

  private func lowerExpr(_ expr: ExprSyntax) throws -> Expr {
    if let lit = expr.as(IntegerLiteralExprSyntax.self) {
      let digits = lit.literal.text.filter { $0 != "_" }
      guard let value = Int64(digits) else {
        throw error("integer literal is out of range or not supported in M1", lit)
      }
      return Expr(kind: .int(value), ty: .int)
    }
    if let lit = expr.as(BooleanLiteralExprSyntax.self) {
      return Expr(kind: .bool(lit.literal.tokenKind == .keyword(.true)), ty: .bool)
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
        throw error("implicit member access is not supported in M1", member)
      }
      let b = try lowerExpr(base)
      let field = try fieldOf(b.ty, member.declName.baseName.text, member)
      return Expr(kind: .field(b, field.cName), ty: field.ty)
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
        throw error("assignment is not an expression in M1", infix)
      }
      let l = try lowerExpr(infix.leftOperand)
      let r = try lowerExpr(infix.rightOperand)
      return try binary(op.operator.text, l, r, infix)
    }
    if let call = expr.as(FunctionCallExprSyntax.self) {
      return try lowerCall(call)
    }
    throw error("this expression is not supported in M1", expr)
  }

  private func binary(_ op: String, _ l: Expr, _ r: Expr, _ node: some SyntaxProtocol) throws -> Expr {
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
      throw error("operator '\(op)' is not supported in M1", node)
    }
  }

  private func lowerCall(_ call: FunctionCallExprSyntax) throws -> Expr {
    guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else {
      throw error("trailing closures are not supported in M1", call)
    }
    guard let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else {
      throw error("only calls to named functions are supported in M1", call)
    }
    let name = callee.baseName.text
    let args = try call.arguments.map { arg in
      (label: arg.label?.text, value: try lowerExpr(arg.expression), node: arg)
    }

    if let f = funcs[name] {
      guard args.count == f.params.count else {
        throw error("wrong number of arguments to '\(name)': expected \(f.params.count), got \(args.count)", call)
      }
      for (arg, param) in zip(args, f.params) {
        guard arg.label == param.label else {
          throw error("incorrect argument label (have '\(arg.label ?? "_"):', expected '\(param.label ?? "_"):')", arg.node)
        }
        guard arg.value.ty == param.ty else { throw mismatch(expected: param.ty, actual: arg.value.ty, arg.node.expression) }
      }
      return Expr(kind: .call(f, args.map { $0.value }), ty: f.ret)
    }

    if name == "print" {
      guard args.count == 1, args[0].label == nil else {
        throw error("print takes exactly one unlabeled argument in M1", call)
      }
      let v = args[0].value
      guard v.ty == .int || v.ty == .bool else {
        throw error("print is supported for Int and Bool only in M1", args[0].node.expression)
      }
      return Expr(kind: .print(v), ty: .void)
    }

    if let s = structs[name] {
      guard args.count == s.fields.count else {
        throw error("wrong number of arguments to '\(name)': expected \(s.fields.count), got \(args.count)", call)
      }
      for (arg, field) in zip(args, s.fields) {
        guard arg.label == field.name else {
          throw error("incorrect argument label (have '\(arg.label ?? "_"):', expected '\(field.name):')", arg.node)
        }
        guard arg.value.ty == field.ty else { throw mismatch(expected: field.ty, actual: arg.value.ty, arg.node.expression) }
      }
      return Expr(kind: .structLit(s, args.map { $0.value }), ty: .structure(name))
    }

    throw error("cannot find '\(name)' in scope", callee)
  }

  private func lowerLValue(_ expr: ExprSyntax) throws -> (LValue, Ty) {
    if let ref = expr.as(DeclReferenceExprSyntax.self) {
      let name = ref.baseName.text
      guard let local = lookup(name) else { throw error("cannot find '\(name)' in scope", ref) }
      guard local.mutable else {
        throw error("cannot assign to value: '\(name)' is a 'let' constant", ref)
      }
      return (.local(local.cName), local.ty)
    }
    if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
      let (target, baseTy) = try lowerLValue(base)
      let field = try fieldOf(baseTy, member.declName.baseName.text, member)
      guard field.mutable else {
        throw error("cannot assign to 'let' property '\(field.name)'", member)
      }
      return (.field(target, field.cName), field.ty)
    }
    throw error("expression is not assignable", expr)
  }

  // MARK: - Helpers

  private func resolveType(_ type: TypeSyntax) throws -> Ty {
    guard let id = type.as(IdentifierTypeSyntax.self) else {
      throw error("this type is not supported in M1", type)
    }
    switch id.name.text {
    case "Int": return .int
    case "Bool": return .bool
    default:
      if let s = structs[id.name.text] { return .structure(s.name) }
      throw error("cannot find type '\(id.name.text)' in scope", type)
    }
  }

  private func fieldOf(_ ty: Ty, _ name: String, _ node: some SyntaxProtocol) throws -> Field {
    guard case .structure(let sname) = ty, let s = structs[sname] else {
      throw error("value of type '\(ty.swiftName)' has no member '\(name)'", node)
    }
    guard let field = s.fields.first(where: { $0.name == name }) else {
      throw error("value of type '\(sname)' has no member '\(name)'", node)
    }
    return field
  }

  private func lookup(_ name: String) -> Local? {
    for scope in scopes.reversed() {
      if let local = scope[name] { return local }
    }
    return nil
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
