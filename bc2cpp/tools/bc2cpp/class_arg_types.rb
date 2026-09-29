# frozen_string_literal: true

require_relative 'call_site_index'

# Step 6c-bis: whole-program CALL-SITE CLASS inference.
#
# ArgTypes does this for the :fixnum/:symbol lattice, using
# IvarLayout.trace_type. This is the same idea for the class-name lattice, using
# trace_new_target: for a MONO name every call site reaches the one definition,
# so if every caller's argument at position k traces to a class, position k is
# that class. POLY names are skipped for ArgTypes' own reason -- their call
# sites may target different methods.
#
# Why this exists at all. ClassAnnotations (`# bc2cpp: (ClassName, ...)`) was
# consumed only as a SEED into ClassLayout's fixed point, so a wrong class
# annotation was indistinguishable from one that merely failed to apply: the
# seed and the facts it seeds are never compared. With an INDEPENDENT proof
# from the call sites, RBS_SEED_CONTRADICTION can compare the two -- Spinel's
# "an assertion, not a hint" rule, which the fixnum/symbol half already has.
#
# The three things this must not do, each of which cost a wrong answer first:
#
#   * it must not report a class from a call site whose receiver is unknown. A
#     `nil` here means "no fact", never "some other class" -- the same rule the
#     :nil_literal case in the contradiction check turned on.
#   * it must not join two different classes into one. ClassLayout's join
#     collapses any disagreement to UNKNOWN, and that stickiness is load-bearing
#     (docs/adr/0139: dropping an UNKNOWN because a concrete type arrived first
#     wrongly embedded ivars in Game::Screen and Game::State). Two call sites
#     passing different classes mean the position is genuinely unknown, so this
#     records nil rather than picking a winner.
#   * it must not feed IvarLayout or ClassLayout. This table is a REPORTING and
#     CHECKING artifact only. Feeding it into either analysis would make a new
#     inference feed a fixed point that ADR 0139's order-independence argument
#     was written about, for no proven benefit.
class ClassArgTypes
  def self.analyze(ireps, registry, owner_of, class_layout = {}, container_constants = nil, call_sites: nil)
    call_sites ||= CallSiteIndex.build(ireps)
    types = {}
    # Private, default-proc-free copies at every level the tracer indexes. Two
    # separate tables are affected, and the second one is the subtle one:
    #
    #   * `class_layout` -- the GETIV arm indexes `class_layout[owner]`, whose
    #     per-owner maps are `Hash.new { |h, k| h[k] = {} }`.
    #   * `registry` -- the chained-accessor arm does `registry[name]&.find`, and
    #     a Hash default that INSERTS on a miss turns that read into a mutation.
    #     scripts/bc2cpp_never_called_registrations_check.rb walks the registry
    #     while calling this, and hit "can't add a new key into hash during
    #     iteration" from registry.rb:95.
    #
    # Both are copies, so this analysis never mutates a table the caller owns.
    layout_snapshot = class_layout.each_with_object({}) do |(owner, ivars), out|
      out[owner] = ivars.each_with_object({}) { |(ivar, cls), inner| inner[ivar] = cls }
    end
    registry_snapshot = registry.each_with_object({}) do |(name, defs), out|
      out[name] = defs
    end

    registry.each do |name, defs|
      next unless defs.size == 1 # MONO names only -- ArgTypes' own reason.
      next unless defs.first.irep # native-only definition -- no body to walk.

      irep = ireps.fetch(defs.first.irep)
      enter = irep.enter
      mand = enter ? enter.enter_fields.first : 0
      next if mand.zero?

      arg_classes = Array.new(mand)
      conflicts = Array.new(mand, false)
      call_sites.fetch(name, []).each do |caller_irep, idx, d, n|
        next unless n == mand # a real call site to a MONO name matches its arity.

        caller_owner = owner_of[caller_irep.label]
        (1..mand).each do |k|
          found = trace_new_target(caller_irep, idx, (d + k).to_s, {}, mand, nil,
                                   owner: caller_owner, class_layout: layout_snapshot,
                                   registry: registry_snapshot,
                                   container_constants: container_constants)
          next if found.nil? || found.to_s.empty?

          slot = k - 1
          # A second, DIFFERENT class at the same position is genuine
          # heterogeneity, not evidence: record nothing for that slot.
          if arg_classes[slot] && arg_classes[slot] != found
            conflicts[slot] = true
          else
            arg_classes[slot] ||= found
          end
        end
      end

      types[name] = arg_classes.each_with_index.map { |c, i| conflicts[i] ? nil : c }
    end

    types
  end
end
