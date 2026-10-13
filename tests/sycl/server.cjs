// The WebGPU side of lib/sycl/include/sycl/rt_pipe.hpp: a Node process that owns a WebGPU device (Chromium's, through
// Playwright; SwiftShader gives a software adapter when there is no GPU) and serves the host program's requests over
// stdin/stdout. Usage: node server.cjs PREFIX.wgsl PREFIX.man. Messages are logged to stderr.
//
// Environment: NFCXX_PLAYWRIGHT (path of the playwright module), NFCXX_CHROMIUM (the browser executable),
//              NFCXX_WEBGPU_ARGS (extra Chromium flags), NFCXX_SYCL_TRACE=1 (log every request).
"use strict";
const fs = require("fs");
const path = require("path");

function findPlaywright() {
  const cands = [process.env.NFCXX_PLAYWRIGHT, "playwright", "/opt/node-tools/node_modules/playwright", "/usr/lib/node_modules/playwright",
    "/opt/node22/lib/node_modules/playwright"].filter(Boolean);
  for (const c of cands) { try { return require(c); } catch (e) { /* next */ } }
  throw new Error("cannot find the playwright module (set NFCXX_PLAYWRIGHT)");
}
function findChromium() {
  if (process.env.NFCXX_CHROMIUM) return process.env.NFCXX_CHROMIUM;
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || "/opt/pw-browsers";
  try {
    const dirs = fs.readdirSync(base).filter((d) => d.startsWith("chromium-")).sort().reverse();
    for (const d of dirs) {
      const p = path.join(base, d, "chrome-linux", "chrome");
      if (fs.existsSync(p)) return p;
    }
  } catch (e) { /* none */ }
  return undefined;   // let playwright pick its own
}

const probe = process.argv[2] === "--probe";   // exit 0 when a WebGPU adapter is available (tests/sycl/run.sh skips otherwise)
const wgsl = probe ? "" : fs.readFileSync(process.argv[2], "utf8");
const manifest = {};
let staticImage = null;
const relocs = [];
for (const line of probe ? [] : fs.readFileSync(process.argv[3], "utf8").split("\n")) {
  const [entry, key, size] = line.split("\t");
  if (entry === "S") staticImage = { size: Number(key), bytes: Buffer.from(size || "", "hex") };
  else if (entry === "R") relocs.push([Number(key), Number(size)]);
  else if (entry && key) manifest[key] = { entry, size: Number(size) };
}
const trace = process.env.NFCXX_SYCL_TRACE === "1";
const HEAP_BASE = 0x10000000;   // the device address of heap byte 0 (override HEAP_BASE in the WGSL, HEAP_BASE in rt_pipe.hpp)

