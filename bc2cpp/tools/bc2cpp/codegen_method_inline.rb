# frozen_string_literal: true

require_relative 'bytecode_ir_inline'

class CodeGen
  def bytecode_ir_inline_code(target, dest, argv, owner_def, self_implicit, caller_irep)
    return nil unless ENV['BC2CPP_IR_INLINE'] == '1' && self_implicit && owner_def
    if @resumable
      return nil unless ENV['BC2CPP_IR_RESUMABLE_INLINE'] == '1' && @resumable.flat && caller_irep
      return nil if @fiber_yield_names.include?(target.name)
    else
      return nil unless caller_irep&.label == owner_def.irep
    end
    return nil unless target.owner == owner_def.owner && !target.core && target.name != 'initialize'
    return nil if @fiber_unsafe_methods.include?(target.irep)
    return nil unless native_arg_types(target, argv.size).compact.empty?

    stack = (@ir_inline_stack ||= [])
    return nil if stack.size >= 2 || stack.include?(target.irep) || target.irep == owner_def.irep

    irep = @ireps.fetch(target.irep)
    return nil if calls_fiber_yield?(irep)
    return nil if irep.instructions.any? { |insn| %w[SSEND SSEND0].include?(insn.op) && insn.sym == target.name }

    region = BytecodeIR::MethodInlineRegion.build(irep, argv.size)
    return nil unless region
    return nil if irep.instructions.size > @ir_inline_remaining

    return nil if @resumable && region.program.branch_edges.any? { |edge| region.program.insn_at_addr(edge.target)&.op == 'ENTER' }

    @ir_inline_remaining -= irep.instructions.size

    serial = (@ir_inline_serial = (@ir_inline_serial || 0) + 1)
    prefix = "bc2cpp_ir_inline_#{serial}_"
    exit_label = "#{prefix}exit"
    result = "#{prefix}result"
    args = argv.each_index.map { |i| "#{prefix}arg#{i}" }
    marker = @resumable ? 'BYTECODE_IR_RESUMABLE_INLINE' : 'BYTECODE_IR_INLINE'
    out = "  // #{marker} #{target.owner}##{target.name}\n  {\n"
    args.each_with_index { |arg, i| out << "  mrb_value #{arg} = #{argv[i]};\n" }
    out << "  mrb_value #{result} = mrb_nil_value();\n  {\n"
    local = String.new
    (0...irep.nregs).each { |i| local << "  mrb_value r#{i} = #{i.zero? ? 'self' : 'mrb_nil_value()'};\n" }
    args.each_with_index { |arg, i| local << "  r#{i + 1} = #{arg};\n" }
    stack << target.irep
    begin
      region.program.instructions.each do |node|
        insn = node.source
        local << "#{prefix}#{node.addr}:;\n" if region.program.branch_targets.include?(node.addr)
        code = case node.op
               when 'RETURN', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE'
                 value = { 'RETSELF' => 'self', 'RETNIL' => 'mrb_nil_value()',
                           'RETTRUE' => 'mrb_true_value()', 'RETFALSE' => 'mrb_false_value()' }[node.op] || "r#{insn.reg}"
                 "  #{result} = #{value};\n  goto #{exit_label};\n"
               when 'JMP', 'JMPIF', 'JMPNOT', 'JMPNIL'
                 destination = region.program.instruction_at(node.successors.first).addr
                 condition = { 'JMPIF' => "mrb_test(r#{insn.reg})", 'JMPNOT' => "!mrb_test(r#{insn.reg})",
                               'JMPNIL' => "mrb_nil_p(r#{insn.reg})" }[node.op]
                 "  #{condition ? "if (#{condition}) " : ''}goto #{prefix}#{destination};\n"
               else
                 compile_insn(insn, irep, target, node.index)
               end
        return nil if code.include?('#error')

        local << code
      end
    ensure
      stack.pop
    end
    local << "#{exit_label}:;\n"
    if @resumable
      # These regions cannot suspend; only the caller needs persistent registers.
      # Rename identifiers outside literals so frame assembly ignores local values.
      local = local.gsub(RESUMABLE_REGISTER_TOKENS) do |token|
        reg = Regexp.last_match[:reg]
        reg ? "#{prefix}r#{reg}" : token
      end
    end
    out << local << "  }\n  r#{dest} = #{result};\n  }\n"
  end
end
