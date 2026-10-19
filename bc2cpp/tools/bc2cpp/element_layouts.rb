# frozen_string_literal: true

require_relative 'fixpoint'
require_relative 'bytecode_ir_containers'

# Step 6g-bis: element classes of Array and Hash ivars.

# ---------------------------------------------------------------------------
# Step 6g-bis: ELEMENT_CLASS_SUPPORT: "every element of this Array ivar is
# exactly class X", so calls on an inlined loop's element register can be
# devirtualized (`party.each { |a| a.dead? }`).
#
# Not a proof: the sweep sees only this program's bytecode, and an Array is
# mutable through aliases (`party.actors.push(x)`). Mutations it can attribute
# (ARRAY_ELEMENT_WRITERS on a receiver tracing to `GETIV @x` in the owner) are
# checked; unattributable ones are a named residual. That is harmless because
# every consumer re-checks `mrb_class_ptr(...) == mrb_obj_class(M, elem)` and
# falls back to mrb_funcall. The table is never used to embed, pick a C type or
# skip a check.
# A fixed point (ten passes, sticky UNKNOWN join), as in ClassLayout.
# ---------------------------------------------------------------------------

# ELEMENT_CLASS_SUPPORT: core methods whose result's elements are a subset (or
# permutation) of the receiver's: compact, uniq, sort, reverse, dup (verified
# in 3rd/mruby); plus first/last with an argument, take/drop, and block-carrying
# select/reject (they push the element itself). dup is fine here because the
# receiver is already known to be an Array. map/collect/flat_map replace
# elements and have their own rule.
ARRAY_ELEMENT_PRESERVING = %w[compact uniq sort reverse dup].freeze
ARRAY_ELEMENT_PRESERVING_NEEDS_ARG = %w[first last take drop].freeze
ARRAY_ELEMENT_PRESERVING_NEEDS_BLOCK = %w[select reject].freeze

# ELEMENT_CLASS_SUPPORT: core methods returning one ELEMENT of the receiver:
# `[]`/`at`/`fetch` with one argument (`a[i, n]`/`a[range]` return Arrays),
# argless first/last (mrb_ary_first/mrb_ary_last), sample, min, max.
ARRAY_ELEMENT_INDEXERS_NEEDS_ARG = %w[[] at fetch].freeze
ARRAY_ELEMENT_INDEXERS_NO_ARG = %w[first last sample min max].freeze

# ELEMENT_CLASS_SUPPORT: every in-place element writer. All must agree, or
# `@a = []` followed by `@a.push(x)` would "prove" a class from the empty
# literal.
#   - push/<</unshift: every argument is an element;
#   - insert: every argument after the index;
#   - []=: with two arguments `v` is an element; three (splice) poisons;
#   - concat/replace: the argument is an Array; recurse on it.
# Any other listed writer, or an unmodeled shape, poisons the ivar.
ARRAY_ELEMENT_WRITERS = %w[push << unshift insert []= concat replace fill collect! map! flatten! sort_by!].freeze

# HASH_ELEMENT_SUPPORT: Hash VALUE writers only (the payoff is the value in
# `hash.each { |k, v| v.foo }`). `h[k] = v` compiles to SETIDX (see
# HashElementLayout.analyze); this list covers the explicit `h.[]=(k, v)` /
# `h.store(k, v)` spellings (both hash_set, src/hash.c). No preserving-chain
# rule; unmodeled shapes poison.
HASH_ELEMENT_WRITERS = %w[[]= store].freeze

# PRIMITIVE_ELEMENT_SUPPORT: element tags element_value_class returns for
# literal primitives. `.known` strips them explicitly: consumers
# (with_element_hint et al.) only guard with mrb_obj_class and were never meant
# to receive them. Diagnostic only, distinct from ELEM_HINT and ELEM_CANDIDATE
# (ANY/OPAQUE; see ArrayElementLayout.analyze).
PRIMITIVE_ELEMENT_CLASSES = %w[Integer Hash String Symbol].freeze

# ELEMENT_CLASS_SUPPORT: element class of the Array in `reg` at `idx`, built
# like proven_array_source_scan (nearest write, MOVEs followed, nil on anything
# unmodelled). nil is always safe: the caller poisons the ivar.
# JOIN_DOMINANCE (ADR 0261), element dimension: every walk in this file takes a
# writer only when it dominates the read it feeds, so `@a = c ? [A.new] : [B.new]`
# and `@a = other || []` no longer read just the textually nearest arm. The strict
# hint tier forces ELEMENT hints (ADR 0419), so a guard no longer covers that.
def legacy_array_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  # Two ivars can reference each other (`@a = @b.compact`, `@b = @a.compact`),
  # so the depth cap makes termination local to this function.
  return nil if depth > 8

  # An `Array<Klass>` argument annotation counts only when the walk reaches the
  # untouched incoming argument register; consumers still guard each element.
  at_entry = lambda do |reg|
    pos = reg.to_i
    ctx[:arg_elements][pos - 1] if ctx[:arg_elements] && pos.between?(1, ctx[:mand])
  end
  # BLOCK is skipped: it writes the block proc register (see proven_array_source_scan).
  irep.walk_dominating_writers(idx - 1, dest_reg, use: idx, skip_ops: %w[BLOCK], follow_moves: true,
                                                 exhausted: at_entry) do |insn, i, reg|
    case insn.op
    when 'ARRAY', 'ARRAY2'
      # "ARRAY R3 2": N consecutive registers from Rd.
      # An EMPTY literal is VACUOUS, not unknown: it satisfies "every element is X"
      # for every X, so it must not poison (nearly every array ivar starts as
      # `@x = []`). VACUOUS is skipped by the join, so an ivar whose only site is
      # `[]` gets no entry.
      n = insn.uint_operand
      next nil if n.nil?
      next ArrayElementLayout::VACUOUS if n.zero?

      base = reg.to_i
      classes = (0...n).map { |k| element_value_class(irep, i, (base + k).to_s, ctx, depth + 1) }
      next nil if classes.any?(&:nil?) || classes.uniq.size != 1

      classes.first
    when 'GETIV'
      ivar = insn.ivar
      ivar && ivar_element_hint(ctx[:owner], ivar, ctx)
    when 'SEND', 'SEND0', 'SENDB', 'SSENDB', 'SSEND', 'SSEND0'
      send_element_class(irep, i, reg, insn, ctx, depth)
    end
  end
end

