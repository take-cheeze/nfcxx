// The host for the modules tests/wasm/run.sh emits: runs `main` and prints its result, or "trap" for a wasm trap.
// The imports (functions of module "env", which the IR calls without defining) return their first argument plus one.
// An ASan-mode module (emit with --asan) calls env.__asan_report(addr, size, code) before it traps on a violation: then
// the host prints the access and the kind ("asan: KIND" is the last line), instead of "trap". The allocator's reports have
// codes of 0x100 and up (not shadow codes): a bad free prints the address freed, and an out-of-memory report (the size
// requested is its address) prints the size instead of an access.
const fs = require("fs");
const { importedMemory } = require("./imported-memory.cjs");
const bytes = fs.readFileSync(process.argv[2]);
const compiled = new WebAssembly.Module(bytes);
// the poison codes of the shadow (scripts/pathb-wasm-emit.rb, ASAN_*) and the kinds they report
const kinds = {
  0xf1: "stack-buffer-overflow", 0xf9: "global-buffer-overflow", 0xf5: "stack-use-after-return",
  0xfa: "heap-buffer-overflow", 0xfd: "heap-use-after-free",
  0x100: "attempting-double-free", 0x101: "attempting-free-on-address-which-was-not-malloc",
  0x102: "allocator-out-of-memory",
};
let report = null;
const imports = {};
for (const imp of WebAssembly.Module.imports(compiled)) {
  imports[imp.module] = imports[imp.module] || {};
  if (imp.kind === "memory") {
    // --emscripten-import-memory: the memory the module imports, at the size it declares
    imports[imp.module][imp.name] = new WebAssembly.Memory({ initial: importedMemory(bytes).min });
    continue;
  }
  imports[imp.module][imp.name] =
    imp.name === "__asan_report"
      ? (addr, size, code) => { report = { addr, size, code }; }
      : (x) => (x | 0) + 1;
}
try {
  const instance = new WebAssembly.Instance(compiled, imports);
  console.log(String(instance.exports.main()));
} catch (e) {
  if (!(e instanceof WebAssembly.RuntimeError)) {
    throw e;
  }
  if (report) {
    const addr = `0x${(report.addr >>> 0).toString(16)}`;
    if (report.code === 0x102) console.log(`malloc of ${report.addr >>> 0} byte(s)`);
    else console.log(report.code >= 0x100 ? `free of ${addr}` : `access of ${report.size} byte(s) at ${addr}`);
    console.log(`asan: ${kinds[report.code] || "unknown-0x" + report.code.toString(16)}`);
  } else {
    console.log("trap");
  }
}
