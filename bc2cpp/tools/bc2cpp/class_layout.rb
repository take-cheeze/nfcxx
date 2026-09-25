# frozen_string_literal: true

# Steps 6f-bis and 6g: proven fresh Arrays and ivar classes.

# ---------------------------------------------------------------------------
# Step 6f-bis: the shared "this expression is a proven fresh Array" rule, used
# by Step 6g's SETIV sites and (via CodeGen#proven_array_source) by every
# block recognizer, so the two cannot drift apart.
# ---------------------------------------------------------------------------
# INTERP_UNLOCK: when the static Array trace misses, the nearest write to the
# register (following MOVEs) proves an Array when it is:
#   - a block-carrying `select`/`reject`/`map` (CHAINED_ARRAY_METHODS);
#   - a MONO method with a `-> Array` annotation (annotated_array_return);
#   - a core method verified to return a fresh Array and not redefined in this
#     program (core_array_return?).
# Sound because of SKIP_UNSUPPORTED's per-method partitioning: a producer with
# any gap drops the whole method to the interpreter.
#
# CORE_ARRAY_CHAIN block gate: these three count only from SENDB/SSENDB. A
# blockless map/select/reject returns an Enumerator in mruby (enum.rb:
# `return to_enum(...) unless block`), and an attr_reader is always a
# blockless send; the bare-name rule misclassified `@map = map || state.map`
# (Game::State#map is an attr_accessor) as Array.
# Known narrowing: select/reject on a Hash returns a Hash (hash.rb). Every
# block consumer has an mrb_array_p raise-tripwire and ClassLayout readers
# re-check the class at runtime.
CHAINED_ARRAY_METHODS = %w[select reject map].freeze

# CORE_ARRAY_CHAIN: core methods that return a fresh Array whenever they
# return. Admitted only after core_array_return? confirms nothing in this
# program redefines the name (so a future `def keys` withdraws the claim).
# Verified against 3rd/mruby:
#   - keys/values: mrb_hash_keys/mrb_hash_values (src/hash.c);
#   - compact: ary_compact (mruby-array-ext), a dup;
#   - flatten: ary_flatten -> flatten_internal, a new Array;
#   - split: String#split (src/string.c);
#   - uniq: Array#uniq (dup / __uniq) and Enumerable#uniq (hash.values).
# A receiver without the method raises before returning, and every site
# still passes the emitter's mrb_array_p tripwire.
# Not here: to_a/dup (receiver-dependent), to_h (Hash), blockless sort_by
# (CORE_ARRAY_CHAIN_NEEDS_BLOCK), argless first/last
# (CORE_ARRAY_CHAIN_NEEDS_ARG).
CORE_ARRAY_RETURN_METHODS = %w[keys values compact flatten split uniq].freeze

# CORE_ARRAY_CHAIN: a fresh Array only with an explicit argument (n >= 1):
# src/array.c mrb_ary_first/mrb_ary_last return an ELEMENT with no argument
# and ary_subseq/mrb_ary_new_from_values with one. Neither is redefined in
# this program.
CORE_ARRAY_CHAIN_NEEDS_ARG = %w[first last].freeze

# CORE_ARRAY_CHAIN: a fresh Array only with a block: Array#sort_by and
# Enumerable#sort_by (mruby-enum-ext) both `return to_enum(:sort_by) unless
# block`.
CORE_ARRAY_CHAIN_NEEDS_BLOCK = %w[sort_by].freeze

# CORE_ARRAY_CHAIN: vetted bytecode overrides, by exact Owner#name (a bare name
# here would defeat core_array_return?). mruby-rgss/mrblib/array_sort.rb
# redefines Array#sort; both of its paths return `_rgss_native_sort` (mruby's
# Array#sort, `self.dup.sort!`), and Enumerable#sort returns an Array too.
VETTED_ARRAY_RETURN_OVERRIDES = Set['Array#sort'].freeze

