// The wasm explorer's compile pipeline, shared by the local server (server.cjs) and the static build (build-static.cjs).
// A compile runs, in a fresh temporary directory, a front end to the mid-level IR (docs/notes/pathb-stage2.md), then
// the emitter. The front end depends on the source language (LANGUAGES):
//   C++, C      scripts/pathb-dump --ir [-std=...] [mode] prog.cpp|prog.c   (EDG, in C++ or C mode)
//   LLVM IR     scripts/mrb scripts/llvm-to-pathb.rb prog.ll                (docs/notes/pathb-llvm.md)
//   Rust        rustc -C opt-level=1 -C lto=fat -C save-temps ... prog.rs (the module after LTO, with the parts of core
//               the program uses), llvm-dis of it, then llvm-to-pathb.rb --wasm
//   Go          tinygo build -o prog.ll -gc=leaking -scheduler=none ... prog.go, a main() wrapper, then the same
//   Swift       swiftfe emit-c --bindings prog.swift (tools/swiftfe: LLVM-free, its C), then the C route below
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
// the Swift front end (tools/swiftfe, swift build -c release); SWIFTFE names another build
const swiftfe = process.env.SWIFTFE ? tool(process.env.SWIFTFE)
  : path.join(root, "tools", "swiftfe", ".build", "release", "swiftfe");
const rustc = tool(process.env.RUSTC || "rustc");
// llvm-dis of rustc's own LLVM (rustup component llvm-tools): LLVM_DIS, else the one in rustc's sysroot, found once.
let llvmDis = process.env.LLVM_DIS ? tool(process.env.LLVM_DIS) : null;
async function findLlvmDis(dir) {
  if (llvmDis) return llvmDis;
  const sysroot = (await runStep("front-end", rustc, ["--print", "sysroot"], dir)).stdout.toString().trim();
  const host = /host: (\S+)/.exec((await runStep("front-end", rustc, ["-vV"], dir)).stdout.toString());
  const candidate = path.join(sysroot, "lib", "rustlib", host ? host[1] : "", "bin", "llvm-dis");
  if (!fs.existsSync(candidate)) {
    throw { stage: "front-end", stderr: "", code: null,
      message: "llvm-dis is not installed for rustc (rustup component add llvm-tools, or set LLVM_DIS)" };
  }
  llvmDis = candidate;
  return llvmDis;
}
const bundledTinygo = path.join(root, "build", "tinygo", "bin", "tinygo");
const tinygo = tool(process.env.TINYGO || (fs.existsSync(bundledTinygo) ? bundledTinygo : "tinygo"));

const MAX_SOURCE = 64 * 1024;   // bytes of source per request
const STEP_TIMEOUT = 60000;     // ms per compiler step

const { MODES, LANGUAGES, STANDARDS, checkOptions, stripIrComments, parseDiagnostics } = require("./common.js");

// C++ names in a message (_Z1fi) as the source spells them (f(int)), through c++filt when it is installed; the
// message as it is otherwise.
let cxxfilt;   // undefined: not looked for yet; null: not installed
function demangle(text) {
  if (!/\b_Z\w+/.test(text) || cxxfilt === null) return Promise.resolve(text);
  return new Promise((resolve) => {
    const child = execFile("c++filt", [], { timeout: 5000 }, (err, stdout) => {
      if (err) {
        if (err.code === "ENOENT") cxxfilt = null;
        return resolve(text);
      }
      cxxfilt = true;
      resolve(String(stdout).replace(/\n$/, ""));
    });
    child.stdin.end(text + "\n");
  });
}

