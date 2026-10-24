// The browser bindings of the wasm explorer: the functions a module can import (module "env") and the browser feature
// each one is connected to. Shared by the page (index.html, which loads it as a script) and the static build
// (build-static.cjs, which requires it), so an example is checked with the bindings the page runs it with.
//
// A program declares a binding in extern "C" and calls it; the emitter makes the call an import. The arguments arrive
// as the emitter passes them: i32 as a Number, i64 and LP64 pointers as a BigInt, f64 as a Number. A return value must
// match the declared type. An import without a binding is a stub: it returns its first argument plus one.
(function (root) {
  "use strict";

  const decode = (bytes) => new TextDecoder().decode(bytes);
  const readBytes = (mem, ptr, len) => new Uint8Array(mem().buffer, Number(ptr), Number(len));
  function readCString(mem, ptr) {
    const view = new Uint8Array(mem().buffer);
    let end = Number(ptr);
    while (view[end] !== 0) end++;
    return decode(view.subarray(Number(ptr), end));
  }

  // The output of one Run. sink.write(text) takes the text in order; bytes from putchar wait for a newline (or for the
  // end of the run, ctx.flush), so a multi-byte character is not split. sink.memory() is the module's exported memory.
  // sink.title(text), when given, sets the page's title (a worker has no document of its own).
  function makeContext(sink) {
    const pending = [];
    const ctx = {
      mem: sink.memory,
      title: sink.title || null,
      asan: null,   // the last AddressSanitizer report: { kind, addr, size }
      text(s) {
        ctx.flush();
        sink.write(s);
      },
      log(line) {
        ctx.text(line + "\n");
      },
      putByte(b) {
        pending.push(b);
        if (b === 10) ctx.flush();
      },
      flush() {
        if (pending.length) {
          sink.write(decode(Uint8Array.from(pending)));
          pending.length = 0;
        }
      },
    };
    return ctx;
  }

  const BINDINGS = {
    log_i32: { decl: "void log_i32(int value);", feature: "console: prints the value",
      fn: (ctx, v) => ctx.log(String(Number(v) | 0)) },
    log_i64: { decl: "void log_i64(long long value);", feature: "console: prints the value (BigInt)",
      fn: (ctx, v) => ctx.log(String(v)) },
    log_f64: { decl: "void log_f64(double value);", feature: "console: prints the value",
      fn: (ctx, v) => ctx.log(String(v)) },
    log_str: { decl: "void log_str(const char* s, long length);", feature: "console: prints the UTF-8 string from memory",
      fn: (ctx, ptr, len) => ctx.log(decode(readBytes(ctx.mem, ptr, len))) },
    now_ms: { decl: "double now_ms();", feature: "performance.now(): milliseconds since the page loaded",
      fn: () => performance.now() },
    random_f64: { decl: "double random_f64();", feature: "Math.random(): a number in [0, 1)",
      fn: () => Math.random() },
    set_title: { decl: "void set_title(const char* s, long length);", feature: "document.title (restored after Run)",
      fn: (ctx, ptr, len) => {
        const text = decode(readBytes(ctx.mem, ptr, len));
        if (ctx.title) ctx.title(text);
        else if (typeof document !== "undefined") document.title = text;
      } },
    putchar: { decl: "int putchar(int c);", feature: "stdout: one byte, shown at the end of its line",
      fn: (ctx, c) => {
        ctx.putByte(Number(c) & 0xff);
        return Number(c) | 0;
      } },
    puts: { decl: "int puts(const char* s);", feature: "stdout: the string and a newline",
      fn: (ctx, s) => {
        ctx.log(readCString(ctx.mem, s));
        return 1;
      } },
    write: { decl: "int write(int fd, const void* buf, unsigned long n);",
      feature: "fd 1 is stdout; fd 2 is stderr, marked [stderr]",
      fn: (ctx, fd, buf, n) => {
        const text = decode(readBytes(ctx.mem, buf, n));
        ctx.text(Number(fd) === 2 ? "[stderr] " + text : text);
        return Number(n) | 0;
      } },
    fflush: { decl: "int fflush(void* stream);", feature: "stdout: shows the bytes waiting for their line",
      fn: (ctx) => {
        ctx.flush();
        return 0;
      } },
    // The C library functions that TinyGo's runtime calls (the Go language): its heap, its clock, its random seed.
    mmap: { decl: "void* mmap(void* addr, size_t n, int prot, int flags, int fd, off_t off);",
      feature: "memory.grow: n bytes of new pages (TinyGo's heap)",
      fn: (ctx, addr, n) => {
        const memory = ctx.mem();
        const old = memory.grow(Math.ceil(Number(n) / 65536));
        return BigInt(old * 65536);
      } },
    clock_gettime: { decl: "int clock_gettime(int clock, struct timespec* t);", feature: "performance.now() (time.Now)",
      fn: (ctx, clock, t) => {
        const ns = BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));
        const view = new DataView(ctx.mem().buffer, Number(t), 16);
        view.setBigInt64(0, ns / 1000000000n, true);
        view.setBigInt64(8, ns % 1000000000n, true);
        return 0;
      } },
    getrandom: { decl: "ssize_t getrandom(void* buf, size_t n, unsigned flags);", feature: "crypto.getRandomValues",
      fn: (ctx, buf, n) => {
        crypto.getRandomValues(readBytes(ctx.mem, buf, n));
        return Number(n);
      } },
    memcmp: { decl: "int memcmp(const void* a, const void* b, size_t n);", feature: "compares the bytes in memory",
      fn: (ctx, a, b, n) => compareBytes(ctx, a, b, n) },
    bcmp: { decl: "int bcmp(const void* a, const void* b, size_t n);",
      feature: "compares the bytes in memory (Rust's slice and str equality)",
      fn: (ctx, a, b, n) => compareBytes(ctx, a, b, n) },
    strlen: { decl: "size_t strlen(const char* s);", feature: "the length of the C string in memory",
      fn: (ctx, s) => {
        const view = new Uint8Array(ctx.mem().buffer);
        let end = Number(s);
        while (view[end] !== 0) end++;
        return end - Number(s);
      } },
    __syscall: { decl: "long __syscall(long nr, long a1, ..., long a6);",
      feature: "a Linux system call (llvm-to-pathb.rb --wasm): write (1) as the write binding, exit and exit_group "
        + "(60, 231) as exit, getpid (39) is 1, the others fail with ENOSYS",
      fn: (ctx, nr, a1, a2, a3) => {
        switch (Number(nr)) {
          case 1: return BigInt(BINDINGS.write.fn(ctx, a1, a2, a3));
          case 39: return 1n;
          case 60: case 231: throw new Exit(Number(a1) | 0);
          default: return -38n;
        }
      } },
    abort: { decl: "void abort(void);", feature: "ends the run as aborted (a Rust example's panic handler calls it)",
      fn: () => {
        throw new Abort();
      } },
    __asan_report: { decl: "void __asan_report(void* addr, long size, int code);",
      feature: "the ASan mode's report of a bad access, printed with its kind, before the module traps",
      fn: (ctx, addr, size, code) => {
        const kind = ASAN_KINDS[Number(code)] || `unknown-0x${Number(code).toString(16)}`;
        const at = "0x" + (Number(addr) >>> 0).toString(16);
        ctx.asan = { kind, addr: at, size: Number(size) };
        const what = Number(code) === 0x102 ? `malloc of ${Number(addr) >>> 0} byte(s)`
          : Number(code) >= 0x100 ? `free of ${at}` : `access of ${Number(size)} byte(s) at ${at}`;
        ctx.log(`AddressSanitizer: ${kind}: ${what}`);
      } },
    exit: { decl: "void exit(int status);", feature: "ends the run; the result is the status (Go's os.Exit)",
      fn: (ctx, status) => {
        throw new Exit(Number(status) | 0);
      } },
  };

  // memcmp: the sign of the first differing byte (unsigned), or 0.
  function compareBytes(ctx, a, b, n) {
    const x = readBytes(ctx.mem, a, n);
    const y = readBytes(ctx.mem, b, n);
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
    return 0;
  }

  // The kinds of the ASan mode's reports: the poison codes of the shadow (scripts/pathb-wasm-emit.rb, ASAN_*) and the
  // allocator's own codes (0x100 and up), as tests/wasm/host.cjs prints them.
  const ASAN_KINDS = {
    0xf1: "stack-buffer-overflow", 0xf9: "global-buffer-overflow", 0xf5: "stack-use-after-return",
    0xfa: "heap-buffer-overflow", 0xfd: "heap-use-after-free",
    0x100: "attempting-double-free", 0x101: "attempting-free-on-address-which-was-not-malloc",
    0x102: "allocator-out-of-memory",
  };

  // Thrown by the abort binding.
  class Abort extends Error {
    constructor() {
      super("abort() called");
    }
  }

  // What a trap's message (V8's or Firefox's wording) means for the source program.
  const TRAPS = [
    [/unreachable/i, "a check failed (a checked overflow, a shift or an index out of range, a null pointer), a panic "
      + "(Go's, or a Rust panic handler that traps), or code the compiler knows is never reached"],
    [/divi(de|sion) by zero|divide by zero/i, "an integer division or remainder by zero"],
    [/integer overflow/i, "INT_MIN / -1, or a float converted to an integer type that cannot hold it"],
    [/float unrepresentable|unrepresentable/i, "a float converted to an integer type that cannot hold it (or NaN)"],
    [/memory access out of bounds|out of bounds memory/i, "a load or store outside the module's memory: a wild or "
      + "dangling pointer (the ASan mode reports most bad accesses where they happen)"],
    [/null function|signature mismatch|indirect call/i, "a call through a null function pointer, or one whose type does "
      + "not match the function's"],
    [/table index is out of bounds|index out of bounds/i, "a call through a function pointer that is not a function of "
      + "the module"],
    [/call stack|stack size|too much recursion/i, "the call stack ran out: very deep or infinite recursion"],
  ];
  function explainTrap(message) {
    const t = TRAPS.find(([re]) => re.test(message));
    return t ? t[1] : null;
  }

  // The wasm functions of an error's stack, innermost first (the module's "name" section names them).
  function wasmFrames(stack) {
    const out = [];
    for (const line of String(stack || "").split("\n")) {
      const v8 = /at (\S+) \(wasm:\/\//.exec(line);            // V8: at main (wasm://wasm/1234:wasm-function[2]:0x40)
      const ff = /^(\S+)@.*wasm-function\[/.exec(line);         // Firefox: main@... wasm-function[2]:0x40
      const name = v8 ? v8[1] : ff ? ff[1] : null;
      if (name) out.push(name);
    }
    return out;
  }

  // Runs main() of a module: instantiates it with the bindings, calls main, and says how the run ended.
  //   { kind: "value", result }              main returned (result is its value, as text)
  //   { kind: "exit", result: "exit N" }     the exit binding
  //   { kind: "asan", result: "asan: KIND" } an ASan report, then the trap
  //   { kind: "abort", result: "abort" }     the abort binding
  //   { kind: "trap", result: "trap: MSG", explain, frames }   a trap of the engine (frames: the wasm stack)
  //   { kind: "error", result: MSG }         anything else (an import the page does not provide)
  // sink: { write(text), title(text)? }.
  function runMain(module, bytes, sink) {
    let memory = null;
    const ctx = makeContext({ write: sink.write, memory: () => memory, title: sink.title });
    let out;
    try {
      const instance = new WebAssembly.Instance(module, importsFor(module, ctx, bytes));
      memory = instance.exports.memory || null;
      if (typeof instance.exports.main !== "function") throw new Error("the module has no main export");
      out = { kind: "value", result: String(instance.exports.main()) };
    } catch (e) {
      const message = String((e && e.message) || e);
      if (e instanceof Exit) out = { kind: "exit", result: `exit ${e.status}` };
      else if (ctx.asan) out = { kind: "asan", result: `asan: ${ctx.asan.kind}`, frames: wasmFrames(e && e.stack) };
      else if (e instanceof Abort) out = { kind: "abort", result: "abort", frames: wasmFrames(e && e.stack) };
      else if (e instanceof WebAssembly.RuntimeError || e instanceof RangeError) {
        out = { kind: "trap", result: `trap: ${message}`, explain: explainTrap(message), frames: wasmFrames(e.stack) };
      } else out = { kind: "error", result: message };
    } finally {
      ctx.flush();
    }
    return out;
  }

  // Thrown by the exit binding through the module's frames; a run that catches it reports the status as its result.
  class Exit extends Error {
    constructor(status) {
      super(`exit ${status}`);
      this.status = status;
    }
  }

  // The result types of the module's function imports, by "module.name": "i32", "i64", "f32", "f64" or null (none).
  // JavaScript does not see an import's signature, and a binding or stub must return a BigInt to an i64 result, so
  // they are read from the type section (1) and the import section (2) of the bytes.
  function importResults(bytes) {
    const out = {};
    const types = [];
    let pos = 8;
    const u = () => {
      let r = 0, shift = 0, b;
      do { b = bytes[pos++]; r += (b & 0x7f) * 2 ** shift; shift += 7; } while (b & 0x80);
      return r;
    };
    const name = () => {
      const n = u();
      const text = new TextDecoder().decode(bytes.subarray(pos, pos + n));
      pos += n;
      return text;
    };
    const VT = { 0x7f: "i32", 0x7e: "i64", 0x7d: "f32", 0x7c: "f64" };
    while (pos < bytes.length) {
      const id = bytes[pos++];
      const size = u();
      const end = pos + size;
      if (id === 1) {
        for (let n = u(); n > 0; n--) {
          pos++;                                   // 0x60, a function type
          const params = u();
          pos += params;                           // the parameter types
          const results = u();
          types.push(results ? VT[bytes[pos]] : null);
          pos += results;
        }
      } else if (id === 2) {
        for (let n = u(); n > 0; n--) {
          const key = name() + "." + name();
          const kind = bytes[pos++];
          if (kind === 0) out[key] = types[u()];
          else if (kind === 1) { pos++; const f = bytes[pos++]; u(); if (f & 1) u(); }        // table
          else if (kind === 2) { const f = bytes[pos++]; u(); if (f & 1) u(); }              // memory
          else { pos += 2; }                                                                  // global
        }
      }
      pos = end;
    }
    return out;
  }

  // A JavaScript value as the wasm result type t.
  function asResult(t, v) {
    if (t === "i64") return typeof v === "bigint" ? BigInt.asIntN(64, v) : BigInt(Math.trunc(Number(v) || 0));
    if (t === "i32") return Number(v) | 0;
    if (t === "f32" || t === "f64") return Number(v);
    return undefined;
  }

  // The binding of an import, or null (a stub).
  function bindingFor(name, kind) {
    return kind === "function" && Object.prototype.hasOwnProperty.call(BINDINGS, name) ? BINDINGS[name] : null;
  }

  // The import object of a module: each function import is connected to its binding, or stubbed. A non-function import
  // has nothing to connect to, so it is an error. With the module's bytes, each result is converted to the import's
  // result type (a BigInt for i64); without them a binding's value is returned as it is.
  function importsFor(module, ctx, bytes) {
    const imports = {};
    const results = bytes ? importResults(bytes) : {};
    for (const imp of WebAssembly.Module.imports(module)) {
      if (imp.kind !== "function") throw new Error(`import ${imp.module}.${imp.name} (${imp.kind}) is not provided by this page`);
      const b = bindingFor(imp.name, imp.kind);
      const t = results[imp.module + "." + imp.name];
      const fn = b ? (...args) => b.fn(ctx, ...args) : (x) => (Number(x) | 0) + 1;
      imports[imp.module] = imports[imp.module] || {};
      imports[imp.module][imp.name] = t === undefined ? fn : (...args) => asResult(t, fn(...args));
    }
    return imports;
  }

  const api = { BINDINGS, Exit, Abort, makeContext, bindingFor, importsFor, importResults, runMain, explainTrap, wasmFrames };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.nfcxxBindings = api;
})(typeof self !== "undefined" ? self : this);
