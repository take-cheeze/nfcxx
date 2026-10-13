// Checks a module emitted with scripts/pathb-wasm-emit.rb --emscripten (tests/wasm/run.sh does this with
// NFCXX_WASM_EMSCRIPTEN=1): the export names and kinds the Emscripten JS runtime reads, their types and mutability, the
// layout behind them (the stack top is the heap base, the static data ends below the stack's reach), and that every
// import comes from module "env". Usage: node emscripten.cjs MODULE.wasm. Exits 1 with a message on a failure.
const fs = require("fs");
const file = process.argv[2];
const fail = (msg) => { console.log(`emscripten: ${file}: ${msg}`); process.exit(1); };

const mod = new WebAssembly.Module(fs.readFileSync(file));

const kinds = Object.fromEntries(WebAssembly.Module.exports(mod).map((e) => [e.name, e.kind]));
const want = {
  memory: "memory",
  __indirect_function_table: "table",
  __stack_pointer: "global",
  __data_end: "global",
  __heap_base: "global",
  main: "function",
};
for (const [name, kind] of Object.entries(want)) {
  if (kinds[name] !== kind) fail(`export ${name} is ${kinds[name] ?? "missing"}, want ${kind}`);
}

const imports = {};
for (const imp of WebAssembly.Module.imports(mod)) {
  if (imp.module !== "env") fail(`import ${imp.module}.${imp.name}: want module env`);
  if (imp.kind !== "function") fail(`import ${imp.name} is a ${imp.kind}, want a function`);
  imports.env = imports.env || {};
  imports.env[imp.name] = () => 0;
}

const ex = new WebAssembly.Instance(mod, imports).exports;
if (!(ex.memory instanceof WebAssembly.Memory)) fail("memory is not a WebAssembly.Memory");
if (!(ex.__indirect_function_table instanceof WebAssembly.Table)) fail("__indirect_function_table is not a table");
if (ex.__indirect_function_table.length !== 0) fail("__indirect_function_table has elements (the emitter has none)");
for (const name of ["__stack_pointer", "__data_end", "__heap_base"]) {
  if (!(ex[name] instanceof WebAssembly.Global)) fail(`${name} is not a WebAssembly.Global`);
  if (typeof ex[name].value !== "number") fail(`${name} is not an i32 (its value is not a Number)`);
}

// Mutability: writing an immutable global throws a TypeError.
const sp = ex.__stack_pointer, de = ex.__data_end, hb = ex.__heap_base;
try { sp.value = sp.value; } catch (e) { fail("__stack_pointer is immutable, want mutable"); }
for (const [name, g] of [["__data_end", de], ["__heap_base", hb]]) {
  try { g.value = g.value; fail(`${name} is mutable, want immutable`); } catch (e) {
    if (!(e instanceof TypeError)) throw e;
  }
}

// Layout: the heap begins where the memory ends, the stack starts there, and the stack has room below it: the static
// data ends at least 64 KB below the stack top (the emitter's guarantee for the stack).
const memEnd = ex.memory.buffer.byteLength;
if (hb.value !== memEnd) fail(`__heap_base ${hb.value} is not the end of the memory ${memEnd}`);
if (sp.value !== hb.value) fail(`__stack_pointer ${sp.value} is not __heap_base ${hb.value}`);
if (!(de.value >= 16 && de.value + 65536 <= sp.value)) fail(`__data_end ${de.value} leaves less than 64 KB of stack`);
