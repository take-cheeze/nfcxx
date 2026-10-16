# frozen_string_literal: true

# DECLARED_RETURN_GUARDS_REVIEWED (docs/adr/0455): every runtime-checked return declaration (`%a{bc2cpp:hint}`,
# DECLARED_RETURN_GUARD) is a forced check in its compiled body: a value of another type raises
# BC2cppHintViolation, where the method used to return it. An unlisted guard fails a closed-world run of the reviewed
# program, and so does an entry whose method compiles with no such guard. Key: "<owner>#<method> -> <declared type>",
# as the DECLARED_RETURN_GUARD_SITE listing prints it. The review is the body: read every return path (and the
# writers of what it reads) before listing a declaration; the verify build (-DBC2CPP_NOMETHOD_VERIFY) over the real
# workloads aborts at the first violation.
require 'set'

DECLARED_RETURN_GUARDS_REVIEWED = Set[
  # A database-row read, `|| 0` or `+ 1`: an Integer of the LCF reader's range, a Fixnum on every target.
  'Game::Actor#atb_gauge -> Integer',
  'Game::Actor#attack_hit_rate -> Integer',
  'Game::Actor#battle_x -> Integer',
  'Game::Actor#battle_y -> Integer',
  'Game::Actor#battler_animation_id -> Integer',
  'Game::Actor#faceset_index -> Integer',
  'Game::Actor#max_level -> Integer',
  'Game::Actor#total_state_count -> Integer',
  'Game::Actor#weapon_attack_multiplier -> Integer',
  'Game::Interpreter#teleport_transition -> Integer',
  'Game::Party#death_handler_event -> Integer',
  'Game::Party#item_count -> Integer',
  # Array returns: `is_a?(Array)`-guarded dup or `[0]`, an each_with_object memo, an attr_reader, a cached ivar,
  # a Hash read `|| NO_BLOCKERS`.
  'Game::Actor#class_battle_commands -> Array',
  'Game::Troop#drops -> Array',
  'Game::Interpreter#stat_targets -> Array[Game::Actor]',
  'RPG2k::Scene::EquipMenu#candidates -> Array',
  'RPG2k::Scene::Map#blockers_at -> Array',
  # `@all[id]` reads whose stored values are only `Actor.new`; nil for an absent or invalid id.
  'Game::Actors#[] -> Game::Actor?',
  'Game::Actors#existing -> Game::Actor?'
].freeze
