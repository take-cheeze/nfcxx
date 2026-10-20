# The wasm explorer: an online compiler page for the wasm emitter

`tools/wasm-explorer/` is a page for trying the Path B WebAssembly emitter (`pathb-wasm.md`): C++ in, the IR, the
WebAssembly text and the binary out, and the module runs in the page with the browser's WebAssembly. It is an explorer
in the sense of Compiler Explorer, for one backend.

It runs in two ways:

- **Live**, with the local server. It compiles any source on each edit (or on Compile).
- **Static**, on GitHub Pages (`.github/workflows/wasm-explorer-pages.yml`). It cannot compile: the examples are
  compiled ahead of time in CI, and their results are checked against the expected values before the site is deployed.

```
scripts/setup-pathb.sh && scripts/setup-mruby.sh    # the harness and the mruby tool (once)
node tools/wasm-explorer/server.cjs                  # live: http://127.0.0.1:8080/ (--port, --host)
node tools/wasm-explorer/build-static.cjs            # static: _site/, the examples built and checked
```

The compiler is native, so it runs where `pipeline.cjs` runs (the server, or the build). The module it produces runs in
the browser. The page is one HTML file. The editor and the WAT converter come from jsdelivr (pinned, below); the server
has no dependency beyond node (22 was used).

## Files

| File | What it is |
| --- | --- |
| `pipeline.cjs` | The compile: `pathb-dump --ir`, then `pathb-wasm-emit.rb`, in a temporary directory. Options: the standard and the mode. Diagnostics with line numbers. |
| `server.cjs` | The live server: the page, `examples/`, `GET /api/health`, `POST /api/compile`. |
| `build-static.cjs` | The static site: each example in every mode, run and checked, then the page and `builds/<id>.json`. |
| `index.html` | The page (one file, no build step). |
| `examples/` | The sources and `index.json` (id, title, file, expected `main()` result). |

## The compile

`POST /api/compile` with `{"source": "...", "options": {"std": "c++20", "mode": "asan"}}` answers with
`{ok, ir, wasm (base64), diagnostics, mode, std}`, or `{ok: false, stage, message, diagnostics}`. The stages are
`request` (bad input), `front-end` (a diagnostic from the harness), `emit` (a refusal of the emitter, exit status 3, the
message names the node refused), and `server`. `diagnostics` is `[{line, severity, message}]`, parsed from EDG's
messages; the page puts them on the editor's lines as markers.

The options are checked against a list: `std` is `c++17`, `c++20`, `c++23` or empty (the front end's default); `mode` is
one of:

| Mode | Front end | Emitter | Data model |
| --- | --- | --- | --- |
| `lp64` (default) | as is | as is | LP64, i64 pointers |
| `asan` | as is | `--asan` | LP64, with the ASan shadow |
| `emscripten` | `--freestanding --target=linux_riscv32` | `--emscripten` | ILP32, Emscripten's exports |

Limits: 64 KB of source (413 past it), 60 s per compiler step, two compiles at a time (503 past that). The server listens
on 127.0.0.1 by default, because it runs the compiler on whatever source it is sent. Exposing it needs a process sandbox
and a rate limit, which are not in this change.

## The page

- **Editor**: Monaco 0.52.2 from `cdn.jsdelivr.net/npm/monaco-editor@0.52.2`, with C++ highlighting, diagnostics as
  markers, and Ctrl+Enter. If the CDN cannot be reached, the page uses a plain textarea.
- **Options**: the standard, the mode, and "auto" (compile 0.7 s after an edit; live only).
- **Module** tab: size, exports, imports, the bytes, the `.wasm` download, and Run, which calls `main` the way
  `tests/wasm/host.cjs` does (imports return their first argument plus one; a trap prints its message).
- **WAT** tab: the module as WebAssembly text, converted with `wabt` 1.0.37 (`cdn.jsdelivr.net/npm/wabt@1.0.37`), loaded
  when the tab is first opened, with a `.wat` download.
- **IR** and **Bytes** tabs: the mid-level IR text, and a hex dump of the first KB.
- **Link**: the source, mode and standard are in the URL hash (`#src=<base64url>&mode=asan&std=c++20`).

## Static build

`build-static.cjs` compiles each example in each mode, runs `main` in node, and fails the build if a result differs
from `expect` in `examples/index.json` or if a compile fails. It writes `_site/`: `index.html`, `examples/` (the sources
and the manifest), `builds/<id>.json` (the sources, IR, wasm and diagnostics per mode), and `.nojekyll`.

On a static host the page reads the manifest and the builds. An example's source gets its prebuilt result (and the
default standard only). Any other source gets a message that it needs the local server. A permalink to an example works.

The workflow builds the harness and the mruby tool as `pathb.yml` does, runs the static build (on pull requests too,
without deploying), and deploys from `main`. The one-time repository setting is Settings > Pages > Source: GitHub
Actions.

## Checks

- `build-static.cjs` is the check for the examples: 4 examples x 3 modes, each run and compared with its expected
  result. The three expected results were also checked against `g++ -O0` (modulo 256, the process status).
- Checked by hand in a headless Chromium with the CDN routed to the npm packages, since this sandbox cannot reach the
  CDN: live (the examples, the modes, the standard, markers on a syntax error, auto-compile, WAT, the permalink, no
  console errors); static (the examples, the emscripten mode, WAT, the refusal for other code, no console errors); CDN
  blocked (the textarea takes over and the examples still run; WAT says it could not load wabt).
- Error paths on the server: a front-end syntax error, a refusal (`variadic call`), 413, 400, 404.
- No automated test runs the page. The CDN, and the browser, are not in CI.

## Compiler Explorer features

| Feature | Status | Notes |
| --- | --- | --- |
| Editor with highlighting and diagnostics | done | Monaco, from the CDN. |
| Compile on edit, and on demand | done | Auto on the live server only. |
| Examples | done (4) | Each checked in every mode at build time. |
| Options: standard, emitter mode | done | `pipeline.cjs` takes them. |
| Run the output | done | `main` only; imports are stubbed. |
| Compiler errors | done | Text, and markers on the lines. |
| WAT (text format) | done | `wabt`, from the CDN. |
| IR, bytes, download | done | |
| Shareable links | done | Source and options in the hash. |
| Static deployment | done | GitHub Pages, examples only. |
| Other stages (the C from `--emit-c`, the QBE asm) | not done | Needs the Path A build (`setup-edg.sh`), a second pipeline. |
| Side-by-side comparison, diff | not done | Two modes or two backends in two panels. |
| Compiler flags beyond the standard (`-D`, `-I`, `--target`) | not done | Include directories must be limited to the repo, not free paths. |
| Source-to-output mapping | not done | Needs a line table. The emitter writes none; function names (a `name` section) are cheap. |
| Program output (`printf`) | not done | The emitter refuses variadic calls, so there is no stdout yet. |
| Libraries (`<vector>`, `<string>`) | limited by the emitter | The emitter refuses exceptions, variadic calls, indirect calls, general `goto`, bit-fields, VLAs and 16-byte types. In the IR sweep, 168 of 262 files are refused. The page shows these refusals. |
| Several compilers | not applicable | One backend. |
| Accounts, saved snippets | not planned | |

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

Not implemented. It is a separate change from the page.
