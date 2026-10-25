# The wasm explorer: an online compiler page for the wasm emitter

`tools/wasm-explorer/` is a page for trying the Path B WebAssembly emitter (`pathb-wasm.md`): C++, C, Rust, Go, LLVM IR
or the mid-level IR itself in (see "Languages"), the IR, the WebAssembly text and the binary out, and the module runs in the page with the browser's WebAssembly. It is an explorer
in the sense of Compiler Explorer, for one backend.

It runs in two ways:

- **Live**, with the local server. It compiles any source on each edit (or on Compile).
- **Static**, on GitHub Pages (`.github/workflows/wasm-explorer-pages.yml`). It cannot compile: the examples are
  compiled ahead of time in CI, and their results are checked against the expected values before the site is deployed.

```
scripts/setup-pathb.sh && scripts/setup-mruby.sh    # the harness and the mruby tool (once)
scripts/setup-tinygo.sh                              # Go: TinyGo (pinned), which runs go (1.22 to 1.25); Rust: rustc on PATH
node tools/wasm-explorer/server.cjs                  # live: http://127.0.0.1:8080/ (--port, --host)
node tools/wasm-explorer/build-static.cjs            # static: _site/, the examples built and checked
```

The compiler is native, so it runs where `pipeline.cjs` runs (the server, or the build). The module it produces runs in
the browser. The page is one HTML file. The editor and the WAT converter come from jsdelivr (pinned, below); the server
has no dependency beyond node (22 was used).

## Files

| File | What it is |
| --- | --- |
| `pipeline.cjs` | The compile: the language's front end (`pathb-dump --ir`; or rustc or TinyGo, then `llvm-to-pathb.rb`), then `pathb-wasm-emit.rb`, in a temporary directory. Options: the language, the standard and the mode. Diagnostics with line numbers. |
| `server.cjs` | The live server: the page, `examples/`, `GET /api/health`, `POST /api/compile`. |
| `build-static.cjs` | The static site (run by `.github/workflows/wasm-explorer-build.yml`): each example in every mode of its language, run and checked, then the page and `builds/<id>.json`. |
| `index.html` | The page (one file, no build step). |
| `bindings.js` | The browser bindings (see "Browser bindings"), shared by the page and the static build. |
| `common.js` | The modes, the languages, the option check and the diagnostics parser, shared by `pipeline.cjs`, `inbrowser.js` and the page. |
| `inbrowser.js` | The compile without a server (see "Static build"): `pipeline.cjs`'s steps with the front end and the emitter as wasm. |
| `compile-worker.js` | The page's worker that runs `inbrowser.js`. |
| `inbrowser-assets.cjs`, `test-inbrowser.cjs` | The in-browser compiler's files from this checkout's builds (for the static build and node), and its check against `pipeline.cjs`. |
| `examples/` | The sources and `index.json` (id, title, file, language (default `c++`), expected `main()` result). |

## The compile

`POST /api/compile` with `{"source": "...", "options": {"language": "c++", "std": "c++20", "mode": "asan"}}` answers with
`{ok, ir, wasm (base64), diagnostics, language, mode, std}`, or `{ok: false, stage, message, diagnostics, code}`. The
stages are `request` (bad input), `front-end` (a diagnostic from the harness, or a refusal of `llvm-to-pathb.rb`, exit
status 3), `emit` (a refusal of the emitter, exit status 3, the message names the node refused), and `server`. `diagnostics` is `[{line, severity, message}]`, parsed from EDG's
messages; the page puts them on the editor's lines as markers.

