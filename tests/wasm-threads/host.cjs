// Host for a module built with pathb-wasm-emit.rb --threads. Usage: node host.cjs MODULE.wasm N ITER
//
// Threads are instances of the module over one shared memory, each with its own stack (global 0, __stack_pointer) and its
// own block of the thread-local group (global 1, __tls_base). The module's data is applied once (__nfcxx_init).
//
// Two ways to start a thread:
//  - the host starts N "manual" workers (the first test), each calling the exported bump functions;
//  - the module calls pthread_create / pthread_join, which are env imports served here: a create takes a slot from a
//    shared pool, starts a worker that calls __nfcxx_thread_entry(slot-of-the-start-routine, arg), and the worker publishes
//    its result and wakes the joiner through a shared word.
const { Worker, isMainThread, parentPort, workerData } = require("node:worker_threads");
const fs = require("node:fs");

const PAGE = 65536;
const STACK = 1024;        // bytes of stack per thread, below the top of the memory
const POOL = 8;            // threads the module can create (pthread_create)
const MANUAL = 8;          // manual workers the host starts (slots after the pool)
const EAGAIN = 11;

function threadsSection(mod) {
  const sec = WebAssembly.Module.customSections(mod, "nfcxx.threads");
  if (sec.length !== 1 || sec[0].byteLength !== 12) throw new Error("module has no nfcxx.threads section (built with --threads?)");
  const dv = new DataView(sec[0]);
  return { pages: dv.getUint32(0, true), tlsStart: dv.getUint32(4, true), tlsSize: dv.getUint32(8, true) };
}

// The shared layout, from the memory's size and the thread-local group's size (the same in every thread).
function layout(memory, tlsSize) {
  const top = memory.buffer.byteLength;
  const hostBase = top / 2;
  const block = Math.max(16, Math.ceil(tlsSize / 16) * 16);
  return {
    top, hostBase, block,
    counter32: hostBase,           // byte addresses
    counter64: hostBase + 8,
    cell: hostBase + 16,
    poolCounter: hostBase + 32,    // i32: the next pool slot
    joinBase: hostBase + 64,       // POOL join words, 16 bytes each: done (i32) at +0, the result (i64) at +8
    template: hostBase + 256,      // the group's initial image, copied here once (up to 256 bytes)
    blocks: hostBase + 512,        // thread slot s's block: blocks + s * block
  };
}

function slotStack(L, s) { return L.top - (s + 1) * STACK - 16; }

function instantiate(mod, memory, env) {
  return new WebAssembly.Instance(mod, { env: Object.assign({ memory }, env) });
}

// env: the imports the module may call. The pthread functions start threads from any thread (a pool slot is taken from the
// shared counter), so each instance gets the same ones.
function envFor(ctx) {
  const { mod, memory, tlsSize } = ctx;
  const words = new Int32Array(memory.buffer);
  const big = new BigInt64Array(memory.buffer);
  return {
    pthread_create(th, attr, start, arg) {
      const L = layout(memory, tlsSize);
      const k = Atomics.add(words, L.poolCounter / 4, 1);
      if (k >= POOL) return EAGAIN;
      const joinAddr = L.joinBase + k * 16;
      Atomics.store(words, joinAddr / 4, 0);
      big[Number(th) / 8] = BigInt(k + 1);          // the handle, for pthread_join
      new Uint8Array(memory.buffer, L.blocks + k * L.block, tlsSize).set(
        new Uint8Array(memory.buffer, L.template, tlsSize));
      spawn(ctx, { mode: "thread", slot: k, start: Number(start), arg, joinAddr });
      return 0;
    },
    pthread_join(th, retPtr) {
      const L = layout(memory, tlsSize);
      const k = Number(th) - 1;
      if (k < 0 || k >= POOL) return EAGAIN;
      const joinAddr = L.joinBase + k * 16;
      while (Atomics.load(words, joinAddr / 4) === 0) Atomics.wait(words, joinAddr / 4, 0);
      if (retPtr) big[Number(retPtr) / 8] = big[(joinAddr + 8) / 8];
      return 0;
    },
  };
}

// Starts a worker thread: slot s runs over the shared memory with its own stack and thread-local block (copied from the
// group's initial image). The worker's program is the object: a manual one or a module-created thread.
function spawn(ctx, job) {
  const { mod, memory, tlsSize } = ctx;
  const L = layout(memory, tlsSize);
  const s = job.slot;
  const blockBase = L.blocks + s * L.block;
  if (job.mode === "manual") new Uint8Array(memory.buffer, blockBase, tlsSize).set(new Uint8Array(memory.buffer, L.template, tlsSize));
  return new Worker(__filename, { workerData: { mod, memory, tlsSize, sp: slotStack(L, s), tlsBase: blockBase, job } });
}

