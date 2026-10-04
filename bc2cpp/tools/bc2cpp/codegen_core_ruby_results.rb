# frozen_string_literal: true

require_relative 'numeric_flow'
require_relative 'core_defs'

# ADR 0338: specialize the selected core bytecode, never infer a result from its name.
module CoreRubyResults
  INSTALLERS = %w[alias_method define_method define_singleton_method undef_method remove_method].freeze

  def self.installed_names(ireps)
    names = Set.new
    ireps.each_value do |body|
      next unless CoreDefs.core_source?(body.file)

      body.instructions.each_with_index do |insn, index|
        next unless insn.op.include?('SEND') && INSTALLERS.include?(insn.sym)
        return nil unless insn.plain_fixed_argc? && insn.argc.positive?

        argc = %w[alias_method define_method define_singleton_method].include?(insn.sym) ? 1 : insn.argc
        (1..argc).each do |arg|
          name = body.walk_dominating_writers(index - 1, (insn.reg.to_i + arg).to_s, follow_moves: true) do |writer|
            writer.sym if writer.op == 'LOADSYM'
          end
          return nil unless name

          names << name
        end
      end
    end
    names
  end

  def self.opaque_definitions(registry, ineligible, ireps, alias_sites, aliases)
    omitted = registry.values.flatten.select { |definition| definition.core && (!definition.irep || ineligible.include?(definition.irep)) }
    out = omitted.flat_map do |definition|
      key = [definition.owner, definition.name]
      [key] + Array(aliases[key]).map { |name| [definition.owner, name] }
    end.to_set
    alias_sites.each do |site|
      body = ireps.fetch(site[:irep])
      next unless CoreDefs.core_source?(body.file)

      mapped = Array(aliases[[site[:owner], site[:old]]]).include?(site[:new])
      conditional = body.instructions.any? do |branch|
        next false unless %w[JMPIF JMPNOT JMPNIL JMP].include?(branch.op) && branch.branch_target

        body.instructions.any? do |insn|
          insn.op == 'ALIAS' && insn.sym == site[:new] && branch.addr < insn.addr && insn.addr < branch.branch_target
        end
      end
      out << [site[:owner], site[:new]] unless mapped && !conditional
    end
    out
  end

  # No pooled or growing return facts enter this analysis; caller states therefore
  # need no extra dependency edges into the core body's fixpoint.
  class Oracle
    def initialize(codegen, receiver, block_given, block_register, seen, target, call_name)
      @cg = codegen
      @receiver = receiver
      @block_given = block_given
      @block_register = block_register
      @seen = seen
      @target = target
      @call_name = call_name
    end

    def self_mask = @receiver
    # EXC supplies only truthiness here. It has no exportable result class.
    def entry_mask(_irep, reg) = reg == @block_register ? (@block_given ? NumericFlow::EXC : NumericFlow::NIL) : NumericFlow::OTHER
    def const_mask(_insn) = NumericFlow::OTHER
    def ivar_entry_mask(_irep, _name) = NumericFlow::OTHER
    def ivar_fact_mask(_irep, _name) = NumericFlow::OTHER
    def upvar_mask(_irep, _insn) = NumericFlow::OTHER
    def pool_mask(_irep, _insn) = NumericFlow::OTHER
    def op_native?(_sym) = false
    def nil_raises?(_sym) = false
    def ivar_slots(_irep) = []

    def send_mask(_irep, _index, insn, state)
      @cg.core_ruby_static_send_mask(insn, state)
    end

    def block_send_mask(irep, index, insn, state)
      @cg.core_ruby_class_result(irep, index, insn, state, seen: @seen, name_results: false) || NumericFlow::OTHER
    end

    def super_mask(_irep, _index, insn, _state)
      return NumericFlow::OTHER if @block_given || ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] == '0'
      return NumericFlow::OTHER unless @call_name == @target.name
      return NumericFlow::OTHER unless insn.plain_fixed_argc? && insn.argc.zero?

      target = @cg.core_ruby_super_result_target(@target, @receiver)
      target && @cg.core_ruby_body_result(target, @receiver, false, seen: @seen) || NumericFlow::OTHER
    end
  end
