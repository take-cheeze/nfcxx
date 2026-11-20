# NPU 5000 (SHAVE 5000xx) own assembler/disassembler: working notes

Oracle: moviAsm64.dll via wine. Batch host asmbatch.exe (one process, many lines, diagnostics on ERR).
Target must be 5000xx (3720xx gives wrong code on this device).

## Scope (agreed with user)
Cover only the instruction forms that the OpenVINO blobs on takecheeze-H8.local use.
Blob census needs a working decoder first (carrier shave.text is dense code, up to 35 KB).

## Single ops (verified)
- 697 operand templates fitted (table.json): length, fixed opcode mask/value, bit fields per operand.
- Little-endian words. NOP 1 byte, PEU 2 bytes, reg forms 4 bytes, 16/32-bit immediates or offsets 5 bytes.
- IAU.ADD rr: opcode 0xc6, dst bits 18-22, src1 13-17, src2 23-27. Imm form sets bit 31.
- LSU0.LD.32: dst 13-17, src 18-22. 16-bit ops need .0 sub-register suffix (e.g. i11.0).
- CMU.CMPI imm: field = (v << 2) | 1 at word bits 16.., i.e. v at bits 18+. Verified 0..4096.
- Only 13 opcode classes (unit, low byte, length) among fitted templates.

## Bundles (||): compositional model
- Bundle = header bits, then slot bodies in unit order (CMU, LSU0, LSU1, SAU, IAU, PEU).
- Body of a slot = its single-op word >> 8 (opcode byte dropped). Body width = 8*len - 8.
- Header value/length depends only on the ordered class tuple (unit, low byte, length).
  hdr_table.json: 34 entries for 2-slot pairs of LSU0/LSU1/SAU/IAU/CMU/PEU reps.
  Validated: 16/16 covered non-CMU pairs match exactly.
- Register conflicts: slots may not write the same register in one bundle (e.g. two CP.128 ops
  on IRFrp8). Pick operands that avoid conflicts when assembling representatives.

## CMU bundles (open)
- CMU.CMPI bundles: body of 3 bytes (4a 01 20) then a 4-bit gap before the next slot, so the
  following bodies shift by 4 bits. The compositional body rule fails for CMU pairs (18 of 82).

## Tried and rejected
- Per-tuple bit layouts learned from one representative per class (tuples.py, sweep_tuples.py,
  fit_tuples.py). They do not generalise: body bits include the sub-opcode, so a layout for one
  mnemonic does not match others in the class. Layouts file kept as layouts.json (383 tuples).

## Not yet
- Header table for all class tuples (3+ slots not derived; 3-slot headers measured as 16 bits
  for the four LSU0/LSU1/IAU/SAU triples).
- CMU placement; PEU/VAU/BRU in the header table; full mnemonic-to-class map.
- Immediate-load forms (LDIL/LDIH, LDO.32/STO.32, LDI.32) in the single-op table.
- Decoder: not working on our add kernel (CMU and 3+ slot bundles). Next: compositional decoder =
  header lookup by class tuple, then per-slot single-op match on (low byte | body << 8).

## CMU-first bundles (verified, session 2)
- CMU is always first in a bundle (unit order). Bundle = header | cmu28 << hdr | body2 << (hdr+28)
  | nib << (hdr+28+body2_bits), where cmu28 = (cmu_word >> 8) & (2^28-1), nib = (cmu_word >> 36) & 0xf.
- Verified: 128/128 CMU.CMPI + IAU.ADD bundles over registers, immediates 0..4096; 7/7 CMU pairs in
  pairs.json (CMU header 0xf6 for IAU, 0x74 for LSU0, 0x4c0e 16-bit for LSU1, 0xcc3e 16-bit for SAU).
- Remaining: 2 CMU pairs have no header-table entry (PEU partner).

## Add kernel (generated, 5000xx) needs these forms (not yet in table): LSU0.LDIL, LSU1.LDO.32,
  LSU0.LD.16/LSU1.LD.16 with .0, CMU.CMII.i32 (reg form), PEU.PC1C NEQ || BRU.BRA label,
  BRU.JMP i30, SAU.ADD.f16, LSU1.ST.16, NOP n (encoding of n-cycle NOP not yet checked).

