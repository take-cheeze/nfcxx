// The wasm explorer's compile pipeline, shared by the local server (server.cjs) and the static build (build-static.cjs).
// A compile runs, in a fresh temporary directory, a front end to the mid-level IR (docs/notes/pathb-stage2.md), then
// the emitter. The front end depends on the source language (LANGUAGES):
//   C++, C      scripts/pathb-dump --ir [-std=...] [mode] prog.cpp|prog.c   (EDG, in C++ or C mode)
//   LLVM IR     scripts/mrb scripts/llvm-to-pathb.rb prog.ll                (docs/notes/pathb-llvm.md)
//   Rust        rustc --emit=llvm-ir -C opt-level=1 ... prog.rs, then llvm-to-pathb.rb --wasm
//   Go          tinygo build -o prog.ll -gc=leaking -scheduler=none ... prog.go, a main() wrapper, then the same
//   nfcxx IR    none: the source is the IR
//   then        scripts/mrb scripts/pathb-wasm-emit.rb [mode] prog.ir        the wasm module, in the binary format
// They need the Path B harness and the mruby tool (scripts/setup-pathb.sh, scripts/setup-mruby.sh). The compiler is a
// native program: it runs where this module runs, and the module it returns runs in the browser.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const pathbDump = path.join(root, "scripts", "pathb-dump");
const mrb = path.join(root, "scripts", "mrb");
const emitter = path.join(root, "scripts", "pathb-wasm-emit.rb");
const llvmToPathb = path.join(root, "scripts", "llvm-to-pathb.rb");
// rustc and tinygo: RUSTC and TINYGO name them, else build/tinygo (scripts/setup-tinygo.sh) or the PATH. tinygo runs go.
// A path in RUSTC or TINYGO is taken from the caller's directory (tinygo runs in the temporary one); a bare name is
// looked up on the PATH.
const tool = (value) => (value.includes(path.sep) ? path.resolve(value) : value);
const rustc = tool(process.env.RUSTC || "rustc");
const bundledTinygo = path.join(root, "build", "tinygo", "bin", "tinygo");
const tinygo = tool(process.env.TINYGO || (fs.existsSync(bundledTinygo) ? bundledTinygo : "tinygo"));

const MAX_SOURCE = 64 * 1024;   // bytes of source per request
const STEP_TIMEOUT = 60000;     // ms per compiler step

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

// The IR text has no comments; the page's IR sources may have ; lines, which become empty lines (so line numbers stay).
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
      out.push({ line: Number(m[1]), severity: m[2] === "catastrophic error" ? "error" : m[2], message: m[3].trim() });
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
    const g = /prog\.go:(\d+):\d+: (.*)$/.exec(line);
    if (g) out.push({ line: Number(g[1]), severity: "error", message: g[2].trim() });
  }
  return out;
}

