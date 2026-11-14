# Tiered selection for bc2cpp (Relax idea 1)

Relax's tiers run cold code in an interpreter and recompile hot code while the program runs. bc2cpp cannot do that: it is
an offline compiler, and the sealed binary has no C++ compiler to build a method at run time. The version that fits
bc2cpp is a profile-guided choice at build time: the hot owners compile to C++, and every other method stays on the
mruby VM, which runs the same program (the VM already runs every method bc2cpp does not translate).

The probe takes `--tier-owners=FILE` (tools/optcarrot_probe/compiled_run.rb): the compiled build's `ONLY_OWNERS` is cut to
the owners in FILE plus the core owners the bodies need. The rest of the program runs on the VM. The hot list is the
profile's (`Optcarrot::PPU`, `Optcarrot::CPU`, from the gprof run in docs/notes/bc2cpp-shard-tiers.md).

Measured on optcarrot, 180 frames (see the results section below).

## Result (optcarrot, 180 frames, two interleaved pairs)

| Configuration | Owners compiled | Sealed build (rake) | Hot-path fps (mruby + bc2cpp) |
| --- | ---: | ---: | ---: |
| all compiled owners (baseline) | all | 114.3 s, 102.8 s | 345.3, 391.7 |
| `--tier-owners`: Optcarrot::PPU, Optcarrot::CPU | 37 | 95.2 s, 96.4 s | 244.2, 259.3 |

Both configurations print checksums 59662 (180 frames) and 38895 (18 frames), so mixing the VM and the compiled code is
correct. The selection is slower: the two-owner hot list leaves most of the hot work on the VM, so the tier cost about
30% of the frame rate. The build time went down by about 10 s, which is the 37-owner compile being smaller, but it is not
a clean measurement (two pairs on a shared host).

Conclusion: a build-time tier needs a complete hot ranking of the owners, not the two-owner list from a coarse gprof run
(about 0.36 s of samples). With the current profile the tier loses. The next step is a finer profile (prof_stream, or a
gprof run with more frames) to rank every owner's share of the hot path, then the smallest set that covers most of the
time.

Run-time tiering (Relax's interpreter-then-JIT) is not possible in bc2cpp's design: the sealed binary has no C++ compiler.
