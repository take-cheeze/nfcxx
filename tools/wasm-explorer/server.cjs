// The wasm explorer's server: serves index.html, the examples, and POST /api/compile, which compiles the posted C++
// with the pipeline in pipeline.cjs. The page also runs without this server, on a static host (build-static.cjs).
//
// Usage: node tools/wasm-explorer/server.cjs [--port 8080] [--host 127.0.0.1]
// It listens on localhost by default: the endpoint runs the compiler on whatever source it is sent, so do not expose it
// on a network without a limit you trust (docs/notes/wasm-explorer.md).
const http = require("http");
const fs = require("fs");
const path = require("path");
const { compile, MAX_SOURCE, root } = require("./pipeline.cjs");

const here = __dirname;
const examplesDir = path.join(here, "examples");
const MAX_JOBS = 2;   // compiles in flight; more get 503 rather than queueing without bound
const TYPES = { ".html": "text/html; charset=utf-8", ".cpp": "text/plain; charset=utf-8", ".json": "application/json" };

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const port = Number(opt("--port", "8080"));
const host = opt("--host", "127.0.0.1");

let jobs = 0;

function send(res, status, type, body) {
  res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store" });
  res.end(body);
}

function sendJson(res, status, value) {
  send(res, status, "application/json", JSON.stringify(value));
}

// Reads the body up to limit bytes. Past it the rest is drained (not kept) so the client gets the 413 reply.
class TooLarge extends Error {}
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

// Serves a file under examples/ (only .cpp and .json there). The resolved path must stay inside examples/.
function serveExample(res, name) {
  const file = path.resolve(examplesDir, name);
  if (!file.startsWith(examplesDir + path.sep) || !TYPES[path.extname(file)]) {
    return send(res, 404, "text/plain; charset=utf-8", "not found\n");
  }
  fs.readFile(file, (err, data) => {
    if (err) return send(res, 404, "text/plain; charset=utf-8", "not found\n");
    send(res, 200, TYPES[path.extname(file)], data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
    return send(res, 200, TYPES[".html"], fs.readFileSync(path.join(here, "index.html")));
  }
  if (req.method === "GET" && url.pathname.startsWith("/examples/")) {
    return serveExample(res, url.pathname.slice("/examples/".length));
  }
  if (req.method === "GET" && url.pathname === "/api/health") {
    const ready = ["pathb-dump", "mrb"].every((n) => fs.existsSync(path.join(root, "scripts", n)))
      && fs.existsSync(path.join(root, "scripts", "pathb-wasm-emit.rb"));
    return sendJson(res, 200, { ok: true, ready, live: true });
  }
  if (req.method === "POST" && url.pathname === "/api/compile") {
    let body;
    try {
      body = JSON.parse(await readBody(req, MAX_SOURCE + 1024));
    } catch (e) {
      if (e instanceof TooLarge) {
        return sendJson(res, 413, { ok: false, stage: "request", message: `source is over ${MAX_SOURCE} bytes`, diagnostics: [] });
      }
      return sendJson(res, 400, { ok: false, stage: "request", message: "bad request: " + e.message, diagnostics: [] });
    }
    if (jobs >= MAX_JOBS) {
      return sendJson(res, 503, { ok: false, stage: "request", message: "busy, try again", diagnostics: [] });
    }
    jobs++;
    try {
      const result = await compile(body.source, body.options || {});
      return sendJson(res, 200, result);
    } catch (e) {
      return sendJson(res, 500, { ok: false, stage: "server", message: String((e && e.message) || e), diagnostics: [] });
    } finally {
      jobs--;
    }
  }
  send(res, 404, "text/plain; charset=utf-8", "not found\n");
});

server.listen(port, host, () => {
  console.log(`wasm explorer: http://${host}:${port}/`);
});