// TinyGo's main is the C entry point, main(argc, argv), which runs the Go program. The page calls main(), so it is
// renamed and called by a main of no arguments that returns its status.
function wrapGoMain(ll) {
  const m = /^define [^@\n]*\b(i32|i64) @main\(/m.exec(ll);
  if (!m) return ll;
  const t = m[1];
  return ll.replace(/@main\(/g, "@__nfcxx_go_main(") + `
define i32 @main() {
entry:
  %r = call ${t} @__nfcxx_go_main(i32 0, ptr null)
${t === "i64" ? "  %s = trunc i64 %r to i32\n  ret i32 %s" : "  ret i32 %r"}
}
`;
}

// Runs a step; resolves with { stdout: Buffer, stderr: string }, or rejects with { stage, message, code, stderr }.
// cwd is the repository root, or the temporary directory for a compiler that names files relative to it (tinygo).
function runStep(stage, file, argv, dir, cwd = root) {
  return new Promise((resolve, reject) => {
    execFile(file, argv, { cwd, timeout: STEP_TIMEOUT, encoding: "buffer", maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const text = String(stderr || "").split(dir + path.sep).join("");   // diagnostics name the temporary file
        if (!err) return resolve({ stdout, stderr: text });
        if (err.code === "ENOENT") {
          // a compiler that is not installed: rustc (Rust), or tinygo and go (Go); see docs/notes/wasm-explorer.md
          return reject({ stage, message: `${path.basename(file)} is not installed here (see docs/notes/wasm-explorer.md)`,
            stderr: "", code: null });
        }
        reject({
          stage,
          message: text.trim() || (err.killed ? "timed out" : err.message),
          stderr: text,
          code: typeof err.code === "number" ? err.code : null,
        });
      });
  });
}

// Compiles source with options { language, std, mode }. Resolves with
//   { ok: true, ir, wasm (base64), diagnostics, language, mode, std }   or
//   { ok: false, stage, message, diagnostics, code }                    (stage: request, front-end, emit, or server)
async function compile(source, options = {}) {
  const bad = checkOptions(options);
  if (bad) return { ok: false, stage: "request", message: bad, diagnostics: [] };
  if (typeof source !== "string") return { ok: false, stage: "request", message: "source must be a string", diagnostics: [] };
  if (Buffer.byteLength(source) > MAX_SOURCE) {
    return { ok: false, stage: "request", message: `source is over ${MAX_SOURCE} bytes`, diagnostics: [] };
  }
  const language = options.language || "c++";
  const mode = options.mode || "lp64";
  const std = options.std || "";
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nfcxx-explorer-"));
  const failed = (e) => (
    { ok: false, stage: e.stage, message: e.message, diagnostics: parseDiagnostics(e.stderr), code: e.code });
  try {
    const src = path.join(dir, LANGUAGES[language].file);
    const ir = path.join(dir, "prog.ir");
    let irText;
    let frontStderr = "";
    if (language === "ir") {
      irText = Buffer.from(stripIrComments(source));
    } else {
      fs.writeFileSync(src, source);
      let step;
      try {
        if (language === "rust" || language === "go") {
          // the compiler writes LLVM IR, which llvm-to-pathb.rb translates (for a wasm module: --wasm)
          const ll = path.join(dir, "prog.ll");
          const compiled = language === "rust"
            ? await runStep("front-end", rustc, ["--crate-type=cdylib", "--emit=llvm-ir", `--edition=${std || "2021"}`,
              "-C", "opt-level=1", "-C", "panic=abort", "-C", "overflow-checks=on", "-C", "codegen-units=1",
              "-o", ll, src], dir)
            : await runStep("front-end", tinygo, ["build", "-o", ll, "-gc=leaking", "-scheduler=none", "-panic=trap",
              "-opt=1", "-no-debug", "./prog.go"], dir, dir);
          frontStderr = compiled.stderr;
          if (language === "go") fs.writeFileSync(ll, wrapGoMain(fs.readFileSync(ll, "utf8")));
          step = [mrb, [llvmToPathb, "--wasm", ll]];
        } else if (language === "llvm") {
          step = [mrb, [llvmToPathb, src]];
        } else {
          step = [pathbDump, ["--ir", ...(std ? [`-std=${std}`] : []), ...MODES[mode].dump, src]];
        }
        const dumped = await runStep("front-end", step[0], step[1], dir);
        irText = dumped.stdout;
        frontStderr += dumped.stderr;
      } catch (e) {
        return failed(e);
      }
    }
    fs.writeFileSync(ir, irText);
    let wasm;
    try {
      wasm = await runStep("emit", mrb, [emitter, ...MODES[mode].emit, ir], dir);
    } catch (e) {
      return failed(e);
    }
    return {
      ok: true,
      ir: irText.toString("utf8"),
      wasm: wasm.stdout.toString("base64"),
      diagnostics: parseDiagnostics(frontStderr),
      language,
      mode,
      std,
    };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { compile, checkOptions, parseDiagnostics, MODES, LANGUAGES, STANDARDS, MAX_SOURCE, root };