if (isMainThread) {
  const [file, nArg, iterArg] = process.argv.slice(2);
  const n = Number(nArg), iters = Number(iterArg);
  if (!file || !(n >= 1) || !(iters >= 0) || n > MANUAL) {
    console.error(`usage: node host.cjs MODULE.wasm N ITER   (1 <= N <= ${MANUAL})`);
    process.exit(2);
  }
  const bytes = fs.readFileSync(file);
  const mod = new WebAssembly.Module(bytes);
  const { pages, tlsStart, tlsSize } = threadsSection(mod);
  if (tlsSize > 256) throw new Error("the thread-local group is larger than the host's template area");
  const memory = new WebAssembly.Memory({ initial: pages, maximum: pages, shared: true });
  const L = layout(memory, tlsSize);
  if (L.blocks + (POOL + MANUAL) * L.block > slotStack(L, POOL + MANUAL)) throw new Error("the memory is too small for the threads");
  const words = new Int32Array(memory.buffer);
  const big = new BigInt64Array(memory.buffer);
  const ctx = { mod, memory, tlsSize };

  // the first instance applies the module's data (__nfcxx_init); the threads' instances do not. Its own block is the group.
  const first = instantiate(mod, memory, envFor(ctx));
  first.exports.__nfcxx_init();
  const sharedInit = Number(first.exports.shared_addr());
  new Uint8Array(memory.buffer, L.template, tlsSize).set(new Uint8Array(memory.buffer, tlsStart, tlsSize));

  // The manual workers: slots POOL .. POOL+n-1. Their results come back as messages; the checks run when all have exited.
  let done = 0;
  const failures = [];
  const tlResults = [];
  for (let i = 0; i < n; i++) {
    const w = spawn(ctx, { mode: "manual", slot: POOL + i, iters, counter32: L.counter32, counter64: L.counter64 });
    w.on("message", (m) => { if (m.error) failures.push(m.error); else tlResults.push(m.tl); });
    w.on("error", (e) => failures.push(String(e)));
    w.on("exit", () => { if (++done === n) finish(); });
  }

  function finish() {
    const want32 = n * iters;
    const got32 = Atomics.load(words, L.counter32 / 4);
    const got64 = Number(Atomics.load(big, L.counter64 / 8));
    const gotShared = Atomics.load(words, sharedInit / 4);
    let ok = failures.length === 0 && got32 === want32 && got64 === want32 && gotShared === 100 + want32;
    console.log(`threads: ${n} x ${iters}: counter32 ${got32}, counter64 ${got64}, shared_init ${gotShared} ` +
                `(want ${want32}, ${want32}, ${100 + want32})`);

    const ex = first.exports;
    const badTl = tlResults.filter((v) => v !== 5 + iters);
    if (tlResults.length !== n || badTl.length) { ok = false; console.log(`FAIL thread-local: ${JSON.stringify(tlResults)}, want ${5 + iters} each`); }
    if (ex.tl_get() !== 5) { ok = false; console.log(`FAIL main thread-local: ${ex.tl_get()}, want 5`); }

    // threads the module creates: run_threads(k) starts k threads, joins them, and sums their results (10 * (1 + .. + k))
    const k = 4;
    const sum = ex.run_threads(k);
    const wantSum = 10 * (k * (k + 1) / 2);
    const joined = ex.joined_get();
    if (sum !== wantSum || joined !== k * 1000) { ok = false; console.log(`FAIL pthread: sum ${sum} (want ${wantSum}), joined counter ${joined} (want ${k * 1000})`); }
    else console.log(`pthread: ${k} threads created and joined: sum ${sum}, counter ${joined}`);

    // single-thread checks on the same memory: load, store, exchange, compare-and-swap, fence
    const check = (what, got, want) => {
      if (got !== want) { ok = false; console.log(`FAIL ${what}: got ${got}, want ${want}`); }
    };
    const cell = L.cell;
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
  // a worker: its own instance over the shared memory, with its stack and thread-local block set first
  const { mod, memory, tlsSize, sp, tlsBase, job } = workerData;
  try {
    const inst = instantiate(mod, memory, envFor({ mod, memory, tlsSize }));
    inst.exports.__stack_pointer.value = sp;
    inst.exports.__tls_base.value = tlsBase;
    if (job.mode === "manual") {
      inst.exports.bump(BigInt(job.counter32), job.iters);
      inst.exports.bump64(BigInt(job.counter64), job.iters);
      inst.exports.bump_shared(job.iters);
      const tl = inst.exports.tl_bump(job.iters);
      parentPort.postMessage({ done: true, tl });
    } else {
      // a module-created thread: the start routine at table slot job.start, with arg; the result goes to the join word
      const r = inst.exports.__nfcxx_thread_entry(job.start, job.arg);
      const words = new Int32Array(memory.buffer);
      const big = new BigInt64Array(memory.buffer);
      big[(job.joinAddr + 8) / 8] = r;
      Atomics.store(words, job.joinAddr / 4, 1);
      Atomics.notify(words, job.joinAddr / 4);
    }
  } catch (e) {
    parentPort && parentPort.postMessage({ error: String(e) });
  }
}
