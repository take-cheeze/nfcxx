# C++ language feature coverage for nfcxx: plan

Status: the C++11/C++14 pilot is implemented and run. See [the matrix](cpp-feature-matrix.md) and
[the runner documentation](../../tests/cpp-features/README.md). The parser covers all 246 checklist rows;
51 independently written probes pass on qbe, gcc and Path B in their own standard modes. Later standards,
next-mode reruns for partial support and vendor cross-checks remain to do. The source-access notes below
describe the original planning session.

## Goal

Know, feature by feature, which C++ language features nfcxx accepts and compiles correctly, and on which backend.
The unit is a standard paper (N####, P####R#), because every source below keys its rows by paper number. Library
features are out of scope (see Non-goals).

## Sources

| Source | Use in this plan | Access from this session |
| --- | --- | --- |
| cpprefjp markdown, [cpprefjp/site](https://github.com/cpprefjp/site) at commit `213f89d` (shallow clone) | **Checklist.** `implementation-status.md` has one table per standard (C++11 to C++29) with a row per paper and first-supporting version for GCC, Clang, ICC/ICX and MSVC. Each row links to a `lang/<std>/*.md` page with the feature's sample code. | Cloned read-only to `/home/user/cpprefjp/site`. Anonymous git reads only. |
| cppreference, [C++ compiler support](https://en.cppreference.com/cpp/compiler_support) | Cross-check of the cpprefjp versions, and the C++26/C++29 rows. | Blocked by the session's egress policy. |
| Clang, [C++ status](https://clang.llvm.org/cxx_status.html) | Cross-check of the Clang column, per paper. | Blocked by the session's egress policy. |
| GCC, [C++ standards support](https://gcc.gnu.org/projects/cxx-status.html) | Cross-check of the GCC column, per paper. | Blocked by the session's egress policy. |
| MSVC, [language conformance](https://learn.microsoft.com/en-us/cpp/overview/visual-cpp-language-conformance) | Cross-check of the MSVC column. | Blocked by the session's egress policy. |
| libc++, [C++20](https://libcxx.llvm.org/Status/Cxx20.html) / [C++23](https://libcxx.llvm.org/Status/Cxx23.html) status | Library only; not used for the language checklist. | Blocked by the session's egress policy. |
| libstdc++ manual, [status](https://gcc.gnu.org/onlinedocs/libstdc++/manual/status.html) | Library only; not used for the language checklist. | Blocked by the session's egress policy. |

Snapshot notes for the blocked sources are in the session scratchpad and are not in the repo. They are search
snippets, not page copies, so do not cite version numbers from them.

Caveats on the cpprefjp data, from its own `implementation.md`:

- The versions are the ones the page author could verify, not the exact first-supporting release. Treat them as
  upper bounds on when support started.
- The table mixes ICC (older rows) and ICX (C++29 table). Both names refer to Intel's compiler line; the ICC
  column is not maintained as its own product any more.
- Cells can say "partial", carry a footnote, or be empty. An empty cell means the page has no entry, not that the
  feature is unsupported.

Size of the checklist, verified by `scripts/cpp-feature-checklist.rb`: C++11 41, C++14 10, C++17 40,
C++20 58, C++23 34, C++26 44, C++29 19; 246 feature rows in total (some papers span several rows).

## Non-goals

- Library features. cpprefjp's status page says library support is covered by its reference pages; the library
  side of nfcxx is tested with the freestanding and hosted tests in `docs/README.md`.
- Compiler quality beyond acceptance and correct output: diagnostics wording, performance, ABI.
- Other compilers' bugs. A feature that GCC or Clang gets wrong is recorded as a discrepancy, not copied.

## Method

1. **Pin the checklist.** Record the cpprefjp commit (`213f89d` at the time of writing) and parse
   `implementation-status.md` into a table of standard, paper, feature, page link, and the four compiler versions.
   Keep the parsed file out of the repo unless the license of cpprefjp allows copying; link to the source instead.
   Check `docs/notes/mruby-scripting.md` for the repo's helper-script language before writing the parser.
2. **Write one probe per paper.** Start from the sample code on each `lang/<std>/` page, but write the probe
   ourselves rather than copying text, and check the page's license first. Each probe prints a fixed value and
   carries an `// EXPECT:` line where the existing harness uses one (see `tests/cases/` and `tests/builtins/`;
   `docs/notes/builtins.md` describes the probe style).
3. **Run each probe on every nfcxx route.** Routes are the default qbe backend, `--backend=gcc`, and Path B where
   the probe is in scope, each in the `-std` mode of the paper's standard. Record one of: accepted and output
   correct; accepted and output wrong; rejected by the front end; rejected by the backend; crashed or timed out.
   Use the driver options in `docs/notes/cxx-driver.md`.
4. **Compare.** For each paper, compare nfcxx's result with the cpprefjp versions and with the compiler's own
   status page. A paper that a listed compiler supports and nfcxx rejects is a gap. A paper nfcxx accepts and
   runs correctly is covered for that route. Anything else is a discrepancy to look at by hand.
5. **Publish the matrix.** Write the result as `docs/notes/cpp-feature-matrix.md` with the same columns as the
   source table plus one column per nfcxx route, and add it to the index in `docs/README.md`. Each claim names the
   script that produced it, as the existing status matrix does.

## Open decisions

- **Which standard modes count.** Default: each paper's own standard, plus the next mode for papers marked
  "partial" in cpprefjp. Alternative: only C++20 and C++23, which are what most users compile with.
- **Whether to commit the probes now or after step 3 runs.** Default: after, so the first commit only includes
  probes that were run.
- **C++26 and C++29 rows.** They change as the drafts change; mark them "draft" in the matrix and do not treat
  an absent cpprefjp entry as a claim that the feature is missing.

## Next steps

1. Extend the independently written probes to C++17, then the remaining standards in order.
2. Add next-mode reruns for upstream partial-support notes; the pilot measures each feature's own mode only.
3. Cross-check vendor status pages before drawing support-gap conclusions from upstream version cells.

The pilot commits probes after running them, preserves separate rows for a paper with several features,
and attributes the generated version cells under cpprefjp's CC BY 4.0 license. Draft rows remain inventory only.
