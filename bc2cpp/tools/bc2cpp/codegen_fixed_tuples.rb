# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'branch_hints'

# CodeGen: FIXED_TUPLE. A destructuring AREF (`a, b = v`) of an Array whose length is known reads the element
# directly: no Array test, no bounds check and no nil fallback. The length is known when the AREF's only writer is a
# fresh literal `[e0, ...]` (ARRAY) or a call whose every definition returns one (tuple_shape), with nothing but AREFs
# of it in between (fixed_tuple_writer), so no other code holds the Array or can change its length.
# A source proven an Array (exact_core_value_class) of unknown length keeps the bounds check but loses the Array test.
# A BC2CPP_CLASS_REACH_VERIFY build checks the class and length at every direct read. BC2CPP_FIXED_TUPLE=0 turns it off.
class CodeGen
  FIXED_TUPLE_HELPER = 'bc2cpp_tuple_entry'

  def fixed_tuple_enabled?
    ENV['BC2CPP_FIXED_TUPLE'] != '0'
  end

  # The AREF's text, or nil (compile it as usual). +d+ and +s+ are the shifted registers the text names.
  def fixed_tuple_aref(irep, idx, d, s, c, reg_offset)
    return nil unless fixed_tuple_enabled? && irep && idx && c

    src = unshift_proof_reg(s, reg_offset)
    return nil unless src

    n = fixed_tuple_length(irep, idx, src)
    if n
      return "  #{RegName[d]} = mrb_nil_value(); /* FIXED_TUPLE #{c} >= #{n} */\n" if c >= n

      return "  #{RegName[d]} = #{FIXED_TUPLE_HELPER}(M, #{RegName[s]}, #{c}, #{n}); /* FIXED_TUPLE */\n"
    end
    return nil unless exact_core_value_class(irep, idx, src) == 'Array'

    "  #{RegName[d]} = bc2cpp_ary_entry(M, #{RegName[s]}, #{c}); /* FIXED_TUPLE Array */\n"
  end

  # Length of the Array register +src+ holds at the AREF at +index+, or nil when it is not proven.
  def fixed_tuple_length(irep, index, src)
    j = fixed_tuple_writer(irep, index, src)
    return nil unless j

    writer = BytecodeIR.for(irep).source_at(j)
    return writer.uint_operand if writer.op == :ARRAY

    name = TUPLE_CALL_OPS.include?(writer.op) && writer.sym
    sites = name && @tuple_sites && @tuple_sites[name]
    sites&.first&.[](3)
  end

  # Index of the one write of +src+ the AREF at +index+ reads, when it writes +src+ itself, is entered only from the
  # instruction before it, and nothing but AREFs of +src+ sits between them (see tuple_aref_call).
  def fixed_tuple_writer(irep, index, src)
    program = BytecodeIR.for(irep)
    writers = BytecodeIR.reaching_writer_indices(irep, index, src)
    return nil unless writers&.size == 1

    j = writers.first
    writer = program.source_at(j)
    return nil unless writer.reg == src && (writer.op == :ARRAY || TUPLE_CALL_OPS.include?(writer.op))
    return nil unless ((j + 1)...index).all? do |k|
      insn = program.source_at(k)
      insn.op == :AREF && insn.reg != src && insn.src_and_literal&.first == src
    end

    preds = program.instruction_predecessors(include_handlers: true)
    return nil unless preds && ((j + 1)..index).all? { |k| preds[k].to_a == [k - 1] }

    j
  end

  # Emitted only when some compiled code calls it (checked on the output). +n+ is the proven length.
  def emit_fixed_tuple_helper(compiled)
    return '' unless compiled.any? { |m| m[:code].include?("#{FIXED_TUPLE_HELPER}(") }

    <<~CPP
      BC2CPP_HOT_INLINE static inline mrb_value #{FIXED_TUPLE_HELPER}(mrb_state* M, mrb_value ary, mrb_int i, mrb_int n) {
      #ifdef BC2CPP_CLASS_REACH_VERIFY
        if (!mrb_array_p(ary) || RARRAY_LEN(ary) != n) {
          fprintf(stderr, "bc2cpp: CLASS_REACH_VERIFY: FIXED_TUPLE read of a %s (length %d) proven an Array of %d\\n",
                  mrb_obj_classname(M, ary), mrb_array_p(ary) ? (int)RARRAY_LEN(ary) : -1, (int)n);
          fflush(stderr);
          abort();
        }
      #else
        (void)M;
        (void)n;
      #endif
        struct RArray* a = mrb_ary_ptr(ary);
        return ARY_EMBED_P(a) ? ARY_EMBED_PTR(a)[i] : a->as.heap.ptr[i];
      }

    CPP
  end
end