# CORE_ARRAY_CHAIN: does `name`'s fresh-Array claim hold against this
# program's registry? Every MethodDef must be mruby core (`'<native>'`;
# mruby-rgss/src defines none of these names) or a vetted override. No entry
# at all (uniq, sort_by live in mruby's mrblib) is fine too.
# This rejects attr_reader/attr_accessor defs (real owner, no irep):
# Game::State#map is one, so "no bytecode body" is not "cannot be redefined".
def core_array_return?(name, block_carrying, registry, argc: 0)
  vetted_by_name = VETTED_ARRAY_RETURN_OVERRIDES.any? { |o| o.end_with?("##{name}") }
  if CORE_ARRAY_CHAIN_NEEDS_BLOCK.include?(name)
    return false unless block_carrying
  elsif CORE_ARRAY_CHAIN_NEEDS_ARG.include?(name)
    return false unless argc >= 1
  elsif !CORE_ARRAY_RETURN_METHODS.include?(name) && !vetted_by_name
    return false
  end

  (registry[name] || []).all? do |md|
    md.owner == '<native>' || VETTED_ARRAY_RETURN_OVERRIDES.include?("#{md.owner}##{md.name}")
  end
end

# ARRAY_RETURN_PROOF: `ret_proof` is an optional second oracle ("a call to
# this name leaves an Array"), beside the `-> Array` annotation. nil keeps the
# old behavior (ClassLayout's SETIV call has no CodeGen). See
# CodeGen#compute_array_return_names.
# Consulted only for non-block sends: a `break` in the caller's block makes
# the send evaluate to the BREAK operand (ops.h OP_BREAK). Same argument as
# compute_fixnum_return_names.
def proven_array_source_scan(irep, idx, dest_reg, registry, annotated = nil, ret_proof = nil)
  reg = dest_reg
  (idx - 1).downto(0) do |i|
    pin = irep.instructions[i]
    next unless pin
    # The block proc register (BLOCK writes dest+1) sits between the call and its
    # receiver write; skip it.
    next if pin.op == 'BLOCK'
    next unless pin.args[/^R(\d+)/, 1] == reg

    # CORE_ARRAY_CHAIN: follow MOVE (`regs[a] = regs[b]`, vm.c OP_MOVE) to the
    # register actually written. Skipping a MOVE would let the scan reach an older,
    # overwritten result on a reused register.
    if pin.op == 'MOVE'
      src = pin.args.scan(/R(\d+)/).flatten[1]
      return nil unless src

      reg = src
      next
    end
    return nil unless %w[SEND SSEND SENDB SSENDB SEND0 SSEND0].include?(pin.op)

    called = pin.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
    return nil unless called

    block_carrying = %w[SENDB SSENDB].include?(pin.op)
    # SEND0/SSEND0 print no `n=` field: absent means 0 args.
    argc = pin.args[/n=(\d+)/, 1]&.to_i || 0
    return 'Array' if block_carrying && CHAINED_ARRAY_METHODS.include?(called)
    return 'Array' if annotated&.call(called)
    return 'Array' if core_array_return?(called, block_carrying, registry, argc: argc)
    # ARRAY_RETURN_PROOF: non-block sends only (see ret_proof above).
    return 'Array' if !block_carrying && ret_proof&.call(called)

    return nil
  end
  nil
end

