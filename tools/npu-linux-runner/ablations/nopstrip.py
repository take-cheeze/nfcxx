import re, sys, pathlib
HOME = pathlib.Path.home()
sys.path.insert(0, str(HOME / "npu-linux-runner"))
sys.path.insert(0, str(HOME / "npu-linux-runner" / "frame"))
import run_kernel as rk
import fixtures_check as fc

ROW = sys.argv[sys.argv.index("--row") + 1] if "--row" in sys.argv else "14"
orig = rk.compile_kernel
stats = {}

def strip(asm):
    text = asm.decode(errors="replace")
    start = text.index(f".I{'nr_row_' + ROW}:")
    end = text.index(f".size\t.I{'nr_row_' + ROW}", start)
    seg = text[start:end]
    lines = seg.split("\n")
    kept = [l for l in lines if not re.match(r"^\s*NOP(\s+\d+)?\s*$", l)]
    stats["removed"] = len(lines) - len(kept)
    return (text[:start] + "\n".join(kept) + text[end:]).encode()

def patched(source, work, wine):
    return strip(orig(source, work, wine))

rk.compile_kernel = patched
sys.argv = [a for a in sys.argv if a not in ("--row", ROW)] if "--row" in sys.argv else sys.argv
sys.argv = [sys.argv[0]] + sys.argv[1:]
try:
    fc.main()
finally:
    print("removed NOP lines:", stats.get("removed"), flush=True)
