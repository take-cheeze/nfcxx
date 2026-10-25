// Builds the static site for GitHub Pages (or any static host): the page, the example sources, and each example
// compiled ahead of time in every mode of its language (pipeline.cjs LANGUAGES). A static host cannot run the
// compiler, so the page shows these builds for the examples. Each build is run here in node and checked against the
// example's expected result, so a broken build fails the job rather than the page.
//
// Usage: node tools/wasm-explorer/build-static.cjs [--out DIR]     (default: _site at the repository root)
const fs = require("fs");
const path = require("path");
const { compile, LANGUAGES, root } = require("./pipeline.cjs");
const bindings = require("./bindings.js");
const inbrowser = require("./inbrowser-assets.cjs");

const here = __dirname;
const args = process.argv.slice(2);
const outIndex = args.indexOf("--out");
const out = outIndex >= 0 ? path.resolve(args[outIndex + 1]) : path.join(root, "_site");

// The module's main, run the way the page runs it (bindings.runMain, with the same browser bindings). Returns main's
// result, or the status of the exit binding (C's exit, Go's os.Exit) as "exit N", and the output the module wrote
// (the Console's text). A run that ends any other way (a trap, an abort) is an error.
function runMain(bytes) {
  let output = "";
  const out = bindings.runMain(new WebAssembly.Module(bytes), bytes, { write: (text) => { output += text; } });
  if (out.kind !== "value" && out.kind !== "exit") {
    throw new Error(`${out.result}${out.explain ? ` (${out.explain})` : ""}${out.frames && out.frames.length
      ? ` at ${out.frames.join(" < ")}` : ""}`);
  }
  return { result: out.result, output };
}

async function buildExample(entry, examplesDir) {
  const source = fs.readFileSync(path.join(examplesDir, entry.file), "utf8");
  const language = entry.language || "c++";
  if (!LANGUAGES[language]) throw new Error(`${entry.id}: unknown language ${language}`);
  const builds = {};
  // an entry may name its modes (modes: ["asan"], for a program whose heap only the asan mode has)
  for (const mode of entry.modes || LANGUAGES[language].modes) {
    const result = await compile(source, { language, mode });
    if (!result.ok) {
      throw new Error(`${entry.id} [${mode}]: ${result.stage}: ${result.message}`);
    }
    const bytes = Buffer.from(result.wasm, "base64");
    const { result: got, output } = runMain(bytes);
    if (got !== String(entry.expect)) {
      throw new Error(`${entry.id} [${mode}]: main() returned ${got}, expected ${entry.expect}`);
    }
    if (entry.output !== undefined && output !== entry.output) {
      throw new Error(`${entry.id} [${mode}]: output ${JSON.stringify(output)}, expected ${JSON.stringify(entry.output)}`);
    }
    // the IR of a mode that is the same as an earlier mode's is stored once (irFrom names that mode): the modes that
    // differ only in the emitter's flags share it, and a large program's IR (go-fmt's) is megabytes
    const same = Object.keys(builds).find((m) => builds[m].ir === result.ir);
    builds[mode] = Object.assign(same ? { irFrom: same } : { ir: result.ir },
      { wasm: result.wasm, names: result.names, diagnostics: result.diagnostics, result: got, output });
  }
  return { id: entry.id, title: entry.title, file: entry.file, language, expect: entry.expect, source, builds };
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
  for (const f of ["bindings.js", "common.js", "inbrowser.js", "compile-worker.js"]) {
    fs.copyFileSync(path.join(here, f), path.join(out, f));
  }
  // The in-browser compile (inbrowser.js: the front end and the emitter as wasm), when its tools are built; without
  // them the page compiles the examples only (their prebuilt results). --require-inbrowser makes their absence an error.
  if (inbrowser.available()) {
    const bytes = inbrowser.write(path.join(out, "inbrowser"));
    console.log(`in-browser compiler: inbrowser/, ${(bytes / 1048576).toFixed(1)} MB`);
  } else if (args.includes("--require-inbrowser")) {
    throw new Error("the in-browser compiler is not built (PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh, scripts/setup-mruby-wasm.sh)");
  } else {
    console.log("in-browser compiler: not built, so the site compiles the examples only");
  }
  fs.writeFileSync(path.join(out, ".nojekyll"), "");
  console.log(`site written to ${out}`);
}

main().catch((e) => {
  console.error(`build-static: ${e.message}`);
  process.exit(1);
});
