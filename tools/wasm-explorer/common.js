// The wasm explorer's tables and parsers shared by the server's pipeline (pipeline.cjs), the browser's
// (inbrowser.js) and the page: the modes, the languages, the option check, and the diagnostics parser. Loaded with
// require (node), a <script> tag or importScripts (a worker); in a page it is window.nfcxxCommon.
(function (root) {
  "use strict";

  // The modes: the data model of the IR (pathb-dump) and the emitter's flags. Each name is a value of the page's
  // "mode" option; the emitter flags are documented at the top of scripts/pathb-wasm-emit.rb.
  const MODES = {
    lp64: { dump: [], emit: [], title: "LP64 (x86-64 data model, i64 pointers)" },
    asan: { dump: [], emit: ["--asan"], title: "LP64 with the AddressSanitizer shadow" },
    emscripten: {
      dump: ["--freestanding", "--target=linux_riscv32"],
      emit: ["--emscripten"],
      title: "ILP32 (wasm32 layout, Emscripten exports)",
    },
  };
  // The source languages: the file the source is written to, the standards the front end takes ("" is always allowed,
  // the front end's default), and the modes. LLVM IR and the IR text carry their own data model, LP64 (llvm-to-pathb.rb
  // writes the x86-64 layout), so the ILP32 mode, whose IR comes from EDG's linux_riscv32 target, is not theirs.
  const LANGUAGES = {
    "c++": { title: "C++", file: "prog.cpp", standards: ["c++17", "c++20", "c++23"], modes: Object.keys(MODES) },
    c: { title: "C", file: "prog.c", standards: ["c89", "c99", "c11", "c17", "c23"], modes: Object.keys(MODES) },
    llvm: { title: "LLVM IR", file: "prog.ll", standards: [], modes: ["lp64", "asan"] },
    swift: { title: "Swift", file: "prog.swift", standards: [], modes: ["lp64", "asan"] },
    rust: { title: "Rust", file: "prog.rs", standards: ["2015", "2018", "2021", "2024"], modes: ["lp64", "asan"] },
    go: { title: "Go", file: "prog.go", standards: [], modes: ["lp64", "asan"] },
    ir: { title: "nfcxx IR", file: "prog.ir", standards: [], modes: ["lp64", "asan"] },
  };
  // The C++ standards (pathb-dump -std=c++NN), as before the languages.
  const STANDARDS = LANGUAGES["c++"].standards;
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

  // Returns an error message for options the pipeline does not take, else null.
  function checkOptions(options) {
    if (options.language !== undefined && !has(LANGUAGES, options.language)) {
      return `unknown language: ${options.language}`;
    }
    const lang = LANGUAGES[options.language || "c++"];
    if (options.mode !== undefined && !has(MODES, options.mode)) {
      return `unknown mode: ${options.mode}`;
    }
    if (options.mode !== undefined && !lang.modes.includes(options.mode)) {
      return `mode ${options.mode} is not available for ${lang.title} (${lang.modes.join(", ")})`;
    }
    if (options.std !== undefined && options.std !== "" && !lang.standards.includes(options.std)) {
      return `unknown standard for ${lang.title}: ${options.std}`;
    }
    return null;
  }

  // The IR text has no comments; the page's IR sources may have ; lines, which become empty lines (so line numbers
  // stay).
  function stripIrComments(source) {
    return source.split("\n").map((line) => (/^\s*;/.test(line) ? "" : line)).join("\n");
  }

  // EDG's diagnostics: `"prog.cpp", line 1: error: expected an expression`. A line that does not match is part of the
  // message above it, so it is not a diagnostic of its own. rustc's: `error[E0425]: cannot find value` and, below it,
  // ` --> prog.rs:3:5`. Go's (tinygo): `./prog.go:3:5: undefined: x`.
  function parseDiagnostics(text) {
    const out = [];
    let pending = null;   // rustc: the severity and message waiting for their --> line
    for (const line of text.split("\n")) {
      const m = /line (\d+): (catastrophic error|error|warning|remark): (.*)$/.exec(line);
      if (m) {
        out.push({ line: Number(m[1]), severity: m[2] === "catastrophic error" ? "error" : m[2],
          message: m[3].trim() });
        continue;
      }
      const r = /^(error|warning)(?:\[\w+\])?: (.*)$/.exec(line);
      if (r) {
        pending = { severity: r[1], message: r[2].trim() };
        continue;
      }
      const at = /^\s*--> prog\.rs:(\d+):\d+/.exec(line);
      if (at && pending) {
        out.push({ line: Number(at[1]), severity: pending.severity, message: pending.message });
        pending = null;
        continue;
      }
      // a refusal of the wasm emitter, located (NFCXX_IR_LOC): "refused: variadic call (in main, at prog.c:6)"
      const r2 = /^refused: (.*) \(in (.+?), at prog\.[a-z+]+:(\d+)\)$/.exec(line);
      if (r2) {
        out.push({ line: Number(r2[3]), severity: "error",
          message: `not supported by the wasm emitter: ${r2[1]} (in ${r2[2]})` });
        continue;
      }
      // a Swift program's error (swiftfe, tools/swiftfe): "prog.swift:3:7: error: this expression is not supported in M2"
    const sw = /^prog\.swift:(\d+):\d+: (error|warning): (.*)$/.exec(line);
    if (sw) {
      out.push({ line: Number(sw[1]), severity: sw[2], message: sw[3].trim() });
      continue;
    }
    const g = /prog\.go:(\d+):\d+: (.*)$/.exec(line);
      if (g) out.push({ line: Number(g[1]), severity: "error", message: g[2].trim() });
    }
    return out;
  }

  const api = { MODES, LANGUAGES, STANDARDS, checkOptions, stripIrComments, parseDiagnostics };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.nfcxxCommon = api;
})(typeof self !== "undefined" ? self : this);
