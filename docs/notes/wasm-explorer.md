# The wasm explorer: an online compiler page for the wasm emitter

`tools/wasm-explorer/` is a small page for trying the Path B WebAssembly emitter (`pathb-wasm.md`): C++ in, the mid-level
IR and the wasm module out, and the module runs in the page with the browser's WebAssembly. It is an explorer in the
sense of Compiler Explorer, for one backend.

```
scripts/setup-pathb.sh && scripts/setup-mruby.sh    # the harness and the mruby tool (once)
node tools/wasm-explorer/server.cjs                  # http://127.0.0.1:8080/ (--port, --host)
```

The compiler is native, so the server runs it and the browser runs the result. The page is one HTML file with no
external script or style, and the server has no dependency beyond node (22 was used).

## What the server does

`POST /api/compile` with `{"source": "..."}` writes the source to a temporary directory and runs
`scripts/pathb-dump --ir prog.cpp` (the IR), then `scripts/mrb scripts/pathb-wasm-emit.rb prog.ir` (the module). It
answers with `{ok, ir, wasm}` (wasm in base64), or `{ok: false, stage, message}`: `front-end` for a diagnostic from the
harness, `emit` for a refusal of the emitter (exit status 3, the message names the node refused). `GET /api/health`
says whether the harness and the mruby tool are built.

Limits: 64 KB of source per request (413 past it), 60 s per compiler step, two compiles at a time (503 past that). The
server listens on 127.0.0.1 by default, because it runs the compiler on whatever source it is sent. Exposing it on a
network needs a process sandbox and a rate limit, which are not in this change. A static host (GitHub Pages) can serve
the page but cannot compile; it would need the modules built ahead of time.

## What the page does

- An editor with three examples, Ctrl+Enter to compile, and a permalink: the source is in the URL hash (`#src=`, base64url).
- The Module tab: size, exports, imports, a download of `prog.wasm`, and Run, which calls `main` the way
  `tests/wasm/host.cjs` does. An import is stubbed as "first argument plus one". A trap prints its message (for
  example `divide by zero`). A module without `main`, or with a non-function import, says so.
- The IR tab (the `pathb-dump --ir` text), and the Bytes tab (a hex dump of the first KB).
- Refusals and diagnostics are shown as text, and Run is disabled.

Checked here: the three examples give 385, 300 and 610, which match `g++ -O0` (the process status is these modulo 256).
Front-end errors, a refusal (`variadic call`), an oversized body (413), a bad request, and a trap all come back as
described. A headless Chromium run of the page compiled, ran, and showed the refusal, and had no console errors. At a
390 px width there is no horizontal scroll. `tests/wasm-explorer/` has no test yet; the checks above were done by hand.

## Compiler Explorer features: how far they can go

| Feature | Status | Notes |
| --- | --- | --- |
| Source editor, compile on demand, permalinks | done | Compile on change is not done; it would need debouncing. |
| Examples | done (3) | |
| Run the output | done | `main` only; imports are stubbed. Program output (`printf`) is refused, so there is no stdout yet. |
| Compiler errors | text only | Inline markers need the harness's line numbers in the editor, which is a parse of EDG's messages. |
| Binary download and byte view | done | |
| Module summary (imports, exports, sizes) | done | |
| Text format (WAT) | not done | A disassembler is needed: `wabt.js` if vendored, or a small one of our own. Medium. |
| The IR, and other stages (`--emit-c`, the QBE asm) | IR done | `--emit-c` is a second run of the same front end. The QBE asm is the native path. Small each. |
| Side-by-side comparison, diff | not done | Two panels of stages, or of backends (wasm, `g++ -O0` asm). Medium. |
| Compiler flags (`-std`, `-D`, `-I`, `--freestanding`, `--target`) | not done | `pathb-dump` takes them. Include directories must be restricted to the repo, not left as free paths. Small. |
| Emitter modes (`--asan`, `--emscripten`) | not done | The emitter already takes them. A dropdown per mode. Small. |
| Optimization levels | not applicable | The wasm emitter has no optimizer, so there is no `-O` to choose. The native path would have them. |
| Source-to-output mapping (hover a line, see its code) | not done | Needs a line table. The emitter writes none, and only a `name` section (function names) is cheap. Hard for instructions. |
| Libraries (`<vector>`, `<string>`, `std::`) | limited by the emitter | Hosted headers work in `pathb-dump`. The emitter refuses exceptions, variadic calls, indirect calls, general `goto`, bit-fields, VLAs and 16-byte types, and in the IR sweep 168 of 262 files are refused. The page would show these refusals, not hide them. |
| Several compilers, a compiler list | not applicable | One backend. |
| Accounts, saved snippets, a gallery | not planned | |

So: most of the page's features are reachable with small to medium steps (WAT, the other stages, flags, the modes,
comparison). Two are not practical in the near term: a line-by-line source map, and running programs that print. The
bigger limit is the emitter's coverage of C++, which the page reports rather than changes.

## 64-bit wasm (memory64)

Addable, and the data model already fits it. The IR is LP64 (pointers and `long` 8 bytes), which is the model a 64-bit
wasm module needs. What is 32-bit today is the memory's address type: `addr32` wraps every pointer to `i32`
(`i32.wrap_i64`) and the memory is declared with a 32-bit limit. The memory64 proposal makes the address `i64`.

Checked in this environment: Node 22 (V8) instantiates a module whose memory has the i64 index type (limits flag
`0x04`) without a flag, and a function `f(addr: i64) -> i32 { return i32.load(addr) }` reads at a BigInt address, while
a Number address is a TypeError. So the change can be tested here.

What would change in `scripts/pathb-wasm-emit.rb` (about a dozen sites, found by grepping for `ptr_bytes`, `0xa7`
(`i32.wrap_i64`), `0x41` and `shadow_base`):

1. A `--memory64` mode: the memory limits with flag `0x04` and u64 page counts; the data segments' offsets as `i64.const`
   (`0x42`) instead of `i32.const`.
2. `addr32` becomes `addr64`: no wrap, the pointer is the address. The memarg offset is a u64 under an i64 memory, which is
   the same bytes for the offsets the emitter writes.
3. The shadow stack: the `__stack_pointer` global and the frame arithmetic (`i64.extend_i32_u` for a slot's address and
   the prologue) move to i64.
4. `memory.copy` and `memory.fill` take i64 operands under an i64 memory.
5. ASan and `--emscripten` are refused with `--memory64` at first (their shadow and exports are i32 now), as ILP32 is
   refused with `--asan`.

Tests: `tests/wasm/run.sh` with `NFCXX_WASM_MEMORY64=1` (each module is emitted in the mode and must give the same
result), and a test with a static object above 4 GB, if the Node build will allocate that much memory (not checked).
Whether an Emscripten `MEMORY64` runtime accepts the module was not checked, as before (`pathb-wasm.md`, "Unverified names").

This was not implemented. It is a separate change from the page.
