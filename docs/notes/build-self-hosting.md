# Self-hosting the build

This note covers only the build itself: the compiler stack, its sources and the host tools. It does
not cover CI, code review or hosting of the repository.

## What the build fetches

Only the setup scripts reach the network, and only through git submodules:

| Script | Fetches | Pinned to |
| --- | --- | --- |
| `scripts/setup-edg.sh`, `scripts/setup-pathb.sh` | `3rd/edg` (`https://github.com/edgcpp/compiler`, shallow) | the submodule commit |
| `scripts/setup-qbe.sh` | `3rd/qbe` (`take-cheeze/qbe`, a daily mirror of `c9x.me/git/qbe.git`) and `3rd/cproc` (`michaelforney/cproc`) | the submodule commits |

The EDG CMake files do not fetch anything (no `FetchContent`, `ExternalProject` or downloads). After a
checkout with submodules initialised, the build runs without network access.

Two inputs are used only by the tests, not by the build:

- tinyxml2 and doctest are cloned by `tests/realworld/run.sh` and `tests/realworld/run_doctest.sh`
  into `build/realworld`, at pinned commits.
- The Hexagon checks use clang-19 and `qemu-hexagon-static` from apt, and skip when they are missing.

## Host tools the build assumes

- A C and C++ compiler: gcc and g++. The driver takes the header search path and the GNU version
  from `g++` (`NFCXX_CXX` overrides it), and the current results come from gcc 13.
- `cmake` and `ninja` for EDG; `make` for QBE and cproc.
- `python3` for `scripts/weak-symbols.py` and `scripts/pathb-qbe-emit.py`.
- `git`, `patch`, `sed`, `realpath` and `date` (GNU coreutils) for the setup and wrapper scripts.
- `sccache` is used by CI only. The build works without it.

The C library and the C++ standard library come from the host. Only the compiler stack (EDG, QBE,
cproc) is ours to vendor.

## Self-hosting plan

1. **Mirror the submodules.** Put copies of the three repositories on an internal git server. Point
   the submodule URLs at it: either change `.gitmodules`, or set `submodule.<name>.url` in the local
   git config. Each pinned commit must exist on the mirror. The pins are the only versions the build
   uses.
2. **Keep the patches valid.** `scripts/cproc-empty-struct.patch` applies to the pinned cproc commit
   (`d1c53dd`). It must be regenerated if cproc moves. `setup-edg.sh` edits the EDG base config
   with `sed`, so a new EDG pin needs that edit checked.
3. **Pin the host toolchain.** A container image or an apt list with gcc-13, cmake, ninja, make,
   python3, patch and git. The driver's header discovery depends on the GCC version, so the image
   should not change it silently.
4. **Vendor or mirror the test inputs** (optional for the build): tinyxml2 and doctest. Both are
   small. Their licences travel with them.
5. **Optional:** a local package mirror for apt, so Hexagon checks run offline.

## Verification still to do

No offline build has been run yet. The submodules were already initialised in the development
checkout, so the setup scripts never reached the network there. A real check needs a fresh clone with
the submodule URLs pointed at a local mirror, then:

```
scripts/setup-edg.sh
scripts/setup-qbe.sh
tests/run.sh               # NFCXX_BACKEND=qbe and gcc
```

with the network disabled for the duration. Until that is done, the claim that the build works
offline is untested.