# HASH_ELEMENT_SUPPORT: VALUE class of the Hash in `reg` at `idx`. Narrower
# than array_element_source_scan: only a literal and a chained ivar read, plus
# MOVE-following; nil on anything else.
def legacy_hash_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  return nil if depth > 8

  irep.walk_dominating_writers(idx - 1, dest_reg, use: idx, skip_ops: %w[BLOCK], follow_moves: true) do |insn, i, reg|
    case insn.op
    when 'HASH'
      # "HASH R2 2": N key/value PAIRS from Rd (vm.c OP_HASH sets regs[i] =>
      # regs[i+1]), so values are at odd offsets Rd+1, Rd+3, ... An empty literal is
      # VACUOUS, as in array_element_source_scan.
      n = insn.uint_operand
      next nil if n.nil?
      next HashElementLayout::VACUOUS if n.zero?

      base = reg.to_i
      classes = (0...n).map { |k| element_value_class(irep, i, (base + 2 * k + 1).to_s, ctx, depth + 1) }
      next nil if classes.any?(&:nil?) || classes.uniq.size != 1

      classes.first
    when 'GETIV'
      ivar = insn.ivar
      ivar && ivar_hash_element_hint(ctx[:owner], ivar, ctx)
    end
  end
end

# ELEMENT_CLASS_SUPPORT: the SEND arm of the scan above.
def send_element_class(irep, i, reg, insn, ctx, depth)
  # Same charset as compile_send's own name extraction (see its comment).
  name = insn.sym
  return nil unless name

  block_carrying = %w[SENDB SSENDB].include?(insn.op)
  # SEND0/SSEND0 print no "n=": zero arguments.
  argc = insn.argc || 0
  self_recv = %w[SSEND SSEND0 SSENDB].include?(insn.op)

  # A `-> Array<Klass>` annotation is trusted only when its irep is the only
  # definition of the name (else the call may reach another method).
  annotated = ctx[:annotated_element]&.call(name)
  return annotated if annotated

  # A preserving chain yields the receiver's elements. SSEND has no receiver
  # register to trace.
  preserving =
    ARRAY_ELEMENT_PRESERVING.include?(name) ||
    (ARRAY_ELEMENT_PRESERVING_NEEDS_ARG.include?(name) && argc >= 1) ||
    (ARRAY_ELEMENT_PRESERVING_NEEDS_BLOCK.include?(name) && block_carrying)
  if preserving
    return nil if self_recv

    return array_element_source_scan(irep, i, reg, ctx, depth + 1)
  end

  # `map`/`collect` with a block: elements are the block's yielded values (see
  # block_return_class). `flat_map` splices, so it is excluded.
  if block_carrying && %w[map collect].include?(name) && argc.zero?
    block_irep = adjacent_block_irep(irep, i, reg, ctx)
    return nil unless block_irep

    return block_return_class(block_irep, ctx, depth + 1)
  end

  if block_carrying && name == 'filter_map' && argc.zero?
    block_irep = adjacent_block_irep(irep, i, reg, ctx)
    return nil unless block_irep

    input_class = array_element_source_scan(irep, i - 1, reg, ctx, depth + 1)
    return filter_map_block_return_class(block_irep, ctx, depth + 1, input_class)
  end

  # CHAINED_ACCESSOR_SUPPORT, element dimension (`@state.party.actors`): the
  # receiver resolves to class R, R defines the name as an :ivar_accessor, and
  # R's entry in this table names an element class. Same check as
  # trace_new_target's chained-accessor branch.
  return nil if argc.positive? || block_carrying
  return self_accessor_element(name, ctx) if self_recv

  recv_class = traced_owner(irep, i, reg, ctx)
  return nil unless recv_class

  accessor = ctx[:registry][name]&.find { |md| md.owner == recv_class && md.kind == :ivar_accessor }
  return nil unless accessor

  ivar_element_hint(recv_class, name, ctx)
end

# SELF_ACCESSOR_RECEIVER: `allies` on implicit self reads `@allies` when the call can only reach
# `ctx[:owner]`'s own attr_reader, so the ivar's element hint applies as it would to a GETIV.
# CodeGen answers that with CodeGen#self_accessor_owner? (`ctx[:self_accessor]`, which also covers
# a subclassed owner by hierarchy analysis); without it, self's class must be exact
# (self_receiver_class) and register the reader itself.
def self_accessor_element(name, ctx)
  owner = ctx[:owner]
  reached = if ctx[:self_accessor]
              ctx[:self_accessor].call(name)
            else
              self_receiver_class(ctx) &&
                ctx[:registry][name]&.any? { |md| md.owner == owner && md.kind == :ivar_accessor }
            end
  reached ? ivar_element_hint(owner, name, ctx) : nil
end

# ELEMENT_CLASS_SUPPORT: read the in-progress table without returning UNKNOWN.
# `key?` because `[]` on the `Hash.new { {} }` table would insert an entry and
# perturb the diagnostic ordering.
def ivar_element_hint(owner, ivar, ctx)
  table = ctx[:elements]
  return nil unless owner && ivar && table&.key?(owner)

  hint = table[owner][ivar]
  return nil if hint.nil? || hint == ArrayElementLayout::UNKNOWN

  hint
end

# HASH_ELEMENT_SUPPORT: ivar_element_hint for `ctx[:hash_elements]`.
def ivar_hash_element_hint(owner, ivar, ctx)
  table = ctx[:hash_elements]
  return nil unless owner && ivar && table&.key?(owner)

  hint = table[owner][ivar]
  return nil if hint.nil? || hint == HashElementLayout::UNKNOWN

  hint
end

# ELEMENT_CLASS_SUPPORT: the block irep of the SENDB at `i`, re-checking the
# `BLOCK R(a+1) I[k]` adjacency.
def legacy_adjacent_block_irep(irep, i, recv_reg, ctx)
  block_insn = i.positive? ? irep.instructions[i - 1] : nil
  return nil unless block_insn && block_insn.op == 'BLOCK'
  return nil unless block_insn.reg == (recv_reg.to_i + 1).to_s

  k = block_insn.block_index
  return nil unless k

  label = irep.reps[k.to_i]
  label && ctx[:ireps][label]
end

# ELEMENT_CLASS_SUPPORT: class of a `map` block's yielded value. Every RETURN
# must agree; RETNIL (a bare `next`), RETFALSE/RETTRUE or a break make the
# answer unknown, as does a block with no RETURN.
def block_return_class(block_irep, ctx, depth)
  # A block's `self` is the method's self, so owner and ivar hints carry over.
  # Its parameters are not method arguments: `mand: 0` disables the
  # argument-annotation terminal.
  irep_return_class(block_irep, ctx.merge(arg_classes: nil, mand: 0), depth)
end

