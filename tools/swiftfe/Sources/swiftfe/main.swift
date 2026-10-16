// swiftfe: a Swift frontend that does not depend on LLVM.
//
//   swiftfe check [--stats] <file.swift | dir>...   parse only (M0)
//   swiftfe emit-c <file.swift>                     print C (M1)
//   swiftfe build <file.swift> -o <exe>             compile with cc (M1)
//
// Exit status: 0 success, 1 compile errors or check failures, 2 usage.

import Foundation
import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

func fail(_ message: String) {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func readSource(_ path: String) -> String? {
  guard let data = FileManager.default.contents(atPath: path) else { return nil }
  return String(decoding: data, as: UTF8.self)
}

func swiftFiles(under path: String) -> [String] {
  var isDir: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
  guard isDir.boolValue else { return [path] }
  let enumerator = FileManager.default.enumerator(atPath: path)
  var found: [String] = []
  while let rel = enumerator?.nextObject() as? String {
    if rel.hasSuffix(".swift") { found.append((path as NSString).appendingPathComponent(rel)) }
  }
  return found.sorted()
}

// MARK: - Parsing

/// Parses a file, printing syntax errors. Returns the operator-folded tree
/// (what Lowerer expects) or nil if the file did not parse.
func parseForCompile(_ path: String) -> (SourceFileSyntax, SourceLocationConverter)? {
  guard let source = readSource(path) else {
    fail("\(path): cannot read")
    return nil
  }
  let parsed = Parser.parse(source: source)
  let converter = SourceLocationConverter(fileName: path, tree: parsed)
  var ok = true
  for diagnostic in ParseDiagnosticsGenerator.diagnostics(for: parsed) {
    let loc = converter.location(for: diagnostic.position)
    print("\(path):\(loc.line):\(loc.column): error: \(diagnostic.message)")
    ok = false
  }
  guard ok else { return nil }
  do {
    let folded = try OperatorTable.standardOperators.foldAll(parsed).as(SourceFileSyntax.self)!
    return (folded, SourceLocationConverter(fileName: path, tree: folded))
  } catch {
    print("\(path): error: \(error)")
    return nil
  }
}

/// Lowers a file to C source, printing the first compile error.
func compileToC(_ path: String) -> String? {
  guard let (tree, converter) = parseForCompile(path) else { return nil }
  do {
    let program = try Lowerer(converter: converter).lower(tree)
    return CEmit.emit(program)
  } catch let e as CompileError {
    print("\(path):\(e.line):\(e.column): error: \(e.message)")
  } catch {
    print("\(path): error: \(error)")
  }
  return nil
}

// MARK: - check (M0)

final class KindCounter: SyntaxAnyVisitor {
  var counts: [String: Int] = [:]

  init() { super.init(viewMode: .sourceAccurate) }

  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    counts["\(node.kind)", default: 0] += 1
    return .visitChildren
  }
}

/// Returns true when the file parses with no diagnostics and round-trips.
func check(path: String, counts: KindCounter?) -> Bool {
  guard let source = readSource(path) else {
    print("\(path): cannot read")
    return false
  }
  let tree = Parser.parse(source: source)
  var clean = true

  if tree.description != source {
    print("\(path): round-trip mismatch (tree does not reproduce the input)")
    clean = false
  }

  let converter = SourceLocationConverter(fileName: path, tree: tree)
  for diagnostic in ParseDiagnosticsGenerator.diagnostics(for: tree) {
    let location = converter.location(for: diagnostic.position)
    print("\(path):\(location.line):\(location.column): error: \(diagnostic.message)")
    clean = false
  }

  counts?.walk(tree)
  return clean
}

func runCheck(_ args: [String]) -> Int32 {
  var args = args
  let wantStats = args.contains("--stats")
  args.removeAll { $0 == "--stats" }
  if args.isEmpty {
    fail("usage: swiftfe check [--stats] <file.swift | dir>...")
    return 2
  }

  let files = args.flatMap { swiftFiles(under: $0) }
  let counter = wantStats ? KindCounter() : nil
  let start = Date()
  var clean = 0
  for file in files where check(path: file, counts: counter) {
    clean += 1
  }
  let elapsed = Date().timeIntervalSince(start)
  print("\(files.count) files, \(clean) clean, \(files.count - clean) with problems, "
    + String(format: "%.2fs", elapsed))

  if let counter {
    for (kind, count) in counter.counts.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
      print("\(count)\t\(kind)")
    }
  }
  return clean == files.count ? 0 : 1
}

// MARK: - emit-c and build (M1)

func runEmitC(_ args: [String]) -> Int32 {
  guard args.count == 1 else {
    fail("usage: swiftfe emit-c <file.swift>")
    return 2
  }
  guard let c = compileToC(args[0]) else { return 1 }
  print(c, terminator: "")
  return 0
}

func runBuild(_ args: [String]) -> Int32 {
  var input: String?
  var output: String?
  var i = 0
  while i < args.count {
    if args[i] == "-o", i + 1 < args.count {
      output = args[i + 1]
      i += 2
    } else {
      input = args[i]
      i += 1
    }
  }
  guard let input, let output else {
    fail("usage: swiftfe build <file.swift> -o <exe>")
    return 2
  }
  guard let c = compileToC(input) else { return 1 }

  let cFile = output + ".c"
  do {
    try c.write(toFile: cFile, atomically: true, encoding: .utf8)
  } catch {
    fail("cannot write \(cFile): \(error)")
    return 1
  }

  let cc = Process()
  cc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  cc.arguments = ["cc", "-std=c11", "-O1", "-Wall", "-Werror",
                  "-Wno-unused-function", "-Wno-unused-variable", "-Wno-unused-but-set-variable",
                  "-o", output, cFile]
  do {
    try cc.run()
  } catch {
    fail("cannot run cc: \(error)")
    return 1
  }
  cc.waitUntilExit()
  return cc.terminationStatus == 0 ? 0 : 1
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  fail("usage: swiftfe <check|emit-c|build> ...")
  exit(2)
}
let rest = Array(arguments.dropFirst())
switch command {
case "check": exit(runCheck(rest))
case "emit-c": exit(runEmitC(rest))
case "build": exit(runBuild(rest))
default:
  fail("unknown command '\(command)'; usage: swiftfe <check|emit-c|build> ...")
  exit(2)
}
