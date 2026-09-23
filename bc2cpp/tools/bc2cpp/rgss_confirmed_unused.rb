# frozen_string_literal: true

# The hand-vetted exception to never_called_registrations.rb excluding
# `mruby-rgss-compiled`'s owners wholesale (they are the RGSS scripting API a
# game's own scripts call, invisible to static analysis). **This Set is empty
# on purpose** (ADR 0195): all 29 "never called" entries for this gem failed
# the bar below. Kept so a genuinely new candidate has a bar to clear.
#
# A "never called" RGSS entry is still needed if any of these holds:
# 1. A call site outside the diagnostic's NATIVE_SRCS: top-level `src/*.cxx`
#    (src/main.cxx's --rgss_effect_probe/--rgss_audio_probe, src/
#    error_dump.cxx) calls through a runtime `const char*` name.
# 2. A call site in a sibling maker gem's mrblib (mruby-rpgxp/-rpgvx/-wolf/
#    -mv/-mz), which closed_world_mrblib_srcs does not scan. "Never called"
#    here only means "never called by the RPG2000/2003 engine".
# 3. Documented RGSS API (docs/rpgxp-rgss-api-gap.md, docs/rpgvx-rgss-api-gap.md
#    or, weighted lower, general RGSS knowledge): a getter whose setter is
#    used is still API (`self.zoom_x += 1`, `src_rect.set(...)`,
#    `autotiles[i] = bitmap` -- there is no `autotiles=`).
# 4. The owner is in BC2CPP_WIRED_EMBEDDINGS: the generated
#    bc2cpp_register_owner_methods reinstalls every compiled entry, so
#    deleting its hand registration is a no-op.
#
# Verdict (29 entries, 2026-09-22):
# - RGSS.singleton#audio_probe/#effect_probe, RGSS::ErrorReport.singleton#
#   install/#probe!: 1 and 4.
# - RGSS::Graphics.singleton#resize_screen: 2.
# - RGSS::Graphics.singleton#fadeout, RGSS::Input.singleton#dir8: 3 (dir8
#   also 4).
# - RGSS::Audio.singleton#bgs_fade/#bgs_play/#bgs_pos/#bgs_stop/#me_fade/
#   #setup_midi: 3.
# - RGSS::Bitmap#font=: 3 and 4.
# - RGSS::ErrorReport.singleton#installed?: no call site and not RGSS API,
#   but 4 (confirmed: removing its hand line changed nothing).
# - RGSS::Plane#blend_type/#zoom_x/#zoom_y, RGSS::Sprite#angle/#blend_type/
#   #mirror/#src_rect/#zoom_x/#zoom_y, RGSS::Tilemap#autotiles,
#   RGSS::Window#back_opacity/#close?/#open?/#stretch: 3 (#stretch on general
#   RGSS knowledge only, the lowest-confidence exclusion).
#
# Re-run the diagnostic (`NeverCalledRegistrations.run_bc2cpp` +
# `parse_never_called_names`) before trusting this against a later tree; a new
# name needs the same four checks.
require 'set'

RGSS_CONFIRMED_UNUSED = Set[].freeze
