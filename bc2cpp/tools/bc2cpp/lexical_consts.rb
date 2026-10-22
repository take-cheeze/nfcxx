# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# CodeGen: LEXICAL_CONST.
#
# GETCONST and GETMCNST used to be keyed by the bare constant name, so every definition of a name
# fed one pool: `TURN_LEFT` read in Game::Character (a frozen Hash) shared it with
# Game::MoveRoute::TURN_LEFT (17). Ruby resolves a bare reference through the lexical scope chain,
# then the ancestors of the innermost scope, then Object. Analyze names the definition each read
# reaches, and gives no key whenever the bytecode does not prove that.
#
# A scope is the qualified name of a class/module body entered with a plain `class X` / `module X`
# (its outer register is loaded with LOADNIL), so the chain of a method is exactly its lexical
# nesting. Every other body (a compact `class A::B`, `class << obj`) is :unknown, and so is anything
# below it; a name with a definition in an unknown scope is never resolved.
module LexicalConsts
  TOP = ''
  EMPTY = Set.new.freeze
  # A string evaluated with one of these changes the cref of its code, which is not modelled.
  STRING_EVAL_SENDS = %w[class_eval module_eval instance_eval].freeze
  # The ops collect_definitions reads besides the sends: the class bodies and the constant writes.
  DEFINITION_OPS = %w[CLASS MODULE SETCONST SETMCNST].freeze

  # read_keys: GETCONST/GETMCNST insn (by identity) -> qualified name of the definition it reads.
  # site_keys: SETCONST insn (by identity) -> qualified name it defines, nil when its scope is unknown.
  # An insn with no entry is unresolved; the caller treats it as OTHER.
  Result = Struct.new(:read_keys, :site_keys, keyword_init: true)

  module_function

  def analyze(ireps, static:)
    empty = Result.new(read_keys: {}.compare_by_identity, site_keys: {}.compare_by_identity)
    return empty unless static
    return empty if ireps.each_value.any? { |irep| eval_send?(irep) }

    Model.new(ireps).results
  end

  # Only a string argument evaluates code. A block runs in the lexical cref (mruby: `Foo.class_eval { BAR }`
  # reads the lexical BAR), so the block form of these sends keeps the model. An unknown count may carry a string.
  def eval_send?(irep)
    BytecodeIR.for(irep).instructions_with_op(*BytecodeIR::Ops::SEND_FAMILY).any? do |insn|
      STRING_EVAL_SENDS.include?(insn.sym) && string_argument?(insn)
    end
  end

  def string_argument?(insn)
    return false if insn.op.end_with?('0') # SEND0 / SSEND0 carry no arguments

    insn.n_spec != '0' || !insn.nk_spec.nil?
  end

  def qualify(scope, name)
    scope == TOP ? name : "#{scope}::#{name}"
  end

  # The scopes a lexical lookup from +scope+ visits, innermost first, ending at the top level.
  def chain_of(scope)
    return [TOP] if scope == TOP

    parts = scope.split('::')
    (1..parts.size).map { |n| parts.first(n).join('::') }.reverse << TOP
  end

  class Model
    def initialize(ireps)
      @ireps = ireps
      @scope = {}
      @defs = Hash.new { |h, k| h[k] = Set.new }
      @class_defs = Hash.new { |h, k| h[k] = Set.new }
      @value_defs = Hash.new { |h, k| h[k] = Set.new }
      @unknown = Set.new
      @explicit_super = Set.new
      @mixins = Hash.new { |h, k| h[k] = [] }
      @mixin_unknown = false
      @scoped_unknown = false
      @mixin_sites = []
      assign_scopes
      collect_definitions
      resolve_mixins
    end

    def results
      read_keys = {}.compare_by_identity
      site_keys = {}.compare_by_identity
      @ireps.each do |label, irep|
        scope = @scope.fetch(label, :unknown)
        BytecodeIR.for(irep).each_with_op('SETCONST', 'GETCONST', 'GETMCNST') do |insn, idx|
          case insn.op
          when 'SETCONST'
            site_keys[insn] = scope == :unknown ? nil : LexicalConsts.qualify(scope, insn.const_name)
          when 'GETCONST'
            key = lexical_key(scope, insn.const_name)
            read_keys[insn] = key if key
          when 'GETMCNST'
            key = scoped_key(class_path(irep, idx, insn.paren_reg, scope), insn.mcnst_name)
            read_keys[insn] = key if key
          end
        end
      end
      Result.new(read_keys: read_keys, site_keys: site_keys)
    end

    private

    # Each body's scope: a plain CLASS/MODULE nests inside its parent, anything else is unknown. A
    # nested irep (method, block) inherits the scope of the body it sits in.
    def assign_scopes
      children = Set.new
      @ireps.each_value { |irep| irep.reps.each { |label| children << label } }
      stack = (@ireps.keys - children.to_a).map { |label| [label, LexicalConsts::TOP] }
      until stack.empty?
        label, parent = stack.pop
        next if @scope.key?(label)

        @scope[label] = parent
        irep = @ireps.fetch(label)
        body = {}
        BytecodeIR.class_bodies(irep, 'CLASS', 'MODULE', 'SCLASS').each do |idx, child|
          body[child] = body_scope(irep, idx, irep.instructions[idx], parent)
        end
        irep.reps.each { |child| stack << [child, body.fetch(child, parent)] }
      end
    end

    def body_scope(irep, idx, insn, parent)
      return :unknown if insn.op == 'SCLASS' || parent == :unknown
      return :unknown unless all_writers?(irep, idx, reg_number(insn)) { |_j, w| w.op == 'LOADNIL' }

      LexicalConsts.qualify(parent, insn.sym)
    end

    def collect_definitions
      @ireps.each do |label, irep|
        scope = @scope.fetch(label, :unknown)
        BytecodeIR.for(irep).each_with_op(*DEFINITION_OPS, *BytecodeIR::Ops::SEND_FAMILY) do |insn, idx|
          case insn.op
          when 'CLASS', 'MODULE'
            define(scope, insn.sym, klass: true)
            next unless insn.op == 'CLASS' && scope != :unknown

            # The superclass register is the one after the class's own; only a LOADNIL on every path there is "none"
            # (`class X < (c ? B : nil)` joins a class into it).
            super_reg = (reg_number(insn).to_i + 1).to_s
            unless all_writers?(irep, idx, super_reg) { |_j, w| w.op == 'LOADNIL' }
              @explicit_super << LexicalConsts.qualify(scope, insn.sym)
            end
          when 'SETCONST'
            define(scope, insn.const_name, value: true)
          when 'SETMCNST'
            @unknown << insn.mcnst_name
          else
            # A private constant raises for a scoped `K::NAME` read from outside, which scoped_key does not model.
            @scoped_unknown = true if insn.sym == 'private_constant'
            collect_mixin(scope, irep, idx, insn) if %w[include prepend].include?(insn.sym)
          end
        end
      end
    end

    def define(scope, name, klass: false, value: false)
      return @unknown << name if scope == :unknown

      @defs[name] << scope
      @class_defs[name] << scope if klass
      @value_defs[name] << scope if value
    end

    # `self.include(X)` in a body adds X to that body's ancestors. The argument must be a bare constant
    # with one world definition that the body's lexical chain reaches (or none, a core module);
    # anything else makes every ancestor set unknown.
    def collect_mixin(scope, irep, idx, insn)
      recv = reg_number(insn)
      # SSEND is a send to self, so its receiver register is not read; a SEND needs every writer to be LOADSELF.
      on_self = insn.op.start_with?('SSEND') || (recv && all_writers?(irep, idx, recv) { |_j, w| w.op == 'LOADSELF' })
      # One constant on every arm: `include(c ? A : B)` names no single module.
      names = recv && BytecodeIR.writers_reaching(irep, idx, (recv.to_i + 1).to_s)&.map do |_j, w|
        w.op == 'GETCONST' ? w.const_name : nil
      end
      name = names.first if names && names.uniq.size == 1
      well_formed = scope != :unknown && on_self && insn.argc == 1 && name
      if well_formed
        @mixin_sites << [scope, name]
      else
        @mixin_unknown = true
      end
    end

    def resolve_mixins
      @mixin_sites.each do |scope, name|
        hits = @defs.fetch(name, EMPTY)
        if @unknown.include?(name) || hits.size > 1 || (hits.size == 1 && !LexicalConsts.chain_of(scope).include?(hits.first))
          @mixin_unknown = true
        elsif hits.empty?
          @mixins[scope] << name
        else
          @mixins[scope] << LexicalConsts.qualify(hits.first, name)
        end
      end
    end

    # The scopes whose constants a lookup from +scope+ reaches besides its lexical chain: its own
    # ancestors, Object and what Object includes. Nil when an explicit superclass or a mixin is unmodelled.
    def ancestors_of(scope)
      return nil if @mixin_unknown || scope == :unknown

      result = Set.new
      work = [scope]
      until work.empty?
        cls = work.shift
        next if result.include?(cls)
        return nil if @explicit_super.include?(cls)

        result << cls
        work.concat(@mixins.fetch(cls, []))
        work << LexicalConsts::TOP
      end
      result
    end

    # The sole-definition test: a name defined in one scope is that definition; with more, every
    # definition the lookup could reach must be +hit+ itself, and the reach must be modelled.
    def sole_definition?(name, hit, reach)
      defs = @defs.fetch(name, EMPTY)
      return true if defs.size == 1 && defs.include?(hit)
      return false if reach.nil?

      (defs & reach) == Set[hit]
    end

    # The bare-name read from +scope+: the first chain scope defining +name+, when sole_definition? holds.
    def lexical_hit(scope, name)
      return nil if scope == :unknown || @unknown.include?(name)

      chain = LexicalConsts.chain_of(scope)
      hit = chain.find { |s| @defs.fetch(name, EMPTY).include?(s) }
      return nil unless hit

      reach = ancestors_of(scope)
      reach = (reach | chain) if reach
      hit if sole_definition?(name, hit, reach)
    end

    def lexical_key(scope, name)
      hit = lexical_hit(scope, name)
      hit && LexicalConsts.qualify(hit, name)
    end

    # `base::name` reads base's own definition (or refuses) with the same sole-definition test.
    def scoped_key(base, name)
      return nil if base.nil? || @scoped_unknown || @unknown.include?(name) || !@defs.fetch(name, EMPTY).include?(base)
      return nil unless sole_definition?(name, base, ancestors_of(base))

      LexicalConsts.qualify(base, name)
    end

    # The class/module scope a receiver register holds: a lexical CONST naming a class, or a
    # `Class::CONST` path of one. Nil for any other receiver. Every writer that reaches the register must name the
    # same scope: `(c ? A : B)::X` names A on one arm and B on the other.
    def class_path(irep, idx, reg, scope, depth = 0)
      return nil if reg.nil? || depth > 8

      writers = BytecodeIR.writers_reaching(irep, idx, reg.to_s)
      return nil unless writers

      keys = writers.map { |j, w| class_path_of(irep, j, w, scope, depth) }
      keys.first if keys.first && keys.uniq.size == 1
    end

    def class_path_of(irep, j, w, scope, depth)
      case w.op
      when 'GETCONST'
        hit = lexical_hit(scope, w.const_name)
        class_definition?(w.const_name, hit) ? LexicalConsts.qualify(hit, w.const_name) : nil
      when 'GETMCNST'
        base = class_path(irep, j, w.paren_reg, scope, depth + 1)
        key = scoped_key(base, w.mcnst_name)
        key if key && class_definition?(w.mcnst_name, base)
      end
    end

    # Whether every writer of +reg+ that reaches the read at +idx+ passes the block (BytecodeIR.all_writers_reaching?).
    def all_writers?(irep, idx, reg, &test)
      reg && BytecodeIR.all_writers_reaching?(irep, idx, reg, &test)
    end

    def class_definition?(name, scope)
      return false if scope.nil? || @unknown.include?(name)

      @class_defs.fetch(name, EMPTY).include?(scope) && !@value_defs.fetch(name, EMPTY).include?(scope)
    end

    def reg_number(insn)
      insn.reg_token&.[](/\d+/)
    end
  end
end
