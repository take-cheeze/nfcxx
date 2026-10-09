# Self-hosting the build

This note covers only the build itself: the compiler stack, its sources and the host tools. It does
not cover CI, code review or hosting of the repository.

## What the build fetches

Only the setup scripts reach the network, through git submodules (and, for mruby, one pinned shallow fetch):

| Script | Fetches | Pinned to |
| --- | --- | --- |
| `scripts/setup-edg.sh`, `scripts/setup-pathb.sh` | `3rd/edg` (`https://github.com/edgcpp/compiler`, shallow) | the submodule commit |
| `scripts/setup-mruby.sh` | `mruby/mruby` at tag 4.0.0 (`831da26b`), shallow, into `build/mruby-tool/src` | the commit |
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
- `python3` only for the oracles of `tests/mruby/run.sh` (the Python originals of the scripts now ported to mruby:
  `scripts/qbe-prep.rb`, `scripts/pathb-qbe-emit.rb`, `scripts/weak-symbols.rb`, `tests/hexagon/flatlink.rb`; see `mruby-scripting.md`).
- `ruby` with the `rake` gem, once, to build the mruby interpreter that runs those scripts
  (`scripts/setup-mruby.sh`, output `build/mruby-tool/bin/mruby`). mruby's `minirake` only execs `rake`, so
  CRuby and rake are both needed; nothing needs them after the build. `tests/mruby/run.sh` also uses
  `python3`, for the Python originals kept in `tests/mruby/oracle/` as comparison oracles.
- `git`, `patch`, `sed`, `realpath` and `date` (GNU coreutils) for the setup and wrapper scripts.
- `sccache` is used by CI only. The build works without it.

The C library and the C++ standard library come from the host. Only the compiler stack (EDG, QBE,
cproc) is ours to vendor.

## Self-hosting plan

1. **Mirror the submodules** (and `mruby/mruby`, fetched by `setup-mruby.sh`). Put copies of the three repositories on an internal git server. Point
   the submodule URLs at it: either change `.gitmodules`, or set `submodule.<name>.url` in the local
   git config. Each pinned commit must exist on the mirror. The pins are the only versions the build
   uses.
2. **Keep the patches valid.** `scripts/cproc-empty-struct.patch` applies to the pinned cproc commit
   (`d1c53dd`). It must be regenerated if cproc moves. `setup-edg.sh` edits the EDG base config
   with `sed`, so a new EDG pin needs that edit checked.
3. **Pin the host toolchain.** A container image or an apt list with gcc-13, cmake, ninja, make,
   python3, ruby, rake, patch and git. The driver's header discovery depends on the GCC version, so the image
   should not change it silently.
4. **Vendor or mirror the test inputs** (optional for the build): tinyxml2 and doctest. Both are
   small. Their licences travel with them.
5. **Optional:** a local package mirror for apt, so Hexagon checks run offline.

## Verified offline

Checked on commit `1fae33e`. In a fresh clone, with the submodule URLs set to local bare mirrors and the
network removed (`unshare -rn`, no proxy variables, `GIT_ALLOW_PROTOCOL=file`; `curl` to
`https://github.com` and to `1.1.1.1` both failed inside it), these all pass:

- `scripts/setup-edg.sh` (about 2 minutes)
- `scripts/setup-qbe.sh` (seconds)
- `NFCXX_BACKEND=qbe tests/run.sh` and `NFCXX_BACKEND=gcc tests/run.sh` (15 of 15 cases each)

Not exercised: `scripts/setup-pathb.sh`, the Hexagon checks, and `tests/realworld/*` (which clone
tinyxml2 and doctest and so need the network).

Notes from the check:

- A mirror is a plain `git clone --bare` of each submodule's gitdir. `git submodule update --depth 1`
  fetches by SHA and worked against these bare mirrors, including the shallow EDG one, so no
  `uploadpack.allowAnySHA1InWant` setting was needed.
- The `file://` protocol must be allowed: `git -c protocol.file.allow=always`, or `GIT_ALLOW_PROTOCOL=file`
  in the environment. The environment variable was enough for `setup-qbe.sh`.
- `setup-qbe.sh` runs `git submodule update --init 3rd/qbe 3rd/cproc` every time. `setup-edg.sh` and
  `setup-pathb.sh` only update `3rd/edg` when it is missing.
- Disk: a full build tree plus the mirrors takes about 4.2 GB.
- Nothing else in the build or in `tests/run.sh` reaches the network or files outside the clone, apart
  from the host toolchain listed above.
