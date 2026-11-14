# bc2cpp cache keys: audit against their inputs

Step 4 of the relax plan: every cached result is keyed by the hashes of what can change it, so a cache hit equals a
fresh compute. This note lists each on-disk or cross-run cache bc2cpp has, what its key covers, what it missed, and
what changed. The checks that exercise the keys are `scripts/bc2cpp/scan_cache_check.rb` (the key sections run in any
checkout; the real-scanner section needs the world) and the sections of it named below.

## Inputs that can change a result

- **Sibling sources**: a scan that reads files beyond its own (`*.cxx` next to a native file, the mruby headers that
  `public_mrb_value_functions` reads) must list them in its inputs.
- **Environment**: a cached scan may not read `ENV` at all. `ScanCache::EnvGuard` raises while a scan computes
  (`tools/bc2cpp/scan_cache.rb`, `EnvGuard`), so the BC2CPP_* switches cannot alter a stored scan. The generation
  cache is different: its generator runs with the caller's BC2CPP_* settings unset (`tools/self_compile/artifacts.rb`,
  `generation_environment`), and the settings it does read are in its key.
- **Tool sources**: the bc2cpp code itself, which the generator loads from `tools/bc2cpp` and `tools/mrbc_rb`
  (`irep.rb` requires `mrbc_rb`), plus the `compiled_gems.yml` data file.
- **Toolchain**: RUBY_DESCRIPTION, Prism::VERSION and RBS::VERSION (`tools/bc2cpp/toolchain.rb`). The scans and the
  generation read Prism's trees and RBS's signatures, so a different gem version can change a result under the same
  Ruby.

## Audit table

