// The host for the modules tests/wasm/run.sh emits: runs `main` and prints its result, or "trap" for a wasm trap.
// The imports (functions of module "env", which the IR calls without defining) return their first argument plus one.
const fs = require("fs");
const bytes = fs.readFileSync(process.argv[2]);
const compiled = new WebAssembly.Module(bytes);
const imports = {};
for (const imp of WebAssembly.Module.imports(compiled)) {
  imports[imp.module] = imports[imp.module] || {};
  imports[imp.module][imp.name] = (x) => (x | 0) + 1;
}
try {
  const instance = new WebAssembly.Instance(compiled, imports);
  console.log(String(instance.exports.main()));
} catch (e) {
  if (e instanceof WebAssembly.RuntimeError) {
    console.log("trap");
  } else {
    throw e;
  }
}