# ELEMENT_CLASS_SUPPORT: filter_map drops falsy results, so nil/false exits
# are ignored; every other RETURN must prove the same class.
def legacy_filter_map_block_return_class(block_irep, ctx, depth, input_class)
  return nil if depth > 8

  found = nil
  subctx = ctx.merge(arg_classes: nil, mand: 0)
  block_irep.instructions.each_with_index do |insn, i|
    case insn.op
    when 'RETURN'
      reg = insn.no_operands? ? '0' : insn.reg
      previous = i.positive? ? block_irep.instructions[i - 1] : nil
      # JOIN_DOMINANCE: the literal must be the only value a jump onto the RETURN can bring.
      if previous && %w[LOADNIL LOADFALSE].include?(previous.op) && previous.reg == reg &&
         BytecodeIR.write_dominates?(block_irep, i - 1, i, reg)
        next
      end

      klass = element_value_class(block_irep, i, reg, subctx, depth + 1)
      klass ||= input_class if block_mandatory_param_source?(block_irep, i, reg)
      return nil unless klass && ctx[:known_owners].include?(klass)
      return nil if found && found != klass

      found = klass
    when 'RETNIL', 'RETFALSE'
      # Both are discarded by filter_map's own truthiness check.
      next
    when 'RETTRUE', 'BREAK', 'RETURN_BLK'
      return nil
    end
  end
  found
end

def legacy_block_mandatory_param_source?(irep, idx, reg)
  enter = irep.enter
  mandatory = enter ? enter.enter_fields.first : 0
  return false if mandatory.zero?

  # Only MOVEs may sit between the read and the incoming register.
  irep.walk_dominating_writers(idx - 1, reg, use: idx, follow_moves: true,
                                            exhausted: ->(last) { last.to_i.between?(1, mandatory) }) do
    false
  end || false
end

# ELEMENT_CLASS_SUPPORT: trace a register to a class the REGISTRY knows.
# trace_new_target returns bare names ("Actors" for `Actors.new` in
# Game::Party) while the registry says "Game::Actors", so an unresolved bare
# name is a dead hint. Resolve it like Ruby: lexical nesting innermost first,
# accepting only registry classes; otherwise nil.
# Kept local to this analysis: changing trace_new_target's result would change
# TYPED devirtualization everywhere.
def traced_owner(irep, idx, reg, ctx)
  cls = trace_new_target(irep, idx, reg, ctx[:ivar_classes], ctx[:mand], ctx[:arg_classes],
                         owner: ctx[:owner], class_layout: ctx[:class_layout], registry: ctx[:registry],
                         known_owners: ctx[:known_owners], container_constants: ctx[:container_constants],
                         element_annotations: ctx[:element_annotations])
  resolve_owner_name(cls, ctx)
end

def resolve_owner_name(name, ctx)
  return nil unless name

  known = ctx[:known_owners]
  # Core containers are valid annotation targets without registry methods.
  return name if known.include?(name) || %w[Array Hash].include?(name)
  # Already qualified and unknown: no lexical search can help.
  return nil if name.include?('::')

  nesting = ctx[:owner].to_s.sub(/\.singleton\z/, '').split('::')
  nesting.length.downto(1) do |n|
    candidate = "#{nesting.first(n).join('::')}::#{name}"
    return candidate if known.include?(candidate)
  end
  nil
end

# ELEMENT_CLASS_SUPPORT: mandatory arity from ENTER, 0 if none.
def mand_of(ireps, label)
  enter = ireps.fetch(label).enter
  enter ? enter.enter_fields.first : 0
end

# ELEMENT_CLASS_SUPPORT: every irep reachable through `reps`; `seen` guards
# against cycles.
def nested_block_labels(ireps, label, seen = Set.new)
  out = []
  stack = [label]
  until stack.empty?
    cur = stack.pop
    irep = ireps[cur]
    next unless irep

    (irep.reps || []).each do |child|
      next if child.nil? || seen.include?(child) || !ireps.key?(child)

      seen << child
      out << child
      stack << child
    end
  end
  out
end

# ELEMENT_CLASS_SUPPORT: the one class every RETURN of this irep hands back,
# or nil. Shared by block_return_class and mono_fresh_return_class.
def legacy_irep_return_class(irep, ctx, depth)
  return nil if depth > 8

  found = nil
  irep.instructions.each_with_index do |insn, i|
    case insn.op
    when 'RETURN'
      r = insn.no_operands? ? '0' : insn.reg
      cls = element_value_class(irep, i, r, ctx, depth)
      return nil unless cls
      return nil if found && found != cls

      found = cls
    when 'RETNIL', 'RETFALSE', 'RETTRUE', 'BREAK', 'RETURN_BLK'
      # nil/false/true is not an object class, and a non-local return leaves by a
      # path not read here.
      return nil
    end
  end
  found
end

# ELEMENT_CLASS_SUPPORT: return class of a call whose RECEIVER traces to one
# exact class, looked up class-exactly. Needed for names like `:[]`, which are
# POLY program-wide (Game::Party builds `@actors` from `@roster[i]`, and
# Game::Actors#[] returns a Game::Actor or nil).
# The class-exact definition counts when it has a `-> Klass` annotation or
# provably returns a fresh `Klass.new` on every path (X.new never allocates a
# subclass). Guarded downstream like every other fact here.
def receiver_scoped_return_class(irep, i, recv_reg, name, ctx, depth)
  return nil if depth > 8

  recv_class = traced_owner(irep, i, recv_reg, ctx)
  return nil unless recv_class

  class_scoped_return_class(recv_class, name, ctx, depth)
end

# ELEMENT_CLASS_SUPPORT: what `name` returns on an exact receiver class.
def class_scoped_return_class(recv_class, name, ctx, depth)
  return nil if depth > 8

  defs = ctx[:registry][name] || []
  direct_defs = defs.select { |m| m.owner == recv_class }
  return nil if direct_defs.size > 1
  return nil if direct_defs.any? && !direct_defs.first.irep

  md = direct_defs.first if direct_defs.first&.irep
  unless md
    # Inherited lookup is useful when another class makes this name globally
    # polymorphic. Require a closed-world proof and a fully known, mixin-free
    # ancestry; otherwise Ruby's lookup order may differ from this walk.
    world = ctx[:closed_world]
    return nil unless world&.inherited_lookup_safe?(name, recv_class)

    seen = Set.new
    owner = recv_class
    loop do
      return nil unless seen.add?(owner)
      return nil if [ctx[:included_modules], ctx[:prepended_modules], ctx[:unknown_mixins]].any? do |mixins|
        next false unless mixins

        entries = mixins.respond_to?(:key?) ? mixins[owner] : (mixins.include?(owner) ? [owner] : [])
        !entries.to_a.empty?
      end

      owner = (ctx[:superclass_of] || {})[owner]
      break unless owner.is_a?(String)

      inherited_defs = defs.select { |m| m.owner == owner }
      unless inherited_defs.empty?
        return nil unless inherited_defs.size == 1 && inherited_defs.first.irep

        md = inherited_defs.first
        break
      end
    end
  end
  return nil unless md

  ann = ctx[:element_annotations][md.irep]&.ret_class
  return ann if ann

  callee = ctx[:ireps][md.irep]
  return nil unless callee

  sub = ctx.merge(owner: md.owner, ivar_classes: (ctx[:class_layout][md.owner] || {}),
                  mand: mandatory_arity(callee), arg_classes: ctx[:class_annotations][md.irep]&.args)
  irep_return_class(callee, sub, depth + 1)
