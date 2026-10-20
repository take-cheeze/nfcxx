// Builds the static site for GitHub Pages (or any static host): the page, the example sources, and each example
// compiled ahead of time in every mode (pipeline.cjs MODES). A static host cannot run the compiler, so the page
// shows these builds for the examples. Each build is run here in node and checked against the example's expected
// result, so a broken build fails the job rather than the page.
//
// Usage: node tools/wasm-explorer/build-static.cjs [--out DIR]     (default: _site at the repository root)
const fs = require("fs");
const path = require("path");
const { compile, MODES, root } = require("./pipeline.cjs");

const here = __dirname;
const args = process.argv.slice(2);
const outIndex = args.indexOf("--out");
const out = outIndex >= 0 ? path.resolve(args[outIndex + 1]) : path.join(root, "_site");

// The module's main, run the way the page runs it: imports return their first argument plus one.
function runMain(bytes) {
  const module = new WebAssembly.Module(bytes);
  const imports = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.kind !== "function") throw new Error(`import ${imp.module}.${imp.name} (${imp.kind}) is not provided`);
    imports[imp.module] = imports[imp.module] || {};
    imports[imp.module][imp.name] = (x) => (Number(x) | 0) + 1;
  }
  const instance = new WebAssembly.Instance(module, imports);
  return String(instance.exports.main());
}

async function buildExample(entry, examplesDir) {
  const source = fs.readFileSync(path.join(examplesDir, entry.file), "utf8");
  const builds = {};
  for (const mode of Object.keys(MODES)) {
    const result = await compile(source, { mode });
    if (!result.ok) {
      throw new Error(`${entry.id} [${mode}]: ${result.stage}: ${result.message}`);
    }
    const bytes = Buffer.from(result.wasm, "base64");
    const got = runMain(bytes);
    if (got !== String(entry.expect)) {
      throw new Error(`${entry.id} [${mode}]: main() returned ${got}, expected ${entry.expect}`);
    }
    builds[mode] = { ir: result.ir, wasm: result.wasm, diagnostics: result.diagnostics, result: got };
  }
  return { id: entry.id, title: entry.title, file: entry.file, expect: entry.expect, source, builds };
}

async function main() {
  const examplesDir = path.join(here, "examples");
  const manifest = JSON.parse(fs.readFileSync(path.join(examplesDir, "index.json"), "utf8"));
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(path.join(out, "examples"), { recursive: true });
  fs.mkdirSync(path.join(out, "builds"), { recursive: true });

  for (const entry of manifest) {
    const built = await buildExample(entry, examplesDir);
    fs.writeFileSync(path.join(out, "builds", `${entry.id}.json`), JSON.stringify(built));
    fs.copyFileSync(path.join(examplesDir, entry.file), path.join(out, "examples", entry.file));
    console.log(`ok ${entry.id}: ${Object.keys(built.builds).join(", ")} -> ${entry.expect}`);
  }
  fs.copyFileSync(path.join(examplesDir, "index.json"), path.join(out, "examples", "index.json"));
  fs.copyFileSync(path.join(here, "index.html"), path.join(out, "index.html"));
  fs.writeFileSync(path.join(out, ".nojekyll"), "");
  console.log(`site written to ${out}`);
}

main().catch((e) => {
  console.error(`build-static: ${e.message}`);
  process.exit(1);
});
