// The assets of the in-browser compile (inbrowser.js) from this checkout's builds: the front end
// (PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh: build/pathb-wasm), the interpreter (scripts/setup-mruby-wasm.sh:
// build/mruby-wasm), EDG's base directory, the two scripts and the GNU version. load() gives them as inbrowser.js's
// makeCompiler takes them (under node); write(dir) writes them as the page loads them (build-static.cjs).
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const files = {
  cpfeJs: path.join(root, "build", "pathb-wasm", "cmake", "bin", "cpfe.js"),
  cpfeWasm: path.join(root, "build", "pathb-wasm", "cmake", "bin", "cpfe.wasm"),
  mrubyJs: path.join(root, "build", "mruby-wasm", "out", "wasm", "bin", "mruby.js"),
  mrubyWasm: path.join(root, "build", "mruby-wasm", "out", "wasm", "bin", "mruby.wasm"),
  base: path.join(root, "build", "pathb-wasm", "edg-base"),
  emitter: path.join(root, "scripts", "pathb-wasm-emit.rb"),
  llvmToPathb: path.join(root, "scripts", "llvm-to-pathb.rb"),
};

// Both tools are built.
function available() {
  return ["cpfeJs", "cpfeWasm", "mrubyJs", "mrubyWasm", "base"].every((k) => fs.existsSync(files[k]));
}

// EDG's base directory as { relative path: text } (symbolic links followed).
function baseFiles(dir = files.base, rel = "", out = {}) {
  for (const n of fs.readdirSync(dir).sort()) {
    const p = path.join(dir, n), st = fs.statSync(p);
    if (st.isDirectory()) baseFiles(p, rel + n + "/", out);
    else if (st.isFile()) out[rel + n] = fs.readFileSync(p, "utf8");
  }
  return out;
}

// The GNU version the server's front end runs with (scripts/pathb-dump, scripts/host-sys.sh).
function gnuVersion() {
  const sh = `source "${root}/scripts/host-sys.sh"; host_gnu_version`;
  return execFileSync("bash", ["-c", sh], { encoding: "utf8" }).trim();
}

function load() {
  return {
    cpfe: { factory: require(files.cpfeJs), module: new WebAssembly.Module(fs.readFileSync(files.cpfeWasm)) },
    mruby: { factory: require(files.mrubyJs), module: new WebAssembly.Module(fs.readFileSync(files.mrubyWasm)) },
    base: baseFiles(),
    emitter: fs.readFileSync(files.emitter, "utf8"),
    llvmToPathb: fs.readFileSync(files.llvmToPathb, "utf8"),
    gnuVersion: gnuVersion(),
  };
}

// Writes the assets into dir (inbrowser/ of the site). Returns the total size in bytes.
function write(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const copy = { "cpfe.js": files.cpfeJs, "cpfe.wasm": files.cpfeWasm, "mruby.js": files.mrubyJs,
    "mruby.wasm": files.mrubyWasm, "pathb-wasm-emit.rb": files.emitter, "llvm-to-pathb.rb": files.llvmToPathb };
  for (const n of Object.keys(copy)) fs.copyFileSync(copy[n], path.join(dir, n));
  fs.writeFileSync(path.join(dir, "base.json"), JSON.stringify(baseFiles()));
  fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ gnuVersion: gnuVersion() }) + "\n");
  return fs.readdirSync(dir).reduce((n, f) => n + fs.statSync(path.join(dir, f)).size, 0);
}

module.exports = { available, load, write, files };
