# frozen_string_literal: true

# `mruby-rgss-compiled`'s own owners (RGSS::Sprite/Window/Plane/Bitmap/Audio/
# Graphics/Input, plus bare Array/StringIO) are excluded wholesale from
# `tools/bc2cpp/never_called_registrations.rb`'s own `SAFE_UNREGISTER_OWNER_RE`
# -- see that file's own header comment for why: those ARE the real RGSS
# scripting API a downstream game's own bundled "stock scripts"
# (`Data/Scripts.rxdata`) call, invisible to this project's own static
# analysis, so a "never called" verdict there is the expected shape of a
# public API surface, not proof of dead code.
#
# This file was meant to be the one, hand-vetted exception to that blanket
# rule: every one of bc2cpp.rb's own "never called" entries for this gem,
# individually investigated (not just grepped for a name match) against real
# evidence of dead-ness. The investigation happened; the exception did not
# survive it. **This Set is empty on purpose** -- see "Verdict" below for why
# every single candidate turned out to be either really called or
# structurally impossible to safely unregister anyway. Kept as a real,
# checked-in file (not deleted after the fact) so the next round does not
# have to redo this same investigation from zero, and so a genuinely new
# "never called" name added by some future change has a place to land if it
# clears the bar this file's own methodology sets.
#
# ## Methodology
#
# Run for real (2026-09-22) against the current tree: bc2cpp.rb's own
# "never called" diagnostic for `mruby-rgss-compiled`
# (`NeverCalledRegistrations.run_bc2cpp("mruby-rgss-compiled", ...)`) names
# 29 compiled, currently-registered entry points with zero evidence of any
# call site in this program's own bytecode or `NATIVE_SRCS`. Each of those
# 29 was checked against these, in order of trust:
#
# 1. **A real call site this project's own `NATIVE_SRCS` scan cannot see.**
#    The diagnostic's own `NATIVE_SRCS` is a fixed, target-independent set
#    (`mruby-rgss/src/*.cxx` + the core/external gem native sources -- see
#    `run_bc2cpp`'s own comment) that deliberately does NOT include this
#    project's own top-level `src/*.cxx` (the executable, not a gem). Two
#    real call sites live there: `src/main.cxx`'s `--rgss_effect_probe`/
#    `--rgss_audio_probe` CLI flags `mrb_funcall` `RGSS.effect_probe`/
#    `RGSS.audio_probe` through a `const char*` chosen at runtime (never a
#    string literal `extract_native_call_names` could match), and
#    `src/error_dump.cxx`'s `error_dump_install`/`error_dump_run_probe`
#    call `RGSS::ErrorReport.install`/`#probe!` the same way. All four are
#    exercised for real by this project's own CI (the `audio_probe`/
#    `render_probe`/`error_dump` ctests) -- provably alive, just outside
#    this one diagnostic's own native scan.
# 2. **A real call site in a sibling maker gem's own mrblib.**
#    `tools/bc2cpp/compiled_gems.rb`'s own `closed_world_mrblib_srcs`
#    deliberately scans only `mruby-rpg2k`, `mruby-lcf` and `mruby-rgss`'s
#    own mrblib (see that function's own comment) -- NOT `mruby-rpgxp`,
#    `mruby-rpgvx`, `mruby-wolf`, `mruby-mv`/`mruby-mz`, every one of which
#    is a real, shipped consumer of the RGSS API `mruby-rgss` provides, in
#    this project's own tree, not merely a hypothetical downstream game.
#    `RGSS::Graphics.resize_screen`, for one, is called for real from both
#    `mruby-rpgvx/mrblib/lib.rb` and `mruby-wolf/mrblib/runtime.rb` --
#    outside the diagnostic's own scanned closed world, but unambiguously
#    alive in the real, built game. This is the single biggest reason this
#    file ends up excluding almost everything bc2cpp.rb's own diagnostic
#    names: "never called" here only ever means "never called by RPG2000/
#    2003's own engine", never "never called by anything in this repo".
# 3. **Real, documented RGSS class-library API**, cross-checked against
#    `docs/rpgxp-rgss-api-gap.md` / `docs/rpgvx-rgss-api-gap.md` (this
#    project's own measured real-usage survey across two real RPG Maker XP
#    games' bundled scripts, plus the stock VX Ace bundle) wherever those
#    docs cover the property, and against general RGSS/RPG Maker domain
#    knowledge otherwise (flagged inline below as such, and weighted lower
#    than the two kinds of evidence above). A "never called" **getter**
#    paired with a doc-confirmed, heavily-used **setter** of the same name
#    (`Sprite#zoom_x` vs. the doc's own measured `Sprite#zoom_x=`) is NOT on
#    its own evidence of dead code -- these are real, symmetric RGSS
#    accessor pairs the actual engine has always exposed both halves of,
#    and a custom script reading before writing (`self.zoom_x += 1`), or
#    mutating the returned object in place (`src_rect.set(...)` -- this
#    project's own doc explicitly names this as the real per-frame idiom
#    character sprites use; `autotiles[i] = bitmap`, the *only* way RGSS
#    ever lets a script set autotiles, there being no `autotiles=` --
#    mruby-rgss/mrblib/lib.rb's own comment says so directly), is a
#    completely ordinary thing for one to do.
# 4. **Whether the owner is even structurally prunable at all.**
#    `BC2CPP_WIRED_EMBEDDINGS` (`tools/bc2cpp/compiled_gems.rb`) owners are
#    a hard stop independent of call evidence, and for a reason stronger
#    than "risky": `register.cxx`'s own generated
#    `bc2cpp_register_owner_methods(M)` call (OWNER_METHOD_REGISTRATION,
#    invoked unconditionally at the top of this gem's `_gem_init`)
#    reinstalls *every* compiled entry point of *every* wired owner by
#    itself, regardless of whatever the hand-written `mrb_define_*` calls
#    below it do or do not say -- `scripts/bc2cpp_wired_embedding_check.rb`
#    counts a hand registration and the generated one as interchangeable
#    for exactly this reason ("harmlessly idempotent with a generated one
#    for the same name+function"). Deleting a wired owner's hand
#    registration line is therefore not merely unsafe, it is a **no-op**:
#    confirmed directly this session by removing
#    `RGSS::ErrorReport.singleton#installed?`'s own hand line and re-running
#    `bc2cpp_wired_embedding_check.rb`, which still reported
#    "RGSS::ErrorReport.singleton: 9/9 compiled entry points installed" --
#    the generated call had already put it straight back. The edit was
#    reverted (`git diff` on `register.cxx` is empty again). Three RGSS
#    owners are wired this way: `RGSS.singleton`, `RGSS::Input.singleton`,
#    `RGSS::ErrorReport.singleton` (plus `RGSS::Bitmap` and
#    `RGSS::ErrorReport::Tee`, which own none of the 29 candidates here) --
#    see `BC2CPP_WIRED_EMBEDDINGS` for the authoritative list.
#
# ## Verdict (all 29 "never called" entries, 2026-09-22)
#
# - `RGSS.singleton#audio_probe`, `#effect_probe`; `RGSS::ErrorReport.
#   singleton#install`, `#probe!` -- real call sites (evidence 1). Also
#   wired owners (evidence 4) -- doubly excluded.
# - `RGSS::Graphics.singleton#resize_screen` -- real call sites in
#   `mruby-rpgvx`/`mruby-wolf` (evidence 2).
# - `RGSS::Graphics.singleton#fadeout`, `RGSS::Input.singleton#dir8` --
#   measured real usage in this project's own XP/VX-Ace survey docs
#   (evidence 3); `dir8` additionally shares an owner
#   (`RGSS::Input.singleton`) that is wired (evidence 4).
# - `RGSS::Audio.singleton#bgs_fade/#bgs_play/#bgs_pos/#bgs_stop/#me_fade/
#   #setup_midi` -- genuine RGSS1/RGSS2 `Audio` module API, measured used as
#   a group in both survey docs and unmistakable from general RGSS
#   knowledge (evidence 3).
# - `RGSS::Bitmap#font=` -- the writer half of a real, doc-confirmed-used
#   accessor pair (`font` is measured used; `font=` is its documented
#   symmetric setter) (evidence 3); owner is also wired (evidence 4).
# - `RGSS::ErrorReport.singleton#installed?` -- the one entry with **no**
#   real call site found anywhere (native, any gem's mrblib, or even the
#   CRuby-only `scripts/error_report_check.rb`, which never touches this
#   compiled gem at all) and no real-RGSS-API claim possible
#   (`RGSS::ErrorReport` is this project's own crash-reporting
#   infrastructure; no real engine ships it). Would be the one candidate
#   evidence 1-3 could not save -- except its owner,
#   `RGSS::ErrorReport.singleton`, is wired (evidence 4), which makes
#   unregistering it a confirmed no-op, not merely a risk. **Left out of
#   this Set accordingly**, and left registered in `register.cxx`
#   (reverted after confirming the no-op).
# - `RGSS::Plane#blend_type/#zoom_x/#zoom_y`; `RGSS::Sprite#angle/
#   #blend_type/#mirror/#src_rect/#zoom_x/#zoom_y`; `RGSS::Tilemap
#   #autotiles`; `RGSS::Window#back_opacity/#close?/#open?/#stretch` --
#   real, symmetric RGSS accessor pairs (evidence 3); `Tilemap#autotiles`
#   and `Sprite#src_rect` additionally have a doc-confirmed in-place-mutate
#   call shape (`autotiles[i] = ...`, `src_rect.set(...)`) that requires
#   calling the getter for real; `Window#open?`/`#close?` are additionally
#   measured used (~15) by the stock VX Ace bundle per this project's own
#   `mruby-rgss/mrblib/lib.rb` comment and `docs/rpgvx-rgss-api-gap.md`.
#   `Window#stretch` is the one entry in this bucket with no
#   project-doc-measured count either way -- excluded on general RGSS
#   domain knowledge alone (a real, symmetric RGSS2/RGSS3 accessor,
#   flagged here as the lowest-confidence exclusion in this file).
#
# Net: every one of the 29 either has real call evidence this session could
# find, or names a property whose reader is a real half of a documented
# RGSS accessor pair, or belongs to an owner where a `register.cxx` edit
# cannot remove the registration regardless. None qualify.
#
# Re-run the diagnostic yourself
# (`NeverCalledRegistrations.run_bc2cpp` + `parse_never_called_names`,
# `tools/bc2cpp/never_called_registrations.rb`) before trusting the above
# still matches a later tree -- a name *leaving* bc2cpp.rb's own "never
# called" list only ever makes exclusion more clearly correct, but a
# genuinely new name appearing needs this same four-part check run against
# it fresh, not assumed to fall into one of the buckets above.
require 'set'

RGSS_CONFIRMED_UNUSED = Set[].freeze