## Add kernel decode (milestone, session 2)
- decode_kernel.py decodes all 80 bytes of the linked add kernel text (add_text.bin); round trip (rt.py)
  reproduces 26 of 28 items exactly with moviAsm.
- Residues not modelled (2 items): (1) branch bundle "PEU || BRU.BRA -28" carries an extra byte 0x0b
  (linker relocation bits); (2) "BRU.JMP i30" third byte 0x01 when a NOP delay follows.
- Probed encodings used by the decoder:
  - LSU0.LDIL: value bit k at encoding bit 18+k (k>=1). Verified 2, 4, 8, 64, 2048, 4096, 8192.
  - LSU0/LSU1.LDO.32 offset: stored as offset>>3, bit j at encoding bit 24+j. Verified 8..2048.
  - BRU.BRA: signed 16-bit offset at bits 8..23 (c7 xx yy 00). Verified -28, -16..1000.
  - NOP n: one byte, (n-1)<<4 (n=1..8). Bare NOP is 0x07.
  - BRU.JMP i30: 47 f1 00 (01 when followed by NOP delay). Register field not decoded yet.
- Bundles: 2-slot headers 0x79 (LSU0.LDO.32 || LSU1.LD.32), 0x59 (LSU0.LD || LSU1.LD),
  0xb5 (BRU || PEU). Body widths: 5-byte LSU = 32 bits, 4-byte = 24 bits, PEU = 8 bits.
- Not yet: general operand decoding (only forms in this kernel), 3+ slot bundles, the 2536-mnemonic
  map, OpenVINO blob census.

## Census and coverage (session 2, latest)
- Mnemonics that assemble: 775 with the first shape pass; +259 from operand-shape discovery
  (discover_shapes.py, diagnostics-guided). 1034 of 2536. 1502 still unassembled: CMB params,
  bare ops, vector/other register classes with suffixes.
- Templates learned: all_templates.json (1034 mnemonics; 1004 linear).
- Opcode classes from templates: 23 (unit, low byte, length). Units: CMU, LSU0, LSU1, SAU, IAU, BRU,
  PEU, VAU, NOP. Bundle header table (tuple_hdr.json, 1006 entries) covers all of these except VAU
  and NOP (VAU not in ORDER yet).
- VAU bundles are not fixed-width per class: VAU.EXP v1 v2 bundles are 4-8 bytes depending on partner.
  VAU body rule not derived.
- Generic decoder (decode_generic.py, indexed header lookup): add kernel 80/80 bytes.
- Census (523186 bytes of OpenVINO shave.text, 148 blobs): 41.2% decoded.
  Top first-failure bytes: 0xd4 (85 blobs), 0xc6 (16), 0xea (12), 0xc2 (12), 0xd6 (10).
  0xd4 bundles contain mnemonics that are not yet assembled (not a header-table gap).

## Re-scope: generator kernels (session 2, latest)
Scope: every kernel our generator emits (gen_*.bin, linked .text). Done when all decode with 0 unknown
bytes and round-trip through moviAsm (except known linker residues).

Status (unknown bytes of total):
- add2in 0/80, p1 0/80, p2 0/80, p3 0/80, exp1024 0/176  -> decode + round-trip OK (2 known residues)
- exp1024h 2/160, relu1024 6/64, relu 14/256, relu2d 24/336, mul2 10/240, add1 9/240, add2in2d 157/496

Learned/measured this round:
- STO.32: offset>>2, bit j at 23+j. LDO.16/STO.16/LSU1.LDO.16: offset bytes, bit k at 22+k, sign at bit 11.
- IAU.SUB imm: 7-bit, bit k at 23+k.
- LDIL (LSU0 0x82, LSU1 0x89): imm bit k at 18+k (k>=0). In bundles the LDIL body is 28 bits (top nibble zero).
- LSU1.LDIH also has class 0x89; its bundle layout may differ (suspected cause of relu regressions).
- Residues in round trip: branch bundle byte 0x0b (linker relocation), BRU.JMP delay bit 0x01.

