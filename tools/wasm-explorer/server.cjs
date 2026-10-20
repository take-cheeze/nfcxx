// The wasm explorer's server: serves index.html and compiles the posted C++ to WebAssembly with the Path B pipeline,
// which needs the harness and the mruby tool (scripts/setup-pathb.sh, scripts/setup-mruby.sh). Each request runs
//   scripts/pathb-dump --ir prog.cpp        the mid-level IR (docs/notes/pathb-stage2.md)
//   scripts/mrb scripts/pathb-wasm-emit.rb  the wasm module, in the binary format
// in a fresh temporary directory. The compiler is a native program, so this runs on the server, not in the browser; the
// module it returns runs in the browser with the WebAssembly API.
//
// Usage: node tools/wasm-explorer/server.cjs [--port 8080] [--host 127.0.0.1]
// It listens on localhost by default: the endpoint runs the compiler on whatever source it is sent, so do not expose it
// on a network without a limit you trust (see docs/notes/wasm-explorer.md).
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const pageFile = path.join(__dirname, "index.html");
const pathbDump = path.join(root, "scripts", "pathb-dump");
const mrb = path.join(root, "scripts", "mrb");
const emitter = path.join(root, "scripts", "pathb-wasm-emit.rb");

const MAX_SOURCE = 64 * 1024;   // bytes of C++ per request
const STEP_TIMEOUT = 60000;     // ms per compiler step
const MAX_JOBS = 2;             // compiles in flight; more get 503 rather than queueing without bound

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const port = Number(opt("--port", "8080"));
const host = opt("--host", "127.0.0.1");

let jobs = 0;

// Runs a command and resolves with its stdout (a Buffer), or rejects with { stage, message } on a non-zero exit.
function run(stage, file, argv, cwd) {
  return new Promise((resolve, reject) => {
    execFile(file, argv, { cwd, timeout: STEP_TIMEOUT, encoding: "buffer", maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (!err) return resolve(stdout);
        const text = String(stderr || "").trim() || (err.killed ? "timed out" : err.message);
        reject({ stage, message: text, code: typeof err.code === "number" ? err.code : null });
      });
  });
}

// A failed step gives { ok: false, stage, message, code }: the emitter's refusals have code 3 and name the node refused.
async function compile(source) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nfcxx-explorer-"));
  try {
    const cpp = path.join(dir, "prog.cpp");
    const ir = path.join(dir, "prog.ir");
    fs.writeFileSync(cpp, source);
    const irText = await run("front-end", pathbDump, ["--ir", cpp], root).catch((e) => {
      throw { ...e, message: e.message.split(dir + path.sep).join("") };   // diagnostics name the temporary file
    });
    fs.writeFileSync(ir, irText);
    const wasm = await run("emit", mrb, [emitter, ir], root);
    return { ok: true, ir: irText.toString("utf8"), wasm: wasm.toString("base64") };
  } catch (e) {
    if (e && e.stage) {
      return { ok: false, stage: e.stage, message: e.message, code: e.code };
    }
    throw e;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function send(res, status, type, body) {
  res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store" });
  res.end(body);
}

// Reads the body up to limit bytes. Past it the rest is drained (not kept) so the client gets the 413 reply.
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let tooLarge = false;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) tooLarge = true;
      if (!tooLarge) chunks.push(c);
    });
    req.on("end", () => (tooLarge ? reject(new TooLarge()) : resolve(Buffer.concat(chunks).toString("utf8"))));
    req.on("error", reject);
  });
}

class TooLarge extends Error {}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
    return send(res, 200, "text/html; charset=utf-8", fs.readFileSync(pageFile));
  }
  if (req.method === "GET" && url.pathname === "/api/health") {
    const ready = fs.existsSync(pathbDump) && fs.existsSync(mrb) && fs.existsSync(emitter);
    return send(res, 200, "application/json", JSON.stringify({ ok: true, ready }));
  }
  if (req.method === "POST" && url.pathname === "/api/compile") {
    let body;
    try {
      body = JSON.parse(await readBody(req, MAX_SOURCE + 1024));
    } catch (e) {
      if (e instanceof TooLarge) {
        return send(res, 413, "application/json", JSON.stringify({ ok: false, stage: "request", message: `source is over ${MAX_SOURCE} bytes` }));
      }
      return send(res, 400, "application/json", JSON.stringify({ ok: false, stage: "request", message: "bad request: " + e.message }));
    }
    if (typeof body.source !== "string") {
      return send(res, 400, "application/json", JSON.stringify({ ok: false, stage: "request", message: "source must be a string" }));
    }
    if (Buffer.byteLength(body.source) > MAX_SOURCE) {
      return send(res, 413, "application/json", JSON.stringify({ ok: false, stage: "request", message: `source is over ${MAX_SOURCE} bytes` }));
    }
    if (jobs >= MAX_JOBS) {
      return send(res, 503, "application/json", JSON.stringify({ ok: false, stage: "request", message: "busy, try again" }));
    }
    jobs++;
    try {
      const result = await compile(body.source);
      return send(res, 200, "application/json", JSON.stringify(result));
    } catch (e) {
      return send(res, 500, "application/json", JSON.stringify({ ok: false, stage: "server", message: String(e && e.message || e) }));
    } finally {
      jobs--;
    }
  }
  send(res, 404, "text/plain; charset=utf-8", "not found\n");
});

server.listen(port, host, () => {
  console.log(`wasm explorer: http://${host}:${port}/`);
});
