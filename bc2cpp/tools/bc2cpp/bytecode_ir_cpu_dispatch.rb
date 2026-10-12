# frozen_string_literal: true

require_relative 'bytecode_ir'

module BytecodeIR
  # Literal call arms are inserted before registry/dataflow construction, so
  # their effects remain visible to every compiler analysis (ADR 0422).
  module CPUDispatch
    WRAPPERS = { 'r_op' => 2, 'w_op' => 3, 'rw_op' => 3, 'a_op' => 1, 'no_op' => 3 }.freeze
    # Guesses only: an unlisted name keeps the original dispatch operation.
    DIRECT_NAMES = %w[_bcc _bcs _beq _bmi _bne _bpl _brk _bvc _bvs _clc _cld _cli _clv
                      _dex _dey _inx _iny _jam _jmp_a _jmp_i _jsr _pha _php _pla _plp
                      _rti _rts _sec _sed _sei _tax _tay _tsx _txa _txs _tya].freeze
    CORE_OWNERS = %w[Array Symbol Integer Numeric Object Kernel BasicObject].freeze

    def self.apply(ireps, registry, fixed_core: false)
      return false unless fixed_core
      return false unless core_operations_safe?(registry)

      run = registry.fetch('run', []).find { |definition| definition.owner == 'Optcarrot::CPU' && definition.irep }
      return false unless run

      source = ireps.fetch(run.irep)
      return false unless Array(source.catch_handlers).empty?

      program = Program.new(source)
      return false unless program.resolved?

      sites = source.instructions.each_index.select do |index|
        insn = source.instructions[index]
        insn.op == 'SSEND' && insn.sym == 'send' && insn.n_spec == '*' && insn.nk_spec.nil?
      end
      return false unless sites.size == 1 && canonical_splat?(source, program, sites.first)

      arms = registry.values.flatten.filter_map do |definition|
        next unless definition.owner == 'Optcarrot::CPU' && definition.irep

        arity = WRAPPERS[definition.name]
        arity = 0 if DIRECT_NAMES.include?(definition.name)
        next unless arity

        enter = ireps.fetch(definition.irep).enter
        fields = enter&.enter_fields
        next unless fields && fields == [arity, 0, 0, 0, 0, 0, 0, 0]

        [definition.name, arity]
      end.uniq.sort_by { |name, _| [WRAPPERS.key?(name) ? 0 : 1, WRAPPERS.keys.index(name) || 0, name] }
      return false if arms.empty?

      replacement = rewrite(source, sites.first, arms)
      ireps[source.label] = replacement
      registry.values.flatten.each do |definition|
        next unless WRAPPERS.key?(definition.name) && definition.owner == 'Optcarrot::CPU' && definition.irep

        wrapper = ireps.fetch(definition.irep)
        next unless Array(wrapper.catch_handlers).empty? && Program.new(wrapper).resolved?

        sends = wrapper.instructions.each_index.select do |index|
          insn = wrapper.instructions[index]
          insn.op == 'SSEND' && insn.sym == 'send' && insn.plain_fixed_argc? && [1, 3].include?(insn.n_spec.to_i)
        end
        sends.reverse_each do |index|
          count = wrapper.instructions[index].n_spec.to_i - 1
          targets = registry.values.flatten.filter_map do |target|
            next unless target.owner == 'Optcarrot::CPU' && target.irep && target.name.match?(/\A[a-z_][a-z0-9_]*\z/)
            next if count.zero? && !target.name.start_with?('_')
            next if WRAPPERS.key?(target.name)
            next unless ireps.fetch(target.irep).enter&.enter_fields == [count, 0, 0, 0, 0, 0, 0, 0]

            [target.name, count]
          end.uniq.sort
          wrapper = rewrite(wrapper, index, targets) unless targets.empty?
        end
        ireps[definition.irep] = wrapper
      end
      ireps.each_value { |irep| irep.tree = ireps }
      warn "BYTECODE_IR_CPU_DISPATCH #{arms.size} guarded literal call arms"
      true
    end

    # The generated guards use core Array#length and Symbol#==. Calls through
    # these names with Ruby replacements cannot establish the array shape.
    def self.core_operations_safe?(registry)
      %w[length == send].all? do |name|
        registry.fetch(name, []).none? do |definition|
          definition.owner != '<native>' && (name != '==' || CORE_OWNERS.include?(definition.owner))
        end
      end
    end

    # ARYCAT into a freshly nil register creates a plain Array even when an
    # upstream table entry requires splat coercion; keep that conversion intact.
    def self.canonical_splat?(source, program, site)
      return false if site < 5

      call = source.instructions.fetch(site)
      arg = call.reg.to_i + 1
      nodes = source.instructions[(site - 5)...site]
      return false unless nodes.map(&:op) == %w[LOADNIL GETCONST GETIV GETIDX ARYCAT]
      return false unless nodes.map(&:reg) == [arg, arg + 1, arg + 2, arg + 1, arg].map(&:to_s)
      return false unless nodes[1].const_name == 'DISPATCH' && nodes[2].ivar == 'opcode'

      preds = program.instruction_predecessors
      ((site - 4)..site).all? { |index| preds[index] == Set[index - 1] }
    end

    def self.rewrite(source, site, arms)
      call = source.instructions.fetch(site)
      d = call.reg.to_i
      splat = call.n_spec == '*'
      base = source.nregs
      ary, count, name, guard, rhs, recv = (base...(base + 6)).to_a
      emitted = []
      labels = {}
      add = lambda do |op, args|
        emitted << Insn.synthetic(op, args)
      end
      source.instructions.each_with_index do |insn, index|
        labels[[:original, insn.addr]] = emitted.size
        if index != site
          copy = Insn.synthetic(insn.op, insn.args)
          if insn.branch_target
            copy.typed = insn.typed.map do |operand|
              OperandSchema::Operand.new(kind: operand.kind, value: operand.kind == :addr ? [:original, operand.value] : operand.value)
            end
          end
          emitted << copy
          next
        end

        if splat
          add.call('MOVE', "R#{ary} R#{d + 1}")
          add.call('AREF', "R#{name} R#{ary} 0")
          add.call('MOVE', "R#{count} R#{ary}")
          add.call('SEND0', "R#{count} :length")
        else
          add.call('MOVE', "R#{name} R#{d + 1}")
        end
        arms.each_with_index do |(method, arity), arm|
          if splat
            add.call('MOVE', "R#{guard} R#{count}")
            add.call('LOADI8', "R#{rhs} #{arity + 1}")
            add.call('EQ', "R#{guard} (R#{rhs})")
            add_branch(emitted, 'JMPNOT', guard, [:arm, arm])
          end
          add.call('LOADSYM', "R#{guard} :#{method}")
          add.call('MOVE', "R#{rhs} R#{name}")
          add.call('EQ', "R#{guard} (R#{rhs})")
          add_branch(emitted, 'JMPNOT', guard, [:arm, arm])
          (0...arity).each do |arg|
            add.call(splat ? 'AREF' : 'MOVE', splat ? "R#{recv + arg + 1} R#{ary} #{arg + 1}" : "R#{recv + arg + 1} R#{d + arg + 2}")
          end
          add.call('SSEND', "R#{recv} :#{method} n=#{arity}")
          add.call('MOVE', "R#{d} R#{recv}")
          add_branch(emitted, 'JMP', nil, :done)
          labels[[:arm, arm]] = emitted.size
        end
        emitted << Insn.synthetic(call.op, call.args)
        labels[:done] = emitted.size
      end
      emitted.each_with_index do |insn, addr|
        insn.addr = addr
        next unless %w[JMP JMPUW JMPIF JMPNOT JMPNIL].include?(insn.op)

        insn.typed = insn.typed.map do |operand|
          OperandSchema::Operand.new(kind: operand.kind, value: operand.kind == :addr ? labels.fetch(operand.value) : operand.value)
        end
        insn.args = insn.typed.map { |operand| OperandSchema.operand_text(operand) }.join(' ')
        insn.raw = "#{insn.op} #{insn.args}"
      end
      Irep.new(**source.to_h.merge(instructions: emitted, nregs: recv + arms.map(&:last).max + 2))
    end

    def self.add_branch(emitted, op, reg, target)
      insn = Insn.synthetic(op, reg ? "R#{reg} 0" : '0')
      insn.typed = insn.typed.map do |operand|
        OperandSchema::Operand.new(kind: operand.kind, value: operand.kind == :addr ? target : operand.value)
      end
      emitted << insn
    end
  end
end
