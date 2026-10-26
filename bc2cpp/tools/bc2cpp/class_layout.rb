# frozen_string_literal: true

require_relative 'bytecode_ir_ops'
require_relative 'fixpoint'
require_relative 'record_hash'
require_relative 'ivar_poison_causes'
require_relative 'native_core_result_sigs'
require_relative 'core_block_iterator_sigs'
require_relative 'lcf_file_fields'

# Steps 6f-bis and 6g: proven fresh Arrays and ivar classes.

# ---------------------------------------------------------------------------
# Step 6f-bis: the shared "this expression is a proven fresh Array" rule, used
# by Step 6g's SETIV sites and (via CodeGen#proven_array_source) by every
# block recognizer, so the two cannot drift apart.
# ---------------------------------------------------------------------------
# INTERP_UNLOCK: when the static Array trace misses, the nearest write to the
# register (following MOVEs) proves an Array when it is:
#   - a block-carrying call that block_result_array? confirms for its receiver;
#   - a MONO method with a `-> Array` annotation (annotated_array_return);
#   - a core method verified to return a fresh Array and not redefined in this
#     program (core_array_return?).
# Sound because of SKIP_UNSUPPORTED's per-method partitioning: a producer with
# any gap drops the whole method to the interpreter.
#
# BLOCK_RESULT_ARRAY: a block-form call answers an Array only as
# core_block_iterators (declarations.rbs) declares for its exact receiver. The
# bare name is not enough: a blockless map/select/reject is an Enumerator (enum.rb
# `return to_enum(...) unless block`), an attr_reader is always blockless
# (Game::State#map is an attr_accessor), and Hash#select keeps the Hash.
# The names come from that table, so a new block iterator is a declaration, not code.
BLOCK_RESULT_NAMES = CoreBlockIteratorSigs.results.values.flat_map(&:keys).to_set.freeze

# BLOCK_RESULT_ARRAY: does `name` sent with a block to an exact `receiver_class`
# answer an Array? Looked up as mruby does: the receiver's own entry, else
# Enumerable's (Array defines none of these; Hash declares each Enumerable entry
# it overrides, checked by core_facts_rbs_check). A program definition on the
# receiver or on Enumerable would win that lookup, so it withdraws the claim.
def block_result_array?(name, receiver_class, registry)
  return false unless CoreBlockIteratorSigs::CLASSES.include?(receiver_class)

  results = CoreBlockIteratorSigs.results
  owner = results.fetch(receiver_class, {}).key?(name) ? receiver_class : 'Enumerable'
  return false unless results.dig(owner, name) == 'Array'

  (registry[name] || []).all? do |md|
    md.owner == '<native>' || ![receiver_class, 'Enumerable'].include?(md.owner)
  end
end

# CORE_ARRAY_CHAIN: core methods that return a fresh Array whenever they
# return. Admitted only after core_array_return? confirms nothing in this
# program redefines the name (so a future `def keys` withdraws the claim).
# The names and their 3rd/mruby verification live in sig/bc2cpp/declarations.rbs#core_fresh_arrays.
# Not here: to_a/dup (receiver-dependent), to_h (Hash), sort_by (blockless it
# is an Enumerator, and no block-only name is admitted here).
CORE_ARRAY_RETURN_METHODS = NativeCoreResultSigs.fresh_array_names

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
def core_array_return?(name, registry)
  vetted_by_name = VETTED_ARRAY_RETURN_OVERRIDES.any? { |o| o.end_with?("##{name}") }
  return false unless CORE_ARRAY_RETURN_METHODS.include?(name) || vetted_by_name

  (registry[name] || []).all? do |md|
    md.owner == '<native>' || VETTED_ARRAY_RETURN_OVERRIDES.include?("#{md.owner}##{md.name}")
  end
end

# LCF_FILE_FIELDS: a GETIDX whose key is a literal Symbol and whose receiver is exactly an LCF file class reads that
# file's schema field. The receiver class comes from the caller's trace (receiver_class); nil means no fact.
def lcf_file_array_read?(irep, pin_idx, pin, receiver_class)
  return false unless receiver_class

  keys = BytecodeIR.producers(irep, pin_idx, (pin.reg + 1))
  return false unless keys&.size == 1 && !keys.first.entry? && keys.first.insn&.op == :LOADSYM

  file_class = receiver_class.call(pin_idx, pin)
  return false unless file_class.is_a?(String)

  LcfFileFields.array_field?(file_class, keys.first.insn.sym.to_s)
end

# LCF_FILE_FIELDS join: `@x = unit[:key] || []` stores a register with two reaching definitions, and neither dominates
# the store, so proven_array_source_scan's single-writer walk finds nothing. Every definition being an Array (an ARRAY
# allocation, or a schema Array read off an exact LCF file) makes the join an Array.
def array_join_source?(irep, idx, reg, receiver_class)
  defs = BytecodeIR.reaching_definitions(irep, idx, reg, through_handlers: true, shared: true)
  return false if defs.nil? || defs.size < 2

  defs.all? do |defn|
    next false if defn.entry?

    insn = BytecodeIR.for(irep).source_at(defn.index)
    next true if BytecodeIR::Ops::ARRAY_ALLOC.include?(insn.op)

    insn.op == :GETIDX && lcf_file_array_read?(irep, defn.index, insn, receiver_class)
  end
end