end

# ELEMENT_CLASS_SUPPORT: the exact class of `self` in a method of `owner`,
# for implicit-self calls (`@members << member(db, m)`, where :member is POLY).
# Only answered when no class declares `owner` as its superclass (`subclassed`,
# from resolve_superclass_ref): a subclass instance could dispatch to an
# override. `.singleton` owners are refused: their self is the class object.
def self_receiver_class(ctx)
  owner = ctx[:owner]
  return nil if owner.nil? || owner.end_with?('.singleton')
  return nil unless ctx[:known_owners].include?(owner)
  closed_world = ctx[:closed_world]
  if closed_world
    return nil unless closed_world.exact_class?(owner)
  else
    return nil if ctx[:subclassed].include?(owner)
  end

  owner
end

def mono_fresh_return_class(name, ctx, depth)
  defs = ctx[:registry][name]
  return nil unless defs && defs.size == 1 && defs.first.irep

  d = defs.first
  irep = ctx[:ireps][d.irep]
  return nil unless irep

  sub = ctx.merge(owner: d.owner, ivar_classes: (ctx[:class_layout][d.owner] || {}),
                  mand: mandatory_arity(irep), arg_classes: ctx[:class_annotations][d.irep]&.args)
  irep_return_class(irep, sub, depth + 1)
end

# ELEMENT_CLASS_SUPPORT: class of the SCALAR value in `reg` at `idx`, from:
#   1. trace_new_target (fresh `X.new`, known ivar, argument annotation,
#      chained accessor);
#   2. a `-> Klass` return annotation (ElementAnnotations);
#   3. an indexer on an array with a known element class (`@actors[i]`), which
#      lets a self-referential reorder (`@a = order.map { |i| @a[i] }`) agree
#      instead of poisoning.
def legacy_element_value_class(irep, idx, reg, ctx, depth = 0)
  return nil if depth > 8

  direct = traced_owner(irep, idx, reg, ctx)
  return direct if direct
  irep.walk_dominating_writers(idx - 1, reg, use: idx, skip_ops: %w[BLOCK], follow_moves: true) do |insn, i, cur|
    # PRIMITIVE_ELEMENT_SUPPORT: a literal Integer/Hash/String/Symbol element.
    # Diagnostic only (`.known` strips these; see PRIMITIVE_ELEMENT_CLASSES): it
    # separates "provably Integer" from "untraceable" in the ANY/OPAQUE report.
    # LOADNIL is deliberately absent; a nil element was not a real shape here.
    case insn.op
    when 'HASH'
      next 'Hash'
    when 'STRING'
      next 'String'
    when /^LOADI/
      next 'Integer'
    when 'LOADSYM'
      next 'Symbol'
    end

    # ELEMENT_CLASS_SUPPORT: `a[i]` is an index opcode, not SEND :[] (the VM only
    # sends :[] for non-Array/Hash receivers), so element reads are recognized by
    # opcode. Receiver position differs:
    #   GETIDX  R2 (R3)      -- R[a] = R[a][R[a+1]]: receiver is R2 itself.
    #   GETIDX0 R7 R4[0]     -- R[a] = R[b][0]:      receiver is R4.
    #   AREF    R2 R6 0      -- R[a] = R[b][c]:      receiver is R6.
    if %w[GETIDX GETIDX0 AREF].include?(insn.op)
      recv = insn.op == 'GETIDX' ? cur : insn.regs[1]
      next nil unless recv

      hit = array_element_source_scan(irep, i, recv, ctx, depth + 1)
      next hit if hit && hit != ArrayElementLayout::VACUOUS
      # Not a known-element array. For GETIDX/GETIDX0 the VM's non-Array/non-Hash
      # path is a real `:[]` send, so resolve it like one (`@roster[i]` on a
      # Game::Actors). AREF is excluded: its non-Array behavior (index 0 yields the
      # receiver) is destructuring, not a `:[]` dispatch.
      next nil if insn.op == 'AREF'

      next receiver_scoped_return_class(irep, i, recv, '[]', ctx, depth)
    end
    next nil unless %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].include?(insn.op)

    name = insn.sym
    next nil unless name

    annotated = ctx[:annotated_ret_class]&.call(name)
    next annotated if annotated

    argc = insn.argc || 0
    self_recv = %w[SSEND SSEND0 SSENDB].include?(insn.op)
    indexer =
      (ARRAY_ELEMENT_INDEXERS_NEEDS_ARG.include?(name) && argc == 1) ||
      (ARRAY_ELEMENT_INDEXERS_NO_ARG.include?(name) && argc.zero?)
    # An indexer on a known-element array. Allowed to miss (not fail) so
    # `@roster[i]` on a non-Array falls through to the receiver-scoped rule.
    if indexer && !self_recv
      hit = array_element_source_scan(irep, i, cur, ctx, depth + 1)
      next hit if hit && hit != ArrayElementLayout::VACUOUS
    end

    scoped = if self_recv
               sc = self_receiver_class(ctx)
               sc && class_scoped_return_class(sc, name, ctx, depth)
             else
               receiver_scoped_return_class(irep, i, cur, name, ctx, depth)
             end
    next scoped if scoped

    # Last resort: a MONO name whose body returns one exact class on every path.
    # The SEND is the value's only writer: walking on past it (as this did, to stay
    # output-neutral) read an older, overwritten value of the register, so
    # `@a << @b[0].to_s` took @b's element class for @a.
    mono_fresh_return_class(name, ctx, depth)
  end
end

# The queries over an element table (owner => { ivar => class }, UNKNOWN for an ivar
# with no proven class), shared by ArrayElementLayout and HashElementLayout.
module ElementTableQueries
  UNKNOWN = :unknown

  # analyze's result minus UNKNOWN and empty owners. Kept separate so poisoned
  # entries can be reported (`== array-element candidates ==`).
  def known(table)
    table.each_with_object({}) do |(owner, ivars), out|
      # PRIMITIVE_ELEMENT_SUPPORT: primitive tags are dropped too; CodeGen consumers
      # only guard with mrb_obj_class against registry classes.
      known = ivars.reject { |_, c| c == UNKNOWN || PRIMITIVE_ELEMENT_CLASSES.include?(c) }
      out[owner] = known unless known.empty?
    end
  end

  # PRIMITIVE_ELEMENT_SUPPORT: diagnostic-only counterpart of `.known`, so
  # provably-primitive ivars are not listed with the OPAQUE ones.
  def primitives(table)
    table.each_with_object({}) do |(owner, ivars), out|
      prim = ivars.select { |_, c| PRIMITIVE_ELEMENT_CLASSES.include?(c) }
      out[owner] = prim unless prim.empty?
    end
  end

  def unknowns(table)
    table.flat_map { |owner, ivars| ivars.select { |_, c| c == UNKNOWN }.keys.map { |i| "#{owner}#@#{i}" } }
  end

  # ANY_OPAQUE_SUPPORT: `.unknowns` split by `poison_reason`; a filter over
  # `.unknowns` so the two cannot disagree.
  def unknowns_by_reason(table, poison_reason, reason)
    unknowns(table).select do |name|
      owner, ivar = name.split('#@', 2)
      poison_reason.dig(owner, ivar) == reason
    end
  end
