// Host for a module built with pathb-wasm-emit.rb --threads: N worker threads, each with its own instance of the module
// over one shared memory. Usage: node host.cjs MODULE.wasm N ITER
//
// The module imports env.memory (shared, its page count in the custom section "nfcxx.threads"), exports
// __stack_pointer (each instance sets its own stack, below the others') and the functions of counter.cpp. The host owns the
// words the threads use (a 32-bit and a 64-bit counter, and one cell for the single-thread checks).
const { Worker, isMainThread, parentPort, workerData } = require("node:worker_threads");
const fs = require("node:fs");

const PAGE = 65536;
const STACK = 4096;   // bytes of stack per thread, below the top of the memory

function pagesOf(mod) {
  const sec = WebAssembly.Module.customSections(mod, "nfcxx.threads");
  if (sec.length !== 1 || sec[0].byteLength !== 4) throw new Error("module has no nfcxx.threads section (built with --threads?)");
  return new DataView(sec[0]).getUint32(0, true);
}

function instantiate(mod, memory) {
  return new WebAssembly.Instance(mod, { env: { memory } });
}

if (isMainThread) {
  const [file, nArg, iterArg] = process.argv.slice(2);
  const n = Number(nArg), iters = Number(iterArg);
  if (!file || !(n >= 1) || !(iters >= 0)) {
    console.error("usage: node host.cjs MODULE.wasm N ITER");
    process.exit(2);
  }
  const bytes = fs.readFileSync(file);
  const mod = new WebAssembly.Module(bytes);
  const pages = pagesOf(mod);
  const memory = new WebAssembly.Memory({ initial: pages, maximum: pages, shared: true });
  const top = pages * PAGE;
  if (n * STACK + 64 > top / 2) throw new Error("too many threads for the memory");
  // the words: the 32-bit counter, the 64-bit counter (8-aligned), and a cell for the single-thread checks
  const counter32 = top / 2;            // byte address
  const counter64 = top / 2 + 8;
  const cell = top / 2 + 16;
  const words = new Int32Array(memory.buffer);
  const big = new BigInt64Array(memory.buffer);

  let done = 0;
  const failures = [];
  for (let i = 0; i < n; i++) {
    const sp = top - i * STACK - 16;   // each thread's stack starts below the previous one's
    const w = new Worker(__filename, { workerData: { mod, memory, sp, iters, counter32, counter64 } });
    w.on("message", (m) => { if (m.error) failures.push(m.error); });
    w.on("error", (e) => failures.push(String(e)));
    w.on("exit", () => {
      if (++done === n) finish();
    });
  }

  function finish() {
    const want32 = n * iters;
    const got32 = Atomics.load(words, counter32 / 4);
    const got64 = Number(Atomics.load(big, counter64 / 8));
    let ok = failures.length === 0 && got32 === want32 && got64 === want32;
    console.log(`threads: ${n} x ${iters}: counter32 ${got32}, counter64 ${got64} (want ${want32} each)`);

    // single-thread checks on the same memory: load, store, exchange, compare-and-swap, fence
    const inst = instantiate(mod, memory);
    const ex = inst.exports;
    const check = (what, got, want) => {
      if (got !== want) { ok = false; console.log(`FAIL ${what}: got ${got}, want ${want}`); }
    };
    Atomics.store(words, cell / 4, 5);
    check("load", ex.load(BigInt(cell)), 5);
    ex.store(BigInt(cell), 7);
    check("store", Atomics.load(words, cell / 4), 7);
    check("exchange", ex.xchg(BigInt(cell), 9), 7);
    check("exchange stored", Atomics.load(words, cell / 4), 9);
    check("cas (expected 9) returns old", ex.cas(BigInt(cell), 9, 11), 9);
    check("cas stored", Atomics.load(words, cell / 4), 11);
    check("cas (expected 9, a miss) returns old", ex.cas(BigInt(cell), 9, 13), 11);
    check("cas miss leaves the value", Atomics.load(words, cell / 4), 11);
    ex.fence();
    for (const f of failures) { ok = false; console.log("FAIL worker: " + f); }
    console.log(ok ? "threads: ok" : "threads: FAILED");
    process.exit(ok ? 0 : 1);
  }
} else {
  // a worker: its own instance of the module over the shared memory, its own stack, then the adds
  const { mod, memory, sp, iters, counter32, counter64 } = workerData;
  try {
    const inst = instantiate(mod, memory);
    inst.exports.__stack_pointer.value = sp;
    inst.exports.bump(BigInt(counter32), iters);
    inst.exports.bump64(BigInt(counter64), iters);
    parentPort.postMessage({ done: true });
  } catch (e) {
    parentPort.postMessage({ error: String(e) });
  }
}
