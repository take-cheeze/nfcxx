# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'

# DEFINE_METHOD_SITES (docs/adr/0288): `define_method(:name) { |a, b| ... }` written
# directly in a class or module body is an ordinary method definition to the registry,
# provided the block is one a `def` could have spelled. Everything else stays a dynamic
# installer that poisons its name (symbol_installed_names).
#
# DEFINE_METHOD_LOOPS (docs/adr/0469): the same send in the block of a class-body loop over a
# literal container (`%i[a b].each { |n| define_method(n) { n } }`) is one definition per name the
# loop hands it. LoopInstallers runs the loop on the literal and asks #loop_body_captures whether the
# body is method-shaped; #expand gives each expansion its own irep, with the loop variable it reads
# replaced by the Symbol that iteration bound.
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
  #
  # A `return` in the body itself (RETURN_BLK at depth 0) is the method's own: vm.c's OP_RETURN_BLK
  # returns normally from a strict proc, and a compiled method body compiles it as a C++ `return`. One in
  # a nested block stays refused.
  #
  # +captures+ (a Set, loop expansions only) admits a GETUPVAR of the frame that created the block (level
  # 0, in the body itself) and collects the register it reads; without it every upvar past the body refuses.
  def method_shaped?(body, ireps, captures: nil)
    first = body.instructions.first
    return false unless first&.op == 'ENTER'
    return false unless first.enter_fields[1..].all?(&:zero?)

    self_contained?(body, ireps, 0, captures)
  end

  # +depth+ counts blocks between +body+ and +irep+ (0 for +body+ itself). An upvar of depth
  # c names the frame c + 1 levels up, so c < depth stays inside +body+.
  def self_contained?(irep, ireps, depth, captures = nil)
    irep.instructions.each do |insn|
      next if insn.op == 'RETURN_BLK' && depth.zero?
      return false if FRAME_ESCAPES.include?(insn.op) || DEFINITION_OPS.include?(insn.op)
      return false if BytecodeIR::Ops::SEND.include?(insn.op) && FRAME_SENDS.include?(insn.sym)
      return false if insn.op == 'LOADSYM' && FRAME_SENDS.include?(insn.sym_token)
      next unless %w[GETUPVAR SETUPVAR].include?(insn.op)

      level = insn.typed.last.value
      next if level < depth
      return false unless captures && depth.zero? && level.zero? && insn.op == 'GETUPVAR'

      captures << insn.upvar_ref.first
    end
    irep.reps.compact.all? { |label| ireps[label] && self_contained?(ireps[label], ireps, depth + 1, captures) }
  end

  # DEFINE_METHOD_LOOPS: the registers of the loop block a define_method body in that loop reads, or nil
  # when the body is not one #expand can turn into a method. A body with nested blocks is refused: each
  # expansion is its own irep, and a child irep shared between expansions would be compiled under more
  # than one method.
  def loop_body_captures(body, ireps)
    return nil unless body.reps.compact.empty?

    captures = Set.new
    method_shaped?(body, ireps, captures: captures) ? captures : nil
  end

  # DEFINE_METHOD_LOOPS: the label of a copy of +label+'s irep, added to +ireps+, in which every GETUPVAR of
  # the loop block loads the Symbol +captures+ maps its register to. +seq+ numbers the expansions of one
  # body in iteration order, so the label is the same on every run.
  def expand(ireps, label, captures, seq)
    body = ireps.fetch(label)
    clone_label = "#{label}~dm#{seq}"
    insns = body.instructions.map do |insn|
      next insn unless insn.op == 'GETUPVAR'

      index, level = insn.upvar_ref
      unless level.zero? && captures.key?(index)
        raise "bc2cpp: the define_method expansion of irep #{label} reads an upvar it did not capture"
      end

      text = "R#{insn.reg} :#{captures.fetch(index)}"
      Insn.new(lineno: insn.lineno, addr: insn.addr, op: 'LOADSYM', args: text, raw: "LOADSYM #{text}")
    end
    clone = Irep.new(label: clone_label, nlocals: body.nlocals, nregs: body.nregs, pool: body.pool,
                     syms: body.syms, reps: body.reps, lv: body.lv, instructions: insns, file: body.file,
                     catch_handlers: body.catch_handlers)
    clone.tree = ireps
    ireps[clone_label] = clone
    clone_label
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
  # DEFINE_METHOD_LOOPS: the expansions of one loop send (one `site` entry) are kept or dropped together:
  # that send is settled only while the registry holds every name it installs.
  # Returns [kept, dropped].
  def settle(registry, trusted:)
    doomed = registry.each_value.flat_map do |defs|
      defs.select do |d|
        d.installer == :define_method && (!trusted || defs.any? { |other| !other.equal?(d) && other.owner == d.owner })
      end
    end
    doomed_sites = doomed.flat_map { |d| d.site || [] }.to_set
    kept = dropped = 0
    registry.each_value do |defs|
      gone = defs.select do |d|
        d.installer == :define_method && (doomed.any? { |x| x.equal?(d) } || (d.site || []).any? { |s| doomed_sites.include?(s) })
      end
      kept += defs.count { |d| d.installer == :define_method } - gone.size
      dropped += gone.size
      defs.reject! { |d| gone.any? { |x| x.equal?(d) } }
    end
    registry.delete_if { |_, defs| defs.empty? }
    [kept, dropped]
  end

  # True when a `define_method` SSENDB at +idx+ is one the settled registry defines: a class-body site whose
  # body is registered, or a loop send whose expansions are (DEFINE_METHOD_LOOPS).
  def settled?(registry, irep, idx, ireps)
    found = site(irep, idx, ireps)
    return true if found && registry.fetch(found.name, []).any? { |d| d.installer == :define_method && d.irep == found.child }

    loop_sites(registry).key?([irep.label, idx])
  end

  # DEFINE_METHOD_LOOPS: [irep label, index] of every loop send the registry defines => the names it installs.
  def loop_sites(registry)
    registry.each_value.with_object({}) do |defs, sites|
      defs.each do |d|
        next unless d.installer == :define_method

        d.site&.each { |s| (sites[s] ||= []) << d.name }
      end
    end
  end
end
