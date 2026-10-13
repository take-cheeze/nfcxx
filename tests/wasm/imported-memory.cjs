// The limits of the memory a module imports (env.memory, emitted by scripts/pathb-wasm-emit.rb --emscripten-import-memory).
// WebAssembly.Module does not give them, so the host reads the import section: importedMemory(bytes) returns
// { min, max } (max is null without a maximum), or null when the module imports no memory.
function importedMemory(bytes) {
  let pos = 8;                            // after the magic and the version
  const uleb = () => {
    let result = 0, shift = 0, b;
    do { b = bytes[pos++]; result += (b & 0x7f) * 2 ** shift; shift += 7; } while (b & 0x80);
    return result;
  };
  const name = () => { const n = uleb(); pos += n; };
  while (pos < bytes.length) {
    const id = bytes[pos++];
    const size = uleb();
    const end = pos + size;
    if (id === 2) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        name(); name();
        const kind = bytes[pos++];
        if (kind === 0) uleb();           // function: a type index
        else if (kind === 1) { pos++; const flag = bytes[pos++]; uleb(); if (flag & 1) uleb(); }  // table: reftype, limits
        else if (kind === 2) {            // memory: limits
          const flag = bytes[pos++];
          const min = uleb();
          const max = flag & 1 ? uleb() : null;
          return { min, max };
        } else if (kind === 3) pos += 2;  // global: valtype, mutability
        else throw new Error(`unknown import kind ${kind}`);
      }
    }
    pos = end;
  }
  return null;
}
module.exports = { importedMemory };