The options are checked against a list: `language` (default `c++`) is one of the table in "Languages", `std` is one of
its standards or empty (the front end's default), and `mode` is one of its modes:

| Mode | Front end | Emitter | Data model |
| --- | --- | --- | --- |
| `lp64` (default) | as is | as is | LP64, i64 pointers |
| `asan` | as is | `--asan` | LP64, with the ASan shadow |
| `emscripten` | `--freestanding --target=linux_riscv32` | `--emscripten` | ILP32, Emscripten's exports |

### Languages

| `language` | Front end | Standards (`std`) | Modes |
| --- | --- | --- | --- |
| `c++` | `pathb-dump --ir` (EDG, C++23 by default) | `c++17`, `c++20`, `c++23` | all |
| `c` | `pathb-dump --ir -std=cNN` (EDG in C mode, `--gcc`, C17 by default) | `c89`, `c99`, `c11`, `c17`, `c23` | all |
| `rust` | `rustc --crate-type=cdylib -C opt-level=1 -C panic=abort -C overflow-checks=on -C lto=fat -C save-temps`, `llvm-dis` of the module after LTO, then `llvm-to-pathb.rb --wasm` | editions `2015`, `2018`, `2021` (default), `2024` | `lp64`, `asan` |
| `go` | `tinygo build -o prog.ll -gc=leaking -scheduler=none -panic=trap -opt=1`, a `main()` wrapper, then `llvm-to-pathb.rb --wasm` | none | `lp64`, `asan` |
| `swift` | `swiftfe emit-c --bindings prog.swift` (tools/swiftfe: LLVM-free, Swift to C), then `pathb-dump --ir` of that C and the emitter | none | `lp64`, `asan` |
| `llvm` | `llvm-to-pathb.rb` (`pathb-llvm.md`: the subset of `clang -S -emit-llvm` it reads) | none | `lp64`, `asan` |
| `ir` | none: the source is the IR (`pathb-stage2.md`, section 6); lines that start with `;` are blanked first | none | `lp64`, `asan` |

Swift (`tools/swiftfe`, its README) is a subset: functions, `Int`, `Bool`, `while`, `if`, classes with
stored properties and methods, and `print`. A class, or an array, needs a heap, which only the `asan` mode has (`lp64`
calls `malloc` as a stub, see the note on it below). Printing a `Double` traps at run time in the browser: its format is
Swift's, which the browser's bindings cannot reproduce. The emitted C is `swiftfe emit-c --bindings`: its runtime
prints through the browser's `putchar` and traps through `abort`. Swift runs on the server only (the static build
compiles its examples ahead of time, with `swiftc`'s expected output checked in `examples/index.json`).

**Known gap, not Swift's:** in the `lp64` mode `malloc` and `free` are imports that the page stubs (`first argument + 1`),
so a C or Swift program that allocates in `lp64` writes through a fake pointer. The result can look right, as a class's
does here by chance, and corrupt data in other cases. Only `asan` provides an allocator. Giving `lp64` one is the fix.


C goes through the same EDG front end and the same IR as C++: `pathb-dump` takes a C standard (`-std=c11`), or a `.c`
file without one, and runs `cpfe --cNN --gcc` (no `-tused`); hosted, its system include directories are the host C
compiler's (`host_sys_includes c`, `gcc -x c`), not the C++ library's. LLVM IR and the IR text carry the LP64 layout
(`llvm-to-pathb.rb` writes the x86-64 one), so the `emscripten` mode, whose IR is ILP32 from EDG's `linux_riscv32`
target, is not theirs.

**Rust** is compiled by rustc (`RUSTC`, else `rustc` on PATH; CI pins 1.97.0) at `-O1`, with overflow checks on and
fat LTO. The crate's own LLVM IR (`--emit=llvm-ir`) is not enough: it calls `core`'s non-generic functions (`str::split`
calls `memchr`), which live in `core`'s compiled library, not in the crate. LTO links the parts of `core` that the program
uses into one module; rustc keeps it with `-C save-temps` (`<crate>.<crate>.<hash>-cgu.0.rcgu.bc`), and the `llvm-dis` of
rustc's own LLVM (`rustup component add llvm-tools`; `LLVM_DIS` names another) turns it into text. What is left
external is the program's bindings and libc's `memcmp`/`bcmp`, which are bindings too. The crate is `#![no_std]`
`#![no_main]`: `main` is an `extern "C"` function that the page calls, the browser
bindings are `extern "C"` declarations, and a panic (an overflow, an index out of range) calls the crate's
`#[panic_handler]`: the examples' handler prints the file and line (`PanicInfo::location`, through `log_str` and
`log_i32`) and calls `abort`, a binding that ends the run. A handler that loops (`loop {}`, the usual `no_std` one) is
stopped by the page's timeout. Enums, slices, iterators, closures, trait
objects (`dyn`) and function pointers work. `-O0` is not used: its code keeps unwinding edges (`invoke`, `resume`),
which the translator refuses. `std` is not available (it needs an operating system the module does not have).

