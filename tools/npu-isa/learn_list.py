import re, os, json, subprocess, shutil, struct, sys
HOST = os.path.expanduser("~/.wine-movi/drive_c/movi/host")
TOK_REG = re.compile(r"^i(\d+)(\.\d)?$")
TOK_NUM = re.compile(r"^-?(0x[0-9a-fA-F]+|\d+)$")
REGV = [1, 2, 3, 4, 5, 8, 9, 16, 17, 30, 31]
IMMV = list(range(0, 32)) + [64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 0x800, 0x1000]
def run_batch(lines, name):
    with open(f"{HOST}/{name}.in", "w") as f: f.write("\n".join(lines) + "\n")
    subprocess.run(["wine", "C:\\movi\\host\\asmbatch.exe", "C:\\movi\\MVC_DEPEND", f"C:\\movi\\host\\{name}.in",
                    f"C:\\movi\\host\\{name}.out", "5000xx"], capture_output=True,
                   env=dict(os.environ, WINEPREFIX=os.path.expanduser("~/.wine-movi"), WINEDEBUG="-all"))
    return [l.rstrip("\n").split("\t") for l in open(f"{HOST}/{name}.out")]
def word_of(objhex):
    d = bytes.fromhex(objhex); so = struct.unpack_from("<I", d, 0x20)[0]; se, sn, ss = struct.unpack_from("<HHH", d, 0x2e)
    secs = [struct.unpack_from("<IIIIIIIIII", d, so + i * se) for i in range(sn)]; st = secs[ss]
    nm = lambda o: d[st[4] + o:d.index(b"\0", st[4] + o)].decode()
    for s in secs:
        if nm(s[0]) == ".text": return d[s[4]:s[4] + s[5]]
def learn(templates):
    res = {}
    for t in templates:
        toks = t.split(" "); lines = [t]; meta = [None]
        for si, tok in enumerate(toks):
            if si == 0: continue
            if TOK_REG.match(tok):
                suf = TOK_REG.match(tok).group(2) or ""
                vals = [("reg", v) for v in REGV]
            elif TOK_NUM.match(tok):
                suf = ""; vals = [("imm", v) for v in IMMV]
            else: continue
            for kind, v in vals:
                nt = list(toks); nt[si] = (f"i{v}{suf}" if kind == "reg" else str(v))
                lines.append(" ".join(nt)); meta.append((si, v))
        out = run_batch(lines, "ll")
        base = out[0]
        if base[1] != "OK": res[t] = {"error": base[3][:120] if len(base) > 3 else "ERR"}; continue
        B = word_of(base[2]); nb = len(B); bw = int.from_bytes(B, "little")
        flips = 0; fields = {}
        for (si, v), o in zip(meta[1:], out[1:]):
            if o[1] != "OK": continue
            V = word_of(o[2])
            if len(V) != nb: continue
            x = int.from_bytes(V, "little") ^ bw; flips |= x
            fields.setdefault(si, {"bits": 0, "s": []})
            fields[si]["bits"] |= x; fields[si]["s"].append((v, int.from_bytes(V, "little")))
        nbits = 8 * nb
        entry = {"len": nb, "fixed_mask": ((1 << nbits) - 1) & ~flips, "fixed_val": bw & (((1 << nbits) - 1) & ~flips), "fields": {}, "toks": toks}
        ok = True
        for si, f in fields.items():
            bits = [b for b in range(nbits) if f["bits"] >> b & 1]
            sh = None
            for cand in range(0, 20):
                if all(sum(((w >> b) & 1) << k for k, b in enumerate(bits)) == (v << cand) for v, w in f["s"]):
                    sh = cand; break
            if sh is None: ok = False
            entry["fields"][si] = {"bits": bits, "shift": sh}
        entry["linear"] = ok
        res[t] = entry
    return res
if __name__ == "__main__":
    tpl = [l.strip() for l in open(sys.argv[1]) if l.strip()]
    res = learn(tpl)
    json.dump(res, open(sys.argv[2], "w"), indent=0)
    print("learned", sum(1 for v in res.values() if "error" not in v), "of", len(res),
          "linear", sum(1 for v in res.values() if v.get("linear")))
    for t, v in res.items():
        if "error" in v: print("  ERR", t, v["error"][:80])
        elif not v["linear"]: print("  NONLINEAR", t)
