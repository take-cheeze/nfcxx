// Runs a module under the real Emscripten glue: createGlue from a MODULARIZE build by emcc (tests/wasm/run.sh makes it
// with NFCXX_WASM_EMSCRIPTEN=glue). It instantiates the module with the glue's own imports and calls _main. Prints the
// result, "trap" for a wasm trap, or "skip: ..." when the glue cannot instantiate the module (a function import it does
// not provide: a LinkError, which the glue reports inside its own abort message).
const fs = require("fs");
const path = require("path");
const createGlue = require(path.resolve(process.argv[2]));
const bytes = fs.readFileSync(process.argv[3]);
createGlue({ wasmBinary: bytes, noInitialRun: true, print: () => {}, printErr: () => {} })
  .then((M) => {
    try {
      console.log(String(M._main()));
    } catch (e) {
      console.log(e instanceof WebAssembly.RuntimeError ? "trap" : `error: ${e.message}`);
    }
  })
  .catch((e) => {
    // the glue reports a failed instantiation as Aborted(LinkError: ...), a RuntimeError whose message names the LinkError
    if (/LinkError/.test(e && e.message)) console.log(`skip: ${e.message}`);
    else console.log(`error: ${e && e.message}`);
  });
