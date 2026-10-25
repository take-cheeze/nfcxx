// The wasm explorer's compile without a server (docs/notes/pathb-wasm-frontend.md): the Path B front end built with
// Emscripten (cpfe.wasm, PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh) and the mruby interpreter built with it
// (mruby.wasm, scripts/setup-mruby-wasm.sh) running scripts/llvm-to-pathb.rb and scripts/pathb-wasm-emit.rb. It is
// pipeline.cjs's compile, step for step, for the languages whose front end runs here: C++, C, LLVM IR and the IR (Rust
// and Go need their compilers, so the server only). The C library and C++ library headers are not here: a program
// that includes one compiles on the server only. It runs in the page's worker (index.html) and under node
// (test-inbrowser.cjs).
//
// The assets (build-static.cjs writes them to inbrowser/ of the site):
//   manifest.json        { gnuVersion }: the GNU version the server's front end runs with (scripts/host-sys.sh)
//   cpfe.js, cpfe.wasm   the front end (createCpfe)          mruby.js, mruby.wasm   the interpreter (createMruby)
//   base.json            { path: text }: EDG's base directory (predefined macros, EDG's own headers)
//   pathb-wasm-emit.rb, llvm-to-pathb.rb
(function (root) {
  "use strict";
  const C = typeof module === "object" && module.exports ? require("./common.js") : root.nfcxxCommon;
  const BASE = "/edg-base";   // EDG's base directory in the front end's file system
  const WORK = "/work";       // the source and the IR
  const MAX_SOURCE = 64 * 1024;
  const utf8 = new TextEncoder();
  const text = (bytes) => new TextDecoder().decode(bytes);

  // Runs a tool once: { factory (createCpfe or createMruby), module (its compiled WebAssembly.Module) }, a fresh
  // instance with files ({ path: string or bytes }) in its file system. Resolves with
  // { status, stdout (bytes), stderr }.
  async function run(tool, argv, files, env, cwd) {
    const out = [], err = [];
    const m = await tool.factory({
      noInitialRun: true,
      instantiateWasm(imports, done) {
        WebAssembly.instantiate(tool.module, imports).then((instance) => done(instance, tool.module));
        return {};
      },
      quit(status, e) { throw e; },   // not the process's exit (node)
      preRun: [(mod) => {
        // stdout and stderr as bytes: the emitter writes a binary module to stdout
        mod.FS.init(null, (c) => { if (c !== null) out.push(c); }, (c) => { if (c !== null) err.push(c); });
        for (const p of Object.keys(files)) {
          mod.FS.mkdirTree(p.slice(0, p.lastIndexOf("/")) || "/");
          mod.FS.writeFile(p, files[p]);
        }
        Object.assign(mod.ENV, env || {});
        if (cwd) mod.FS.chdir(cwd);
      }],
    });
    let status;
    try {
      status = m.callMain(argv);
    } catch (e) {
      if (e && typeof e.status === "number") status = e.status;   // exit(), or main's return through it
      else {
        status = 4;   // a trap of the tool (a crash of the front end): as a catastrophe
        for (const b of utf8.encode(`${(e && e.message) || e}\n`)) err.push(b);
      }
    }
    return { status, stdout: Uint8Array.from(out), stderr: text(Uint8Array.from(err)) };
  }

  function base64(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return typeof btoa === "function" ? btoa(s) : Buffer.from(bytes).toString("base64");
  }

  // The compiler for the assets: { cpfe, mruby (tools, as run takes them), base ({ path: text }), emitter, llvmToPathb
  // (the scripts' text), gnuVersion }. compile(source, options) resolves as pipeline.cjs's compile.
  function makeCompiler(assets) {
    const baseFiles = {};
    for (const p of Object.keys(assets.base)) baseFiles[BASE + "/" + p] = assets.base[p];
    const scripts = { "/scripts/pathb-wasm-emit.rb": assets.emitter, "/scripts/llvm-to-pathb.rb": assets.llvmToPathb };
    const strip = (s) => s.split(WORK + "/").join("");   // the diagnostics and the IR name prog.c, as the server's

    // pathb-dump --ir, as the pipeline runs it (scripts/pathb-dump): hosted (the GNU version of the server's front end,
    // no system include directories) or, in the emscripten mode, freestanding for EDG's linux_riscv32
    function frontEndArgs(language, std, mode, file) {
      const freestanding = C.MODES[mode].dump.includes("--freestanding");
      const target = (C.MODES[mode].dump.find((a) => a.startsWith("--target=")) || "").slice(9);
      const s = std ? "--" + std : language === "c" ? "--c17" : "--c++23";
      const cxx = s.startsWith("--c++");
      return ["-D_POSIX_SOURCE", "-D__CHAR_BIT__=8", s, cxx ? "--g++" : "--gcc", "--wdir", "/",
        ...(!freestanding && assets.gnuVersion ? ["--gnu_version=" + assets.gnuVersion] : []),
        ...(cxx ? ["-tused"] : []),
        ...(target ? ["--target", target, "--signed_chars"] : []), "--sys_include=" + BASE + "/include", file];
    }

    return async function compile(source, options = {}) {
      const bad = C.checkOptions(options);
      if (bad) return { ok: false, stage: "request", message: bad, diagnostics: [] };
      if (typeof source !== "string") {
        return { ok: false, stage: "request", message: "source must be a string", diagnostics: [] };
      }
      if (utf8.encode(source).length > MAX_SOURCE) {
        return { ok: false, stage: "request", message: `source is over ${MAX_SOURCE} bytes`, diagnostics: [] };
      }
      const language = options.language || "c++";
      const mode = options.mode || "lp64";
      const std = options.std || "";
      if (language === "rust" || language === "go" || language === "swift") {
        return { ok: false, stage: "browser", diagnostics: [],
          message: `${C.LANGUAGES[language].title} needs its compiler, which runs on the server only` };
      }
      const failed = (stage, r) => {
        const message = strip(r.stderr).trim() || `exit status ${r.status}`;
        return { ok: false, stage, message, diagnostics: C.parseDiagnostics(message), code: r.status };
      };
      let irText, frontStderr = "";
      if (language === "ir") {
        irText = C.stripIrComments(source);
      } else if (language === "llvm") {
        const r = await run(assets.mruby, ["/scripts/llvm-to-pathb.rb", WORK + "/prog.ll"],
          Object.assign({ [WORK + "/prog.ll"]: source }, scripts));
        if (r.status !== 0) return failed("front-end", r);
        irText = text(r.stdout);
        frontStderr = r.stderr;
      } else {
        const file = WORK + "/" + C.LANGUAGES[language].file;
        const r = await run(assets.cpfe, frontEndArgs(language, std, mode, file),
          Object.assign({ [file]: source }, baseFiles),
          { NFCXX_PATHB_MODE: "ir", NFCXX_IR_LOC: "1", EDG_BASE: BASE }, BASE);
        if (r.status !== 0) return failed("front-end", r);
        irText = strip(text(r.stdout));
        frontStderr = strip(r.stderr);
      }
      const e = await run(assets.mruby,
        ["/scripts/pathb-wasm-emit.rb", "--names", ...C.MODES[mode].emit, WORK + "/prog.ir"],
        Object.assign({ [WORK + "/prog.ir"]: irText }, scripts));
      if (e.status !== 0) return failed("emit", e);
      // names: the server demangles the IR's names with c++filt (pipeline.cjs, demangleNames); there is none here
      return { ok: true, ir: irText, wasm: base64(e.stdout), names: {}, diagnostics: C.parseDiagnostics(frontStderr),
        language, mode, std };
    };
  }

  // The assets from a directory URL (a page or a worker): the tools' scripts must be loaded already (createCpfe and
  // createMruby defined, e.g. by importScripts of inbrowser/cpfe.js and inbrowser/mruby.js).
  async function loadAssets(url) {
    const get = async (name, how) => {
      const r = await fetch(url + name);
      if (!r.ok) throw new Error(`${url}${name}: ${r.status}`);
      return how === "json" ? r.json() : r.text();
    };
    const wasm = async (name) => WebAssembly.compile(await (await fetch(url + name)).arrayBuffer());
    const [manifest, base, emitter, llvmToPathb, cpfeModule, mrubyModule] = await Promise.all([
      get("manifest.json", "json"), get("base.json", "json"), get("pathb-wasm-emit.rb"), get("llvm-to-pathb.rb"),
      wasm("cpfe.wasm"), wasm("mruby.wasm")]);
    return {
      cpfe: { factory: root.createCpfe, module: cpfeModule },
      mruby: { factory: root.createMruby, module: mrubyModule },
      base, emitter, llvmToPathb, gnuVersion: manifest.gnuVersion,
    };
  }

  const api = { makeCompiler, loadAssets, run, BASE, WORK };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.nfcxxInBrowser = api;
})(typeof self !== "undefined" ? self : this);