end

class CodeGen
  def core_ruby_class_result(irep, index, insn, state, seen: Set.new, name_results: true)
    return nil if ENV['BC2CPP_CORE_RUBY_RESULTS'] == '0'
    return nil unless %w[SEND0 SSEND0 SENDB SSENDB].include?(insn.op)
    return nil unless insn.sym && (%w[SEND0 SSEND0].include?(insn.op) || (insn.argc == 0 && insn.plain_fixed_argc?))

    receiver = state[insn.reg.to_i]
    receiver &= ~NumericFlow::NIL if receiver.is_a?(Integer) && receiver.anybits?(NumericFlow::NIL) && nil_unanswerable?(insn.sym)
    klass = RETURN_CORE_CLASS[receiver]
    chain = klass && BlockCoreDirectFallback::RECEIVERS.dig(klass, :chain)
    return name_results ? core_ruby_name_result(irep, index, insn) : nil unless chain
    return nil if !seen.empty? && ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] == '0'
    return nil unless @closed_world&.exact_instances_singleton_free? && @native_name_sources && captured_local_class_enabled?

    block_given = insn.op.end_with?('B')
    return nil if block_given && !core_ruby_literal_block_safe?(irep, index, insn)

    target = core_ruby_result_target(chain, insn.sym)
    return nil unless target

    core_ruby_body_result(target, receiver, block_given, seen: seen, call_name: insn.sym)
  end

  # Every answering definition must be modelled; receiver class knowledge is
  # unnecessary when every body allocates its result independently of self.
  def core_ruby_name_result(irep, index, insn)
    return nil if ENV['BC2CPP_CORE_RUBY_NAME_RESULTS'] == '0'
    return nil unless @closed_world&.exact_instances_singleton_free? && @native_name_sources && captured_local_class_enabled?
    block_given = insn.op.end_with?('B')
    return nil if block_given && !core_ruby_literal_block_safe?(irep, index, insn)

    @core_ruby_name_results ||= {}
    key = [insn.sym, block_given]
    return @core_ruby_name_results[key] if @core_ruby_name_results.key?(key)

    @core_ruby_name_results[key] = compute_core_ruby_name_result(insn.sym, block_given)
  end

  def compute_core_ruby_name_result(name, block_given)
    return nil unless @closed_world.native_paths_spelling(name).empty?
    paths = @closed_world.outside_ruby_paths_defining(name).select { |path| CoreDefs.core_source?(path) }
    return nil unless @closed_world.native_return_sources_visible?(name, paths)
    installed = symbol_installed_names
    core_installed = self.class.core_result_installed_names
    return nil unless installed && core_installed && !installed.include?(name) && !core_installed.include?(name)
    return nil if numeric_aliased_names.include?(name)
    opaque = self.class.core_result_opaque_defs
    return nil unless opaque && opaque.none? { |_owner, method| method == name }
    return nil unless (@registry[name] || []).all? { |definition| definition.core }

    definitions = block_core_index.select { |(_owner, method), _defs| method == name }.values.flatten
    definitions += (@registry[name] || [])
    definitions = definitions.uniq
    return nil if definitions.empty?

    definitions.reduce(0) do |mask, definition|
      result = core_ruby_body_result(definition, NumericFlow::OTHER, block_given, call_name: name)
      return nil unless result

      mask | result
    end
  end

  def core_ruby_body_result(target, receiver, block_given, seen: Set.new, call_name: target.name)
    return nil unless target.irep

    key = [target.irep, receiver, block_given]
    # Recursive specializations contribute no class fact until their result is known.
    return nil if seen.include?(key)

    body = @ireps.fetch(target.irep)
    fields = body.enter&.enter_fields
    return nil unless fields && fields.size == 8 && fields.values_at(0, 1, 2, 3, 4, 5, 7).all?(&:zero?)
    return nil unless core_ruby_result_exits_safe?(body)

    oracle = CoreRubyResults::Oracle.new(self, receiver, block_given, fields[6] == 1 ? 1 : nil, seen | Set[key], target, call_name)
    states = NumericFlow.states(body, oracle, fixnum_proof_ctx(body)[:upvars])
    return nil unless states

    mask = body.instructions.each_with_index.reduce(0) do |joined, (op, idx)|
      st = states[idx]
      value = if st && op.op == 'RETURN' then st[op.reg.to_i]
              elsif st && op.op == 'RETSELF' then receiver
              elsif st && op.op == 'RETNIL' then NumericFlow::NIL
              elsif st && %w[RETTRUE RETFALSE STOP].include?(op.op) then NumericFlow::OTHER
              else 0
              end
      joined | value
    end
    mask if mask.positive? && (mask & ~NumericFlow::CONTAINERS).zero?
  end

  # Use the alias-aware core index and the same lookup exclusions as core arms,
  # without probing emitted C++ while return facts are still being built.
  def core_ruby_result_target(chain, name)
    installed = symbol_installed_names
    return nil unless installed && !installed.include?(name)
    core_installed = self.class.core_result_installed_names
    return nil unless core_installed && !core_installed.include?(name)
    registry = @registry[name] || []
    return nil if registry.any? { |definition| chain.include?(definition.owner) && !definition.core }

    chain.each do |owner|
      return nil if self.class.core_result_opaque_defs&.include?([owner, name])
      return nil unless block_core_owner_plain?(owner, name)

      definitions = Array(block_core_index[[owner, name]]) + registry.select { |definition| definition.owner == owner && definition.core && definition.irep }
      return definitions.one? ? definitions.first : nil unless definitions.empty?
    end
    nil
  end

  def core_ruby_super_result_target(target, receiver)
    klass = RETURN_CORE_CLASS[receiver]
    chain = klass && BlockCoreDirectFallback::RECEIVERS.dig(klass, :chain)
    position = chain&.index(target.owner)
    return nil unless position
    # The fixed core chain cannot skip a newly included module's super method.
    return nil unless chain.each_with_index.all? do |owner, index|
      Array(@included_modules[owner]).all? { |mod| chain.drop(index + 1).include?(mod) }
    end

    core_ruby_result_target(chain.drop(position + 1), target.name)
  end

  def core_ruby_literal_block_safe?(irep, index, insn)
    irep.walk_dominating_writers(index - 1, (insn.reg.to_i + 1).to_s, follow_moves: true) do |writer|
      body = writer.op == 'BLOCK' && @ireps[irep.reps[writer.block_index]]
      body && core_ruby_result_exits_safe?(body, caller: true)
    end || false
  end

  # A nested break can replace a block-taking send's value. Callee nonlocal
  # returns also need a context-sensitive child flow, which is not modelled here.
  def core_ruby_result_exits_safe?(irep, caller: false)
    forbidden = caller ? %w[BREAK] : %w[BREAK RETURN_BLK]
    return false if irep.instructions.any? { |insn| forbidden.include?(insn.op) }

    irep.reps.all? { |label| core_ruby_result_exits_safe?(@ireps.fetch(label), caller: caller) }
  end

  def core_ruby_static_send_mask(insn, state)
    return NumericFlow::OTHER unless %w[SEND SEND0 SSEND SSEND0].include?(insn.op)
    installed = self.class.core_result_installed_names
    opaque = self.class.core_result_opaque_defs
    return NumericFlow::OTHER unless installed && !installed.include?(insn.sym) && opaque && opaque.none? { |_owner, name| name == insn.sym }

    if insn.sym == 'dup' && insn.op == 'SEND0' && native_dup_result_safe?
      return state[insn.reg.to_i]
    end
    core = native_core_class_result(insn, state)
    return core if core

    definitions = @registry[insn.sym] || []
    hidden = self.class.core_hidden_defs || []
    if NativeClassResults::FACTS.key?(insn.sym) && definitions.all? { |definition| definition.owner == '<native>' } &&
       hidden.none? { |definition| definition.name == insn.sym } && !numeric_aliased_names.include?(insn.sym)
      kinds = native_result_name_kinds(insn.sym)
      return kinds.values.reduce(0) { |mask, kind| mask | native_result_bits(kind, true) } if kinds
    end
    NumericFlow::OTHER
  end
end