**Go** is compiled by TinyGo (`TINYGO`, else `build/tinygo/bin/tinygo` from `scripts/setup-tinygo.sh`, else `tinygo` on
PATH) for its Linux target, which writes the whole program, runtime included, as one LLVM IR module. The flags: a
leaking heap (`-gc=leaking`: TinyGo's bump allocator, which takes its memory from `mmap`), no goroutines
(`-scheduler=none`), and panics that trap (`-panic=trap`). TinyGo's `main` is the C entry point `main(argc, argv)`;
the pipeline renames it and adds a `main()` that calls it, so the page runs it as any other module. The runtime's
system calls go to bindings (below): `println` and `fmt` print to the Console, `os.Exit(n)` ends the run with
`exit n`, and `time.Now` reads the clock. Interfaces, maps, slices and `append`, strings and `strconv`, closures,
`errors` and `fmt.Println`/`Printf` work; `fmt` makes a module of about 640 KB that takes about 20 s to compile.
Goroutines and channels do not (no scheduler), nor does anything that needs a file system.

LLVM IR needed three things of the emitter that EDG's IR did not: the checked arithmetic (`nsw` becomes `cadd`, `csub`,
`cmul`), `alloca` (each local of `clang -O0`), and the flat control flow graph of labels and gotos, which the emitter now
lowers as a dispatch loop (`pathb-wasm.md`, "What is handled"). So `clang-18 -O0 -S -emit-llvm` output runs when it stays
in the translator's subset. Rust and Go needed more, in the translator (structs and aggregate values, overflow
intrinsics, atomics and system calls under `--wasm`, and others: `pathb-llvm.md`) and in the emitter: function
pointers (a function table and `call_indirect`), `copy` and `zero-fill` of a run-time length, float and integer
`bitcast` (`pathb-wasm.md`). The repository's own Rust front end, mrustc (`mrustc-monomir.md`), is not used: it needs a
build of mrustc and of its standard library (a 270 MB download and minutes of build) that rustc makes unnecessary here.
Cpp2 (`cpp2.md`) is not added: EDG rejects its runtime header in most programs.

Limits: 64 KB of source (413 past it), 60 s per compiler step, two compiles at a time (503 past that). The server listens
on 127.0.0.1 by default, because it runs the compiler on whatever source it is sent. Exposing it needs a process sandbox
and a rate limit, which are not in this change.

## The page