| Cache | Key (before) | Covers | Misses (before) | Action |
| --- | --- | --- | --- | --- |
| ScanCache entries, `build/bc2cpp-cache/<name>-<key>.bin` (`scan_cache.rb`, `key_for`) | scan name, VERSION 4, RUBY_VERSION, RUBY_PLATFORM, Marshal version, digest of `tools/bc2cpp/*.rb` (top level only), per input: path and SHA-256, or `absent` | Each of the 17 `ScanCache.fetch` files' inputs (audited call by call: `closed_world`, `native_direct`, `native_expression_devirt`, `native_names`, `native_owner_map`, `native_constructor_sigs`, `native_sigs`, `native_singletons`, `class_world`, `gem_owners`, `dispatch_targets`, `compiled_gems`, `integer_constants`, `const_site_cache`, `codegen_class_narrowing`, `lint_crosscheck`, `rbs_param_check`); sibling lists; `cache_absent` | The Prism version (only some scan names embedded `Prism::VERSION`); RBS unless a name embedded it; RUBY_DESCRIPTION (patch and build); `tools/mrbc_rb` (loaded by the generator); `tools/bc2cpp/compiled_gems.yml`; a racy file digest (a same-size rewrite within one mtime tick, reused from the per-process memo) | Key holds `Toolchain.versions` (Ruby description, Prism, RBS); `tools_sources` (`.rb` and `.yml` under `tools/bc2cpp` and `tools/mrbc_rb`, recursive); `file_digest` remembers a digest only when the file is older than `RACY_SECONDS` (2 s) when hashed; VERSION 5. Checks: "the key covers the toolchain", "the key covers every bc2cpp tool source" (includes a test that the generator's require closure, 334 files, lies inside `tools_sources`), "a file digest is reused only for a file that is not racily timed" (fails with `RACY_SECONDS = -1`, checked). **Every entry misses once.** |
| Singleton registration table, `native_singletons.file_table` (`native_singletons.rb:114`) | ScanCache key over `[path, *NativeDirect.sibling_sources(path)]` | The file and its `*.cxx` siblings, which `scan_file_table` reads through `sibling_param_owners` | Only the ScanCache misses above (toolchain, tools, racy digest) | Covered by the ScanCache fix. Test: `scripts/bc2cpp/native_singleton_cache_cases.rb`, run by `native_registration_check.rb` (a sibling rewrite within a second, a fresh in-process memo, a rewritten binding) |
| Per-file owner and registration scans, `native_direct.sibling_param_owners` and `native_direct.file_registrations` (`native_direct.rb:114, 135`), `native_owner_map.file` (`native_owner_map.rb:336`), `native_constructor_sigs.class_variables` (`native_constructor_sigs.rb:390`) | ScanCache over the sibling list (`*.cxx` of the file's directory) | The file and every sibling whose parameter owners the scan reads | Only the ScanCache misses above | Covered by the ScanCache fix |
| `native_expression_devirt` entries (`analyze`, `analyze.file`, `analyze.bodies.<digest>`, `exact_class`, `exact_class.bodies.<digest>`, `class_registrations(.file)`, `class_method_registrations(.file)`) (`native_expression_devirt.rb:112-624`) | Path list; for `exact_class` the list plus `public_api_header_paths`; for the bodies, `[path] + public headers`, and a digest of the needed arities and `mruby_root` | `scan_analyze` reads only the files (checked: no header or root use); `scan_exact_class_expressions` reads the public headers (`public_mrb_value_functions`) and the mruby root | Only the ScanCache misses above; the in-process `read_source` memo (`SOURCE_CACHE`, keyed by `[path, mtime, size]`) shares the racy-tick residual below | Covered by the ScanCache fix |
| `native_names` and `outside_world_tokens` entries (`native_names.rb:112-492`), `closed_world.*` entries (`closed_world.rb:1100-1408`), `class_world.build`, `gem_owners`, `dispatch_targets`, `native_constructor_sigs.ruby_initialize`, `rbs_param_check`, `lint_crosscheck`, `integer_constants`, `const_site_cache`, `codegen_class_narrowing`, `compiled_gems.c_definition_owners`, `native_sigs.kept_texts` | Path list (per file for the `.file` variants); some names embed `Prism::VERSION` or `RBS::VERSION` | As the rows above | Prism version missing from the key for scans that did not embed it (`closed_world.ruby`, `native_names.foreign_method_names`, `closed_world.native`, `const_site_cache.*`, `integer_constants.*`, `compiled_gems.*`) | Covered by the ScanCache fix (the version is now in every key). `native_sigs` keeps its RBS version in its name, which stays |
| analysis headers, `analysis_headers.onigmo_h` (`scripts/bc2cpp/analysis_headers.rb:77`) | ScanCache over the Onigmo tarball | The tarball bytes | The member name `ONIGMO_MEMBER` (the block's `tar -xzOf` text is code, not keyed) | Name is now `analysis_headers.onigmo_h.<member>`. No local test: the tarball is `3rd/mruby-onig-regexp/onigmo-6.2.0.tar.gz` of the world, which this checkout does not have. Entries miss once |
| IrepCache, decoded RITE trees (`BC2CPP_IREP_CACHE_DIR/<sha>.marshal`, `tools/bc2cpp/irep_cache.rb`) | SHA-256 of `[fingerprint, RUBY_ENGINE, RUBY_VERSION, RUBY_PLATFORM, Marshal version, InsnDecoder.fold_ext_prefix? (BC2CPP_EXT_PREFIX), RITE bytes]`; fingerprint is a hand list of 7 files | The RITE image, and the decoder's own inputs through the list | The list misses `bytecode_ir_ops.rb` (loaded by `insn_decoder.rb`) and any other file the decode follows | Fingerprint is now `ScanCache.tools_digest` plus `Toolchain.versions`. Check: "the decoded-tree cache (IrepCache) covers every tool source", which shows a changed decoder source decodes again. **Entries miss once** (when the cache is enabled) |
| Self-AOT generation, `build/bc2cpp-self/generation/fingerprint` and `host.json` (`tools/self_compile/build.rb`) | JSON of `[RUBY_DESCRIPTION, generator env without nil, selectors (BC2CPP_HOST_RUBY, BC2CPP_SELF_BUILD_DIR, BC2CPP_SELF_CXX, BC2CPP_SELF_SHARDS, BC2CPP_BUILD_JOBS), defines, [path, SHA-256] of the baked closure, native, ruby and header inputs]` | The generator's Ruby, its environment, the baked tool closure (`bake` follows require_relative, so `mrbc_rb` is in it), native and header inputs, defines | Prism and RBS versions; caller variables that reach the generator unchanged: `RUBYOPT`, `RUBYLIB`, `NFCXX_AST_DUMP`, `LIBCLANG_EDG_CPFE`, and the AST producer that auto selection picks (`BC2CPP_AST_PRODUCER` is unset for the generator, so the choice follows `LIBCLANG_EDG_CPFE`); `tools/bc2cpp/compiled_gems.yml` and every tool source outside the baked closure | `Bc2cppSelfCompile.generation_fingerprint` (artifacts.rb) takes the toolchain, the environment, the controls (now with `INHERITED_KEYS` and `ast_producer`), the defines and the sorted digests; build.rb adds `ScanCache.tools_sources`. Check: "the self-generation fingerprint covers its toolchain, environment, controls, defines and sources" (each part changes the key). Not run locally: build.rb needs CRuby 4 with YJIT and the mruby build. **The generation runs once more** |
| Host AST manifest, `main_ast.json` (`scripts/bc2cpp/main_ast.rb:47-55, 119`) | `expected_command` (clang, host_cxx, target, flags, sources, lookup_names_only, ast_producer) and SHA-256 of every dependency (depfile headers, the exporter, `main_roots.rb`, and the nfcxx tool and cpfe when the producer is nfcxx) | The command line, the producer and its binaries, the sources and headers | Covered for what the file contains. The Ruby interpreter is not keyed (the exporter's output is the C front end's JSON; Ruby only reshapes it) | No change |
| Native preprocessing inventory, `bc2cpp_native_inventory.json` (`tools/bc2cpp/native_inventory.rb:10-65`) | `dependencies`: SHA-256 of every `tools/bc2cpp/**/*.rb`, the sources, preprocessed inputs, depfiles, included headers, configuration dependencies; `read` re-hashes each | All of those | Ruby version and the Prism/RBS versions are not keyed (the inventory is text processing of preprocessed C, no parse) | No change; the key covers what it reads |
| Static dispatch lists stamp, `inputs_digest` (`tools/bc2cpp/static_dispatch_registrations.rb:2074`) | SHA-256 of the closed-world and outside-world sources, `tools/bc2cpp/**/*.{rb,rbs,erb}`, build_config.rb, trace_host.cxx, sig/**/*.rbs | Listed files | Prism/RBS/Ruby versions; `tools/mrbc_rb` | **Not changed.** This is a staleness stamp for lists that are committed in the world (`static_dispatch_lists.rb:104-110` refuses lists whose stamp differs), not a cache, and adding inputs would make every committed list refuse until regenerated. Follow-up: regenerate the world's lists in the same change that adds the toolchain line |
| Runtime header, `bc2cpp_runtime_<digest>.hxx` (`runtime_header.rb:61-63`) | Content digest of FORMAT and the header text | Everything it writes | None | No change (content-addressed) |
| Compiled gem sources and stamps (`compiled_gem_sources.rb:157`, `compiled_gems.rb:814-818`, `native_vm_build.rb:34`) | Rewrite only when the content or the stamp string differs | The file content; the shard count; the native VM mode | Build stamps only; make tracks the rest | No change |
| mrbc snapshot tables (`tools/mrbc_rb/snapshot*.txt`) | SHA-256 over sources; the value is the oracle's RITE digest | Source content | The oracle's version, on purpose (drift is reported as STALE by `snapshot.rb --check`) | Fixture, not a cache. No change |
| RubyParseCache (`ruby_parse_cache.rb`) | In process: path, and the exact bytes | Bytes | Prism version (constant within one process) | Not a disk cache; no change |
| Sealed hash stores (`codegen_sealed_containers.rb`, `record_hash.rb`) | None | No file writes in either module (`record_hash.rb` reads source texts into memory for its own analysis) | n/a | Not a cache; no change |
| In-process memos keyed by `[path, mtime, size]`: `FileIdentity`, `NativeDirect.file_identity`, `native_expression_devirt` `SOURCE_CACHE`, `ScanCache.file_digest` (now racy-safe) | Stat identity | Input files, as long as their mtime moves | A same-size rewrite within one mtime tick in the same process | **Residual.** The generator does not rewrite its sources during a run; the checks that rewrite fixtures use distinct mtimes. Not changed |

## Files changed

- `tools/bc2cpp/toolchain.rb` (new): the Ruby, Prism and RBS versions.
- `tools/bc2cpp/scan_cache.rb`: VERSION 5; toolchain in the key; `tools_sources`; racy-safe `file_digest`.
- `tools/bc2cpp/irep_cache.rb`: fingerprint from `ScanCache.tools_digest` and the toolchain, not a file list.
- `tools/self_compile/artifacts.rb`: `generation_fingerprint`; inherited interpreter and front-end variables in the controls.
- `tools/self_compile/build.rb`: the fingerprint uses those, with the toolchain, the AST producer and `tools_sources`.
- `scripts/bc2cpp/analysis_headers.rb`: the Onigmo member is in the scan name.
- `scripts/bc2cpp/scan_cache_check.rb`: the key checks run before the world-only real-scanner section (the file used to
  fail at load time without a world).

## What existing caches do after this change

- ScanCache entries under `build/bc2cpp-cache` miss once (key format and VERSION changed). Old entries are not read.
- With `BC2CPP_IREP_CACHE_DIR` set, decoded trees miss once.
- The self-AOT generation runs once (its fingerprint now has the toolchain and more sources).
- The Onigmo header entry is renamed and misses once.
- Static dispatch lists are unchanged, so the committed lists stay valid.

## Verified and not verified

Verified locally (Ruby 3.3.6, no world): the key sections of `scripts/bc2cpp/scan_cache_check.rb` (toolchain, tool
sources and the generator's require closure, racy file digest, IrepCache fingerprint and decode, generation
fingerprint and its environment), `shard_output_check.rb` (15 checks passed), `irep_tree_check.rb` and
`foreign_definers_cache_check.rb` (PASS). The racy-digest test fails when the guard is disabled. `ruby -c` passes on
every touched file.

Not verified locally: the real-scanner section of `scan_cache_check.rb` (needs `sig/bc2cpp/core.rbs` and 3rd/mruby, so
the check stops there, as it did before this change); `self_build_kind_check.rb`, `const_site_cache_check.rb`,
`sealed_hash_stores_check.rb`, `owner_call_icache_check.rb` (world-only); the self-AOT build itself (CRuby 4 with YJIT
and mruby); the analysis-headers path (needs the Onigmo tarball from the world).
