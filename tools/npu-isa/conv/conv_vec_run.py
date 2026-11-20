"""Vectorized conv (conv_vec kernels) behind the same interface as conv_npu.run_conv.

run_conv(x, W, B, stride, pad): x (cin, hin, hin) fp16, W (cout, cin, k, k) fp16, B (cout,) fp16 -> (cout, ho, ho) f32.
Channel blocks are multiples of 8 (the vector width). Launches are in-process (conv_npu.launch).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import conv_vec as cv  # noqa: E402
import conv_npu  # noqa: E402

LIMIT = 262144


def plan(cin, cout, k, wp, stride, ho, wo):
    for ho_t in sorted([d for d in range(1, ho + 1) if ho % d == 0], reverse=True):
        hp_t = (ho_t - 1) * stride + k
        for cblk in sorted([c for c in range(8, cout + 1, 8) if cout % c == 0], reverse=True):
            nx = cin * hp_t * wp
            nw = cblk * cin * k * k
            nout = ho_t * wo * cblk
            npad = max(nx + nw + cblk, nout)
            if npad <= LIMIT:
                return ho_t, hp_t, cblk, nx, nw, npad, nout
    raise RuntimeError("no vector tile fits: cin=%d cout=%d k=%d wp=%d stride=%d" % (cin, cout, k, wp, stride))


def run_conv(x, W, B, stride, pad):
    cin, hin, _ = x.shape
    cout, _, k, _ = W.shape
    xp = np.pad(x, ((0, 0), (pad, pad), (pad, pad)))
    hp = wp = xp.shape[1]
    ho = (hp - k) // stride + 1
    wo = ho
    ho_t, hp_t, cblk, nx, nw, npad, nout = plan(cin, cout, k, wp, stride, ho, wo)
    wb, bb = nx, nx + nw
    key = "c%d_k%d_s%d_hp%d_wp%d_ho%d_b%d" % (cin, k, stride, hp_t, wp, ho_t, cblk)
    blob = cv.build(key, cv.kernel_ll(cin, k, stride, hp_t, wp, ho_t, wo, cblk, npad, wb, bb), npad)
    out = np.zeros((cout, ho, wo), dtype=np.float32)
    for b0 in range(0, cout, cblk):
        Wt = np.ascontiguousarray(W[b0:b0 + cblk].transpose(1, 2, 3, 0)).reshape(-1)   # (cin, k, k, cblk)
        for r0 in range(0, ho, ho_t):
            flat = np.zeros(npad, dtype=np.float16)
            flat[:nx] = xp[:, r0 * stride:r0 * stride + hp_t, :].reshape(-1)
            flat[wb:wb + nw] = Wt
            flat[bb:bb + cblk] = B[b0:b0 + cblk]
            got = conv_npu.launch(blob, flat, nout).reshape(ho_t, wo, cblk)
            out[b0:b0 + cblk, r0:r0 + ho_t, :] = got.transpose(2, 0, 1)
    return out
