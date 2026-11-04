// Host for a module built with pathb-wasm-emit.rb --threads: N worker threads, each with its own instance of the module
// over one shared memory. Usage: node host.cjs MODULE.wasm N ITER
//
// The module imports env.memory (shared; its page count and the thread-local group, [tlsStart, tlsStart + tlsSize), are in
// the custom section "nfcxx.threads"), exports __stack_pointer (global 0), __tls_base (global 1: the base of this thread's
// block of the group), __nfcxx_init (the data, applied once), and the functions of counter.cpp. The host owns the words the
// threads use, and gives each thread a block of the group (a copy of the initial image) and a stack.
const { Worker, isMainThread, parentPort, workerData } = require("node:worker_threads");
const fs = require("node:fs");

const PAGE = 65536;
const STACK = 4096;   // bytes of stack per thread, below the top of the memory

function threadsSection(mod) {
  const sec = WebAssembly.Module.customSections(mod, "nfcxx.threads");
  if (sec.length !== 1 || sec[0].byteLength !== 12) throw new Error("module has no nfcxx.threads section (built with --threads?)");
  const dv = new DataView(sec[0]);
  return { pages: dv.getUint32(0, true), tlsStart: dv.getUint32(4, true), tlsSize: dv.getUint32(8, true) };
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
  const { pages, tlsStart, tlsSize } = threadsSection(mod);
  const memory = new WebAssembly.Memory({ initial: pages, maximum: pages, shared: true });
  const top = pages * PAGE;
  // the layout: the stacks grow down from the top; the host's words and the thread-local blocks are in the middle
  const block = Math.ceil(tlsSize / 16) * 16;
  const hostBase = top / 2;
  const counter32 = hostBase;           // byte addresses
  const counter64 = hostBase + 8;
  const cell = hostBase + 16;
  const blocks = hostBase + 256;        // thread i's block of the group: blocks + i * block
  if (n * STACK + 64 > top / 2 || blocks + n * block > top - n * STACK) throw new Error("too many threads for the memory");
  const words = new Int32Array(memory.buffer);
  const big = new BigInt64Array(memory.buffer);

  // the first instance applies the module's data (__nfcxx_init); the thread instances do not. Its own block is the group.
  const first = instantiate(mod, memory);
  first.exports.__nfcxx_init();
  const sharedInit = Number(first.exports.shared_addr());
  const template = new Uint8Array(memory.buffer, tlsStart, tlsSize).slice();

  let done = 0;
  const failures = [];
  const tlResults = [];
  for (let i = 0; i < n; i++) {
    const sp = top - i * STACK - 16;   // each thread's stack starts below the previous one's
    const blockBase = blocks + i * block;
    new Uint8Array(memory.buffer, blockBase, tlsSize).set(template);   // the thread's copy of the group
    const w = new Worker(__filename, { workerData: { mod, memory, sp, tlsBase: blockBase, iters, counter32, counter64 } });
    w.on("message", (m) => {
      if (m.error) failures.push(m.error);
      else tlResults.push(m.tl);
    });
    w.on("error", (e) => failures.push(String(e)));
    w.on("exit", () => {
      if (++done === n) finish();
    });
  }

  function finish() {
    const want32 = n * iters;
    const got32 = Atomics.load(words, counter32 / 4);
    const got64 = Number(Atomics.load(big, counter64 / 8));
    const gotShared = Atomics.load(words, sharedInit / 4);
    let ok = failures.length === 0 && got32 === want32 && got64 === want32 && gotShared === 100 + want32;
    console.log(`threads: ${n} x ${iters}: counter32 ${got32}, counter64 ${got64}, shared_init ${gotShared} ` +
                `(want ${want32}, ${want32}, ${100 + want32})`);

    // each thread's thread-local counts its own adds from the initial 5; the main thread's copy is untouched
    const badTl = tlResults.filter((v) => v !== 5 + iters);
    if (tlResults.length !== n || badTl.length) { ok = false; console.log(`FAIL thread-local: ${JSON.stringify(tlResults)}, want ${5 + iters} each`); }
    const ex = first.exports;
    if (ex.tl_get() !== 5) { ok = false; console.log(`FAIL main thread-local: ${ex.tl_get()}, want 5`); }

    // single-thread checks on the same memory: load, store, exchange, compare-and-swap, fence
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
  // a worker: its own instance of the module over the shared memory, its own stack and thread-local block, then the adds
  const { mod, memory, sp, tlsBase, iters, counter32, counter64 } = workerData;
  try {
    const inst = instantiate(mod, memory);
    inst.exports.__stack_pointer.value = sp;
    inst.exports.__tls_base.value = tlsBase;
    inst.exports.bump(BigInt(counter32), iters);
    inst.exports.bump64(BigInt(counter64), iters);
    inst.exports.bump_shared(iters);
    const tl = inst.exports.tl_bump(iters);
    parentPort.postMessage({ done: true, tl });
  } catch (e) {
    parentPort.postMessage({ error: String(e) });
  }
}
