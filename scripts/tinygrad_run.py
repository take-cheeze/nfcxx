#!/usr/bin/env python3
"""Run an ONNX model with tinygrad, for the nfcuop tinygrad back end (lib/uop/nfcuop_tinygrad.cpp, nfcuop_tinygrad.hpp).

  tinygrad_run.py --check    import tinygrad (exit 0) or print why it cannot be imported (exit 1)
  tinygrad_run.py DIR        run DIR/model.onnx on the inputs listed in DIR/request.txt

DIR is a scratch directory written by nfcuop. It holds:
  model.onnx    the ONNX ModelProto (opset 18 from hir::Graph::to_onnx)
  request.txt   one line per input and per output, the fields separated by single spaces:
                  input  FILE DTYPE RANK D0 ... D(RANK-1) NAME_HEX
                  output FILE DTYPE NAME_HEX
                FILE is a file of DIR; DTYPE is bool, int32, int64, float32 or float64; NAME_HEX is the tensor name as the
                hex of its UTF-8 bytes (so that no name needs quoting).
  An input FILE is the raw tensor: its elements row-major, little endian, one per dtype size (bool is one byte).

The outputs are written in the same raw format to the FILE names of the request. DIR/result.txt is written last, with one
line per output in request order: FILE DTYPE RANK D0 ... D(RANK-1). Its presence is the success signal, with exit status 0.
An output whose dtype differs from the request is an error (tinygrad's own dtype is not converted silently).

Errors go to stderr (the caller shows them) and the exit status is 1. tinygrad is imported only here: nfcuop itself has no
Python dependency. Requires tinygrad, numpy and onnx (tinygrad.nn.onnx reads the model with onnx's protobuf definitions).
"""
import os
import sys

# numpy dtype of each nfcuop dtype name (little endian; bool is one byte)
NP_DTYPES = {"bool": "?", "int32": "<i4", "int64": "<i8", "float32": "<f4", "float64": "<f8"}


def check():
    import tinygrad
    import tinygrad.nn.onnx  # the imports are the check
    print("tinygrad " + str(getattr(tinygrad, "__version__", "unknown version")))
    return 0


def parse_request(path):
    inputs, outputs = [], []
    with open(path, encoding="ascii") as f:
        for lineno, line in enumerate(f, 1):
            t = line.split()
            if not t:
                continue
            if t[0] == "input":
                rank = int(t[3])
                if len(t) != 5 + rank or t[2] not in NP_DTYPES:
                    raise ValueError(f"{path}:{lineno}: bad input line")
                shape = tuple(int(x) for x in t[4:4 + rank])
                inputs.append((t[1], t[2], shape, bytes.fromhex(t[-1]).decode("utf-8")))
            elif t[0] == "output":
                if len(t) != 4 or t[2] not in NP_DTYPES:
                    raise ValueError(f"{path}:{lineno}: bad output line")
                outputs.append((t[1], t[2], bytes.fromhex(t[3]).decode("utf-8")))
            else:
                raise ValueError(f"{path}:{lineno}: unknown line kind {t[0]!r}")
    return inputs, outputs


def run(d):
    import numpy as np
    from tinygrad import Tensor
    from tinygrad.nn.onnx import OnnxRunner

    inputs, outputs = parse_request(os.path.join(d, "request.txt"))
    feeds = {}
    for fname, dt, shape, name in inputs:
        arr = np.fromfile(os.path.join(d, fname), dtype=NP_DTYPES[dt])
        if arr.size != int(np.prod(shape, dtype=np.int64)):
            raise ValueError(f"input {name}: file {fname} has {arr.size} elements, the shape {shape} has more or fewer")
        feeds[name] = Tensor(arr.reshape(shape))

    res = OnnxRunner(os.path.join(d, "model.onnx"))(feeds)
    lines = []
    for fname, dt, name in outputs:
        if name not in res:
            raise ValueError(f"tinygrad returned no output {name}; it returned {sorted(res)}")
        arr = np.array(res[name].numpy(), order="C")  # not ascontiguousarray: that makes a scalar (1,)
        if arr.dtype != np.dtype(NP_DTYPES[dt]):
            raise ValueError(f"output {name} is {arr.dtype} in tinygrad, the graph has {dt}")
        arr.tofile(os.path.join(d, fname))
        lines.append(" ".join([fname, dt, str(arr.ndim)] + [str(s) for s in arr.shape]))
    with open(os.path.join(d, "result.txt"), "w", encoding="ascii") as f:
        f.write("".join(line + "\n" for line in lines))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--check":
        return check()
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    return run(argv[1])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # noqa: BLE001 (every failure reaches the caller as this text on stderr)
        sys.stderr.write(f"tinygrad_run: {type(e).__name__}: {e}\n")
        sys.exit(1)
