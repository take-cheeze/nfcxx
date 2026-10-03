# frozen_string_literal: true

# DEFINE_METHOD_SITES (docs/adr/0288): `define_method(:name) { |a, b| ... }` written
# directly in a class or module body is an ordinary method definition to the registry,
# provided the block is one a `def` could have spelled. Everything else stays a dynamic
# installer that poisons its name (symbol_installed_names).
#
# Only the shape is decided here; ClosedWorld#define_method_sites_trusted? decides whether
# the program may rename `define_method` itself, and build_registry whether the owner's
# (owner, name) pair is unambiguous.
module DefineMethodSites
  Site = Struct.new(:name, :child, keyword_init: true)

  # Ops that reach the frame that created the block (its locals, its block, its `return`).
  # Nested blocks may still use the upvars of the blocks below `child`, see #self_contained?.
  FRAME_ESCAPES = %w[RETURN_BLK BREAK BLKPUSH SUPER ARGARY].freeze
  # Ops that depend on the lexical class the body is compiled under rather than on `self`.
  DEFINITION_OPS = %w[TCLASS TDEF SDEF DEF METHOD CLASS MODULE SCLASS EXEC ALIAS UNDEF].freeze
  # Sends that read the frame of the method they run in; a proc method has its own.
  FRAME_SENDS = %w[block_given? iterator? binding local_variables __method__ caller caller_locations].freeze
  SEND_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze

  module_function

  # Site for the `define_method` SSENDB at insns[idx] of +irep+, or nil unless it has the
  # exact shape mrbc emits for `define_method(:sym) { ... }` in a body.
  def site(irep, idx, ireps)
    insn = irep.instructions[idx]
    return nil unless insn.op == 'SSENDB' && insn.sym == 'define_method' && insn.plain_fixed_argc? && insn.argc == 1
    return nil if idx < 2

    name_insn = irep.instructions[idx - 2]
    block_insn = irep.instructions[idx - 1]
    base = insn.reg.to_i
    return nil unless name_insn.op == 'LOADSYM' && name_insn.reg.to_i == base + 1 && name_insn.sym_token
    return nil unless block_insn.op == 'BLOCK' && block_insn.reg.to_i == base + 2 && block_insn.block_index

    child = irep.reps[block_insn.block_index]
    return nil unless child && ireps[child] && method_shaped?(ireps[child], ireps) && straight_line?(irep, insn)

    Site.new(name: name_insn.sym_token, child: child)
  end

  # The block behaves as the body of a `def` with the same parameters: required
  # parameters only (Module#define_method makes the proc strict, so ENTER's count is
  # enforced exactly as for a `def`) and nothing reaching outside its own frame.
  def method_shaped?(body, ireps)
    first = body.instructions.first
    return false unless first&.op == 'ENTER'
    return false unless first.enter_fields[1..].all?(&:zero?)

    self_contained?(body, ireps, 0)
  end

  # +depth+ counts blocks between +body+ and +irep+ (0 for +body+ itself). An upvar of depth
  # c names the frame c + 1 levels up, so c < depth stays inside +body+.
  def self_contained?(irep, ireps, depth)
    irep.instructions.each do |insn|
      return false if FRAME_ESCAPES.include?(insn.op) || DEFINITION_OPS.include?(insn.op)
      return false if SEND_OPS.include?(insn.op) && FRAME_SENDS.include?(insn.sym)
      return false if insn.op == 'LOADSYM' && FRAME_SENDS.include?(insn.sym_token)
      next unless %w[GETUPVAR SETUPVAR].include?(insn.op)

      return false unless insn.typed.last.value < depth
    end
    irep.reps.compact.all? { |label| ireps[label] && self_contained?(ireps[label], ireps, depth + 1) }
  end

  # The define_method send runs exactly once per execution of the body: no jump or handler
  # range spans it, so it is not conditional, repeated or skipped by a rescue.
  def straight_line?(irep, site_insn)
    at = site_insn.addr
    irep.instructions.none? do |insn|
      target = insn.branch_target
      target && ([insn.addr, target].min..[insn.addr, target].max).cover?(at)
    end && (irep.catch_handlers || []).none? { |h| (h.begin_addr...h.end_addr).cover?(at) || h.target == at }
  end

  # Keeps the registry's define_method candidates only when the program trusts them and each
  # (owner, name) has that one definition: a second body (a `def`, another define_method, a
  # module_function copy) makes the survivor depend on execution order, which the registry
  # does not model. Dropped candidates stay installers for symbol_installed_names.
  # Returns [kept, dropped].
  def settle(registry, trusted:)
    kept = dropped = 0
    registry.each_value do |defs|
      doomed = defs.select do |d|
        d.installer && (!trusted || defs.any? { |other| !other.equal?(d) && other.owner == d.owner })
      end
      kept += defs.count(&:installer) - doomed.size
      dropped += doomed.size
      defs.reject! { |d| doomed.any? { |x| x.equal?(d) } }
    end
    registry.delete_if { |_, defs| defs.empty? }
    [kept, dropped]
  end

  # True when a `define_method` SSENDB at +idx+ is one the settled registry defines.
  def settled?(registry, irep, idx, ireps)
    found = site(irep, idx, ireps)
    found && registry.fetch(found.name, []).any? { |d| d.installer && d.irep == found.child }
  end
end
