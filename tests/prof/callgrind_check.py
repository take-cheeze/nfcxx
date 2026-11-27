#!/usr/bin/env python3
"""Cross-check of a profile against callgrind, for tests/prof/callgrind.sh. Not part of the default test run.

  callgrind_check.py BINARY DB CALLGRIND_OUT

BINARY is the instrumented program, DB the database that prof2sql wrote from the profile of one run with CALLGRIND_OUT
(the same file). This parser is independent of tools/prof/prof2sql.c: it reads the callgrind file by itself, and it maps
a +0x<offset> site to a function through nm on BINARY (not through entry addresses, which prof2sql uses).

Checks (each prints PASS or FAIL):
  1. callgrind's per-function self Ir adds up to callgrind's totals line (the parse is complete).
  2. main's inclusive Ir is at least fib's self Ir.
  3. callgrind's entry address of main and fib is the nm address of the symbol (the entries prof2sql maps by are real).
  4. For each site of the run: calls in the profile equal callgrind's calls to the function, and self_instructions in the
     database equals callgrind's self Ir of the function.
"""
import re
import sqlite3
import subprocess
import sys


def name_key(name):
    # callgrind writes a recursive level as fib'2; the function is fib
    return re.sub(r"'\d+$", "", name)


def pos(tok, last):
    # an instruction address: "0x..." is absolute, "+n" and "-n" are relative to the last one, "*" is the same
    if tok == "*":
        return last
    if tok[0] in "+-":
        return last + int(tok)
    if tok.startswith("0x"):
        return int(tok, 16)
    return int(tok)


def parse(path):
    ids = {}
    fns = {}
    calls_to = {}
    totals = None
    cur = callee = None
    skip = False
    ipos = lpos = 0

    def ref(text):
        m = re.match(r"\((\d+)\)\s*(.*)$", text)
        if not m:
            raise SystemExit("callgrind_check: unexpected name field: " + text)
        i, nm = int(m.group(1)), m.group(2)
        if nm:
            ids[i] = name_key(nm)
        return ids[i]

    def fn(key):
        return fns.setdefault(key, {"self": 0, "incl": 0, "entry": None})

    with open(path) as f:
        saw_positions = False
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("positions:"):
                if line.split(":", 1)[1].strip() != "instr line":
                    raise SystemExit("callgrind_check: callgrind output needs --dump-instr=yes")
                saw_positions = True
            elif line.startswith("events:"):
                if line.split()[1] != "Ir":
                    raise SystemExit("callgrind_check: the first event must be Ir")
            elif line.startswith("totals:"):
                totals = int(line.split()[1])
            elif line.startswith("fn="):
                cur = ref(line[3:])
                fn(cur)
            elif line.startswith("cfn="):
                callee = ref(line[4:])
                fn(callee)
            elif line.startswith("calls="):
                count, a, b = line[6:].split()
                target = pos(a, ipos)
                ipos = target
                lpos = pos(b, lpos)
                calls_to[callee] = calls_to.get(callee, 0) + int(count)
                if fn(callee)["entry"] is None:
                    fn(callee)["entry"] = target
                skip = True
            elif line and line[0] in "0123456789+-*":
                a, b, c = line.split()
                ipos = pos(a, ipos)
                lpos = pos(b, lpos)
                cost = int(c)
                rec = fn(cur)
                rec["incl"] += cost
                if skip:
                    skip = False  # the cost of a call: the callee's inclusive cost, not this function's self
                else:
                    rec["self"] += cost
    if not saw_positions or totals is None:
        raise SystemExit("callgrind_check: not a callgrind output file")
    return fns, calls_to, totals


def symbols(binary):
    # nm offsets from __executable_start: the same offsets the profiler uses as site numbers
    out = subprocess.run(["nm", "-n", binary], capture_output=True, text=True, check=True).stdout
    addr_of = {}
    base = None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        addr = int(parts[0], 16)
        if parts[2] == "__executable_start":
            base = addr
        if parts[1] in "tTwW":
            addr_of.setdefault(parts[2], addr)
    if base is None:
        raise SystemExit("callgrind_check: no __executable_start in " + binary)
    by_offset = {addr - base: name for name, addr in addr_of.items()}
    return addr_of, by_offset


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: callgrind_check.py BINARY DB CALLGRIND_OUT")
    binary, dbpath, cgpath = sys.argv[1:4]
    failures = 0

    def report(ok, text):
        nonlocal failures
        print(("PASS " if ok else "FAIL ") + text)
        if not ok:
            failures += 1

    fns, calls_to, totals = parse(cgpath)
    addr_of, by_offset = symbols(binary)

    total_self = sum(f["self"] for f in fns.values())
    report(total_self == totals, f"callgrind: self Ir of all functions {total_self} equals totals {totals}")

    main_fn, fib_fn = fns.get("main"), fns.get("fib")
    if main_fn is None or fib_fn is None:
        report(False, "callgrind: main and fib are both in the output")
        sys.exit(1)
    report(main_fn["incl"] >= fib_fn["self"],
           f"callgrind: main inclusive Ir {main_fn['incl']} >= fib self Ir {fib_fn['self']}")

    for key in ("main", "fib"):
        want = addr_of.get(key)
        got = fns[key]["entry"]
        report(want is not None and got == want,
               f"callgrind: entry of {key} is {hex(got) if got is not None else 'unknown'}, "
               f"nm gives {hex(want) if want is not None else 'no symbol'}")

    db = sqlite3.connect(dbpath)
    rows = db.execute("SELECT name, calls, exclusive_ns, self_instructions FROM sites WHERE run_id = 1 AND name NOT LIKE '(%' ORDER BY site").fetchall()
    db.close()
    report(len(rows) == 2, f"database: run 1 has {len(rows)} sites (expected 2)")

    print()
    print(f"{'site':<12} {'calls':>8} {'excl_ns':>10} {'self_Ir':>10} {'cg_calls':>9}  function")
    for name, calls, excl_ns, self_ir in rows:
        if name.startswith("+0x"):
            key = by_offset.get(int(name[3:], 16))
            if key is None:
                report(False, f"site {name}: nm has no symbol at that offset")
                continue
        else:
            key = name
        cg = fns.get(key)
        cg_self = cg["self"] if cg else None
        cg_calls = calls_to.get(key, 0)
        print(f"{name:<12} {calls:>8} {excl_ns:>10} {self_ir if self_ir is not None else 'NULL':>10} {cg_calls:>9}  {key}")
        report(calls == cg_calls, f"site {name}: profile calls {calls} equal callgrind calls {cg_calls}")
        report(self_ir is not None and self_ir == cg_self,
               f"site {name}: self_instructions {self_ir} equal callgrind self Ir {cg_self} of {key}")

    print()
    print("callgrind: FAIL" if failures else "callgrind: all checks passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
