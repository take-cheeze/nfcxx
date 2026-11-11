# frozen_string_literal: true

require_relative 'bytecode_ir'

# CLASS_OBJECT_NEW: `klass.new(...)` whose receiver is a parameter every caller passes class constants for
# (CLASS_OBJECT_ARGS, class_object_receiver_classes). The receiver is exactly one of those classes, so the site is one
# exact-class arm per class, each the allocation Class#new makes plus the initialize that class resolves to as a direct
# call (self_new_initialize_call), and a closed-world guard violation for any other receiver. A class whose initialize
# is not one direct call leaves the site to the by-name send.
module ClassObjectNew
  def compile_send(insn, kwargs)
    # The name test first: splatting the options into keywords copies them, and most sends are not `new`.
    (insn.sym == 'new' && class_object_new(insn, **kwargs)) || super
  end

  private

  def class_object_new(insn, self_implicit:, irep: nil, idx: nil, call_receiver: nil, call_arguments: nil, trace_idx: nil,
                       trace_reg_offset: 0, **)
    return nil unless @closed_world && @closed_world.global_refusal.nil? && !@call_block_expr && !self_implicit
    # An inlined loop body carries its site in trace_idx/trace_reg_offset (codegen_send.rb).
    site_idx = idx || trace_idx
    return nil unless irep && site_idx && call_receiver.nil? && call_arguments.nil? && !insn.positional_splat? && !insn.keyword_arguments?
    return nil unless BytecodeIR::Ops::SEND.include?(insn.op)

    n = insn.argc.to_i
    return nil if n > CodeGen::FUNCALL_ARGC_MAX
    # The receiver register as the original SEND names it.
    proof = Struct.new(:reg).new(unshift_proof_reg(insn.reg, trace_reg_offset))
    return nil unless proof.reg

    # A constant receiver is the constant paths' (codegen_send.rb).
    return nil unless constructor_named_classes(irep, site_idx, proof).nil?

    classes = class_object_receiver_classes(irep, site_idx, proof)
    return nil if classes.nil? || classes.empty?
    return nil unless @closed_world.standard_constructor_lookup?

    d = insn.reg
    argv = (1..n).map { |k| "r#{d.to_i + k}" }
    arms = classes.map do |k|
      return nil unless exact_constructor_chain?(k)

      call = self_new_initialize_call(k, argv)
      return nil unless call

      [k, call, self_new_initialize_def(k).owner]
    end

    @direct_alloc_used = true
    recv = "r#{d}"
    args = argv.empty? ? '' : "    mrb_value bc2cpp_cna[] = { #{argv.join(', ')} };\n"
    branches = arms.map do |k, call, _|
      "if (bc2cpp_cnc == #{owner_class_ptr_expr(k)}) {\n" \
        "      bc2cpp_cn = bc2cpp_direct_alloc(M, bc2cpp_cnc);\n      #{format(call, obj: 'bc2cpp_cn')}\n    } else "
    end.join
    marks = arms.map { |_, _, owner| "  // INITIALIZER_DIRECT #{irep.label}:#{site_idx} #{owner}\n" }.uniq.join
    violation = guard_violation_line(d, recv, 'new', argv, 'CLASS_ARGUMENT').sub(/\Ar#{d} = /, '').chomp
    "#{initializer_site_marker(irep, site_idx)}" \
      "  // CLASS_OBJECT_NEW :new -- the receiver is one of #{classes.join(', ')} (every caller passes one of them)\n" \
      "#{marks}" \
      "  {\n" \
      "    struct RClass* bc2cpp_cnc = mrb_class_ptr(#{recv});\n" \
      "    mrb_value bc2cpp_cn;\n" \
      "#{args}" \
      "    #{branches}{\n" \
      "      bc2cpp_cn = #{violation}\n" \
      "    }\n" \
      "    r#{d} = bc2cpp_cn;\n" \
      "  }\n"
  end
end

CodeGen.prepend(ClassObjectNew)