Open:
- ReLU regressions after the LDIL rule (relu1024 a4 header bundle; relu b9 LDO.16 bundles).
- add2in2d: first unknown 'e9 42 01 00 60 d2'; check its bundle header and 3-slot combos.
- mul2/add1: unknown 0f ... bundle header.
- exp1024h, residual 2 bytes.

## Generator-scope status (latest)
Fully decoded and round-trip verified (except known residues): add2in, p1, p2, p3, exp1024, relu1024.
Partial (unknown bytes): add2in2d 151/496, mul2 10/240, add1 9/240, relu 8/256, relu2d 8/336, exp1024h 2/160.

Fixes this round:
- Header length may carry padding: match any header length 8..table value with the same low bits.
- BRU.JMP i30 as a bundle slot (class 0x47/3) + special word decode.
- LDIL/LDIH 5-byte body is 28 bits in bundles (top nibble zero, bundle padded).

Open root cause: for some 3-slot bundles the header bits include operand bits of a slot
(e.g. LSU1.STO.16 with SAU and BRU.JMP: header 0x0f..., table value from another operand choice).
The class-level header table cannot express that; header must be measured per operand pattern or the
slot whose bits leak into the header must be identified.
Residue: branch byte 0x0b/0x06 varies with the target (linker relocation); not reproducible by numeric operands.

## Register-operand field fitting (session 3)

Problem: many templates were fitted from one example, so their register bits were treated as
constant. `VAU.MUL.F32 v1 v2 v3` decoded, but `v4 v5 v6` did not, and every VAU template was
`linear: false` or had no `fields`. The decoder also skipped non-linear templates and printed
vector operands as bare numbers.

Fix (`fit_fields.py`): for each template with register operands, assemble random register numbers
(0..31) with the MoviTools oracle, find the encoding bit that tracks each value bit, keep the
constant bits as `fixed_mask`/`fixed_val`, and accept a template only if it reconstructs every sample.
An operand that no encoding bit tracks is kept as a literal token: for `VAU.DP4A` the fourth operand
is accepted but ignored by the encoder (`v0`, `v4`, `v31` all give `33 5f 84 21`).

Results: 1519 of 1519 register-operand templates refit and verify.
Decoder patches: vector operands print as `vN`; `linear` is no longer required to be true for
fitted entries.

Coverage, frame kernel `ptl frame.c` (106,816 bytes, built with the pinned flags, one hazard NOP):

| Table | Decoded |
| --- | --- |
| origin/main | 60.2 % |
| after register-field refit | 66.4 % (70,931 of 106,816 bytes) |

Open:
- The bundle at offset 0x1b2 (`42 fd 1c 0e 60 …`) is unexplained. Byte 0x42 is `LSU0.BYPASS_OFF` or an
  LSU0 CP/CFLUSH/CINVAL/CPFL form, but no register or immediate variant (registers 0..31, immediates
  0..63) encodes to `42 fd 1c 0e`, and no pair or triple of opcode-class representatives starts with 0x42.
- Remaining unknown runs are most likely bundle combinations or operand-dependent headers.
- Mnemonics still rejected by the assembler for every tried shape: about 1,160 (`mnemonics.txt` minus the
  table). They need operand forms not yet enumerated.

## Bundle shapes fitted from bundle encodings (session 3)

Bundle layouts do not copy the standalone slot encodings at fixed bit positions: register fields
inside a bundle are encoded differently. So bundle shapes are fitted directly from bundle samples.

`bundle_fit.py` assembles every two-slot class pair and every placeholder shape (header length 0 in
`tuple_hdr.json`) with random register numbers, requires every register column to vary, fits one
template per shape with `fit_fields.fit`, and stores the result in `bundle_templates.json`.
`decode_kernel.py` loads that file next to `all_templates.json` and tries single templates up to 16 bytes.

Results: 195 of 248 shapes verify. On the 150 placeholder samples, 146 decode as one item and every
one of those 146 reassembles to the exact bytes. The 4 misses are in `LSU0/5:82|SAU/4:2c|IAU/4:86|PEU`.
The frame kernel's coverage is unchanged (66.4 %): its unknown bundles are not these shapes.

Also needed: `table.json` and `kernel_table.json` (not tracked here) must sit next to the scripts.
