# frozen_string_literal: true

require 'digest'
require_relative 'call_facts'
require_relative 'runtime_header'

# PROGRAM_CLASS_SLOTS (BC2CPP_PROGRAM_CLASS_SLOTS=0 turns it off): one OWNER_CLASS_CACHE table for the program
# instead of one per compiled gem. An owner's slot is its rank in the universe: every owner the registry (core
# hidden definitions too), the superclass table, the closed world's class and module declarations and the core
# hierarchy (CORE_SELF_NATIVE's definers) name, sorted. All of them are built before
# SHARED_GENERATION forks from the same input for every gem, so each gem numbers an owner alike, and a helper that
# tests owner classes prints the same text in every gem (CROSS_GEM_SHARE keeps one copy). An owner outside the
# universe takes a slot after it, in a table of the gem's own.
#
# The table and its VM live in a header named by the digest of the universe and of the lookup the slots are filled
# by, at file scope, so gems that disagree on either get different tables, never one table read two ways
# (runtime_header_check.rb's --isolation fails when the gems of a build include different ones). A slot holds what the
# gem's own slot held: the lookup, the uncached miss (nullptr), the VM binding and the reset at gem_init/gem_final are
# the same code, and a reset by any gem clears every slot, which only costs a refill.
module ProgramClassSlots
  ENV_KEY = 'BC2CPP_PROGRAM_CLASS_SLOTS'
  # Bumped when the header's layout changes.
  FORMAT = 1
  # A constant path, as the slot's lookup spells it in C++ strings; any other owner keeps a slot of the gem's own.
  OWNER = /\A[A-Z]\w*(?:::[A-Z]\w*)*(?:\.singleton)?\z/

  module_function

  def enabled?(env = ENV)
    env[ENV_KEY] != '0' && !env[RuntimeHeader::DIR_KEY].to_s.empty?
  end

  # The sorted owner universe, or nil when the program-wide table is off.
  def universe(known_owners, superclass_of, closed_world = nil)
    return nil unless enabled?

    owners = known_owners.to_a + superclass_of.keys + superclass_of.values.grep(String) + CallFacts::CORE_SUPER.keys
    owners += closed_world.declared_class_names + closed_world.declared_module_names.to_a + closed_world.declared_superclass_names if closed_world
    owners.map(&:to_s).grep(OWNER).uniq.sort.freeze
  end

  def digest(universe, lookup)
    Digest::SHA256.hexdigest([FORMAT, lookup, *universe].join("\n"))[0, 16]
  end

  def state_name(digest) = "bc2cpp_pw_class_state_#{digest}"
  def slots_name(digest) = "bc2cpp_pw_class_slots_#{digest}"

  # Writes the header for `universe` and returns the line that includes it.
  def include_line(universe, lookup)
    d = digest(universe, lookup)
    path = File.join(ENV.fetch(RuntimeHeader::DIR_KEY), "bc2cpp_pw_classes_#{d}.hxx")
    RuntimeHeader.write_once(path, <<~CPP)
      #pragma once
      // PROGRAM_CLASS_SLOTS (program_class_slots.rb): the owner-class slots of every compiled gem, one per program.
      struct mrb_state;
      struct RClass;
      inline mrb_state* #{state_name(d)} = nullptr;
      inline struct RClass* #{slots_name(d)}[#{[universe.size, 1].max}] = {};
    CPP
    [d, "#include \"#{path}\"\n"]
  end
end