end

class ArrayElementLayout
  UNKNOWN = ElementTableQueries::UNKNOWN
  extend ElementTableQueries

  # "This site provably introduces no elements"; kept apart from unreadable (see
  # array_element_source_scan's ARRAY arm).
  VACUOUS = :vacuous

  # owner -> {ivar => element class}, only for ivars ClassLayout proved always
  # hold an Array (every consumer has already proved its receiver is an Array).
  # ANY_OPAQUE_SUPPORT: when given a Hash, `poison_reason` records, at the moment
  # an ivar first becomes UNKNOWN:
  #   :any    -- two traced sites disagree: provably heterogeneous; no
  #              annotation can help.
  #   :opaque -- some site could not be traced: a candidate for an annotation.
  # nil (the default) changes nothing.
  # ELEMENT_SIGNATURE_CHECK: when given a Hash, `site_classes` collects owner -> ivar -> Set of every class a
  # traced site wrote, so an RBS `@x: Array[C]` seed can be checked against them (AnnotationContradictions.
  # ivar_element_conflicts). nil (the default) changes nothing.
  def self.analyze(ireps, registry, class_layout, class_annotations, element_annotations, superclass_of = {},
                    poison_reason: nil, closed_world: nil, included_modules: {}, prepended_modules: {},
                    unknown_mixins: {}, site_classes: nil)
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    # Registry classes, used by resolve_owner_name for bare GETCONST tokens.
    known_owners = Set.new(registry.values.flatten.map(&:owner))
    # Classes some other class declares as its superclass (see
    # self_receiver_class). :none and unrecognized expressions are dropped.
    subclassed = Set.new(superclass_of.values.select { |v| v.is_a?(String) })

    # name -> element/return class, only for MONO names: an annotation sits on one
    # irep, so it can only speak for a call no other method could receive.
    mono_ann = lambda do |field|
      lambda do |name|
        defs = registry[name]
        next nil unless defs && defs.size == 1 && defs.first.irep

        element_annotations[defs.first.irep]&.public_send(field)
      end
    end
    annotated_element = mono_ann.call(:element)
    annotated_ret_class = mono_ann.call(:ret_class)

    elements = Hash.new { |h, k| h[k] = {} }

    Fixpoint.iterate('ArrayElementLayout.analyze', Fixpoint::SWEEP_LIMIT) do
      changed = false
      methods_of.each do |owner, labels|
        array_ivars = (class_layout[owner] || {}).select { |_, c| c == 'Array' }.keys
        next if array_ivars.empty?

        labels.each do |label|
          # ELEMENT_CLASS_SUPPORT: sweep the method AND every nested block body.
          # Populating code often lives in blocks, which have no MethodDef
          # (`row.members.each { |_, m| @members << member(db, m) }`); stopping at the
          # method would miss those writers. Blocks share self, but their parameters are
          # not method arguments, so mand/arg_classes are zeroed (as in
          # block_return_class).
          sweep = [[label, mand_of(ireps, label), class_annotations[label]&.args,
                    element_annotations[label]&.arg_elements]]
          nested_block_labels(ireps, label).each { |bl| sweep << [bl, 0, nil, nil] }

          sweep.each do |(cur_label, mand, arg_classes, arg_elements)|
            irep = ireps.fetch(cur_label)
            ctx = { owner: owner, registry: registry, class_layout: class_layout, ireps: ireps,
                    class_annotations: class_annotations, element_annotations: element_annotations,
                    known_owners: known_owners, subclassed: subclassed,
                    closed_world: closed_world, superclass_of: superclass_of,
                    included_modules: included_modules, prepended_modules: prepended_modules,
                    unknown_mixins: unknown_mixins,
                    ivar_classes: (class_layout[owner] || {}), mand: mand,
                    arg_classes: arg_classes, arg_elements: arg_elements, elements: elements,
                    annotated_element: annotated_element, annotated_ret_class: annotated_ret_class }

            irep.instructions.each_with_index do |insn, idx|
              found = nil
              targets = nil
              if insn.op == 'SETIV'
                ivar = insn.ivar
                next unless array_ivars.include?(ivar)

                targets = [ivar]

                src_reg = insn.regs.first
                found = array_element_source_scan(irep, idx, src_reg, ctx)
                # NIL_TOLERANT_JOIN (element dimension): `@x = nil` says nothing about the
                # elements; see ClassLayout.analyze.
                next if found.nil? && nil_literal_write?(irep, idx, src_reg)
              # SSEND/SSENDB excluded: their receiver is self, and the `^R` register is the
              # destination.
              elsif %w[SEND SEND0 SENDB].include?(insn.op)
                name = insn.sym
                next unless name && ARRAY_ELEMENT_WRITERS.include?(name)

                recv = insn.reg
                targets = mutated_ivar_targets(irep, idx, recv) & array_ivars
                next if targets.empty?

                found = written_element_class(irep, idx, insn, recv, name, ctx)
              elsif insn.op == 'SETIDX'
                # ELEMENT_CLASS_SUPPORT: `@a[0] = x` is OP_SETIDX, not SEND :[]=.
                # "SETIDX R4 (R5) (R6)" is `R[a][R[a+1]] = R[a+2]`: receiver R4, element R6.
                recv, _i_reg, val = insn.regs
                next unless recv && val

                targets = mutated_ivar_targets(irep, idx, recv) & array_ivars
                next if targets.empty?

                found = element_value_class(irep, idx, val, ctx, 1)
              else
                next
              end

              # An element-free site (`@x = []`) must not reach the join.
              next if found == VACUOUS

              found ||= UNKNOWN
              # A mutation through a register that may hold several ivars counts for each.
              targets.each do |ivar|
                (((site_classes[owner] ||= {})[ivar] ||= Set.new) << found) if site_classes && found != UNKNOWN
                before = elements[owner][ivar]
                # Sticky join as in ClassLayout: disagreement or an unreadable site poisons
                # permanently. Never a majority vote.
                merged = if before.nil?
                           found
                         elsif before == UNKNOWN || found == UNKNOWN || before != found
                           UNKNOWN
                         else
                           before
                         end
                if merged != before
                  elements[owner][ivar] = merged
                  if merged == UNKNOWN && poison_reason
                    # First poisoning: `found == UNKNOWN` means some site was never traced
                    # (:opaque); otherwise two traced sites conflict (:any).
                    (poison_reason[owner] ||= {})[ivar] = found == UNKNOWN ? :opaque : :any
                  end
                  changed = true
                end
              end
            end
          end
        end
      end
      changed
    end

    elements
  end
