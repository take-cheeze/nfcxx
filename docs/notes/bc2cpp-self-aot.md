# bc2cpp compiling itself

`scripts/setup-bc2cpp-self.sh` implements this pipeline:

1. Build the bootstrap mruby runtime and its native `mrbc`.
2. Run bc2cpp under **CRuby 4 with YJIT** on its own baked Ruby source graph.
3. Build the emitted C++ and its mruby runtime with **nfcxx** (gcc backend by default).
4. Install those translated methods after loading the same source graph, then run bc2cpp.

This differs from `scripts/bc2cpp`, which runs the compiler's baked bytecode without installing self-generated C++.
As with other bc2cpp programs, methods using unsupported constructs retain their bytecode implementation. The
initial image translates 4,387 methods and leaves 802 on the VM; this is not a claim that every instruction is AOT.

## Build and run

The EDG toolchain must be available (`scripts/setup-edg.sh`). The host needs CRuby 4 with YJIT, Prism 1.9 and RBS 4;
the repository Gemfile provides the host gems. The script fetches the pinned test world unless
`BC2CPP_WORLD_ROOT` or `BC2CPP_RPG_DIR` selects an existing checkout.

```sh
BC2CPP_HOST_RUBY=/path/to/ruby4 scripts/setup-bc2cpp-self.sh
BC2CPP_HOST_RUBY=/path/to/ruby4 scripts/bc2cpp-self --annotated program.rb
```

Supply the input program's closed-world environment (`BC2CPP_BUILD_NAME`, `BC2CPP_BUILD_GEMS`, `NATIVE_SRCS`,
`FOREIGN_RUBY_SRCS`) as with the ordinary compiler. The wrapper sets the native mrbc fallback and the wrapper
used by baked subprocess tools.

The executable path is printed on stdout; progress goes to stderr and detailed logs stay in the build directory.
`BC2CPP_SELF_BUILD_DIR` defaults to `build/bc2cpp-self`; `BC2CPP_SELF_SHARDS` defaults to 16;
`BC2CPP_BUILD_JOBS` defaults to 8; `BC2CPP_SELF_CXX` defaults to this repository's `nfcxx`.
Use separate build directories when changing the C++ compiler, backend or ABI flags.

Generation is cached by the host Ruby version, the Prism and RBS versions, source and header contents (and every bc2cpp
tool source), configured runtime defines, the explicit self-build settings, and the interpreter and front-end variables
the generator inherits (`RUBYOPT`, `NFCXX_AST_DUMP`, `LIBCLANG_EDG_CPFE`); `docs/notes/bc2cpp-cache-keys.md` has the
audit. The input program's owner filters and optimization controls are isolated from self-generation.
Identical generated files retain their timestamps so warm setup does not rebuild every translation unit.
`generation/host.json` records the actual Ruby version, YJIT state and inputs. `generation/coverage.json` records
translated methods and the exact fallback reasons. Its `methods` array has one object per translated method, with
`entry`, `owner`, `name`, `tier` (the `--shard-cold-opt` level when the method is in a cold shard, else `"default"`)
and `compile_seconds` (set when the generation ran with `BC2CPP_PROFILE_TIMINGS=1`, else `null`). The same objects
are the `== compiled method report ==` section of `generation.log`, written by bc2cpp at exit. Self-generation passes
no shard tier, so its tiers are `"default"`. `compile_seconds` includes the probes each method's compilation runs.

## Validation

With a full pinned-world checkout selected, the integration check compares generated C++ and bytecode against CRuby,
builds the result with nfcxx, and compares interpreted and compiled arithmetic, Unicode, binary strings, exception
handling and executable-file checks. It also requires that translated compiler entry points actually ran:

```sh
runner=$(scripts/setup-bc2cpp-self.sh)
MRBC=build/bc2cpp-self/bootstrap/bc2cpp-runner/bin/mrbc \
  BC2CPP_MRUBY_RUNNER="$runner" BC2CPP_REQUIRE_SELF_AOT=1 \
  BC2CPP_RUNNER_MRBC_MODE=verify CXX="$PWD/nfcxx" NFCXX_BACKEND=gcc \
  ruby --yjit tests/bc2cpp/runner_generation.rb
```

`BC2CPP_SELF_STATS=1` enables optional entry counts. A bytecode-only runner cannot satisfy this check. The
counter covers generated entry wrappers; direct calls between translated implementations need not increment it.

The quick `ruby tests/bc2cpp/self_compile.rb` check runs in ordinary CI. A workflow dispatch of `ci.yml` with
`self_aot=true` runs the complete CRuby 4 + YJIT / nfcxx build and integration check and uploads its logs and metadata.

## Installation boundaries

The image loads its definitions before replacing methods. Objects created during that load retain Ruby ivar
storage: self builds disable embedded layouts rather than changing the representation of live objects. Registration
does not rerun top-level or class bodies. Normal program builds keep their existing embedding behavior.

Report/trace modules omitted from the fixed compiler graph and `BC2CPP_STRICT_KEYS=0` (which aliases compiler classes
to core classes) are rejected by the self image. Use the bootstrap runner for those modes.

Self-generation uses the Ruby RITE emitter: the pinned native mrbc hits a jump-offset limit on the combined compiler
source graph. Individual baked files and unsupported emitter inputs still use the native mrbc. An important regression
found by strict self verification was loss of NUL bytes in ordinary string literals; generated pool strings now use the
C++ literal's array length instead of `strlen`, preserving the bytecode emitter's binary record terminators.