- **Editor**: Monaco 0.52.2 from `cdn.jsdelivr.net/npm/monaco-editor@0.52.2`, with highlighting for the language (C++,
  C, Rust and Go are Monaco's, the IR uses its Scheme mode, LLVM IR a small Monarch tokenizer in the page) and
  diagnostics as markers. If the CDN cannot be reached, the page uses a plain textarea.
- **Ctrl+Enter** (Cmd+Enter on a Mac; Ctrl+Enter works there too) compiles and then runs `main`, in the editor and in
  the textarea. Compile (the button), a change of the options and "auto" only compile. Any compile cancels a pending
  automatic one, so the text an example puts in the editor is compiled once.
- **Console**, under the editor: Run (calls `main` the way `tests/wasm/host.cjs` does: an import without a binding
  returns its first argument plus one), the result (`main`'s value, `exit N`, `abort`, `asan: KIND`, the trap's
  message, `timed out` or `stopped`), Clear, and the output of the last run (the bindings' output: `log_*`, `puts`,
  `putchar`, `write`, Go's `println` and `fmt`; the first MB of it). See "Errors".
- **Options**: the language, the standard and the mode (both filled for the language: a choice the new language also
  has is kept), and "auto" (compile 0.7 s after an edit; live only). The examples are grouped by language, and picking
  one sets its language. Changing the language loads its first example unless the source was edited, so an edited
  source can be compiled as C and as C++.
- **Module** tab: the browser bindings, size, exports, imports, the bytes and the `.wasm` download.
- **WAT** tab: the module as WebAssembly text, converted with `wabt` 1.0.37 (`cdn.jsdelivr.net/npm/wabt@1.0.37`), loaded
  when the tab is first opened, with a `.wat` download.
- **IR** and **Bytes** tabs: the mid-level IR text, and a hex dump of the first KB.
- **Link**: the source, language, mode and standard are in the URL hash (`#src=<base64url>&lang=c&mode=asan&std=c11`).
  A link without `lang` is C++, as the links before the languages were.

## Static build

`build-static.cjs` compiles each example in each mode of its language, runs `main` in node, and fails the build if a result differs
from `expect` in `examples/index.json` or if a compile fails. It writes `_site/`: `index.html`, `examples/` (the sources
and the manifest), `builds/<id>.json` (the sources, IR, wasm and diagnostics per mode), and `.nojekyll`.

On a static host the page reads the manifest and the examples' sources at start, and an example's build
(`builds/<id>.json`) only when it is compiled: `go-fmt`'s is about 4.7 MB. An example's source gets its prebuilt result
(and the default standard only), matched by the source and the language. A mode whose IR is the same as an earlier
mode's (`asan` and `lp64` share theirs) stores it once (`irFrom`). A permalink to an example works.

**Compiling in the page.** When the in-browser compiler is built (`docs/notes/pathb-wasm-frontend.md`: the Path B front
end and mruby, built with Emscripten), the static build writes it to `inbrowser/` (18.5 MB, about 4.8 MB as gzip: the
front end's `cpfe.wasm` is 17.9 MB, mruby's 0.9 MB, EDG's base directory 0.3 MB), and any other source in C++, C, LLVM
IR or the IR is compiled in the page: `compile-worker.js` loads the tools the first time (the page says so in its
status line), and runs `inbrowser.js`, which is `pipeline.cjs`'s compile with the same front end (`cpfe.wasm`, with the
arguments of `pathb-dump --ir`, in Emscripten's in-memory file system) and the same scripts (`llvm-to-pathb.rb`,
`pathb-wasm-emit.rb`, run by `mruby.wasm`). The result is the server's, byte for byte (`test-inbrowser.cjs`: every
example in every mode, and `tests/wasm` and `tests/pathb-ir` the same way, 299 compiles). A compile takes 20 to 200 ms
once the tools are loaded. What it cannot do: Rust and Go (their compilers are not in the page), programs that include
the C or C++ library headers (the page has EDG's own headers only: the error says so), and demangling the frames of a
trap (no `c++filt`). With "auto" (off at first on a static host) an edit compiles as on the live server. Without the
tools, any other source gets a message that it needs the local server.

The workflow builds the harness and the mruby tool as `pathb.yml` does, and the in-browser compiler (Emscripten,
`PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh`, `scripts/setup-mruby-wasm.sh`, each cached), checks it
(`tests/pathb-wasm-frontend/run.sh`, `test-inbrowser.cjs`), runs the static build with `--require-inbrowser` (on pull
requests too, without deploying), and deploys from `main`. The one-time repository setting is Settings > Pages > Source: GitHub
Actions.

**Previews on Cloudflare Workers.** A comment `/preview` on a pull request (alone on its first line, by someone with
write access: the author association OWNER, MEMBER or COLLABORATOR) starts `wasm-explorer-preview.yml`. It builds the
pull request's head with `wasm-explorer-build.yml`, the same reusable workflow that the GitHub Pages workflow uses, and
uploads the site as a new version of an assets-only Worker (`wrangler versions upload --assets site --preview-alias
pr-<number>`, wrangler pinned, from npm). The version is not deployed, so the Worker's own URL
(`nfcxx-preview.take-cheeze.workers.dev`) keeps serving what it served; the preview is the alias's URL,
`https://pr-<number>-nfcxx-preview.take-cheeze.workers.dev`. One comment on the pull request gives it and the version's
own URL, and each `/preview` updates it. The comment that asked gets reactions: eyes when the request is taken, a
rocket when the preview is up, confused when the build or the upload failed.

The build runs the pull request's code (the compiler and the examples), so it has no secrets and only reads the
repository; the deploy job, which sees the Cloudflare token, runs none of it: it uploads the built static files. An
`issue_comment` workflow runs from the default branch, so `/preview` works once the workflow is on `main`. One-time
setup, in the repository's settings (Secrets and variables > Actions), and on the Worker:

| Setting | Kind | Value |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | secret | a Cloudflare API token with Account > Workers Scripts > Edit |
| `CLOUDFLARE_ACCOUNT_ID` | secret | the Cloudflare account's ID |
| `CLOUDFLARE_WORKER_NAME` | variable (optional) | the Worker; default `nfcxx-preview` |
| workers.dev and preview URLs | the Worker's Settings > Domains & Routes | enabled (the default) |

## Checks

- `build-static.cjs` is the check for the examples: 9 examples (C++ and C) x 3 modes and 10 (Rust, Go, LLVM IR and IR)
  x 2 modes, each run and compared with its expected result (and output, where `index.json` states one). The new
  examples' results were worked out by hand and, for C, checked against `gcc` (`c-function-pointers` 1140,
  `c-goto` 933). The Rust and
  Go results were also checked by hand: the Rust example's arithmetic (95 + 24), and the Go one's printed values (95,
  37) and status (132). The C++ results were also checked against `g++ -O0` (modulo 256, the
  process status), the C one against `gcc -std=c11`, and the LLVM IR one against `gcc` of the C it was written from (`clang-18 -O0`
  of that C, translated and emitted, gives the same 88).
- The languages, by hand in a headless Chromium (live and static, with Monaco routed to the npm package): switching
  each language loads its example, fills its standards and modes, sets the editor's language and runs; an example of
  another language switches the language; the link carries `lang`; a refusal of `llvm-to-pathb.rb` shows as refused.
- Checked by hand in a headless Chromium with the CDN routed to the npm packages, since this sandbox cannot reach the
  CDN: live (the examples, the modes, the standard, markers on a syntax error, auto-compile, WAT, the permalink, no
  console errors); static (the examples, the emscripten mode, WAT, the refusal for other code, no console errors); CDN
  blocked (the textarea takes over and the examples still run; WAT says it could not load wabt).
- Error paths on the server: a front-end syntax error, a refusal (`variadic call`), 413, 400, 404.
- No automated test runs the page. The CDN, and the browser, are not in CI.

## Errors

- **Compile errors** of the front end are shown as text and as markers on their lines (`parseDiagnostics` in
  `pipeline.cjs`: EDG's `"prog.cpp", line N: error: ...`, rustc's `--> prog.rs:N:M`, Go's `prog.go:N:M:`).
- **Refusals** of the emitter name the function and the line (`pathb-dump` runs with `NFCXX_IR_LOC=1`, see
  `docs/notes/pathb-wasm.md`): `refused: variadic call (in main, at prog.c:2)` is a marker on line 2, and C++ names in
  the message are demangled with `c++filt` when it is installed. The page adds a hint for the refusals met most
  (`REFUSAL_HINTS` in `index.html`): `printf` (variadic: use `puts` or `log_*`), exceptions and the hosted C++ library,
  structs by value, VLAs, `goto` across loops, switch fallthrough, the C library's globals, wide types.
- **Run-time errors**: `main` runs in a Web Worker (`bindings.js`, `runMain`), so a program that does not return does
  not freeze the page: Run becomes Stop while it runs, and a run is stopped after 10 s. A trap is shown with what it
  means for the source (`explainTrap`: `unreachable` is a failed check or a panic, `divide by zero`, `integer
  overflow`, `memory access out of bounds`, a bad indirect call, stack exhaustion) and the wasm stack, innermost first:
  the module has a `name` section (`--names`), and the compile result's `names` (`c++filt` over the IR's mangled
  names, without Rust's hashes) turns `_Z4deepi` into `deep(int)`. An `--asan` report prints the kind of the bad access
  (`AddressSanitizer: heap-buffer-overflow: access of 4 byte(s) at 0x...`) before the trap.
- The static build runs each example with the same `runMain` and fails on any end other than a value or `exit N`.

## Browser bindings

A module's imports (functions of module `env` that the program declares and does not define) are connected to browser
features by name. The table is `BINDINGS` in `bindings.js`; the page lists it in the Module tab, and each import of the
module is marked "browser binding" or "stub" in the imports table. A stub returns its first argument plus one, as before.

| Declaration (C) | Browser feature |
| --- | --- |
| `void log_i32(int)` | the Console tab (the value) |
| `void log_i64(long)` | the Console tab (the value, as a BigInt) |
| `void log_f64(double)` | the Console tab |
| `void log_str(const char* s, long length)` | the Console tab (UTF-8 read from the module's memory) |
| `double now_ms()` | `performance.now()` |
| `double random_f64()` | `Math.random()` |
| `void set_title(const char* s, long length)` | `document.title`, restored after Run |
| `int putchar(int)`, `int puts(const char*)` | stdout: the Console tab (`putchar` shows a line when it ends) |
| `int write(int fd, const void* buf, unsigned long n)` | fd 1 is stdout; fd 2 is shown as `[stderr]` |
| `int fflush(void*)` | shows what `putchar` has left waiting |
| `void exit(int status)` | ends the run, whose result is `exit N` (C's `exit`, Go's `os.Exit`) |
| `void abort(void)` | ends the run, whose result is `abort` (the Rust examples' panic handler) |
| `void __asan_report(void*, long, int)` | the `--asan` mode's report of a bad access, printed before the trap |
| `void* mmap(...)` | `memory.grow` by the pages of the size asked: TinyGo's heap, after everything the module laid out |
| `int clock_gettime(int, struct timespec*)` | `performance.timeOrigin + performance.now()` (Go's `time.Now`) |
| `ssize_t getrandom(void*, size_t, unsigned)` | `crypto.getRandomValues` |
| `size_t strlen(const char*)` | the length of the C string in memory |
| `long __syscall(long nr, ...)` | a Linux system call (`llvm-to-pathb.rb --wasm`): `write` as the binding above, `exit` and `exit_group` as `exit`, `getpid` is 1, the others fail with `ENOSYS` (TinyGo's `os`) |

The JavaScript side of an import cannot see its signature, and an import with an i64 result must return a BigInt, so
`importsFor` reads the result types from the module's type and import sections and converts each binding's (and each
stub's) value.

The emitter passes an i32 as a Number, an i64 or an LP64 pointer as a BigInt, and an f64 as a Number. A return value must
match the declared type. The Console tab shows the output of the last Run. The example `browser-bindings` uses the first seven and returns 3 whatever the timer and random values are. The example
`stdout` uses the stdio ones and returns 0. Both examples state their expected output in `examples/index.json`, and the
static build checks it. Both the live
and the static page run it with the bindings connected (checked in headless Chromium).

`printf` and `std::cout` are not bound. A call to `printf` is variadic, and the emitter refuses variadic calls, so `printf`
needs variadic lowering in the emitter first. `std::cout` needs the hosted C++ library, whose calls the emitter refuses in
most of its code. The example declares `puts`, `putchar`, `write` and `fflush` by hand, which also builds in the
freestanding `emscripten` mode.

Not done: DOM elements and canvas drawing (the module would write a display list into its memory for the page to
read), fetch and timers that call back into the module (the emitter has no function table, so a callback needs one),
and input events.

## Compiler Explorer features

| Feature | Status | Notes |
| --- | --- | --- |
| Editor with highlighting and diagnostics | done | Monaco, from the CDN. |
| Compile on edit, and on demand | done | Auto on the live server only. |
| Examples | done (19) | Each checked in every mode of its language at build time. |
| Several languages | done (6) | C++, C, Rust, Go, LLVM IR, the IR. See "Languages". |
| Options: standard, emitter mode | done | `pipeline.cjs` takes them. |
| Run the output | done | `main`; imports bound to browser features (see "Browser bindings"), others stubbed. |
| Compiler errors | done | Text, and markers on the lines. |
| WAT (text format) | done | `wabt`, from the CDN. |
| IR, bytes, download | done | |
| Shareable links | done | Source and options in the hash. |
| Static deployment | done | GitHub Pages and Cloudflare previews. C, C++, LLVM IR and the IR compile in the page (wasm); Rust and Go: the examples only. |
| Other stages (the C from `--emit-c`, the QBE asm) | not done | Needs the Path A build (`setup-edg.sh`), a second pipeline. |
| Side-by-side comparison, diff | not done | Two modes or two backends in two panels. |
| Compiler flags beyond the standard (`-D`, `-I`, `--target`) | not done | Include directories must be limited to the repo, not free paths. |
| Source-to-output mapping | partly done | A `name` section (stack traces name the functions), and refusals name the line. No line table. |
| Run-time errors | done | A worker with a timeout and Stop; traps explained, with the demangled wasm stack. See "Errors". |
| Program output (stdout) | partly done | `puts`, `putchar`, `write` and `fflush` go to the Console tab. `printf` and `std::cout` do not: the emitter refuses variadic calls and most of the hosted C++ library. |
| Libraries (`<vector>`, `<string>`) | limited by the emitter | The emitter refuses exceptions, variadic calls, indirect calls, `goto` mixed with loops, bit-fields, VLAs and 16-byte types. In the IR sweep, 199 of 306 files are refused. The page shows these refusals. |
| Several compilers | not applicable | One backend. |
| Accounts, saved snippets | not planned | |

## 64-bit wasm (memory64)

Addable, and the data model already fits it. The IR is LP64 (pointers and `long` 8 bytes), which is the model a 64-bit
wasm module needs. What is 32-bit today is the memory's address type: `addr32` wraps every pointer to `i32`
(`i32.wrap_i64`) and the memory is declared with a 32-bit limit. The memory64 proposal makes the address `i64`.

Checked in this environment: Node 22 (V8) instantiates a module whose memory has the i64 index type (limits flag
`0x04`) without a flag, and a function `f(addr: i64) -> i32 { return i32.load(addr) }` reads at a BigInt address, while
a Number address is a TypeError. So the change can be tested here.

Implemented: `scripts/pathb-wasm-emit.rb --memory64` (see `pathb-wasm.md`, "Memory64"). The plan above held with two
changes. The address is taken as the i64 pointer (`push_addr`, no wrap), and `memory.copy` takes i64 lengths. The
stack pointer stays i32 (point 3): the memory is far below 4 GB, so a slot's address is extended to i64 only where it is
used as an address. `--asan` and `--emscripten` are refused with `--memory64`, as the plan says.

Tests: `NFCXX_WASM_MEMORY64=1 tests/wasm/run.sh` emits every module in the mode and checks the same results, and
`memory64_high_address.cpp` checks that an address above 2^32 traps. A static object above 4 GB was not tried. Whether an
Emscripten `MEMORY64` runtime accepts the module was not checked.