# ---------------------------------------------------------------------------
# Step 6g: whole-program "this ivar always holds exactly this class" analysis,
# the object-reference analogue of IvarLayout. Never an embedding candidate:
# it only feeds compile_send's devirtualization, which guards every use with a
# runtime mrb_obj_class check.
# A fixed point, because one ivar's class can depend on another's.
class ClassLayout
  UNKNOWN = :unknown

  # ANY_OPAQUE_SUPPORT: see ArrayElementLayout.analyze's `poison_reason`.
  # ARRAY_RETURN_IVAR_HINT: `array_ret_proof` (compute_array_return_names) is
  # passed to proven_array_source_scan as `ret_proof`.
  # RETCLASS_SELF_CALL_SUPPORT: `ret_class_proof` (compute_class_return_names)
  # is passed to trace_new_target. Both default to nil (old behavior), which is
  # also what the driver's first probing pass passes; see that call site for
  # the stratification.
  def self.analyze(ireps, registry, class_annotations = {}, container_constants = {}, annotated_array_return = nil,
                    poison_reason: nil, array_ret_proof: nil, ret_class_proof: nil, module_body_ivar_labels: {})
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    module_body_ivar_labels.each do |owner, labels|
      labels.each { |label| methods_of[owner] << label if ireps[label] }
    end

    classes = Hash.new { |h, k| h[k] = {} } # owner -> {ivar_name => class_name or UNKNOWN}

    10.times do
      changed = false
      methods_of.each do |owner, irep_labels|
        irep_labels.each do |label|
          irep = ireps.fetch(label)
          enter = irep.instructions.find { |i| i.op == 'ENTER' }
          mand = enter ? enter.args.split(':').first.to_i : 0
          arg_classes = class_annotations[label]&.args

          irep.instructions.each_with_index do |insn, idx|
            next unless insn.op == 'SETIV'

            ivar = insn.args[/@(\w+)/, 1]
            src_reg = insn.args[/R(\d+)/, 1]
            # Never hand an UNKNOWN entry to trace_new_target's GETIV lookup.
            known_so_far = classes[owner].reject { |_, c| c == UNKNOWN }
            # CHAINED_ACCESSOR_SUPPORT: the full, unfiltered in-progress table, so another
            # class's ivar hints can be read; trace_new_target itself refuses UNKNOWN
            # entries from it.
            found = trace_new_target(irep, idx, src_reg, known_so_far, mand, arg_classes, owner: owner,
                                      class_layout: classes, registry: registry,
                                      container_constants: container_constants,
                                      ret_class_proof: ret_class_proof)
            # CORE_ARRAY_CHAIN: when the trace misses, ask proven_array_source_scan. It
            # only answers 'Array' for an expression that allocates a new Array, the same
            # kind of fact as an ARRAY literal. It runs only where the trace gave up, and
            # the join still poisons on any disagreeing site.
            # ANNOTATED_ARRAY_RETURN_THREADING: `annotated_array_return` is the same
            # MONO-keyed `-> Array` lookup the block recognizers use (see
            # CodeGen#annotated_array_return), so a self-call to an annotated method
            # (`@base = base_stats(1)`) is Array evidence here too.
            # ARRAY_RETURN_IVAR_HINT: `array_ret_proof` makes a non-block call to a method
            # proven to return an Array count as Array evidence (Game::Battle#@queue =
            # turn_order). Monotone: it only turns UNKNOWN into 'Array'; the join is
            # unchanged, and LOADNIL writes still reach NIL_TOLERANT_JOIN.
            found ||= proven_array_source_scan(irep, idx, src_reg, registry, annotated_array_return,
                                               array_ret_proof)

            # NIL_TOLERANT_JOIN: `@x = nil` (LOADNIL Rn; SETIV @x Rn) is evidence of
            # nothing, so it is skipped rather than joined. Poisoning on it would kill
            # every ivar that #initialize nils out. Sound because every consumer re-checks
            # the class at runtime and falls back to mrb_funcall. IvarLayout (embedding) is
            # separate and still treats nilable ivars as unembeddable.
            next if found.nil? && nil_literal_write?(irep, idx, src_reg)

            found ||= UNKNOWN

            before = classes[owner][ivar]
            # Disagreeing sites poison to UNKNOWN, sticky across passes.
            merged = if before.nil?
                       found
                     elsif before == UNKNOWN || found == UNKNOWN || before != found
                       UNKNOWN
                     else
                       before
                     end
            if merged != before
              classes[owner][ivar] = merged
              if merged == UNKNOWN && poison_reason
                # See `poison_reason` (same :any/:opaque split as ArrayElementLayout).
                (poison_reason[owner] ||= {})[ivar] = found == UNKNOWN ? :opaque : :any
              end
              changed = true
            end
          end
        end
      end
      break unless changed
    end

    classes
  end

  # analyze's result minus UNKNOWN entries and empty owners. The raw result is
  # kept so poisoned ivars can be reported (`== ivar-class candidates (poisoned
  # to unknown) ==`); every consumer sees only this filtered shape.
  def self.known(classes)
    classes.each_with_object({}) do |(owner, ivars), out|
      known = ivars.reject { |_, c| c == UNKNOWN }
      out[owner] = known unless known.empty?
    end
  end

  def self.unknowns(classes)
    classes.flat_map { |owner, ivars| ivars.select { |_, c| c == UNKNOWN }.keys.map { |i| "#{owner}#@#{i}" } }
  end

  # ANY_OPAQUE_SUPPORT: same filter as ArrayElementLayout.unknowns_by_reason.
  def self.unknowns_by_reason(classes, poison_reason, reason)
    unknowns(classes).select do |name|
      owner, ivar = name.split('#@', 2)
      poison_reason.dig(owner, ivar) == reason
    end
  end
end
