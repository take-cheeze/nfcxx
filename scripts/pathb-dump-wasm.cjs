#!/usr/bin/env node
// scripts/pathb-dump-wasm.cjs: scripts/pathb-dump, with the front end built for the browser (PATHB_EMSCRIPTEN=1
// scripts/setup-pathb.sh: build/pathb-wasm/cmake/bin/cpfe.js and cpfe.wasm) run under node. The options are
// pathb-dump's (--ir, --freestanding, --target, -std=, -I, -D, -U, --diag_*), and so is the output: the IR (or the IL
// listing) on stdout, the diagnostics on stderr, the front end's exit status. tests/pathb-wasm-frontend/run.sh compares
// the two. The front end sees an in-memory file system, as in a page: the base directory, the source's directory, the
// -I directories and (hosted, the default) the host's system include directories are copied into it first.
//   PATHB_WASM_OUT   the build (default build/pathb-wasm)
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.resolve(__dirname, "..");
const out = process.env.PATHB_WASM_OUT || path.join(root, "build", "pathb-wasm");
const base = path.join(out, "edg-base");
const cpfeJs = path.join(out, "cmake", "bin", "cpfe.js");
if (!fs.existsSync(cpfeJs)) {
  console.error("pathb-dump-wasm: front end not built; run PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh");
  process.exit(2);
}

// The options, as pathb-dump reads them.
let std = "", mode = "il", hosted = process.env.PATHB_HOSTED !== "0", target = "";
const files = [], userOpts = [], incDirs = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--ir") mode = "ir";
  else if (a === "--freestanding") hosted = false;
  else if (a.startsWith("--target=")) target = a.slice(9);
  else if (a === "--target") target = args[++i] || "";
  else if (a.startsWith("-std=c++")) std = "--c++" + a.slice(8);
  else if (/^-std=(c89|c99|c11|c17|c18|c23)$/.test(a)) std = "--" + a.slice(5);
  else if (a.startsWith("-std=")) { console.error(`pathb-dump-wasm: unknown standard ${a.slice(5)}`); process.exit(2); }
  else if (a.startsWith("-I") && a.length > 2) { const d = path.resolve(a.slice(2)); incDirs.push(d); userOpts.push("-I" + d); }
  else if (/^-[DU]./.test(a) || a.startsWith("--diag_")) userOpts.push(a);
  else if (a === "-Wno-narrowing") userOpts.push("--diag_warning=narrowing_conversion");
  else if (a.startsWith("-W")) { /* other warnings do not change the object code */ }
  else files.push(a);
}
if (files.length === 0) { console.error("pathb-dump-wasm: no input files"); process.exit(2); }
const file = fs.realpathSync(files[0]);
if (files.length > 1) { console.error("pathb-dump-wasm: one input file"); process.exit(2); }
if (!std) std = file.endsWith(".c") ? "--c17" : "--c++23";
const lang = std.startsWith("--c++") ? "c++" : "c";
const targetOpts = [];
if (target) {
  if (hosted) { console.error("pathb-dump-wasm: --target needs --freestanding"); process.exit(2); }
  if (!fs.existsSync(path.join(base, "lib_" + target))) {
    console.error(`pathb-dump-wasm: no predefined macros for target '${target}' in ${base}`);
    process.exit(2);
  }
  targetOpts.push("--target", target, "--signed_chars");
}
// The host's system include directories and GNU version (scripts/host-sys.sh), as the native front end gets them.
const sysInc = [], gnuOpts = [];
if (hosted) {
  const sh = (fn) => execFileSync("bash", ["-c", `source "${root}/scripts/host-sys.sh"; ${fn}`], { encoding: "utf8" });
  for (const d of sh(`host_sys_includes ${lang}`).split("\n")) if (d) sysInc.push(d);
  const gnu = sh("host_gnu_version").trim();
  if (gnu) gnuOpts.push("--gnu_version=" + gnu);
}

// A host directory into the module's file system at the same path (symbolic links followed).
function copyIn(FS, from, to) {
  let st;
  try { st = fs.statSync(from); } catch (e) { return; }
  if (!st.isDirectory()) return;
  FS.mkdirTree(to);
  for (const n of fs.readdirSync(from)) {
    const p = path.join(from, n);
    let s;
    try { s = fs.statSync(p); } catch (e) { continue; }   // a dangling link
    if (s.isDirectory()) copyIn(FS, p, to + "/" + n);
    else if (s.isFile()) FS.writeFile(to + "/" + n, fs.readFileSync(p));
  }
}

const argv = ["-D_POSIX_SOURCE", "-D__CHAR_BIT__=8", std, lang === "c" ? "--gcc" : "--g++", "--wdir", "/",
  ...gnuOpts, ...(lang === "c" ? [] : ["-tused"]), ...userOpts, ...sysInc.map((d) => "--sys_include=" + d),
  ...targetOpts, "--sys_include=" + base + "/include", file];
let status = 0;
require(cpfeJs)({
  print: (s) => process.stdout.write(s + "\n"),
  printErr: (s) => process.stderr.write(s + "\n"),
  preRun: [(m) => {
    copyIn(m.FS, base, base);
    for (const d of [...sysInc, ...incDirs]) copyIn(m.FS, d, d);
    copyIn(m.FS, path.dirname(file), path.dirname(file));   // the source, and what it includes with "..."
    m.FS.chdir(base);
    m.ENV.NFCXX_PATHB_MODE = mode;
    for (const k of ["NFCXX_IR_LOC", "NFCXX_IR_SANITIZE"]) if (process.env[k] !== undefined) m.ENV[k] = process.env[k];
  }],
}).then((m) => {
  try {
    status = m.callMain(argv);
  } catch (e) {
    status = e && typeof e.status === "number" ? e.status : 4;   // a trap of the module: a catastrophe
    if (!(e && typeof e.status === "number")) process.stderr.write(`pathb-dump-wasm: ${(e && e.message) || e}\n`);
  }
  process.exitCode = status;
});