end

# ELEMENT_CLASS_SUPPORT: the ivars a mutation's receiver may name: the GETIV
# `@x` the nearest write of the register (MOVEs followed) is, plus the GETIV of
# every reaching definition (BytecodeIR.reaching_definitions), so
# `(@x ||= []) << v`, whose receiver is `@x` or the fresh `[]` just stored into
# it, still counts as a write to @x. Extra targets only add checks. Empty means
# "not attributed" (the aliasing residual in this section's header), not "no
# mutation".
def legacy_mutated_ivar_targets(irep, idx, reg)
  return [] unless reg

  nearest = irep.walk_writers(idx - 1, reg, skip_ops: %w[BLOCK], follow_moves: true) do |insn|
    insn.ivar if insn.op == 'GETIV'
  end
  defs = BytecodeIR.reaching_definitions(irep, idx, reg) || []
  reached = defs.filter_map do |d|
    next nil if d.index.negative?

    insn = irep.instructions[d.index]
    insn.ivar if insn.op == 'GETIV'
  end
  ([nearest] + reached).compact.uniq
end

# ELEMENT_CLASS_SUPPORT: element class one in-place mutation writes, or nil
# (poison). See ARRAY_ELEMENT_WRITERS for the argument layouts.
def written_element_class(irep, idx, insn, recv, name, ctx)
  # A splat call ("n=*") has no fixed register list, so it poisons.
  return nil if insn.n_spec == '*'

  argc = insn.n_spec.to_i
  base = recv.to_i
  arg_regs = (1..argc).map { |k| (base + k).to_s }

  value_regs =
    case name
    when 'push', '<<', 'unshift' then arg_regs
    when 'insert' then argc >= 2 ? arg_regs.drop(1) : nil
    when '[]=' then argc == 2 ? [arg_regs.last] : nil
    when 'concat', 'replace'
      return nil unless argc == 1

      # The argument is an Array: ask the same scan about it.
      return array_element_source_scan(irep, idx, arg_regs.first, ctx, 1)
    end
  return nil if value_regs.nil? || value_regs.empty?

  classes = value_regs.map { |r| element_value_class(irep, idx, r, ctx, 1) }
  return nil if classes.any?(&:nil?) || classes.uniq.size != 1

  classes.first
end

# HASH_ELEMENT_SUPPORT: value class written by `h[]=`/`h.store` (both
# hash_set, src/hash.c, same (key, value) layout): arity must be 2; read the
# second argument.
def written_hash_element_class(irep, idx, insn, recv, ctx)
  return nil unless insn.n_spec == '2'

  val_reg = (recv.to_i + 2).to_s
  element_value_class(irep, idx, val_reg, ctx, 1)
end

# HASH_ELEMENT_SUPPORT: "every VALUE of this Hash ivar is class X"
# (HASH_ELEM_HINT). Narrower than ArrayElementLayout: values only, no
# preserving-chain rule; unmodeled writers poison. Mirrors ArrayElementLayout's
# analyze/known/unknowns, kept as its own class rather than parameterized.
class HashElementLayout
  UNKNOWN = ElementTableQueries::UNKNOWN
  extend ElementTableQueries

  VACUOUS = :vacuous

  # owner -> {ivar => value class}, only for ivars ClassLayout proved are Hashes.
  # `array_elements` (ArrayElementLayout's finished raw table, so this must run
  # after it) lets `@h[k] = @roster[i]` resolve; empty means such chains poison.
  # ANY_OPAQUE_SUPPORT: `poison_reason` as in ArrayElementLayout.analyze; ELEMENT_SIGNATURE_CHECK: `site_classes`
  # likewise.
  def self.analyze(ireps, registry, class_layout, class_annotations, element_annotations, array_elements = {},
                    superclass_of = {}, poison_reason: nil, closed_world: nil, included_modules: {},
                    prepended_modules: {}, unknown_mixins: {}, site_classes: nil)
    methods_of = Hash.new { |h, k| h[k] = [] }
    registry.each_value { |defs| defs.each { |d| methods_of[d.owner] << d.irep if d.irep } }
    known_owners = Set.new(registry.values.flatten.map(&:owner))
    subclassed = Set.new(superclass_of.values.select { |v| v.is_a?(String) })

    mono_ann = lambda do |field|
      lambda do |name|
        defs = registry[name]
        next nil unless defs && defs.size == 1 && defs.first.irep

        element_annotations[defs.first.irep]&.public_send(field)
      end
    end
    annotated_element = mono_ann.call(:element)
    annotated_ret_class = mono_ann.call(:ret_class)

    hash_elements = Hash.new { |h, k| h[k] = {} }

    Fixpoint.iterate('HashElementLayout.analyze', Fixpoint::SWEEP_LIMIT) do
      changed = false
      methods_of.each do |owner, labels|
        hash_ivars = (class_layout[owner] || {}).select { |_, c| c == 'Hash' }.keys
        next if hash_ivars.empty?

        labels.each do |label|
          # Transitive block-body sweep, as in ArrayElementLayout.analyze.
          sweep = [[label, mand_of(ireps, label), class_annotations[label]&.args]]
          nested_block_labels(ireps, label).each { |bl| sweep << [bl, 0, nil] }

          sweep.each do |(cur_label, mand, arg_classes)|
            irep = ireps.fetch(cur_label)
            ctx = { owner: owner, registry: registry, class_layout: class_layout, ireps: ireps,
                    class_annotations: class_annotations, element_annotations: element_annotations,
                    known_owners: known_owners, subclassed: subclassed,
                    closed_world: closed_world, superclass_of: superclass_of,
                    included_modules: included_modules, prepended_modules: prepended_modules,
                    unknown_mixins: unknown_mixins,
                    ivar_classes: (class_layout[owner] || {}), mand: mand,
                    arg_classes: arg_classes, elements: array_elements, hash_elements: hash_elements,
                    annotated_element: annotated_element, annotated_ret_class: annotated_ret_class }

            irep.instructions.each_with_index do |insn, idx|
              found = nil
              targets = nil
              if insn.op == 'SETIV'
                ivar = insn.ivar
                next unless hash_ivars.include?(ivar)

                targets = [ivar]

                src_reg = insn.regs.first
                found = hash_element_source_scan(irep, idx, src_reg, ctx)
                # NIL_TOLERANT_JOIN (hash-value dimension); see ArrayElementLayout.analyze.
                next if found.nil? && nil_literal_write?(irep, idx, src_reg)
              # SSEND/SSENDB excluded, as in ArrayElementLayout.analyze.
              elsif %w[SEND SEND0 SENDB].include?(insn.op)
                name = insn.sym
                next unless name && HASH_ELEMENT_WRITERS.include?(name)

                recv = insn.reg
                targets = mutated_ivar_targets(irep, idx, recv) & hash_ivars
                next if targets.empty?

                found = written_hash_element_class(irep, idx, insn, recv, ctx)
              elsif insn.op == 'SETIDX'
                # `h[k] = v` is OP_SETIDX: "SETIDX R4 (R5) (R6)", receiver R4, value R6 (the
                # key is not read).
                recv, _i_reg, val = insn.regs
                next unless recv && val

                targets = mutated_ivar_targets(irep, idx, recv) & hash_ivars
                next if targets.empty?

                found = element_value_class(irep, idx, val, ctx, 1)
              else
                next
              end

              # A value-free site (`@h = {}`) is VACUOUS (see hash_element_source_scan).
              next if found == VACUOUS

              found ||= UNKNOWN
              # A mutation through a register that may hold several ivars counts for each.
              targets.each do |ivar|
                (((site_classes[owner] ||= {})[ivar] ||= Set.new) << found) if site_classes && found != UNKNOWN
                before = hash_elements[owner][ivar]
                # Sticky join, as in ArrayElementLayout.analyze.
                merged = if before.nil?
                           found
                         elsif before == UNKNOWN || found == UNKNOWN || before != found
                           UNKNOWN
                         else
                           before
                         end
                if merged != before
                  hash_elements[owner][ivar] = merged
                  if merged == UNKNOWN && poison_reason
                    # See ArrayElementLayout.analyze's `poison_reason`.
                    (poison_reason[owner] ||= {})[ivar] = found == UNKNOWN ? :opaque : :any
                  end
                  changed = true
                end
              end
            end
          end
        end
      end
      changed
    end

    hash_elements
  end