# ARRAY_RETURN_PROOF: `ret_proof` is an optional second oracle ("a call to
# this name leaves an Array"), beside the `-> Array` annotation. nil keeps the
# old behavior (ClassLayout's SETIV call has no CodeGen). See
# CodeGen#compute_array_return_names.
# Consulted only for non-block sends: a `break` in the caller's block makes
# the send evaluate to the BREAK operand (ops.h OP_BREAK). Same argument as
# compute_fixnum_return_names.
def proven_array_source_scan(irep, idx, dest_reg, registry, annotated = nil, ret_proof = nil, receiver_class: nil)
  # The block proc register (BLOCK writes dest+1) sits between the call and its
  # receiver write, so BLOCK is skipped. CORE_ARRAY_CHAIN: MOVE is followed to the
  # register actually written (`regs[a] = regs[b]`, vm.c OP_MOVE); skipping it would
  # let the scan reach an older, overwritten result on a reused register.
  # JOIN_DOMINANCE: the source must be the only value the register can hold.
  irep.walk_dominating_writers(idx - 1, dest_reg, use: idx, skip_ops: %i[BLOCK], follow_moves: true) do |pin, pin_idx|
    # RECORD_HASH_PROOF: `@slot[:key]` on a record Hash whose key only ever holds an Array.
    next 'Array' if pin.op == :GETIDX && RecordHash.array_read?(irep, pin_idx, tier: RecordHash.consumer_tier)
    # LCF_FILE_FIELDS (lcf_file_fields.rb): `unit[:key]` on an exact LCF file whose schema field is an Array.
    next 'Array' if pin.op == :GETIDX && lcf_file_array_read?(irep, pin_idx, pin, receiver_class)

    next nil unless BytecodeIR::Ops::SEND.include?(pin.op)

    called = pin.sym
    next nil unless called

    block_carrying = BytecodeIR::Ops::BLOCK_SEND.include?(pin.op)
    if block_carrying && BLOCK_RESULT_NAMES.include?(called)
      # CHAINED_IVAR_RECEIVER: ClassLayout passes the class it has proven so far, so `@q = @q.reject { }` on an ivar
      # that every other store makes an Array is an Array store too (a plain trace cannot read the ivar).
      traced = receiver_class ? receiver_class.call(pin_idx, pin) : trace_new_target(irep, pin_idx, pin.reg, registry: registry)
      # CHAINED_ARRAY_RECURSION: the receiver may itself be a fresh Array by this rule (`all.reject { }.select { }`,
      # `annotated_array_method.select { }`), which no class trace sees. The scan starts at the chained send's own
      # index, strictly before this one, so the recursion ends.
      traced ||= proven_array_source_scan(irep, pin_idx, pin.reg, registry, annotated, ret_proof,
                                          receiver_class: receiver_class)
      next 'Array' if block_result_array?(called, traced, registry)
    end
    next 'Array' if annotated&.call(called)
    next 'Array' if core_array_return?(called, registry)
    # ARRAY_RETURN_PROOF: non-block sends only (see ret_proof above).
    next 'Array' if !block_carrying && ret_proof&.call(called)

    nil
  end
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
                    poison_reason: nil, array_ret_proof: nil, ret_class_proof: nil, module_body_ivar_labels: {},
                    store_log: nil)
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    module_body_ivar_labels.each do |owner, labels|
      labels.each { |label| methods_of[owner] << label if ireps[label] }
    end

    classes = Hash.new { |h, k| h[k] = {} } # owner -> {ivar_name => class_name or UNKNOWN}
    label_name = {}
    registry.each_value { |defs| defs.each { |d| label_name[d.irep] = d.name if d.irep } } if store_log

    Fixpoint.iterate('ClassLayout.analyze', Fixpoint::SWEEP_LIMIT) do
      changed = false
      methods_of.each do |owner, irep_labels|
        irep_labels.each do |label|
          irep = ireps.fetch(label)
          enter = irep.enter
          mand = enter ? enter.enter_fields.first : 0
          arg_classes = class_annotations[label]&.args

          irep.each_with_op(:SETIV) do |insn, idx|
            ivar = insn.ivar
            src_reg = insn.regs.first
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
            receiver_class = lambda do |pin_idx, pin|
              trace_new_target(irep, pin_idx, pin.reg, known_so_far, mand, arg_classes, owner: owner,
                                                                                         class_layout: classes, registry: registry,
                                                                                         container_constants: container_constants)
            end
            found ||= proven_array_source_scan(irep, idx, src_reg, registry, annotated_array_return,
                                               array_ret_proof, receiver_class: receiver_class)
            found ||= 'Array' if array_join_source?(irep, idx, src_reg, receiver_class)

            # NIL_TOLERANT_JOIN: `@x = nil` (LOADNIL Rn; SETIV @x Rn) is evidence of
            # nothing, so it is skipped rather than joined. Poisoning on it would kill
            # every ivar that #initialize nils out. Sound because every consumer re-checks
            # the class at runtime and falls back to mrb_funcall. IvarLayout (embedding) is
            # separate and still treats nilable ivars as unembeddable.
            next if found.nil? && nil_literal_write?(irep, idx, src_reg)

            # IVAR_POISON_CAUSES: remember each store and what it resolved to on this pass (the last pass, which changed
            # nothing, is the one that stays); IvarPoisonCauses classifies the unresolved ones after the fixed point.
            store_log[[owner, label, idx]] = [ivar, found, irep, src_reg, mand, label_name[label]] if store_log

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
      changed
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
