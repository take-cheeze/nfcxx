# C++ modules

Named C++20 modules: `export module NAME;` interface units, `import NAME;`, and programs that import them. The front
end is EDG's experimental module support (IFC files, `doc/source/modules.rst` in the EDG tree); the driver chooses
the module options and builds the program one source at a time. Test: `tests/modules/run.sh`.

## What works

- One command: `nfcxx geom.cppm main.cpp -o prog`. Each source is compiled on its own (EDG takes one translation unit
  per call with modules on), the interface units first in dependency order, then the objects are linked. The order
  of the sources on the command line does not matter for interface units.
- Separate compile: `nfcxx -c base.cppm -o build/base.o`, `nfcxx -c main.cpp -o build/main.o`, then
  `nfcxx build/main.o build/base.o -o prog`. The interface file, `NAME.eifc`, is written beside the object. An
  importer reads it from the directory of its own `-o`.
- `--module-dir=DIR` puts the interface files in DIR for both the writer and the importers.
- Interface units that export classes, templates, inline functions (their bodies may call builtins), plain functions
  and enums, and chains of imports. The file name does not matter: `.cppm`, `.ixx` and `.cpp` all work.
- A source with no `export module` and no `import` takes the unchanged path, so `import` and `module` stay ordinary
  identifiers there (`tests/modules/plain.cpp`).

The gcc backend is checked by `tests/modules/run.sh`. The qbe backend runs the same script in CI.

## Refused, with the reason in the message

- `import std;` and `import std.*;`: no standard library module. The host libstdc++ (13.3 here) has none. Header units
  are the first step towards it.
- Header units, `import <h>;` and `import "h";`.
- Module partitions, `export module a:b;`.
- Standards before C++20 (`-std=c++17` and older), `--emit-c`, and Path B (`NFCXX_PATH=b`, `--backend=pathb`).
- Cyclic imports among interface units.

## Known gaps

- **Standard headers in the global module fragment.** `module; #include <cstdio>` then `export module m;` fails in the
  IFC writer ("one or more entities cannot currently be written"). The writer dumps every entity of the global scope,
  including the declarations of the included headers, and glibc declares functions with `_Float32x` and `_Float64x`
  types, which the writer cannot represent. The fix is a dump that writes the module's purview and what the exports
  refer to, not the whole global scope. The writer never looks at the global-module membership flag that EDG keeps
  (`src/modules.h`, `is_module_entity_globally_visible`), so that is where the fix starts.
- **Unions across the boundary.** The writer now writes class, struct and union types (it used to abort on a union).
  The reader rejects a union type with "invalid combination of type specifiers", both for a named union and for an
  anonymous union member, so an importer of a module that exports one fails.
- **Builds.** `g++ -M` does not see `import`, so a build system that runs `-c` itself must order the interface units.
  The compile cache is skipped for module compiles (`NFCXX_CACHE`): the key does not cover the interface files an
  importer read, so a cached object could be stale.
- **Path A link.** The module objects go through the same EDG prelink and C compile as every other object. Module-owned
  templates instantiated in several translation units are not tested.

## The EDG changes

The front end is `take-cheeze/edg-compiler` (`3rd/edg`). The changes are in `src/ifc_modules_write.c` and
`src/ifc_modules_read.c`:

- `_Float16` is written as a bit16 float. `__fp16` has the same format and a different mangling, so it is a bit16 float
  with a plain sign, and the reader tells them apart by the sign. `__float128` (bit128) is read back too.
- The class writer accepts unions (its assertion allowed only classes and structs).
- The global dump skips the predeclared typedefs and the compiler builtin routines. They are predeclared in every
  translation unit, and their types are not all representable in the IFC (GNU mode declares builtins for the
  extended floating-point types).

These changes are on the branch `claude/exciting-euler-h9iicd` of the EDG fork. The `3rd/edg` pin in this repository
still names the commit before them, so the module tests need an EDG build from that branch (`EDG_SRC=<clone>
scripts/setup-edg.sh`).
