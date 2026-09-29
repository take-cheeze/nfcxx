# frozen_string_literal: true

require 'set'

# CORE_DEFS (ADR 0264): what decides whether a definition from mruby's own Ruby
# may be compiled and registered over the interpreter's. The registry walks a
# class body as straight-line code; these two facts are where that is false.
module CoreDefs
  # Where mruby's own Ruby lives: core mrblib, every core gem's mrblib, and the
  # external gems that ship Ruby (compiled_gems.rb BC2CPP_EXTERNAL_MRBLIB_GEMS).
  SOURCE = %r{/3rd/(?:mruby/(?:mrblib|mrbgems/[^/]+/mrblib)|mruby-stringio/mrblib|mruby-onig-regexp/mrblib)/}

  module_function

  def core_source?(file)
    file.to_s.match?(SOURCE)
  end

  # Irep labels of the method bodies a later definition of the same owner and
  # name replaces. Definition order is the registry's walk order, which is the
  # source order mrbc was given, i.e. the order the interpreter runs the class
  # bodies. Only a core-source definition is dropped (an engine definition that
  # replaces one is the live method; two engine definitions keep the registry's
  # conservative treatment). The replaced body stays reachable only through an
  # alias, which is interpreted either way.
  def shadowed_labels(registry, ireps)
    out = Set.new
    registry.each_value do |defs|
      defs.select(&:irep).group_by(&:owner).each_value do |same|
        next if same.size < 2

        same[0...-1].each { |d| out << d.irep if core_source?(ireps.fetch(d.irep).file) }
      end
    end
    out
  end

  # Irep labels of every def instruction that a conditional forward jump can skip
  # (`def x ... end unless method_defined?(:x)`, a def in an `if` arm). The
  # registry sees the def, but at run time it may not happen, and a registration
  # would then define the method unconditionally.
  def conditional_def_labels(ireps)
    out = Set.new
    ireps.each_value do |irep|
      spans = irep.instructions.filter_map do |insn|
        next unless %w[JMPIF JMPNOT JMPNIL JMP].include?(insn.op)

        target = insn.branch_target
        [insn.addr, target] if target && target > insn.addr
      end
      next if spans.empty?

      irep.instructions.each do |insn|
        next unless %w[TDEF SDEF DEF].include?(insn.op)
        next unless spans.any? { |from, to| from < insn.addr && insn.addr < to }

        label = def_body_label(irep, insn)
        out << label if label
      end
    end
    out
  end

  # `alias new old` in a core body, where `old` is the one live definition of its owner and
  # nothing else defines `new` there: [owner, old] => [new, ...]. The interpreter's alias
  # copied the method it replaced, so a compiled `old` is registered under `new` as well
  # (Array#map, #select, Hash#each_pair, ...) and the guard's fallback is `old`'s bytecode.
  def alias_map(sites, registry, ireps, shadowed_pairs)
    defs = registry.values.flatten.group_by { |d| [d.owner, d.name] }
    sites.each_with_object(Hash.new { |h, k| h[k] = [] }) do |site, out|
      next unless core_source?(ireps.fetch(site[:irep]).file)

      old_key = [site[:owner], site[:old]]
      next if site[:new] == site[:old] || shadowed_pairs.include?(old_key)

      old_defs = defs[old_key]
      next unless old_defs && old_defs.size == 1 && old_defs.first.irep && old_defs.first.core
      next if defs.key?([site[:owner], site[:new]])
      next if sites.count { |other| other[:owner] == site[:owner] && other[:new] == site[:new] } > 1

      out[old_key] << site[:new]
    end
  end

  # mruby-enumerator runs Enumerator#next and the generators on a Fiber.
  def fiber_gem?(file)
    file.to_s.include?('/mruby-enumerator/')
  end

  # Opcodes that build or forward a block, and the ENTER block field.
  BLOCK_OPS = %w[BLKPUSH BLOCK LAMBDA SENDB SSENDB].freeze

  # Does the method body (or a block or lambda nested in it) take, build, yield to or
  # forward a block? Such a compiled frame stays on the C++ stack while the block
  # runs, and a `Fiber.yield` inside the block (the RGSS script host's
  # Graphics.update, an Enumerator#next) cannot cross it: mruby raises FiberError
  # for a yield through a C frame. The compiled entry of these "guarded" methods
  # hands the call to the bytecode whenever a Fiber runs (CORE_BLOCK_GUARD, ADR 0269).
  def touches_block?(irep, ireps)
    enter = irep.enter
    return true if enter && enter.enter_fields[6].to_i.positive?
    return true if irep.instructions.any? { |insn| BLOCK_OPS.include?(insn.op) }

    irep.reps.any? { |child| child && touches_block?(ireps.fetch(child), ireps) }
  end

  # Does the body build a lambda? It is the one opcode that can make a closure the
  # method's result; the guard covers frames that sit on the stack while a block runs,
  # not a closure that a Fiber calls after the frame is gone.
  def builds_lambda?(irep, ireps)
    return true if irep.instructions.any? { |insn| insn.op == 'LAMBDA' }

    irep.reps.any? { |child| child && builds_lambda?(ireps.fetch(child), ireps) }
  end

  # Does the body name the Fiber class? mruby-enumerator's Enumerator#next and the
  # Generator run their iteration inside a Fiber; a compiled frame in there breaks
  # the same way.
  def references_fiber?(irep, ireps)
    return true if irep.instructions.any? { |insn| %w[GETCONST GETMCNST].include?(insn.op) && insn.const_name == 'Fiber' }

    irep.reps.any? { |child| child && references_fiber?(ireps.fetch(child), ireps) }
  end

  # The child irep a TDEF/SDEF names, or, for the unfused DEF, the METHOD before it.
  def def_body_label(irep, insn)
    return irep.reps[insn.block_index] unless insn.op == 'DEF'

    idx = irep.instructions.index(insn)
    method_idx = irep.previous_real_index(idx - 1)
    method_insn = method_idx >= 0 ? irep.instructions[method_idx] : nil
    method_insn && method_insn.op == 'METHOD' ? irep.reps[method_insn.block_index] : nil
  end
end
