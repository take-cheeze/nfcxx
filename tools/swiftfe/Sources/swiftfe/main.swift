// M0: parse Swift sources with swift-syntax, report syntax errors, check that
// the lossless tree prints back to the input, and optionally count node kinds.
//
//   swiftfe [--stats] <file.swift | dir>...
//
// Exit status: 0 all clean, 1 diagnostics or round-trip mismatch, 2 usage.

import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

final class KindCounter: SyntaxAnyVisitor {
  var counts: [String: Int] = [:]

  init() { super.init(viewMode: .sourceAccurate) }

  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    counts["\(node.kind)", default: 0] += 1
    return .visitChildren
  }
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

/// Returns true when the file parses with no diagnostics and round-trips.
func check(path: String, counts: KindCounter?) -> Bool {
  guard let data = FileManager.default.contents(atPath: path) else {
    print("\(path): cannot read")
    return false
  }
  let source = String(decoding: data, as: UTF8.self)
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

var args = Array(CommandLine.arguments.dropFirst())
let wantStats = args.contains("--stats")
args.removeAll { $0 == "--stats" }
if args.isEmpty {
  FileHandle.standardError.write("usage: swiftfe [--stats] <file.swift | dir>...\n".data(using: .utf8)!)
  exit(2)
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

exit(clean == files.count ? 0 : 1)
