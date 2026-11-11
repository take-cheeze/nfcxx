// The page's in-browser compile (index.html, on a static host): a worker that loads the front end and the emitter once
// (inbrowser.js: inbrowser/ of the site) and compiles each { id, source, options } it is sent, posting { id, result }
// (pipeline.cjs's result), or { id, progress } while the tools load.
importScripts("common.js", "inbrowser.js", "inbrowser/cpfe.js", "inbrowser/mruby.js");
let compiler = null;
onmessage = async (e) => {
  const { id, source, options } = e.data;
  try {
    if (!compiler) {
      postMessage({ id, progress: "loading the compiler (EDG's front end and the emitter, as wasm)…" });
      compiler = self.nfcxxInBrowser.makeCompiler(await self.nfcxxInBrowser.loadAssets("inbrowser/"));
    }
    postMessage({ id, result: await compiler(source, options) });
  } catch (err) {
    postMessage({ id, result: { ok: false, stage: "browser", diagnostics: [],
      message: "the in-browser compiler failed: " + ((err && err.message) || err) } });
  }
};
