// Checks a module emitted with scripts/pathb-wasm-emit.rb --emscripten (tests/wasm/run.sh does this with
// NFCXX_WASM_EMSCRIPTEN=1 or =import): the export names and kinds the Emscripten JS runtime reads, their types and
// mutability, the layout behind them (the stack top is the heap base, the static data ends below the stack's reach),
// that every import comes from module "env", and that the exports are callable. A module with --emscripten-import-memory
// imports env.memory instead of exporting memory; the checker detects it from the module. The host below provides only
// the imports the module declares. Usage: node emscripten.cjs MODULE.wasm. Exits 1 with a message on a failure.
const fs = require("fs");
const { importedMemory } = require("./imported-memory.cjs");
const file = process.argv[2];
const fail = (msg) => { console.log(`emscripten: ${file}: ${msg}`); process.exit(1); };

const bytes = fs.readFileSync(file);
const mod = new WebAssembly.Module(bytes);

const imported = WebAssembly.Module.imports(mod);
const memImp = imported.find((i) => i.kind === "memory");
const importMode = memImp !== undefined;
if (importMode && (memImp.module !== "env" || memImp.name !== "memory")) {
  fail(`memory import is ${memImp.module}.${memImp.name}, want env.memory`);
}

const kinds = Object.fromEntries(WebAssembly.Module.exports(mod).map((e) => [e.name, e.kind]));
const want = {
  __indirect_function_table: "table",
  __stack_pointer: "global",
  __data_end: "global",
  __heap_base: "global",
  main: "function",
  __wasm_call_ctors: "function",
};
if (importMode) {
  // the memory is imported with no maximum (it may grow), so it is not exported too
  if (importedMemory(bytes).max !== null) fail("the imported memory has a maximum, want none");
  if ("memory" in kinds) fail("memory is exported and imported, want only the import");
} else {
  want.memory = "memory";
}
for (const [name, kind] of Object.entries(want)) {
  if (kinds[name] !== kind) fail(`export ${name} is ${kinds[name] ?? "missing"}, want ${kind}`);
}
// the names the emitter does not export (docs/notes/pathb-wasm.md, "Emscripten", points 6 to 8)
for (const name of ["__set_stack_limits", "malloc", "free", "emscripten_resize_heap"]) {
  if (name in kinds) fail(`export ${name} is present, the emitter does not export it`);
}

// The host: only the imports the module declares. Functions return 0; the memory is the module's import, at the size
// the module declares (its initial pages), or the module's own export when it is not imported.
const imports = {};
for (const imp of imported) {
  if (imp.module !== "env") fail(`import ${imp.module}.${imp.name}: want module env`);
  if (imp.kind === "memory") continue;
  if (imp.kind !== "function") fail(`import ${imp.name} is a ${imp.kind}, want a function`);
  imports.env = imports.env || {};
  imports.env[imp.name] = () => 0;
}
if (importMode) {
  imports.env = imports.env || {};
  imports.env.memory = new WebAssembly.Memory({ initial: importedMemory(bytes).min });
}

const ex = new WebAssembly.Instance(mod, imports).exports;
const mem = importMode ? imports.env.memory : ex.memory;
if (!(mem instanceof WebAssembly.Memory)) fail("memory is not a WebAssembly.Memory");
if (!(ex.__indirect_function_table instanceof WebAssembly.Table)) fail("__indirect_function_table is not a table");
// The table holds the functions whose address the module takes, from slot 1; slot 0 stays null (a call through a null
// function pointer traps). A module that takes no address has an empty table.
{
  const t = ex.__indirect_function_table;
  if (t.length === 1) fail("__indirect_function_table has a null slot and no functions");
  if (t.length > 0 && t.get(0) !== null) fail("__indirect_function_table slot 0 is not null");
  for (let i = 1; i < t.length; i++) {
    if (typeof t.get(i) !== "function") fail(`__indirect_function_table slot ${i} is not a function`);
  }
}
// Its growth from the JS side must work (no maximum), which is what an addFunction-style grow needs: grow it by one
// and check the length.
{
  const t = ex.__indirect_function_table;
  const before = t.length;
  if (t.grow(1) !== before || t.length !== before + 1) fail("__indirect_function_table cannot grow (it has a maximum)");
}
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
const memEnd = mem.buffer.byteLength;
if (hb.value !== memEnd) fail(`__heap_base ${hb.value} is not the end of the memory ${memEnd}`);
if (sp.value !== hb.value) fail(`__stack_pointer ${sp.value} is not __heap_base ${hb.value}`);
if (!(de.value >= 16 && de.value + 65536 <= sp.value)) fail(`__data_end ${de.value} leaves less than 64 KB of stack`);

// __wasm_call_ctors: a function with no parameters that returns nothing and changes nothing (the IR has no list of
// static constructors). It must return and leave the stack pointer alone.
if (typeof ex.__wasm_call_ctors !== "function" || ex.__wasm_call_ctors.length !== 0) {
  fail("__wasm_call_ctors is not a function of no parameters");
}
const spBefore = sp.value;
if (ex.__wasm_call_ctors() !== undefined) fail("__wasm_call_ctors returned a value, want none");
if (sp.value !== spBefore) fail("__wasm_call_ctors changed the stack pointer");

// Pointers are i32 in the ILP32 module (wasm32). A function that takes an address and returns one (ident in
// emscripten_pointer.cpp) is called with a Number and returns a Number; an i64 pointer would take a BigInt and throw.
if ("ident" in kinds) {
  if (kinds.ident !== "function") fail(`export ident is ${kinds.ident}, want function`);
  let r;
  try { r = ex.ident(16); } catch (e) { fail(`ident does not take an address as a Number: ${e.message}`); }
  if (r !== 16) fail(`ident(16) returned ${typeof r} ${String(r)}, want the Number 16`);
}
