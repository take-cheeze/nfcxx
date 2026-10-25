// The in-browser compile (inbrowser.js, under node) against the server's (pipeline.cjs): every example in C++, C, LLVM
// IR and the IR, in every mode of its language, must give the same result, the same IR and the same module, byte for
// byte. Skips (exit 0) when the browser tools are not built (inbrowser-assets.cjs).
//   node tools/wasm-explorer/test-inbrowser.cjs [FILE.c|.cpp|.ll|.ir ...]   the examples, or these files
const fs = require("fs");
const path = require("path");
const assets = require("./inbrowser-assets.cjs");
const { compile } = require("./pipeline.cjs");
const { makeCompiler } = require("./inbrowser.js");

const byExt = { ".cpp": "c++", ".c": "c", ".ll": "llvm", ".ir": "ir" };
async function main() {
  if (!assets.available()) {
    console.log("skip: the browser tools are not built " +
      "(PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh, scripts/setup-mruby-wasm.sh)");
    return;
  }
  const browser = makeCompiler(assets.load());
  const dir = path.join(__dirname, "examples");
  const cases = process.argv.length > 2
    ? process.argv.slice(2).map((f) => ({ id: f, file: path.resolve(f), language: byExt[path.extname(f)] }))
    : JSON.parse(fs.readFileSync(path.join(dir, "index.json"), "utf8"))
      .map((e) => ({ id: e.id, file: path.join(dir, e.file), language: e.language || "c++" }))
      .filter((e) => Object.values(byExt).includes(e.language));
  const { LANGUAGES } = require("./common.js");
  let pass = 0, fail = 0;
  for (const c of cases) {
    const source = fs.readFileSync(c.file, "utf8");
    for (const mode of LANGUAGES[c.language].modes) {
      const t0 = Date.now();
      const b = await browser(source, { language: c.language, mode });
      const ms = Date.now() - t0;
      const s = await compile(source, { language: c.language, mode });
      const same = b.ok === s.ok && (b.ok ? b.ir === s.ir && b.wasm === s.wasm : b.stage === s.stage);
      if (same) {
        pass++;
        const what = b.ok ? `${Buffer.from(b.wasm, "base64").length} bytes` : `${b.stage} error`;
        console.log(`ok   ${c.id} [${mode}] ${what}, ${ms} ms`);
      } else {
        fail++;
        const say = (r) => (r.ok ? "ok" : r.stage + ": " + r.message.split("\n")[0]);
        const which = b.ok && s.ok ? (b.ir === s.ir ? " (the modules differ)" : " (the IR differs)") : "";
        console.log(`FAIL ${c.id} [${mode}]: browser ${say(b)}, server ${say(s)}${which}`);
      }
    }
  }
  console.log(`test-inbrowser: ${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