// ---- page side: everything that touches the GPU
const pageSetup = async (wgslText, staticBase0) => {
  let staticBase = staticBase0 || 0;
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error("no WebGPU adapter");
  const heapSize = Math.min(adapter.limits.maxStorageBufferBindingSize, adapter.limits.maxBufferSize, 768 * 1024 * 1024);   // HEAP_BASE + heap must stay below the 0x40000000 tag bit
  const device = await adapter.requestDevice({ requiredLimits: {
    maxStorageBufferBindingSize: heapSize, maxBufferSize: heapSize, maxComputeWorkgroupStorageSize: Math.min(adapter.limits.maxComputeWorkgroupStorageSize, 32768) } });
  const errors = [];
  device.addEventListener("uncapturederror", (e) => errors.push(String(e.error && e.error.message)));
  const module = device.createShaderModule({ code: wgslText });
  const info = await module.getCompilationInfo();
  const msgs = info.messages.map((m) => `${m.type} ${m.lineNum}:${m.linePos}: ${m.message}`);
  if (info.messages.some((m) => m.type === "error")) return { error: msgs.join("\n") };
  const heap = device.createBuffer({ size: heapSize, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST });
  const args = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const clbuf = device.createBuffer({ size: 4096, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const bgl = device.createBindGroupLayout({ entries: [
    { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } },
    { binding: 1, visibility: GPUShaderStage.COMPUTE, buffer: { type: "uniform" } },
    { binding: 2, visibility: GPUShaderStage.COMPUTE, buffer: { type: "uniform" } }] });
  const layout = device.createPipelineLayout({ bindGroupLayouts: [bgl] });
  const bind = device.createBindGroup({ layout: bgl, entries: [{ binding: 0, resource: { buffer: heap } }, { binding: 1, resource: { buffer: args } }, { binding: 2, resource: { buffer: clbuf } }] });
  const stage = device.createBuffer({ size: 65536, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
  const bytes = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const b64 = (u8) => { let s = ""; for (let i = 0; i < u8.length; i += 8192) s += String.fromCharCode.apply(null, u8.subarray(i, i + 8192)); return btoa(s); };
  const pipes = new Map();
  window.G = {
    setStaticBase(v) { staticBase = v; },
    heapSize, maxWgInvocations: device.limits.maxComputeInvocationsPerWorkgroup, maxWgSize: [device.limits.maxComputeWorkgroupSizeX, device.limits.maxComputeWorkgroupSizeY, device.limits.maxComputeWorkgroupSizeZ],
    maxGroups: device.limits.maxComputeWorkgroupsPerDimension, maxWgStorage: device.limits.maxComputeWorkgroupStorageSize, adapterInfo: adapter.info ? `${adapter.info.vendor} ${adapter.info.architecture} ${adapter.info.description}` : "",
    msgs, errors,
    write(off, data64) {
      let u = bytes(data64);
      if (u.length & 3) { const t = new Uint8Array((u.length + 3) & ~3); t.set(u); u = t; }   // a tail of up to 3 bytes beyond the data is harmless
      device.queue.writeBuffer(heap, off, u);
    },
    async dispatch(entry, g, l, lmem, key, closure64) {
      if (l[0] * l[1] * l[2] > device.limits.maxComputeInvocationsPerWorkgroup || l[0] > device.limits.maxComputeWorkgroupSizeX || l[1] > device.limits.maxComputeWorkgroupSizeY || l[2] > device.limits.maxComputeWorkgroupSizeZ)
        return { error: `a work-group of ${l.join("x")} work-items exceeds the device limit (${device.limits.maxComputeInvocationsPerWorkgroup} work-items, ${device.limits.maxComputeWorkgroupSizeX}x${device.limits.maxComputeWorkgroupSizeY}x${device.limits.maxComputeWorkgroupSizeZ}); device::get_info<info::device::max_work_group_size> says ${device.limits.maxComputeInvocationsPerWorkgroup}` };
      if (lmem + 1024 > device.limits.maxComputeWorkgroupStorageSize)
        return { error: `${lmem} bytes of local memory (plus 1024 kept for the group algorithms) exceed the device limit of ${device.limits.maxComputeWorkgroupStorageSize}` };
      let c = bytes(closure64);
      if (c.length & 3) { const t = new Uint8Array((c.length + 3) & ~3); t.set(c); c = t; }
      if (c.length > 4096) return { error: `the kernel's captured state is ${c.length} bytes; the limit is 4096` };
      if (c.length) device.queue.writeBuffer(clbuf, 0, c);
      const wgWords = Math.max(1, (lmem + 3) >> 2);
      const pk = `${entry}/${l.join(",")}/${wgWords}`;
      let pipe = pipes.get(pk);
      if (!pipe) {
        pipe = await device.createComputePipelineAsync({ layout, compute: { module, entryPoint: entry,
          constants: { WGX: l[0], WGY: l[1], WGZ: l[2], WG_WORDS: wgWords, HEAP_BASE: 0x10000000, STATIC_BASE: staticBase } } });
        pipes.set(pk, pipe);
      }
      // a dispatch has at most maxComputeWorkgroupsPerDimension groups per dimension: larger ones run as several, with the
      // group offset in the uniform (the kernel adds it to the ids)
      const n = [0, 1, 2].map((i) => Math.ceil(g[i] / l[i])), lim = device.limits.maxComputeWorkgroupsPerDimension;
      for (let oz = 0; oz < n[2]; oz += lim)
        for (let oy = 0; oy < n[1]; oy += lim)
          for (let ox = 0; ox < n[0]; ox += lim) {
            device.queue.writeBuffer(args, 0, new Uint32Array([g[0], g[1], g[2], 0, ox, oy, oz, 0]));
            const enc = device.createCommandEncoder();
            const pass = enc.beginComputePass();
            pass.setPipeline(pipe);
            pass.setBindGroup(0, bind);
            pass.dispatchWorkgroups(Math.min(lim, n[0] - ox), Math.min(lim, n[1] - oy), Math.min(lim, n[2] - oz));
            pass.end();
            device.queue.submit([enc.finish()]);
          }
      return {};
    },
    async read(off, n) {
      const out = new Uint8Array(n);
      for (let p = 0; p < n; p += 65536) {
        const len = Math.min(65536, n - p), alen = (len + 3) & ~3;
        const enc = device.createCommandEncoder();
        enc.copyBufferToBuffer(heap, off + p, stage, 0, alen);
        device.queue.submit([enc.finish()]);
        await stage.mapAsync(GPUMapMode.READ, 0, alen);
        out.set(new Uint8Array(stage.getMappedRange(0, alen)).subarray(0, len), p);
        stage.unmap();
      }
      return b64(out);
    },
    async wait() {
      await device.queue.onSubmittedWorkDone();
      const enc = device.createCommandEncoder();
      enc.copyBufferToBuffer(heap, 0, stage, 0, 16);
      device.queue.submit([enc.finish()]);
      await stage.mapAsync(GPUMapMode.READ, 0, 16);
      const flag = new Uint32Array(stage.getMappedRange(0, 16).slice(0))[1];
      stage.unmap();
      if (flag) device.queue.writeBuffer(heap, 4, new Uint32Array([0]));
      return { flag, errors: errors.splice(0) };
    },
  };
  return { ok: true, heapSize, msgs, adapter: window.G.adapterInfo };
};

(async () => {
  const { chromium } = findPlaywright();
  const browser = await chromium.launch({ executablePath: findChromium(), args: ["--no-sandbox", "--enable-unsafe-webgpu", "--enable-features=Vulkan",
    "--use-webgpu-adapter=swiftshader", "--use-angle=swiftshader", "--enable-webgpu-developer-features", "--ignore-gpu-blocklist",
    ...(process.env.NFCXX_WEBGPU_ARGS ? process.env.NFCXX_WEBGPU_ARGS.split(" ") : [])] });
  const page = await browser.newPage();
  await page.route("**/*", (r) => r.fulfill({ body: "<html></html>", contentType: "text/html" }));
  await page.goto("http://localhost/");
  if (probe) {
    const ok = await page.evaluate(async () => !!(navigator.gpu && await navigator.gpu.requestAdapter()));
    process.stdout.write(ok ? "webgpu: yes\n" : "webgpu: no adapter\n");
    await browser.close();
    process.exit(ok ? 0 : 1);
  }
  const init = await page.evaluate(pageSetup, wgsl);
  if (init.error) { process.stderr.write("sycl server: WGSL does not compile:\n" + init.error + "\n"); await browser.close(); process.exit(2); }
  if (init.msgs.length && trace) process.stderr.write("sycl server: WGSL warnings:\n" + init.msgs.join("\n") + "\n");
  if (trace) process.stderr.write(`sycl server: adapter ${init.adapter}, heap ${init.heapSize} bytes\n`);

  // The device allocator: first fit over a free list, a bump pointer above it. Bytes 0..8191 are the trap flag and the closure.
  let next = 8192;
  const free = [];                 // [offset, size], sorted by offset
  const used = new Map();          // offset -> size
  function alloc(n) {
    n = Math.max(16, (n + 15) & ~15);
    for (let i = 0; i < free.length; i++) {
      if (free[i][1] >= n) {
        const off = free[i][0];
        if (free[i][1] === n) free.splice(i, 1); else { free[i][0] += n; free[i][1] -= n; }
        used.set(off, n);
        return off;
      }
    }
    if (next + n > init.heapSize) return -1;
    const off = next;
    next += n;
    used.set(off, n);
    return off;
  }
  function release(off) {
    const n = used.get(off);
    if (n === undefined) return;
    used.delete(off);
    if (off + n === next) { next = off; }
    else {
      let i = 0;
      while (i < free.length && free[i][0] < off) i++;
      free.splice(i, 0, [off, n]);
      for (let k = Math.max(0, i - 1); k < free.length - 1;) {
        if (free[k][0] + free[k][1] === free[k + 1][0]) { free[k][1] += free[k + 1][1]; free.splice(k + 1, 1); } else k++;
      }
    }
    // give a free block at the top back to the bump pointer
    while (free.length && free[free.length - 1][0] + free[free.length - 1][1] === next) { next = free[free.length - 1][0]; free.pop(); }
  }
  if (staticImage) {   // the constant tables and globals of the kernels: allocate, relocate, upload
    const off = alloc(staticImage.size), base = 0x10000000 + off;
    const img = Buffer.from(staticImage.bytes);
    for (const [o, t] of relocs) { img.writeUInt32LE(base + t, o); img.writeUInt32LE(0, o + 4); }
    await page.evaluate(([b, d, o]) => { window.G.setStaticBase(b); window.G.write(o, d); }, [base, img.toString("base64"), off]);
  }
  const send = (buf) => { const h = Buffer.alloc(4); h.writeUInt32LE(buf.length); process.stdout.write(Buffer.concat([h, buf])); };
  const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32LE(v >>> 0); return b; };
  let pending = Buffer.alloc(0), busy = Promise.resolve();

  async function handle(op, p) {
    if (op === 1) {
      const off = alloc(p.readUInt32LE(0));
      send(u32(off < 0 ? 0 : HEAP_BASE + off));
    } else if (op === 2) {
      const off = p.readUInt32LE(0) - HEAP_BASE;
      await page.evaluate(([o, d]) => window.G.write(o, d), [off, p.subarray(4).toString("base64")]);
    } else if (op === 3) {
      const off = p.readUInt32LE(0) - HEAP_BASE, n = p.readUInt32LE(4);
      const d = await page.evaluate(([o, n]) => window.G.read(o, n), [off, n]);
      send(Buffer.from(d, "base64"));
    } else if (op === 6) {
      release(p.readUInt32LE(0) - HEAP_BASE);
    } else if (op === 7) {
      send(u32(init.heapSize));
    } else if (op === 4) {
      const g = [0, 1, 2].map((i) => p.readUInt32LE(4 * i)), l = [3, 4, 5].map((i) => p.readUInt32LE(4 * i));
      const lmem = p.readUInt32LE(24), klen = p.readUInt32LE(28), clen = p.readUInt32LE(32);
      const key = p.subarray(36, 36 + klen).toString(), closure = p.subarray(36 + klen, 36 + klen + clen);
      const found = manifest[key], entry = found && found.entry;
      if (!entry) { process.stderr.write(`sycl server: no kernel for the closure type ${key}\n  the device image has:\n${Object.keys(manifest).map((k) => "    " + k).join("\n")}\n`); process.exit(3); }
      if (found.size && found.size !== clen) {
        process.stderr.write(`sycl server: the closure of ${key} is ${clen} bytes on the host but ${found.size} in the device pass.\n` +
          "  The host compiler lays the lambda out differently from the front end of the device pass (compile the host side with nfcxx,\n" +
          "  or avoid captures that differ, e.g. constants one compiler captures and the other folds).\n");
        process.exit(5);
      }
      if (trace) process.stderr.write(`sycl server: dispatch ${entry} global ${g} local ${l} closure ${clen} bytes\n`);
      const dr = await page.evaluate(([e, g, l, m, k, c]) => window.G.dispatch(e, g, l, m, k, c), [entry, g, l, lmem, key, closure.toString("base64")]);
      if (dr && dr.error) { process.stderr.write("sycl server: " + dr.error + "\n"); process.exit(6); }
    } else if (op === 5) {
      const r = await page.evaluate(() => window.G.wait());
      if (r.errors.length) process.stderr.write("sycl server: WebGPU errors:\n" + r.errors.join("\n") + "\n");
      send(u32(r.flag || (r.errors.length ? 99 : 0)));
    }
  }
  process.stdin.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    busy = busy.then(async () => {
      while (pending.length >= 8) {
        const op = pending.readUInt32LE(0), n = pending.readUInt32LE(4);
        if (pending.length < 8 + n) break;
        const p = pending.subarray(8, 8 + n);
        pending = pending.subarray(8 + n);
        await handle(op, p);
      }
    }).catch((e) => { process.stderr.write("sycl server: " + (e && e.stack || e) + "\n"); process.exit(4); });
  });
  process.stdin.on("end", () => busy.then(() => browser.close()).then(() => process.exit(0)));
})().catch((e) => { process.stderr.write("sycl server: " + (e && e.stack || e) + "\n"); process.exit(1); });
