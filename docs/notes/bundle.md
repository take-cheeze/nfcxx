# Bundling shared libraries into the output (`--bundle-libs`, `nfcbundle`)

`nfcxx --bundle-libs` and `nfcc --bundle-libs` copy the shared libraries the output needs into the output itself,
so the program (or shared object) runs on a machine that has glibc but not libstdc++, libgcc_s or the program's own
libraries. The work is done after the link by `build/nfcbundle` (`tools/bundle/nfcbundle.cpp`, one C++17 file built by
`make -C tools/bundle`, which the driver runs on first use). It takes the idea of [pfnet/sold](https://github.com/pfnet/sold)
and is written anew (sold is GPLv3; nfcbundle is MIT like the rest of the repository). sold only takes shared objects;
nfcbundle takes executables (PIE and position-dependent) as well.

```
./nfcxx --bundle-libs prog.cpp -o prog              # prog needs only libc, libm and ld.so
./nfcxx --bundle-libs -shared lib.cpp -o lib.so     # a shared object with libstdc++ and libgcc_s inside
./nfcc --bundle-libs main.c -Lmylibs -lfoo -o prog  # libfoo found through -L: no run-time path needed
./nfcxx --bundle-libs --bundle-exclude=libgcc_s prog.cpp -o prog
build/nfcbundle [-v] [--list] [-L DIR]... [--exclude NAME]... [--only NAME]... [--export=all|main] IN -o OUT
```

`--bundle-exclude=NAME,...` keeps libraries external and `--bundle-only=NAME,...` bundles only the named ones; a NAME is a
soname (`libfoo.so.1`), a file name, or a soname stem (`libfoo`). With `-c`, `-E`, `-S`, `-M`, `-MM`, `-fsyntax-only` or
`--emit-c` there is no link and the options do nothing. `nfcbundle --list IN` prints what would be bundled.

Test: `tests/bundle/run.sh` (CI: ci.yml). Each case builds a program the usual way, runs it, bundles it, renames the
directory of the bundled libraries, runs the bundle, and requires the same output and exit status:

| Case | What it covers |
| --- | --- |
| C, libA under libB (`liba.c`, `libb.c`, `main.c`) | TLS in all four models (the program's local-exec, initial-exec into libA, general and local dynamic in the libraries), threads, constructor and destructor order, a weak undefined hook, a function the program interposes, an IFUNC, two versions of one symbol (`a_ver@V1`, `a_ver@@V2`), copy relocations of plain data and of data with relocations; linked by GNU ld (PIE, position dependent, `-z pack-relative-relocs`, `-z lazy`) and by lld (PIE, position dependent) |
| libB as the input | dlopen'ed (`dl.c`), with `--export=main`, linked against (the output's section headers) with the program's interposition and copy relocations intact, and that program bundled in turn |
| C++ (`cxx.cpp`, host g++) | libstdc++ and libgcc_s bundled: streams, containers, exceptions thrown inside libstdc++ and caught by the program, a static destructor |
| C++ shared object (`cxxlib.cpp`) dlopen'ed from C (`cxxdl.c`) | exceptions inside the library, `thread_local`, libstdc++ inside a shared object |
| `nfcxx --bundle-libs`, both back ends | `cxx.cpp`; `--bundle-exclude=libgcc_s`; `-shared --bundle-libs` with `cxxlib.cpp`; `-c` |
| `nfcc --bundle-libs` | `main.c` built by nfcc against gcc-built libA and libB found through `-L` only (QBE writes local-exec TLS code only, which a shared object cannot use, so the libraries are gcc's) |
| refusals | a program that needs only glibc is copied unchanged; a static executable is refused |

Checked by hand once (not in CI): the Ubuntu 24.04 binaries of curl (33 libraries; an HTTPS request), git, gdb (52;
runs a program), clang 18 (libLLVM and libclang-cpp, 242 MB; compiles C++ and reports a syntax error), python3 (imports
`ssl`, `sqlite3`, `ctypes`, `decimal`), vim and openssl bundle and run. Bundling clang takes about 2 s. ruby 3.3 does not
work (see "Limitations").

## What the output is

The input's bytes are kept where they are, so its code and data addresses do not move. Each bundled library ("unit")
is placed above the previous unit's highest address at its own alignment, and its PT_LOAD segments are copied with the
same layout (address `base + p_vaddr`). One new read-write PT_LOAD at the end holds everything that has to be merged,
because ld.so and the unwinder see a single object:

- **Dynamic section, symbols, versions, relocations.** A new `.dynamic` (PT_DYNAMIC moves there), `.dynsym` with
  `DT_HASH`, `.gnu.version`/`_d`/`_r`, and one `DT_RELA` table (RELATIVE first for `DT_RELACOUNT`, IRELATIVE last,
  because a resolver may read other relocated data). `DT_NEEDED` lists the libraries that stay external. The
  `DT_RUNPATH` (or `DT_RPATH`) is the input's plus the bundled libraries' own entries with `$ORIGIN` made absolute.
- **Binding.** Every relocation of every unit is translated. Its symbol is looked up as ld.so would: in the unit itself
  when the definition is local, protected or the unit is `DT_SYMBOLIC`; otherwise along the input, the bundled libraries,
  and then the excluded libraries in load order, with symbol versions matched (a definition made by a copy relocation
  matches the version it needed). A definition in a unit is bound now: `RELATIVE` with the final address, `IRELATIVE`
  for an IFUNC, a constant for `SHN_ABS`, the merged TLS offsets below. A definition in an excluded library (libc) stays
  a symbolic relocation with its version need. A shared object output is the exception: a reference to one of its own
  exported default-visibility definitions stays symbolic against that export, so the program that loads it can still
  interpose the symbol or take it with a copy relocation (an executable is first in the lookup scope, so for it the
  early binding gives the same result).
- **PLT.** Each unit keeps its PLT and GOT, but an object has one `DT_PLTGOT`, so there is no lazy binding: the
  `JUMP_SLOT` relocations go into `DT_RELA` and the output has `DF_BIND_NOW`.
- **Copy relocations.** A copy relocation of the input whose source is a bundled library is done while bundling: the
  bytes are copied into the input's bss (that part of its last segment is then written to the file) and the source's
  relocations are repeated at the copy. One whose source stays external is kept and names the input's definition.
- **TLS.** One PT_TLS block: the libraries' blocks first, each at its alignment, and the input's last, placed so that its
  distance from the thread pointer is the one the linker used for local-exec code (`round(memsz, align)`, x86-64 variant
  II). The init image is copied into the new segment. Module-relative offsets of the other units are rewritten: the
  `DTPOFF64` values, the offset word of each local-dynamic GOT pair (a `DTPMOD64` against the null symbol), and the
  addends of `TPOFF64`; `DTPMOD64` names the output's own module. Relocations that pointed into a unit's `.tdata` point
  into the new image. `DF_STATIC_TLS` is set when any initial-exec access remains.
- **Initialization.** One `DT_INIT_ARRAY`: for each unit, dependencies first and the input last, its `DT_INIT` and then
  its init array entries (each entry's relocation re-targeted at the new slot). `DT_FINI_ARRAY` is the mirror image
  (ld.so runs a fini array from the end): the input's fini functions first, each library after the libraries that need
  it are done. `DT_PREINIT_ARRAY` of the input is kept.
- **Unwinding.** The unwinder (`_Unwind_Find_FDE` through `dl_iterate_phdr`) reads one PT_GNU_EH_FRAME per object, so
  a new `.eh_frame_hdr` holds the search tables of all units, sorted, in one table. The FDEs stay where they are. This is
  what lets an exception thrown inside the bundled libstdc++ reach a handler in the program.
- **Section headers.** One section per unit segment (`<soname>.rx`, `.rw`, `.r`, `.bss`), `.tdata`/`.tbss`, and the new
  tables under their usual names, so ld can link against an output shared object and `nm -D`, `objdump -T` and gdb
  see the dynamic symbols. The input's static symbol tables and debug sections are not kept.
- **Exports.** The output exports the input's dynamic symbols with their versions and (default `--export=all`) the
  default-version, default-visibility definitions of the bundled libraries, unversioned and first definition wins. That
  keeps interposition by bundled code working for the excluded libraries (libc calls a bundled `malloc`), and lets a
  dlopen'ed plugin bind to the bundled libstdc++. `--export=main` exports only the input's.
- **Program headers.** The new PT_PHDR is inside the new segment, whose file offset keeps the input's first segment's
  address-to-offset difference (a kernel older than 5.18 takes `AT_PHDR` as that difference plus `e_phoff`). PT_INTERP,
  PT_NOTE, PT_GNU_RELRO and PT_GNU_STACK are the input's (PF_X if any unit needs an executable stack);
  PT_GNU_PROPERTY is dropped.

Which libraries are bundled: every library reachable through `DT_NEEDED` (found as ld.so finds it: `DT_RPATH` when
there is no `DT_RUNPATH`, `LD_LIBRARY_PATH`, `DT_RUNPATH`, `-L`, `/etc/ld.so.conf`, the default directories), except
the glibc libraries (libc, libm, libpthread, libdl, librt, libutil, libresolv, libmvec, ld.so, libnss_*, ...), which
depend on ld.so's internals and must be the one copy in the process, and except `--bundle-exclude`d ones. A library that
an excluded one needs stays external too, so it is not loaded twice. A non-glibc library that cannot be found is an
error.

## Limitations

- x86-64 only (ELF64, little endian). Not aarch64, which sold has.
- A plugin that names a bundled library in its own `DT_NEEDED` loads a second copy of it next to the bundled one. ruby
  3.3 is the case found: its extension modules need `libruby.so.3.3`, and ruby refuses the second copy ("linked to
  incompatible libruby"). Plugins that rely on the executable's exports (python3's extension modules) work.
- A library that `dlopen`s itself or another bundled library by name gets a second copy, for the same reason.
- `LD_PRELOAD` no longer interposes calls between bundled units in an executable output, because they are bound when
  bundling. In a shared object output they stay preemptible.
- Bundled code is bound before the excluded libraries in symbol lookup: a symbol defined by both a bundled library and
  an excluded one that comes earlier in the load order now binds to the bundled one.
- No lazy binding (`DF_BIND_NOW`): a program that relies on an undefined function never being called fails to load.
- Only the input's `PT_GNU_RELRO` is kept: the bundled libraries' GOTs stay writable after relocation.
- Refused: TLS descriptors (`R_X86_64_TLSDESC`, `-mtls-dialect=gnu2`), text relocations other than `PC32`/`PC64`/`SIZE*`
  against bundled definitions, a bundled library that is not `ET_DYN`, a static executable, and an executable linked
  with the startup code of glibc before 2.34 (`__libc_start_main@GLIBC_2.2.5`), whose crt code runs the init array itself
  so the bundled constructors would not run.
- The output is not smaller than the sum of its parts, and the input's static symbols and debug information are lost
  (`strip` before or after makes no difference to running it).
