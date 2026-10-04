# frozen_string_literal: true

require_relative 'native_class_results'

module ProfilerResults
  PATH = 'mruby-rgss/src/profiler.cxx'
  SHA = '570124ed60611c04e5d69ef862f7f42ab207b706421cb7bfce6fcd35749d806b'

  # Captures and pools could recurse into the enclosing flow being computed.
  class Oracle < CodeGen::ExactOracle
    def entry_mask(_irep, _reg) = NumericFlow::OTHER
    def const_mask(_insn) = NumericFlow::OTHER
    def ivar_entry_mask(_irep, _name) = NumericFlow::OTHER
    def ivar_fact_mask(_irep, _name) = NumericFlow::OTHER
    def upvar_mask(_irep, _insn) = NumericFlow::OTHER
  end
end

class CodeGen
  def profiler_result_body(irep, index, insn)
    return nil if ENV['BC2CPP_PROFILER_RESULTS'] == '0'
    return nil unless insn.op == 'SENDB' && PROFILER_SECTION_NAMES[insn.sym] == insn.argc && insn.plain_fixed_argc?
    return nil unless @closed_world&.exact_instances_singleton_free? && captured_local_class_enabled?
    return nil unless profiler_result_lookup_safe?(insn.sym)
    return nil unless straight_line_constant_name(irep, index, insn.reg, skip_blocks: true) == 'RGSS::Profiler'
    return nil unless resolve_class_constant_name('RGSS', numeric_owner_of(irep)&.owner) == 'RGSS'

    reg = (insn.reg.to_i + insn.argc + 1).to_s
    body = irep.walk_dominating_writers(index - 1, reg, follow_moves: true) do |writer|
      @ireps[irep.reps[writer.block_index]] if writer.op == 'BLOCK'
    end
    return nil unless body && mandatory_arity(body).zero? && pure_mandatory_arity?(body)
    return nil unless core_ruby_result_exits_safe?(body)

    body
  end

  def profiler_result_lookup_safe?(name)
    @profiler_result_lookup ||= {}
    return @profiler_result_lookup[name] if @profiler_result_lookup.key?(name)

    @profiler_result_lookup[name] = begin
      paths = (@closed_world.native_paths_spelling(name) + Array(@native_name_sources&.fetch(name, nil))).uniq
      installed = symbol_installed_names
      core_installed = self.class.core_result_installed_names
      opaque = self.class.core_result_opaque_defs
      paths.one? && NativeClassResults.source_matches?(paths.first, ProfilerResults::PATH, ProfilerResults::SHA) &&
        @closed_world.native_exact_direct_name_safe?(name, '/mruby-rgss/src/') &&
        @closed_world.native_class_constant_stable?('RGSS::Profiler', bindings: 2) &&
        @closed_world.stable_constant_identity?('RGSS') && installed && !installed.include?(name) &&
        core_installed && !core_installed.include?(name) && opaque && opaque.none? { |_owner, method| method == name } &&
        !devirt_blocked_name?(name) && !numeric_aliased_names.include?(name) &&
        (@registry[name] || []).all? { |definition| definition.owner == '<native>' && definition.irep.nil? } &&
        %w[RGSS::Profiler RGSS::Profiler.singleton].all? do |owner|
          Array(@prepended_modules[owner]).empty? && !@unknown_mixins.include?(owner)
        end
    end
  end

  # A nested callee's changing name result must invalidate every enclosing result.
  def setup_profiler_result_dependencies
    @profiler_result_parents = Hash.new { |h, k| h[k] = Set.new }
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, index|
        body = profiler_result_body(irep, index, insn)
        next unless body

        stack = [body.label]
        until stack.empty?
          label = stack.pop
          next unless @profiler_result_parents[label].add?(irep.label)

          stack.concat(@ireps.fetch(label).reps)
        end
      end
    end
  end

  def profiler_class_result(irep, index, insn)
    body = profiler_result_body(irep, index, insn)
    return nil unless body

    states = NumericFlow.states(body, ProfilerResults::Oracle.new(self), fixnum_proof_ctx(body)[:upvars])
    return nil unless states

    mask = body.instructions.each_with_index.reduce(0) do |joined, (op, idx)|
      state = states[idx]
      value = if state && op.op == 'RETURN' then state[op.reg.to_i]
              elsif state && op.op == 'RETNIL' then NumericFlow::NIL
              elsif state && %w[RETSELF RETTRUE RETFALSE STOP].include?(op.op) then NumericFlow::OTHER
              else 0
              end
      joined | value
    end
    mask if (mask & NumericFlow::OTHER).zero?
  end
end
