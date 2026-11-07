# frozen_string_literal: true

require 'json'
require 'set'
require 'shellwords'
require_relative 'static_dispatch_symbol_uses'

module InitializerTables
  PREFIX = 'INITIALIZER_TABLE_EVIDENCE '
  DIRECT = %r{// INITIALIZER_DIRECT (\w+):(\d+) (\S+)}
  BYTECODE_PROC = /\bmrb_(?:proc_new|closure_new)\s*\(/

  module_function

  def proven(runs)
    evidence = runs.map do |run|
      rows = run.fetch(:err).lines.grep(/^#{PREFIX}/)
      return Set.new unless rows.size == 1

      JSON.parse(rows.first.delete_prefix(PREFIX))
    end
    direct = evidence.flat_map { |row| row.fetch('direct') }.to_set
    evidence.flat_map { |row| row.fetch('candidates') }.filter_map do |candidate|
      owner = candidate.fetch('owner')
      next unless candidate.fetch('sites').all? { |label, index| direct.include?([label, index, owner]) }

      "#{owner}#initialize"
    end.to_set
  end
  # The bodies a construction site may count as direct: every compiled body that does not run while mrblib loads.
  # A body that runs at load is called before the initializer table exists, so its construction keeps the
  # initializer (the stub rewrite used this same split, see StaticDispatchRegistrations.load_phase).
  def self.direct_candidate_keys(compiled, ireps, registry)
    require_relative 'static_dispatch_registrations'
    body_of = {}
    registry.each { |name, defs| defs.each { |d| body_of[d.irep] = [d.owner, name] if d.irep } }
    parent = {}
    ireps.each_value { |irep| irep.reps.each { |c| parent[c.respond_to?(:label) ? c.label : c] = irep.label } }
    method_of = ireps.keys.to_h do |label|
      up = label
      up = parent[up] until up.nil? || body_of.key?(up)
      [label, up]
    end
    overridden = body_of.each_value.map { |owner, name| "#{owner}##{name}" }.to_set
    load_bodies, = StaticDispatchRegistrations.load_phase(ireps, body_of, method_of, overridden)
    compiled.reject { |m| load_bodies.include?(m[:label]) }.to_set { |m| "#{m[:owner]}##{m[:name]}" }
  end

end

class CodeGen
  # Enumerate lookups, not just entries past ENTER: a wrong-arity new still needs its initializer's slot.
  def initializer_table_plan
    return @initializer_table_plan if defined?(@initializer_table_plan)

    result = { candidates: [], direct: [], refused: {} }
    @initializer_table_plan = result
    refusal = constructor_pools_refusal
    if refusal
      result[:refused]['all'] = refusal
      return result
    end
    if @ireps.values.any? { |ir| BytecodeIR.for(ir).each_source.any? { |insn, _| StaticDispatchSymbolUses::INTROSPECTION_SENDS.include?(insn.sym) } }
      result[:refused]['all'] = 'method-table introspection'
      return result
    end
    if initializer_foreign_reflection?
      result[:refused]['all'] = 'unmodeled foreign Ruby reflection'
      return result
    end
    @ireps.each_value do |ir|
      next if CoreDefs.core_source?(ir.file)

      program = BytecodeIR.for(ir)
      program.each_source do |insn, index|
        next unless BytecodeIR::Ops::SEND.include?(insn.op)

        unsafe = DynamicNames.string_named_call?(ir, program, index, insn)
        unsafe ||= %w[eval instance_eval class_eval module_eval instance_exec class_exec module_exec binding
                      method public_method singleton_method instance_method public_instance_method].include?(insn.sym)
        unsafe ||= %w[to_enum enum_for].include?(insn.sym) && !DynamicNames.literal_enumerator_name?(ir, program, index, insn)
        unsafe ||= %w[inject reduce to_proc].include?(insn.sym) && !StaticDispatchSymbolUses.literal_arguments(ir, program, index, insn, Set.new)
        unsafe ||= BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op) && !StaticDispatchSymbolUses.literal_block(ir, program, index, insn, Set.new)
        if unsafe
          result[:refused]['all'] = "unbounded Ruby lookup at #{ir.file}:#{insn.lineno} (#{insn.sym})"
          return result
        end
      end
    end

    sites = Hash.new { |h, k| h[k] = [] }
    rooted = []
    unresolved = nil
    @ireps.each_value do |ir|
      BytecodeIR.for(ir).each_source do |insn, index|
        if insn.op == :SUPER && entry_arg_body_owner[ir.label]&.name == 'initialize'
          parent = @superclass_of[entry_arg_body_owner[ir.label].owner]
          target = parent.is_a?(String) ? constructor_init_target(parent) : nil
          sites[target.irep] << [ir.label, index] if target&.irep
        end
        next unless BytecodeIR::Ops::SEND.include?(insn.op) && insn.sym == 'new'

        classes = nil
        classes = constructor_named_classes(ir, index, insn) unless BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)
        classes ||= class_object_receiver_classes(ir, index, insn) unless BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)
        if classes.nil?
          root = constructor_new_root(ir, index, insn, numeric_irep_owner[ir.label])
          if root
            rooted << [root, ir.label, index]
            next
          else
            unresolved = "unresolved new at #{ir.file}:#{insn.lineno}"
            next
          end
        end
        if !CoreDefs.core_source?(ir.file) && classes.include?('Enumerator')
          argc = insn.plain_fixed_argc? ? insn.argc : nil
          writers = argc && argc >= 2 ? StaticDispatchSymbolUses.writers(ir, BytecodeIR.for(ir), index, insn.reg.to_i + 2) : []
          unresolved = "computed Enumerator method at #{ir.file}:#{insn.lineno}" if argc.nil? || !writers || writers.any? { |op, _| op != :LOADSYM }
        end
        constructor_targets(classes).each { |d| sites[d.irep] << [ir.label, index] }
      end
    end
    (@registry['initialize'] || []).each do |d|
      next unless d.irep && !d.core

      reach = constructor_reach(d)
      why = unresolved || (!reach && 'unresolved hierarchy')
      why ||= 'native or foreign class access' if reach&.any? { |klass| @closed_world.outside_spells_class?(klass) }
      why ||= 'initializer copied by alias' if reach&.any? { |klass| @constructor_aliased.include?(klass) }
      if why
        result[:refused][d.owner] = why
      else
        inherited = rooted.filter_map do |root, label, index|
          [label, index] if reach.any? { |klass| constructor_chain(klass).include?(root) }
        end
        result[:candidates] << { owner: d.owner, sites: (sites[d.irep] + inherited).uniq }
      end
    end
    result
  end

  def initializer_table_evidence(compiled, stub_keys)
    plan = initializer_table_plan
    own = compiled.select { |m| m[:name] == 'initialize' }.to_set { |m| m[:owner] }
    result = { candidates: plan[:candidates].select { |candidate| own.include?(candidate[:owner]) }, direct: [], refused: plan[:refused] }
    compiled.each do |m|
      next if m[:guard] || m[:resumable] || !stub_keys.include?("#{m[:owner]}##{m[:name]}") || m[:code].match?(InitializerTables::BYTECODE_PROC)

      m[:code].scan(InitializerTables::DIRECT) do |label, index, owner|
        result[:direct] << [label, index.to_i, owner] if label == m[:label]
      end
    end
    result
  end

  def initializer_foreign_reflection?
    require 'prism'
    sensitive = %i[send __send__ public_send eval instance_eval class_eval module_eval instance_exec class_exec module_exec
                   method instance_method to_proc define_method define_singleton_method alias_method]
    visible = @ireps.values.map(&:file).to_set
    paths = @closed_world.foreign_ruby_token_files.keys | Shellwords.split(ENV.fetch('FOREIGN_RUBY_SRCS', ''))
    paths.any? do |path|
      next false if visible.include?(path)

      gem = path[%r{/3rd/mruby/mrbgems/([^/]+)/}, 1]
      gem ||= path[%r{/3rd/(mruby-[^/]+)/}, 1]
      next false if gem && !CodeGen.build_gem_names.include?(gem)

      parsed = Prism.parse_file(path)
      next true unless parsed.success?

      queue = [parsed.value]
      unsafe = false
      until queue.empty?
        node = queue.pop
        if node.is_a?(Prism::CallNode)
          if node.name == :alias_method
            args = node.arguments&.arguments
            if args && args.size == 2 && args.all? { |arg| arg.is_a?(Prism::SymbolNode) && !%w[initialize new].include?(arg.unescaped) }
              queue.concat(node.compact_child_nodes)
              next
            end
          end
          if sensitive.include?(node.name)
            unsafe = true
            break
          end
          if node.name == :new
            receiver = node.receiver
            name = nil
            name = receiver.name.to_s if receiver.is_a?(Prism::ConstantReadNode)
            name = receiver.full_name if receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.is_a?(Prism::ConstantReadNode)
            unless name && @closed_world.stable_class_constant?(name)
              unsafe = true
              break
            end
          end
          if %i[attr_reader attr_writer attr_accessor].include?(node.name)
            args = node.arguments&.arguments
            unless args && args.all? { |arg| arg.is_a?(Prism::SymbolNode) && !%w[initialize new].include?(arg.unescaped) }
              unsafe = true
              break
            end
          end
        end
        queue.concat(node.compact_child_nodes)
      end
      unsafe
    end
  end
end
