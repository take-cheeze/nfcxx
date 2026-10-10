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

Some inputs are used only by the tests, not by the build:

- tinyxml2, doctest, Lua and mruby are cloned by `tests/realworld/run.sh`, `run_doctest.sh`, `run_lua.sh` /
  `run_lua_make.sh` and `run_mruby.sh` into `build/realworld`, at pinned commits (a failed fetch is a SKIP, not a failure).
- The Hexagon checks use clang-19 and `qemu-hexagon-static` from apt, and skip when they are missing.

## Host tools the build assumes

- A C and C++ compiler: gcc and g++. The driver takes the header search path and the GNU version
  from `g++` (`NFCXX_CXX` overrides it), and the current results come from gcc 13.
- `cmake` and `ninja` for EDG and the Path B harness; `make` for QBE and cproc (and for Lua's makefile in
  `tests/realworld/run_lua_make.sh`).
- `ruby` with the `rake` gem, **once**, to build the mruby interpreter (`scripts/setup-mruby.sh`, output
  `build/mruby-tool/bin/mruby`). mruby 4.0.0's `minirake` only execs `rake`, so CRuby and rake are both needed
  (`mruby-scripting.md`, "Bootstrap caveat"). Nothing needs them after that build, except
  `tests/realworld/run_mruby.sh`, which runs mruby's own rake build.
- `python3` **only in tests**: the oracles of `tests/mruby/run.sh` (the Python originals kept in
  `tests/mruby/oracle/`, including `tests/mruby/qbe-prep.sh`) and the JSON validation of `tests/trace/run.sh`. No build
  step and no `nfcxx`/`nfcc` run uses it.
- `git`, `patch`, `sed`, `flock`, `realpath` and `date` (GNU coreutils) for the setup and wrapper scripts.
- `sccache` is used by CI only. The build works without it.
- Optional, for the Hexagon checks only: `clang-19` and `qemu-hexagon-static` (apt). `tests/hexagon/run.sh` skips
  without a clang that has the Hexagon target.

The C library and the C++ standard library come from the host. Only the compiler stack (EDG, QBE,
cproc) is ours to vendor.

### What still needs which external tool

| Step | External tools beyond gcc/g++ and coreutils | Network |
| --- | --- | --- |
| `scripts/setup-edg.sh` (EDG `cpfe`, `eccp`, `edg_prelink`, `libC.a`) | cmake, ninja, git (submodule `3rd/edg`) | submodule fetch only |
| `scripts/setup-qbe.sh` (QBE, cproc and the two cproc patches) | make, patch, git (submodules `3rd/qbe`, `3rd/cproc`) | submodule fetch only |
| `scripts/setup-mruby.sh` (the interpreter that runs the helper scripts) | ruby, rake, git, flock | one shallow fetch of `mruby/mruby` at the pinned commit |
| `scripts/setup-pathb.sh` (Path B harness `cpfe`, `build/pathb`) | cmake, ninja, git (the `3rd/edg` submodule) | submodule fetch only |
| `./nfcxx`, `./nfcc` with the gcc backend | EDG built; gcc | none |
| `./nfcxx`, `./nfcc` with the qbe backend (`scripts/qbe-cc`) | EDG, QBE, cproc built; the **mruby interpreter** (`qbe-prep.rb`, `weak-symbols.rb`; built on first use by `scripts/mrb`, which then needs ruby and rake) | none after the setup |
| C-only inputs (`nfcxx x.c`, `nfcc`) | no EDG; the same QBE chain for the qbe backend | none |
| `tests/run.sh`, `tests/lib`, `tests/builtins`, `tests/c`, `tests/eval` | the above | none |
| `tests/trace/run.sh` | python3 | none |
| `tests/pathb/run.sh`, `tests/pathb-ir/run.sh`, `tests/pathb-qbe/run.sh` | the Path B harness, EDG (`libC.a`), QBE, the mruby interpreter (`pathb-qbe-emit.rb`); no python3 | none |
| `tests/mruby/run.sh` | python3 (oracles), the mruby interpreter; optionally the Path B harness, EDG/QBE, clang with Hexagon | none |
| `tests/hexagon/run.sh`, `layout.sh` | EDG, clang-19 with the Hexagon target, qemu-hexagon (run only), the mruby interpreter (`flatlink.rb`) | none |
| `tests/realworld/run.sh`, `run_doctest.sh`, `run_lua.sh`, `run_lua_make.sh` | git; `run_lua_make.sh` also make | fetch of the pinned upstream commit |
| `tests/realworld/run_mruby.sh` | ruby, rake, git | fetch of the pinned mruby commit |

### Which scripts run on mruby

`scripts/mrb script.rb args...` runs a script on `build/mruby-tool/bin/mruby` (building it first if missing).
The Python scripts they replaced exist only as test oracles.

| Script | Run by |
| --- | --- |
| `scripts/qbe-prep.rb` | `scripts/qbe-cc` (every qbe-backend compile, `nfcxx` and `nfcc`) |
| `scripts/weak-symbols.rb` | `scripts/qbe-cc` |
| `scripts/pathb-qbe-emit.rb` | `tests/pathb-qbe/run.sh` (Path B IR to QBE IL; `--append-weak`) |
| `tests/hexagon/flatlink.rb` | `tests/hexagon/run.sh` |

Everything else is bash, C or C++. `scripts/mruby-tool-config.rb` is the mruby build configuration, not a helper script.

## Self-hosting plan

