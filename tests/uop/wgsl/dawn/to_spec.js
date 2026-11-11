// Evaluates a generated case.js (window.CASE = {...}) and writes the WGSL source and a line-based spec for the C runner.
const fs = require('fs');
const [, , jsPath, outPrefix] = process.argv;
global.window = {};
new Function(fs.readFileSync(jsPath, 'utf8'))();
const C = window.CASE;
fs.writeFileSync(outPrefix + '.wgsl', C.source);
const L = [];
L.push(`output ${C.output}`);
C.buffers.forEach((b, i) => L.push(`buf ${i} ${b.count} ${b.input ? 1 : 0}`));
for (const [name, vals] of Object.entries(C.inputs)) {
  const i = C.buffers.findIndex((b) => b.name === name);
  L.push(`input ${i} ${vals.join(' ')}`);
}
for (const k of C.kernels) L.push(`kernel ${k.entry} ${k.count} ${k.bindings.join(' ')}`);
L.push(`expect ${C.expected.map((v) => Math.fround(Number(v))).join(' ')}`);
fs.writeFileSync(outPrefix + '.spec', L.join('\n') + '\n');
console.log(`${outPrefix}: ${C.kernels.length} kernels, ${C.buffers.length} buffers, ${C.expected.length} expected values`);