// The demangled names of the IR's mangled functions (C++ _Z..., Rust _R... and _ZN...17h<hash>E), as a map
// { mangled: demangled }, for the page to show a wasm stack trace (whose frames are the name section's names) as the
// source spells them. Empty without c++filt.
function demangleNames(irText) {
  const names = [...new Set(String(irText).match(/\(function "(_[ZR]\w+)"/g) || [])].map((m) => m.slice(11, -1));
  if (names.length === 0 || cxxfilt === null) return Promise.resolve({});
  return new Promise((resolve) => {
    const child = execFile("c++filt", [], { timeout: 5000, maxBuffer: 16 * 1024 * 1024 }, (err, stdout) => {
      if (err) {
        if (err.code === "ENOENT") cxxfilt = null;
        return resolve({});
      }
      const out = String(stdout).split("\n");
      const map = {};
      // without Rust's hashes: the legacy scheme's ::h<hash>, v0's crate disambiguators core[<hash>]
      names.forEach((n, i) => {
        if (out[i] && out[i] !== n) map[n] = out[i].replace(/::h[0-9a-f]{16}$/, "").replace(/\[[0-9a-f]{16}\]/g, "");
      });
      resolve(map);
    });
    child.stdin.end(names.join("\n") + "\n");
  });
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
// env: variables added to the environment of the step.
function runStep(stage, file, argv, dir, cwd = root, env = null) {
  return new Promise((resolve, reject) => {
    execFile(file, argv, { cwd, timeout: STEP_TIMEOUT, encoding: "buffer", maxBuffer: 16 * 1024 * 1024,
      env: env ? Object.assign({}, process.env, env) : process.env },
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
//   { ok: true, ir, wasm (base64), names, diagnostics, language, mode, std }   or
// (names: demangleNames; the module has a name section, for stack traces)
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
  const failed = async (e) => {
    const message = await demangle(e.message);
    // a Swift program's C lines are not the program's: only swiftfe's diagnostics (which name prog.swift) get markers
    const diagnostics = e.noLines ? [] : parseDiagnostics(message);
    return { ok: false, stage: e.stage, message, diagnostics, code: e.code };
  };
  try {
    const src = path.join(dir, LANGUAGES[language].file);
    const ir = path.join(dir, "prog.ir");
    let irText;
    let frontStderr = "";
    let fromSwiftC = false;   // the steps after swiftfe run on the C it wrote (see failed)
    if (language === "ir") {
      irText = Buffer.from(stripIrComments(source));
    } else {
      fs.writeFileSync(src, source);
      let step;
      try {
        if (language === "rust" || language === "go") {
          // the compiler writes LLVM IR, which llvm-to-pathb.rb translates (for a wasm module: --wasm)
          const ll = path.join(dir, "prog.ll");
          let compiled;
          if (language === "rust") {
            // Fat LTO links in the parts of core the program uses (core's non-generic functions, such as memchr, are
            // not in the crate's own IR); --emit=llvm-ir would give the module before LTO, so the optimized module
            // after it is taken from the saved temporaries (out/<crate>.<crate>.<hash>-cgu.0.rcgu.bc) and
            // disassembled with rustc's own llvm-dis.
            const out = path.join(dir, "out");
            fs.mkdirSync(out);
            compiled = await runStep("front-end", rustc, ["--crate-type=cdylib", `--edition=${std || "2021"}`,
              "-C", "opt-level=1", "-C", "panic=abort", "-C", "overflow-checks=on", "-C", "codegen-units=1",
              "-C", "lto=fat", "-C", "save-temps", `--remap-path-prefix=${dir}${path.sep}=`, "--out-dir", out, src],
              dir);
            const bc = fs.readdirSync(out).find((f) => /-cgu\.0\.rcgu\.bc$/.test(f));
            if (!bc) throw { stage: "front-end", message: "rustc left no module after LTO", stderr: "", code: null };
            await runStep("front-end", await findLlvmDis(dir), [path.join(out, bc), "-o", ll], dir);
          } else {
            compiled = await runStep("front-end", tinygo, ["build", "-o", ll, "-gc=leaking", "-scheduler=none",
              "-panic=trap", "-opt=1", "-no-debug", "./prog.go"], dir, dir);
          }
          frontStderr = compiled.stderr;
          if (language === "go") fs.writeFileSync(ll, wrapGoMain(fs.readFileSync(ll, "utf8")));
          step = [mrb, [llvmToPathb, "--wasm", ll]];
        } else if (language === "llvm") {
          step = [mrb, [llvmToPathb, src]];
        } else if (language === "swift") {
          // swiftfe's C for the browser's bindings (ints, bools and the putchar/abort imports), then the C route
          const emitted = await runStep("front-end", swiftfe, ["emit-c", "--bindings", src], dir);
          const c = path.join(dir, "prog.c");
          fs.writeFileSync(c, emitted.stdout);
          step = [pathbDump, ["--ir", ...MODES[mode].dump, c]];
          fromSwiftC = true;
        } else {
          step = [pathbDump, ["--ir", ...(std ? [`-std=${std}`] : []), ...MODES[mode].dump, src]];
        }
        // NFCXX_IR_LOC: EDG's IR names the source line of each statement, so that a refusal of the emitter does too
        // (not for Swift: the IR's lines are the generated C's, which the program's diagnostics would name)
        const dumped = await runStep("front-end", step[0], step[1], dir, root,
          step[0] === pathbDump && language !== "swift" ? { NFCXX_IR_LOC: "1" } : null);
        // the (loc ...) statements name the source file without the temporary directory, as the diagnostics do
        irText = Buffer.from(dumped.stdout.toString("utf8").split(dir + path.sep).join(""));
        frontStderr += dumped.stderr;
      } catch (e) {
        if (fromSwiftC) e.noLines = true;
        return await failed(e);
      }
    }
    fs.writeFileSync(ir, irText);
    let wasm;
    try {
      wasm = await runStep("emit", mrb, [emitter, "--names", ...MODES[mode].emit, ir], dir);
    } catch (e) {
      if (fromSwiftC) e.noLines = true;
      return await failed(e);
    }
    return {
      ok: true,
      ir: irText.toString("utf8"),
      wasm: wasm.stdout.toString("base64"),
      names: await demangleNames(irText),
      diagnostics: parseDiagnostics(frontStderr),
      language,
      mode,
      std,
    };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { compile, demangleNames, checkOptions, parseDiagnostics, MODES, LANGUAGES, STANDARDS, MAX_SOURCE, root };