1. **Mirror the submodules** (and `mruby/mruby`, fetched by `setup-mruby.sh`). Put copies of the three repositories on an internal git server. Point
   the submodule URLs at it: either change `.gitmodules`, or set `submodule.<name>.url` in the local
   git config. Each pinned commit must exist on the mirror. The pins are the only versions the build
   uses.
2. **Keep the patches valid.** `scripts/cproc-empty-struct.patch` applies to the pinned cproc commit
   (`d1c53dd`). It must be regenerated if cproc moves. `setup-edg.sh` edits the EDG base config
   with `sed`, so a new EDG pin needs that edit checked.
3. **Pin the host toolchain.** A container image or an apt list with gcc-13, cmake, ninja, make,
   ruby, rake, patch and git (and python3 where the tests that use it should run). The driver's header discovery depends on the GCC version, so the image
   should not change it silently.
4. **Vendor or mirror the test inputs** (optional for the build): tinyxml2, doctest, Lua and mruby (the last is
   also what `setup-mruby.sh` fetches). All are small. Their licences travel with them.
5. **Optional:** a local package mirror for apt, so Hexagon checks run offline.

## Verified offline

### First check (commit `1fae33e`)

In a fresh clone, with the submodule URLs set to local bare mirrors and the network removed (`unshare -rn`, no proxy
variables, `GIT_ALLOW_PROTOCOL=file`; `curl` to `https://github.com` and to `1.1.1.1` both failed inside it):
`scripts/setup-edg.sh`, `scripts/setup-qbe.sh`, and `NFCXX_BACKEND=qbe|gcc tests/run.sh` (15 of 15 cases each) passed.

### Second check (commit `b75f391` plus this branch's edits): mruby, Path B, no python3 and no ruby

A fresh `git clone` of this branch into a scratch directory, the three submodules and `mruby/mruby` mirrored as bare
repositories, `url.<mirror>.insteadOf` entries for the four GitHub URLs in a `GIT_CONFIG_GLOBAL` file with
`protocol.file.allow=always`, and the whole sequence run inside `unshare -rn` (`curl https://github.com` failed there).
The setup steps ran with ruby, rake and python3 available; the tests ran with `python3`, `ruby`, `rake`, `gem` shadowed
by stubs that exit 127. Results:

| Step | Result |
| --- | --- |
| `scripts/setup-edg.sh` | built (about 4 minutes on a shared 4-core machine) |
| `scripts/setup-qbe.sh` | built |
| `scripts/setup-mruby.sh` | built (about 1 minute); the pinned commit came from the mruby mirror |
| `NINJA_JOBS=4 scripts/setup-pathb.sh` | built (about 4 minutes, cold, no sccache) |
| `tests/run.sh` (qbe, gcc), `tests/lib/run.sh`, `tests/builtins/run.sh`, `tests/c/run.sh` (22 passed), `tests/c/cc-mode.sh` (145 passed), `tests/eval/run.sh` | pass without python3, ruby and rake |
| `tests/pathb/run.sh`, `tests/pathb-ir/run.sh` (1997 node occurrences, 0 unsupported) | pass without python3, ruby and rake |
| `tests/pathb-qbe/run.sh` | 74 programs, 74 built, 74 ran, 58 match EXPECT, 16 trapped as required, 0 refused, 0 failed, without python3, ruby and rake. The first run failed all 74 on a relative `PATHB_CPFE` that `scripts/pathb-dump` could not use from its working directory; fixed in the script on this branch. |
| `tests/mruby/run.sh` (python3 back on the path) | 32 passed; the qbe-prep corpora compared 145 inputs identical; the tinyxml2, doctest and Lua corpora skipped (not cached) |

So the build and the qbe-backend compile chain need python3 for nothing, and ruby and rake only for `setup-mruby.sh`.
That is what the host-tool list above claims.

Not exercised in either check: `tests/trace/run.sh` (python3, no network use, but it was not run here), the Hexagon
checks (clang-19 with the Hexagon target and qemu-hexagon are apt packages), and `tests/realworld/*` (the sources
come from GitHub; mirrors of tinyxml2, doctest, Lua and mruby would be needed; the mruby *interpreter* build of
`setup-mruby.sh` is covered above, but `run_mruby.sh`'s own rake build was not run).

Notes from the checks:

- A mirror is a plain `git clone --bare` of each submodule's gitdir. `git submodule update --depth 1`
  fetches by SHA and worked against these bare mirrors, including the shallow EDG one, so no
  `uploadpack.allowAnySHA1InWant` setting was needed.
- The `file://` protocol must be allowed: `git -c protocol.file.allow=always`, or `GIT_ALLOW_PROTOCOL=file`
  in the environment. The environment variable was enough for `setup-qbe.sh`.
- `setup-qbe.sh` runs `git submodule update --init 3rd/qbe 3rd/cproc` every time. `setup-edg.sh` and
  `setup-pathb.sh` only update `3rd/edg` when it is missing.
- `setup-mruby.sh` fetches `https://github.com/mruby/mruby` by SHA into `build/mruby-tool/src`; a
  `url.<mirror>.insteadOf` entry redirects it (the URL is not a submodule, so `.gitmodules` does not cover it).
- Disk: a full build tree (EDG, QBE, mruby, Path B) takes about 4.3 GB; the four mirrors 113 MB.
- Nothing else in the build or in `tests/run.sh` reaches the network or files outside the clone, apart
  from the host toolchain listed above.