end

# Stage switch (BytecodeIR.container_shape): the legacy walks above or the IR scans below.

def container_where(irep, idx, reg)
  refusal = {}
  BytecodeIR.for(irep).reaching_definitions(idx, reg.to_s, opaque_regs: BytecodeIR.own_upvar_written_regs(irep),
                                                          refusal: refusal)
  ["#{File.basename(irep.file.to_s)}:#{irep.instructions[idx]&.lineno}", irep.label, idx, reg, refusal[:cause]]
end

def array_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  BytecodeIR.container_shape('array_element_source_scan', -> { container_where(irep, idx, dest_reg) },
                             -> { legacy_array_element_source_scan(irep, idx, dest_reg, ctx, depth) }, -> { ir_array_element_source_scan(irep, idx, dest_reg, ctx, depth) })
end

def hash_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  BytecodeIR.container_shape('hash_element_source_scan', -> { container_where(irep, idx, dest_reg) },
                             -> { legacy_hash_element_source_scan(irep, idx, dest_reg, ctx, depth) }, -> { ir_hash_element_source_scan(irep, idx, dest_reg, ctx, depth) })
end

def adjacent_block_irep(irep, i, recv_reg, ctx)
  BytecodeIR.container_shape('adjacent_block_irep', -> { container_where(irep, i, recv_reg) },
                             -> { legacy_adjacent_block_irep(irep, i, recv_reg, ctx) }, -> { ir_adjacent_block_irep(irep, i, recv_reg, ctx) })
end

def filter_map_block_return_class(block_irep, ctx, depth, input_class)
  BytecodeIR.container_shape('filter_map_block_return_class', -> { [block_irep.label] },
                             -> { legacy_filter_map_block_return_class(block_irep, ctx, depth, input_class) }, -> { ir_filter_map_block_return_class(block_irep, ctx, depth, input_class) })
end

def block_mandatory_param_source?(irep, idx, reg)
  BytecodeIR.container_shape('block_mandatory_param_source?', -> { container_where(irep, idx, reg) },
                             -> { legacy_block_mandatory_param_source?(irep, idx, reg) }, -> { ir_block_mandatory_param_source?(irep, idx, reg) })
end

def irep_return_class(irep, ctx, depth)
  BytecodeIR.container_shape('irep_return_class', -> { [irep.label] },
                             -> { legacy_irep_return_class(irep, ctx, depth) }, -> { ir_irep_return_class(irep, ctx, depth) })
end

def element_value_class(irep, idx, reg, ctx, depth = 0)
  BytecodeIR.container_shape('element_value_class', -> { container_where(irep, idx, reg) },
                             -> { legacy_element_value_class(irep, idx, reg, ctx, depth) }, -> { ir_element_value_class(irep, idx, reg, ctx, depth) })
end

def mutated_ivar_targets(irep, idx, reg)
  BytecodeIR.container_shape('mutated_ivar_targets', -> { container_where(irep, idx, reg) },
                             -> { legacy_mutated_ivar_targets(irep, idx, reg) }, -> { ir_mutated_ivar_targets(irep, idx, reg) })
end

# ---------------------------------------------------------------------------
# The element scans on the IR (ADR 0493). Each scan joins over every producer of the register the shared reaching
# definitions find (BytecodeIR.producers), not the nearest dominating writer: all producers must classify and agree,
# and a VACUOUS one (an empty literal) agrees with any class. A refused dataflow answers nil, as a non-dominating
# writer did. A container literal counts only when nothing can mutate it before the read (Program#quiet_span?).
# ---------------------------------------------------------------------------

# The one class +classify+ gives every producer of +reg+ at +idx+, VACUOUS when each is vacuous, else nil. +entry+
# classifies the value the frame was entered with.
def join_element_producers(irep, idx, reg, entry: nil)
  sources = BytecodeIR.producers(irep, idx, reg, through_handlers: true) or return nil
  found = nil
  vacuous = false
  sources.each do |producer|
    cls = producer.entry? ? entry&.call(producer.reg) : yield(producer)
    return nil if cls.nil?

    if cls == ArrayElementLayout::VACUOUS
      vacuous = true
      next
    end
    return nil if found && found != cls

    found = cls
  end
  found || (vacuous ? ArrayElementLayout::VACUOUS : nil)
end

# The one class every element (or Hash value) of a container literal has, VACUOUS for an empty one, else nil.
def literal_element_class(irep, literal, ctx, depth)
  return ArrayElementLayout::VACUOUS if literal.empty?

  classes = literal.value_regs.map { |r| element_value_class(irep, literal.index, r, ctx, depth + 1) }
  classes.any?(&:nil?) || classes.uniq.size != 1 ? nil : classes.first
end

