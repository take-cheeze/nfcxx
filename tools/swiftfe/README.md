# swiftfe

Milestone M0 of a Swift frontend that does not depend on LLVM. It parses Swift
with `swift-syntax` (pure Swift, pinned to 601.0.1) and reports what it finds.
There is no type checking or code generation yet.

```
swift build -c release
.build/release/swiftfe [--stats] <file.swift | dir>...
```

- Prints each syntax error as `file:line:col: error: message`.
- Checks that the lossless tree prints back to the exact input bytes. A mismatch
  is reported as a round-trip failure.
- `--stats` prints how many nodes of each syntax kind were seen.
- Exit status: 0 all clean, 1 problems found, 2 usage.

M0 is done when the parser is confirmed to handle real code and to recover from
broken input without crashing or losing source text. Checked so far:

| Input | Files | Result |
| --- | --- | --- |
| `swift-syntax/Sources` | 333 | all clean |
| `swift-syntax/Tests` | 257 | all clean |
| `.swiftinterface` files from the Swift 6.1 toolchain | 92 | all clean |
| Those interfaces truncated at 30%, 50% and 70% | 276 | no crashes, every tree round-trips, 241 of 276 files reported errors |
