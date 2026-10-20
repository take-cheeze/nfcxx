// The wasm explorer's compile pipeline, shared by the local server (server.cjs) and the static build (build-static.cjs).
// A compile runs, in a fresh temporary directory:
//   scripts/pathb-dump --ir [-std=...] [mode] prog.cpp   the mid-level IR (docs/notes/pathb-stage2.md)
//   scripts/mrb scripts/pathb-wasm-emit.rb [mode] prog.ir  the wasm module, in the binary format
// Both need the Path B harness and the mruby tool (scripts/setup-pathb.sh, scripts/setup-mruby.sh). The compiler is a
// native program: it runs where this module runs, and the module it returns runs in the browser.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const pathbDump = path.join(root, "scripts", "pathb-dump");
const mrb = path.join(root, "scripts", "mrb");
const emitter = path.join(root, "scripts", "pathb-wasm-emit.rb");

const MAX_SOURCE = 64 * 1024;   // bytes of C++ per request
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
// The C++ standards the front end takes (pathb-dump -std=c++NN). "" is the front end's default.
const STANDARDS = ["c++17", "c++20", "c++23"];

// Returns an error message for options the pipeline does not take, else null.
function checkOptions(options) {
  if (options.mode !== undefined && !Object.prototype.hasOwnProperty.call(MODES, options.mode)) {
    return `unknown mode: ${options.mode}`;
  }
  if (options.std !== undefined && options.std !== "" && !STANDARDS.includes(options.std)) {
    return `unknown standard: ${options.std}`;
  }
  return null;
}

// EDG's diagnostics: `"prog.cpp", line 1: error: expected an expression`. A line that does not match is part of the
// message above it, so it is not a diagnostic of its own.
function parseDiagnostics(text) {
  const out = [];
  for (const line of text.split("\n")) {
    const m = /line (\d+): (catastrophic error|error|warning|remark): (.*)$/.exec(line);
    if (m) {
      out.push({ line: Number(m[1]), severity: m[2] === "catastrophic error" ? "error" : m[2], message: m[3].trim() });
    }
  }
  return out;
}

// Runs a step; resolves with { stdout: Buffer, stderr: string }, or rejects with { stage, message, code, stderr }.
function runStep(stage, file, argv, dir) {
  return new Promise((resolve, reject) => {
    execFile(file, argv, { cwd: root, timeout: STEP_TIMEOUT, encoding: "buffer", maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const text = String(stderr || "").split(dir + path.sep).join("");   // diagnostics name the temporary file
        if (!err) return resolve({ stdout, stderr: text });
        reject({
          stage,
          message: text.trim() || (err.killed ? "timed out" : err.message),
          stderr: text,
          code: typeof err.code === "number" ? err.code : null,
        });
      });
  });
}

// Compiles source with options { std, mode }. Resolves with
//   { ok: true, ir, wasm (base64), diagnostics, mode, std }   or
//   { ok: false, stage, message, diagnostics, code }          (stage: request, front-end, emit, or server)
async function compile(source, options = {}) {
  const bad = checkOptions(options);
  if (bad) return { ok: false, stage: "request", message: bad, diagnostics: [] };
  if (typeof source !== "string") return { ok: false, stage: "request", message: "source must be a string", diagnostics: [] };
  if (Buffer.byteLength(source) > MAX_SOURCE) {
    return { ok: false, stage: "request", message: `source is over ${MAX_SOURCE} bytes`, diagnostics: [] };
  }
  const mode = options.mode || "lp64";
  const std = options.std || "";
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nfcxx-explorer-"));
  try {
    const cpp = path.join(dir, "prog.cpp");
    const ir = path.join(dir, "prog.ir");
    fs.writeFileSync(cpp, source);
    const dumpArgs = ["--ir", ...(std ? [`-std=${std}`] : []), ...MODES[mode].dump, cpp];
    let dumped;
    try {
      dumped = await runStep("front-end", pathbDump, dumpArgs, dir);
    } catch (e) {
      return { ok: false, stage: e.stage, message: e.message, diagnostics: parseDiagnostics(e.stderr), code: e.code };
    }
    fs.writeFileSync(ir, dumped.stdout);
    let wasm;
    try {
      wasm = await runStep("emit", mrb, [emitter, ...MODES[mode].emit, ir], dir);
    } catch (e) {
      return { ok: false, stage: e.stage, message: e.message, diagnostics: parseDiagnostics(e.stderr), code: e.code };
    }
    return {
      ok: true,
      ir: dumped.stdout.toString("utf8"),
      wasm: wasm.stdout.toString("base64"),
      diagnostics: parseDiagnostics(dumped.stderr),
      mode,
      std,
    };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { compile, checkOptions, parseDiagnostics, MODES, STANDARDS, MAX_SOURCE, root };
