#!/usr/bin/env python3
"""Convert a tinygrad profile binary to Chrome trace-event JSON (open in ui.perfetto.dev).

  python3 -I tinygrad_trace.py PROFILE.BIN TRACE.JSON

PROFILE.BIN is what tinygrad's viz server returns for a profile (viz.get_profile): the binary layout that tinygrad's own
decoder reads (decode_profile in tinygrad/viz/cli.py, tinygrad 0.14.0). tinygrad_profile_dump.py writes it from the
profile.pkl that PROFILE=1 leaves at exit. This converter reads only the binary and uses only the standard library.

Each timeline event of every device becomes one "X" event: name (ANSI colour codes removed), ts and dur in microseconds from
the first event of the profile, pid per device, tid 0. The args carry the device, the event's ref and key, and the JSON fields
tinygrad recorded for it (estimates, sizes). A kernel's name encodes its launch dimensions (E_2048_32_2 is global 2048, 32, 2),
which are kept as args.launch_dims. The binary has no tensor shapes, so none are written.

Memory events (alloc, free, freq) are not timeline events and are skipped.
"""
import json
import re
import struct
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
LAUNCH = re.compile(r"^[A-Za-z]+(_[0-9]+)+$")


def decode(data):
    off = 0

    def u(fmt):
        nonlocal off
        vals = struct.unpack_from(fmt, data, off)
        off += struct.calcsize(fmt)
        return vals

    total_dur, global_peak, index_len, layout_len = u("<IQII")
    index = json.loads(data[off:off + index_len])
    off += index_len
    strings = index["strings"]
    layout = {}
    option = lambda i: None if i == 0 else i - 1
    for _ in range(layout_len):
        klen = u("<B")[0]
        key = data[off:off + klen].decode()
        off += klen
        event_type, event_count = u("<BI")
        events = []
        if event_type == 0:
            for _ in range(event_count):
                name, ref, ekey, st, dur, fmt = u("<IIIIfI")
                events.append({"name": strings[name], "ref": option(ref), "key": option(ekey), "st": st, "dur": dur,
                               "fmt": json.loads(strings[fmt])})
        else:
            linear = u("<B")[0]
            u("<Q")  # peak
            for _ in range(event_count):
                if linear:
                    u("<IQ")
                    continue
                alloc, _ts, _key = u("<BII")
                if alloc:
                    u("<I")
                    u("<Q")
                else:
                    for _ in range(u("<I")[0]):
                        u("<IIIB")
        layout[key] = {"event_type": event_type, "events": events}
    return {"dur": total_dur, "layout": layout, "markers": index.get("markers", [])}


def convert(data):
    profile = decode(data)
    trace = []
    devices = [k for k, v in profile["layout"].items() if v["event_type"] == 0]
    for pid, dev in enumerate(devices, 1):
        trace.append({"ph": "M", "name": "process_name", "pid": pid, "tid": 0, "args": {"name": dev}})
        for ev in profile["layout"][dev]["events"]:
            name = ANSI.sub("", ev["name"])
            args = {"device": dev, "ref": ev["ref"], "key": ev["key"], **ev["fmt"]}
            if LAUNCH.match(name):
                args["launch_dims"] = [int(d) for d in name.split("_")[1:]]
            trace.append({"ph": "X", "cat": dev.split(":")[0], "name": name, "pid": pid, "tid": 0,
                          "ts": ev["st"], "dur": ev["dur"], "args": args})
    return trace


def main(argv):
    if len(argv) != 3:
        print("usage: tinygrad_trace.py PROFILE.BIN TRACE.JSON", file=sys.stderr)
        return 2
    with open(argv[1], "rb") as f:
        trace = convert(f.read())
    with open(argv[2], "w") as f:
        json.dump(trace, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
