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
  function makeContext(sink) {
    const pending = [];
    const ctx = {
      mem: sink.memory,
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
        if (typeof document !== "undefined") document.title = decode(readBytes(ctx.mem, ptr, len));
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
  };

  // The binding of an import, or null (a stub).
  function bindingFor(name, kind) {
    return kind === "function" && Object.prototype.hasOwnProperty.call(BINDINGS, name) ? BINDINGS[name] : null;
  }

  // The import object of a module: each function import is connected to its binding, or stubbed. A non-function import
  // has nothing to connect to, so it is an error.
  function importsFor(module, ctx) {
    const imports = {};
    for (const imp of WebAssembly.Module.imports(module)) {
      if (imp.kind !== "function") throw new Error(`import ${imp.module}.${imp.name} (${imp.kind}) is not provided by this page`);
      const b = bindingFor(imp.name, imp.kind);
      imports[imp.module] = imports[imp.module] || {};
      imports[imp.module][imp.name] = b ? (...args) => b.fn(ctx, ...args) : (x) => (Number(x) | 0) + 1;
    }
    return imports;
  }

  const api = { BINDINGS, makeContext, bindingFor, importsFor };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.nfcxxBindings = api;
})(typeof self !== "undefined" ? self : this);
