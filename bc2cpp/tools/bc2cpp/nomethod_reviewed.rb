# frozen_string_literal: true

# NOMETHOD_REVIEWED (docs/adr/0226): every guard-chain fallback the closed
# world proves dead (a `bc2cpp_nomethod` site, ADR 0210) is a build error
# unless its key is listed here. A dead fallback means no class in the build
# answers that name, which is either a defensive branch the runtime rescues or
# a real bug; each listed key was read and judged the former (see the ADR).
#
# Key: "<compiled owner>#<compiled method> -> <called name>", the method the
# site sits in (owners as in STATIC_DISPATCH_UNREGISTERED) and the name it
# sends. bc2cpp.rb enforces the list on every closed-world run;
# scripts/bc2cpp_nomethod_reviewed_check.rb re-proves it exactly in both
# directions over a full (not hot-only) wio run of all three gems.
# Regenerate with `MRBC=... ruby scripts/bc2cpp_nomethod_reviewed_update.rb`.
require 'set'

module NomethodReviewed
  MARKER = %r{/\* CLOSED_WORLD nomethod: (self|recv)\.(\S+) \*/}
  # Test-only escape for fixture worlds (scripts/bc2cpp_closed_world_check.rb):
  # their dead sites are the point of the fixture, not code a build ships.
  ALLOW_ENV = 'BC2CPP_NOMETHOD_UNREVIEWED'

  module_function

  def marker(name, self_receiver:)
    "/* CLOSED_WORLD nomethod: #{self_receiver ? 'self' : 'recv'}.#{name} */"
  end

  def key(owner, method, called)
    "#{owner}##{method} -> #{called}"
  end

  # Every marked site in `compiled` (bc2cpp.rb's compiled-method hashes).
  def sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(MARKER).map do |recv, called|
        { key: key(m[:owner], m[:name], called), owner: m[:owner], method: m[:name], called: called,
          self_receiver: recv == 'self' }
      end
    end
  end

  # Why this run's sites break NOMETHOD_REVIEWED; empty when they do not.
  # A run compiles one gem's owners, so an entry is stale here only when its
  # method was compiled and no longer has the site. `stale: false` for a
  # hot-only run: a chain depends on which callees are compiled, so a site
  # can vanish from a compiled method there without the proof changing.
  def violations(sites, compiled, reviewed: NOMETHOD_REVIEWED, stale: true)
    found = sites.map { |s| s[:key] }.to_set
    compiled_methods = compiled.reject { |m| m[:unsupported] }.map { |m| "#{m[:owner]}##{m[:name]}" }.to_set
    unreviewed = (found - reviewed).sort.map { |k| "unreviewed dead fallback: #{k}" }
    return unreviewed unless stale

    stale = reviewed.select { |k| compiled_methods.include?(k.split(' -> ', 2).first) && !found.include?(k) }
    unreviewed + stale.sort.map { |k| "stale NOMETHOD_REVIEWED entry (no such site any more): #{k}" }
  end

  # bc2cpp.rb's "  NOMETHOD <key>[ [self]]" stderr lines, back into sites.
  def parse_listing(stderr)
    stderr.scan(/^  NOMETHOD (.+? -> \S+?)( \[self\])?$/).map { |k, s| { key: k, self_receiver: !s.nil? } }
  end
end

NOMETHOD_REVIEWED = Set[
  "LCF::File#initialize -> header",
  "LCF::File#initialize -> schema",
  "LCF::File#to_lcf -> header",
  "LCF::File#to_lcf -> schema",
  "LCF::File#to_lcf -> terminate_root?",
  "RPG2k::Scene::Base#state_display -> state_table",
  "RPG2k::Scene::Battle#apply_pending_item -> advance_actor",
  "RPG2k::Scene::Battle#apply_pending_item_all -> advance_actor",
  "RPG2k::Scene::Battle#apply_pending_skill -> advance_actor",
  "RPG2k::Scene::Battle#apply_pending_skill_all -> advance_actor",
  "RPG2k::Scene::Battle#apply_pending_switch_item -> advance_actor",
  "RPG2k::Scene::Battle#battle_cmd_window_rect -> gauge_battle_layout?",
  "RPG2k::Scene::Battle#draw_battle_ally_target -> gauge_battle_layout?",
  "RPG2k::Scene::Battle#draw_battle_command -> battle_commands",
  "RPG2k::Scene::Battle#drive_battle_animate -> finish_round_animation",
  "RPG2k::Scene::Battle#drive_battle_command -> battle_commands",
  "RPG2k::Scene::Battle#drive_battle_command -> open_battle_options",
  "RPG2k::Scene::Battle#drive_battle_command -> prev_commandable_actor_index",
  "RPG2k::Scene::Battle#drive_battle_encounter_message -> enter_command_phase",
  "RPG2k::Scene::Battle#drive_battle_target -> advance_actor",
  "RPG2k::Scene::Battle#enter_command_phase -> open_battle_options",
  "RPG2k::Scene::Battle#leave_battle_event_phase -> enter_command_phase",
  "RPG2k::Scene::Battle#refresh_battle_status -> gauge_battle_layout?",
  "RPG2k::Scene::Battle#select_battle_command -> advance_actor",
  "RPG2k::Scene::Battle#start -> enter_command_phase",
  "RPG2k::Scene::Battle#update -> drive_battle_command",
  "RPG2k::Scene::GameOver#update -> parent",
  "RPG2k::Scene::Map#note_party_step -> state_table",
  "RPG2k::Scene::Map#setup_sprites -> parent",
  "RPG2k::Scene::SaveLoad#slot_timestamp -> parent",
  "RPG2k::Scene::Title#battle_troop -> parent",
  "RPG2k::Scene::Title#chipset_editor_flag? -> parent",
  "RPG2k::Scene::Title#continue_available? -> parent",
  "RPG2k::Scene::Title#hide_title? -> parent",
  "RPG2k::Scene::Title#map_editor_flag? -> parent",
  "RPG2k::Scene::Title#preview_animation_id -> parent",
  "RPG2k::Scene::Title#preview_map_id -> parent",
  "RPG2k::Scene::Title#update -> parent",
].freeze
