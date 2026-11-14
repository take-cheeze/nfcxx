# Tiered selection for bc2cpp (Relax idea 1)

Relax's tiers run cold code in an interpreter and recompile hot code while the program runs. bc2cpp cannot do that: it is
an offline compiler, and the sealed binary has no C++ compiler to build a method at run time. The version that fits
bc2cpp is a profile-guided choice at build time: the hot owners compile to C++, and every other method stays on the
mruby VM, which runs the same program (the VM already runs every method bc2cpp does not translate).

The probe takes `--tier-owners=FILE` (tools/optcarrot_probe/compiled_run.rb): the compiled build's `ONLY_OWNERS` is cut to
the owners in FILE plus the core owners the bodies need. The rest of the program runs on the VM. The hot list is the
profile's (`Optcarrot::PPU`, `Optcarrot::CPU`, from the gprof run in docs/notes/bc2cpp-shard-tiers.md).

Measured on optcarrot, 180 frames (see the results section below).
