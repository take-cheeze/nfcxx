# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'core_defs'
require_relative 'define_method_sites'
require_relative 'send_names'

# ALIAS_SITES (docs/adr/0474): `alias_method :new, :old` (or `alias new old`) written straight in a class
# or module body of the engine, with literal names, runs once while the class is defined and copies the
# method `old` names at that moment. To the registry it is a definition of `new` on that class:
#
# - when `old` is, at that point of the walk, the owner's own engine Ruby definition (and the body is one a
#   copy can stand for), `new` gets a copy of that body's irep tree (`<label>~al<i>`), compiled and
#   registered like any method. A later `def old` replaces `old` only, as in Ruby: the copy was taken from
#   the definition the walk had seen when it reached the alias;
# - otherwise (`old` is native, core Ruby, inherited, an attr_* accessor, a candidate installer) `new` is a
#   definition with no body the compiler knows (irep: nil), dispatched by name like a Struct member. The name
#   is then a known method of that class, not one installed at run time.
#
# A site that is anything else (a method body, a branch or a loop, a computed name, a singleton receiver
# other than the body's own) is not recognized and stays the dynamic installer it was. `settle` keeps the
# recognized ones only in a closed world that trusts `alias_method`, and only while no other definition of
# `new` on that owner makes the survivor depend on execution order.
module AliasSites
  Site = Struct.new(:new_name, :old_name, keyword_init: true)

  # Ops a copy cannot carry: `super` and `__method__` answer the original name in an aliased method
  # (mruby's MRB_PROC_ALIAS), a compiled copy registered under `new` would answer `new`.
  NAME_OPS = %w[SUPER ARGARY].freeze
  NAME_SENDS = %w[__method__ binding].freeze
  # `private alias_method :a, :b` hands the alias's answer (`:a`) to a visibility send, which the registry
  # does not attribute; such a site is not recognized.
  VISIBILITY_SENDS = SendNames::VISIBILITY_SENDS

  module_function

  # The alias at insns[idx] of +irep+, or nil unless it is `alias new old` or `alias_method :new, :old` with
  # an implicit receiver, literal Symbols in the argument registers, run once per execution of the body.
  def site(irep, idx)
    insn = irep.instructions[idx]
    found =
      case insn.op
      when 'ALIAS'
        old = insn.first_of(:name)&.value
        Site.new(new_name: insn.sym, old_name: old) if insn.sym && old
      when 'SSEND'
        method_site(irep, idx, insn)
      end
    found if found && DefineMethodSites.straight_line?(irep, insn)
  end

  def method_site(irep, idx, insn)
    return nil unless insn.sym == 'alias_method' && insn.plain_fixed_argc? && insn.argc == 2 && idx >= 2

    base = insn.reg.to_i
    new_insn, old_insn = irep.instructions[idx - 2, 2]
    return nil unless new_insn.op == 'LOADSYM' && new_insn.reg.to_i == base + 1 && new_insn.sym_token
    return nil unless old_insn.op == 'LOADSYM' && old_insn.reg.to_i == base + 2 && old_insn.sym_token

    following = irep.instructions[idx + 1]
    return nil if following && BytecodeIR::Ops::SEND.include?(following.op) && VISIBILITY_SENDS.include?(following.sym)

    Site.new(new_name: new_insn.sym_token, old_name: old_insn.sym_token)
  end

  # The MethodDef for `new` at a recognized site of +label+'s body, +idx+, defined on +owner+. +prior+ is
  # every definition of `old` on +owner+ the walk has registered so far; the last one is the live method.
  # +conditional+ (lazy) gives the labels of defs a branch can skip (CoreDefs.conditional_def_labels).
  def definition(site, owner, prior, ireps, label, idx, conditional, seq)
    live = prior.last
    copy = live && copyable?(live, ireps, conditional) ? copy_tree(ireps, live.irep, "~al#{seq}") : nil
    visibility = live ? live.visibility : implicit_visibility(site.old_name)
    MethodDef.new(name: site.new_name, owner: owner, irep: copy, visibility: visibility, installer: :alias,
                  site: [[label, idx]])
  end

  # mruby's own private-by-name rule (src/class.c) for a method the registry holds no body of.
  def implicit_visibility(name)
    %w[initialize initialize_copy respond_to_missing?].include?(name) ? :private : :public
  end

  def copyable?(definition, ireps, conditional)
    return false unless definition.irep && definition.kind.nil? && definition.installer.nil? && !definition.core

    body = ireps[definition.irep]
    body && !CoreDefs.core_source?(body.file) && !conditional.call.include?(definition.irep) && name_free?(body, ireps)
  end

  def name_free?(irep, ireps)
    irep.instructions.none? do |insn|
      NAME_OPS.include?(insn.op) || (BytecodeIR::Ops::SEND.include?(insn.op) && NAME_SENDS.include?(insn.sym)) ||
        (insn.op == 'LOADSYM' && NAME_SENDS.include?(insn.sym_token))
    end && irep.reps.compact.all? { |child| ireps[child] && name_free?(ireps[child], ireps) }
  end

  # Copies +label+'s irep and every irep below it into +ireps+ under "<label><suffix>", children remapped,
  # and returns the copy's label. Instructions are shared: the copy differs only in where it lives.
  def copy_tree(ireps, label, suffix)
    body = ireps.fetch(label)
    copy_label = "#{label}#{suffix}"
    return copy_label if ireps.key?(copy_label)

    reps = body.reps.map { |child| child && copy_tree(ireps, child, suffix) }
    copy = Irep.new(label: copy_label, nlocals: body.nlocals, nregs: body.nregs, pool: body.pool, syms: body.syms,
                    reps: reps, lv: body.lv, instructions: body.instructions, file: body.file,
                    catch_handlers: body.catch_handlers)
    copy.tree = ireps
    ireps[copy_label] = copy
    copy_label
  end

  # Keeps the alias definitions only in a closed world (+closed+), for `alias_method` only when +method_trusted+
  # (ClosedWorld#alias_method_trusted?: nothing renames or wraps the send; the `alias` keyword is an opcode
  # nothing can), and only while no other definition of the same name on the same owner exists.
  # Returns [kept, dropped].
  def settle(registry, ireps, closed:, method_trusted:)
    kept = dropped = 0
    registry.each_value do |defs|
      doomed = defs.select do |d|
        next false unless d.installer == :alias

        label, idx = d.site.first
        keyword = ireps.fetch(label).instructions[idx].op == 'ALIAS'
        !(closed && (keyword || method_trusted)) || defs.any? { |o| !o.equal?(d) && o.owner == d.owner }
      end
      kept += defs.count { |d| d.installer == :alias } - doomed.size
      dropped += doomed.size
      defs.reject! { |d| doomed.any? { |x| x.equal?(d) } }
      # A dropped copy is no method: its irep tree leaves the program again.
      doomed.each do |d|
        suffix = d.irep&.[](/~al\d+\z/)
        ireps.delete_if { |l, _| l.end_with?(suffix) } if suffix
      end
    end
    registry.delete_if { |_, defs| defs.empty? }
    [kept, dropped]
  end

  # True when the alias at [+label+, +idx+] is one the settled registry defines.
  def settled?(registry, label, idx)
    key = [label, idx]
    registry.each_value.any? { |defs| defs.any? { |d| d.installer == :alias && d.site&.include?(key) } }
  end
end