def ir_array_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  return nil if depth > 8

  # An `Array<Klass>` argument annotation counts only for the untouched incoming argument register; consumers
  # still guard each element.
  at_entry = lambda do |reg|
    pos = reg.to_i
    ctx[:arg_elements][pos - 1] if ctx[:arg_elements] && pos.between?(1, ctx[:mand])
  end
  program = BytecodeIR.for(irep)
  join_element_producers(irep, idx, dest_reg, entry: at_entry) do |producer|
    literal = program.container_literal(producer.index)
    if literal
      next nil unless literal.kind == :array && program.quiet_span?(producer.index, idx)

      literal_element_class(irep, literal, ctx, depth)
    else
      case producer.op
      when 'GETIV'
        ivar = producer.insn.ivar
        ivar && ivar_element_hint(ctx[:owner], ivar, ctx)
      when 'SEND', 'SEND0', 'SENDB', 'SSENDB', 'SSEND', 'SSEND0'
        send_element_class(irep, producer.index, producer.reg, producer.insn, ctx, depth)
      end
    end
  end
end

def ir_hash_element_source_scan(irep, idx, dest_reg, ctx, depth = 0)
  return nil if depth > 8

  program = BytecodeIR.for(irep)
  join_element_producers(irep, idx, dest_reg) do |producer|
    literal = program.container_literal(producer.index)
    if literal
      next nil unless literal.kind == :hash && program.quiet_span?(producer.index, idx)

      literal_element_class(irep, literal, ctx, depth)
    elsif producer.op == 'GETIV'
      ivar = producer.insn.ivar
      ivar && ivar_hash_element_hint(ctx[:owner], ivar, ctx)
    end
  end
end

def ir_adjacent_block_irep(irep, i, recv_reg, ctx)
  k = BytecodeIR.for(irep).adjacent_block_index(i, recv_reg)
  label = k && irep.reps[k.to_i]
  label && ctx[:ireps][label]
end

def ir_filter_map_block_return_class(block_irep, ctx, depth, input_class)
  return nil if depth > 8

  found = nil
  subctx = ctx.merge(arg_classes: nil, mand: 0)
  program = BytecodeIR.for(block_irep)
  program.each_with_op('RETURN', 'RETNIL', 'RETFALSE', 'RETTRUE', 'BREAK', 'RETURN_BLK') do |insn, i|
    # filter_map drops nil and false itself.
    next if %w[RETNIL RETFALSE].include?(insn.op)
    return nil unless insn.op == 'RETURN'

    reg = insn.no_operands? ? '0' : insn.reg
    sources = BytecodeIR.producers(block_irep, i, reg, through_handlers: true)
    next if sources&.all? { |p| %w[LOADNIL LOADFALSE].include?(p.op) }

    klass = element_value_class(block_irep, i, reg, subctx, depth + 1)
    klass ||= input_class if block_mandatory_param_source?(block_irep, i, reg)
    return nil unless klass && ctx[:known_owners].include?(klass)
    return nil if found && found != klass

    found = klass
  end
  found
end

def ir_block_mandatory_param_source?(irep, idx, reg)
  enter = irep.enter
  mandatory = enter ? enter.enter_fields.first : 0
  return false if mandatory.zero?

  sources = BytecodeIR.producers(irep, idx, reg, through_handlers: true)
  !sources.nil? && sources.all? { |p| p.entry? && p.reg.to_i.between?(1, mandatory) }
end

def ir_irep_return_class(irep, ctx, depth)
  return nil if depth > 8

  found = nil
  BytecodeIR.for(irep).each_with_op('RETURN', 'RETNIL', 'RETFALSE', 'RETTRUE', 'BREAK', 'RETURN_BLK') do |insn, i|
    # nil/false/true is not an object class, and a non-local return leaves by a path not read here.
    return nil unless insn.op == 'RETURN'

    cls = element_value_class(irep, i, insn.no_operands? ? '0' : insn.reg, ctx, depth)
    return nil unless cls
    return nil if found && found != cls

    found = cls
  end
  found
end

def ir_element_value_class(irep, idx, reg, ctx, depth = 0)
  return nil if depth > 8

  direct = traced_owner(irep, idx, reg, ctx)
  return direct if direct

  join_element_producers(irep, idx, reg) do |producer|
    element_producer_class(irep, producer, ctx, depth)
  end
end

# One producer's class for element_value_class.
def element_producer_class(irep, producer, ctx, depth)
  insn = producer.insn
  i = producer.index
  # PRIMITIVE_ELEMENT_SUPPORT: diagnostic only (`.known` strips these); nil is not an element shape here.
  literal = BytecodeIR.literal_class(irep, i)
  return PRIMITIVE_ELEMENT_CLASSES.include?(literal) ? literal : nil if literal

  # `a[i]` is an index opcode, not SEND :[]. GETIDX reads R[a][R[a+1]], GETIDX0 R[b][0], AREF R[b][c].
  if %w[GETIDX GETIDX0 AREF].include?(insn.op)
    recv = insn.op == 'GETIDX' ? producer.reg : insn.regs[1]
    return nil unless recv

    hit = array_element_source_scan(irep, i, recv, ctx, depth + 1)
    return hit if hit && hit != ArrayElementLayout::VACUOUS
    # AREF on a non-Array is destructuring (index 0 yields the receiver), not a `:[]` dispatch.
    return nil if insn.op == 'AREF'

    return receiver_scoped_return_class(irep, i, recv, '[]', ctx, depth)
  end
  return nil unless %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].include?(insn.op)

  name = insn.sym
  return nil unless name

  annotated = ctx[:annotated_ret_class]&.call(name)
  return annotated if annotated

  argc = insn.argc || 0
  self_recv = %w[SSEND SSEND0 SSENDB].include?(insn.op)
  indexer = (ARRAY_ELEMENT_INDEXERS_NEEDS_ARG.include?(name) && argc == 1) ||
            (ARRAY_ELEMENT_INDEXERS_NO_ARG.include?(name) && argc.zero?)
  if indexer && !self_recv
    hit = array_element_source_scan(irep, i, producer.reg, ctx, depth + 1)
    return hit if hit && hit != ArrayElementLayout::VACUOUS
  end

  scoped = if self_recv
             sc = self_receiver_class(ctx)
             sc && class_scoped_return_class(sc, name, ctx, depth)
           else
             receiver_scoped_return_class(irep, i, producer.reg, name, ctx, depth)
           end
  scoped || mono_fresh_return_class(name, ctx, depth)
end

# The ivars a mutation's receiver may name: the GETIV of every producer (through handler edges, so a write inside a
# protected range is still attributed). Empty means "not attributed", not "no mutation".
def ir_mutated_ivar_targets(irep, idx, reg)
  return [] unless reg

  sources = BytecodeIR.producers(irep, idx, reg, through_handlers: true) || []
  sources.filter_map { |p| p.insn.ivar if p.op == 'GETIV' }.uniq
end
