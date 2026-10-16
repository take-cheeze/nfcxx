#!/usr/bin/env python3
"""Write tinygrad's profile binary from a profile.pkl, and print how many compute kernels it ran.

  PROFILE=1 TMPDIR=DIR python tinygrad_run.py ...   (tinygrad writes DIR/profile.pkl.<user> at exit)
  python3 tinygrad_profile_dump.py PROFILE.PKL PROFILE.BIN

Needs tinygrad (the pickled events are tinygrad's classes). Prints "kernels N": the exec points of the compute kernels (not
copies) in the profile, which is the number of kernel launches tinygrad recorded for the calls it ran. tinygrad_trace.py
converts PROFILE.BIN to Chrome trace-event JSON.
"""
import pickle
import re
import sys

from tinygrad.uop.ops import RewriteTrace
from tinygrad.viz import serve as viz

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def main(argv):
    if len(argv) != 3:
        print("usage: tinygrad_profile_dump.py PROFILE.PKL PROFILE.BIN", file=sys.stderr)
        return 2
    with open(argv[1], "rb") as f:
        events = pickle.load(f)
    raw = viz.get_profile(viz.VizData(RewriteTrace([], [], {})), events)
    if raw is None:
        print("empty profile", file=sys.stderr)
        return 1
    with open(argv[2], "wb") as f:
        f.write(raw)
    kernels = sum(1 for e in events if type(e).__name__ == "ProfilePointEvent" and e.name == "exec"
                  and not ANSI.sub("", e.arg["name"]).startswith("copy"))
    print(f"kernels {kernels}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
