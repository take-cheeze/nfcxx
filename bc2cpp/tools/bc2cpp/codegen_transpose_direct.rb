# frozen_string_literal: true

require_relative 'codegen_collect_direct'

# TRANSPOSE_DIRECT: the compiled core Array#transpose body starts with a call to bc2cpp_ary_transpose, which answers
# an exact Array of exact, equal-length Arrays in C and otherwise hands the receiver to the compiled body. The body
# maps every column through a block (one block call per element) and builds each column with pushes; the helper
# reads the rows' slots and fills pre-sized columns. docs/bc2cpp-transpose-direct.md has the equivalence.
#
# BC2CPP_TRANSPOSE_DIRECT=0 keeps the compiled body alone.
module TransposeDirect
  TRANSPOSE_BODY = <<~RUBY
    def transpose
      return [] if empty?
      column_count = nil
      self.each do |row|
        raise TypeError unless row.is_a?(Array)
        column_count ||= row.size
        raise IndexError, 'element size differs' unless column_count == row.size
      end
      Array.new(column_count) do |column_index|
        self.map {|row| row[column_index] }
      end
    end
  RUBY

  # The natives the body sends to its receiver and rows, read from the RArray by the helper. `row[column_index]` is
  # OP_GETIDX, which vm.c answers itself for an exact Array and an Integer index, so it binds to nothing.
  ARRAY_NATIVES = %w[empty? size].freeze

  # Returns mrb_undef_value() (nothing allocated, nothing raised) for anything but an exact Array whose rows are exact
  # Arrays of one length, so a subclass, a singleton, a non-Array row and a ragged row all reach the body, which
  # answers or raises as the interpreter does. Nothing runs between allocating a column and storing it into `result`,
  # and a fresh column is younger than any GC mark, so its slots are written without a barrier; the store into
  # `result` (pre-sized, rooted by the arena slot below `ai`) takes one.
  HELPER = <<~CPP
    static mrb_value bc2cpp_ary_transpose(mrb_state* M, mrb_value self) {
      if (!(mrb_array_p(self) && mrb_obj_ptr(self)->c == M->array_class)) return mrb_undef_value();
      mrb_int rows = ARY_LEN(mrb_ary_ptr(self));
      if (rows == 0) return mrb_ary_new(M);
      const mrb_value* rp = ARY_PTR(mrb_ary_ptr(self));
      mrb_int cols = 0;
      for (mrb_int r = 0; r < rows; ++r) {
        mrb_value row = rp[r];
        if (!(mrb_array_p(row) && mrb_obj_ptr(row)->c == M->array_class)) return mrb_undef_value();
        mrb_int len = ARY_LEN(mrb_ary_ptr(row));
        if (r == 0) cols = len;
        else if (len != cols) return mrb_undef_value();
      }
      mrb_value result = mrb_ary_new_capa(M, cols);
      int ai = mrb_gc_arena_save(M);
      for (mrb_int c = 0; c < cols; ++c) {
        mrb_value col = mrb_ary_new_capa(M, rows);
        struct RArray* ca = mrb_ary_ptr(col);
        mrb_value* cp = ARY_PTR(ca);
        for (mrb_int r = 0; r < rows; ++r) cp[r] = ARY_PTR(mrb_ary_ptr(rp[r]))[c];
        ARY_SET_LEN(ca, rows);
        struct RArray* ra = mrb_ary_ptr(result);
        ARY_PTR(ra)[c] = col;
        ARY_SET_LEN(ra, c + 1);
        mrb_field_write_barrier_value(M, (struct RBasic*)ra, col);
        mrb_gc_arena_restore(M, ai);
      }
      return result;
    }

  CPP

  NOTE = '// TRANSPOSE_DIRECT -- exact Array of exact equal-length Arrays: bc2cpp_ary_transpose, else the body below'

  def transpose_direct_enabled?
    ENV['BC2CPP_TRANSPOSE_DIRECT'] != '0'
  end

  # The first lines of the core Array#transpose body, or '' for any other method or when the proof does not hold.
  def core_body_fast_prologue(definition)
    prologue = super
    return prologue unless transpose_direct_core?(definition)

    "#{prologue}  #{NOTE}\n" \
      "  { mrb_value bc2cpp_tr = bc2cpp_ary_transpose(M, self); if (!mrb_undef_p(bc2cpp_tr)) return bc2cpp_tr; }\n"
  end

  def emit_transpose_direct_helper(compiled)
    compiled.any? { |m| m[:code].include?('bc2cpp_ary_transpose(M, self)') } ? HELPER : ''
  end

  private

  # What the body would bind to on an exact Array of exact Arrays, every name the helper skips: `empty?` and `size`
  # are Array's own natives, `is_a?` is Kernel's only definition, `each`/`map` are core Array#each and
  # Enumerable#collect as COLLECT_DIRECT proves them, and `Array.new { }` is mruby's construction (ARRAY_NEW_BLOCK).
  # The body itself must still be TRANSPOSE_BODY.
  def transpose_direct_core?(definition)
    return false unless transpose_direct_enabled? && definition.core && definition.owner == 'Array' &&
                        definition.name == 'transpose'
    return @transpose_direct_core unless @transpose_direct_core.nil?

    @transpose_direct_core = transpose_direct_proof(definition)
  end

  def transpose_direct_proof(definition)
    return false unless block_core_world && array_new_world && @native_name_sources
    return false unless core_def_text_is?(definition, TRANSPOSE_BODY, 'TRANSPOSE_DIRECT')
    return false unless ARRAY_NATIVES.all? { |name| array_native_refusal(name).nil? }
    return false unless kernel_direct_entry('is_a?', 1, false)&.owner == 'Kernel'
    return false unless array_new_world_refusal('Array').nil?

    array_map_collect_direct?
  end

  # `map` on an exact Array is the core Enumerable#collect COLLECT_DIRECT follows, asked as a send would ask it
  # (`collect(&block)` is an extended callee shape; range_map_core? does the same).
  def array_map_collect_direct?
    saved = @extended_callee_shapes
    @extended_callee_shapes = true
    chain = BlockCoreDirectFallback::RECEIVERS.fetch('Array')[:chain]
    core_body_is?(block_core_target('Array', chain, 'map', 0), 'Enumerable', 'collect') && array_each_core?
  ensure
    @extended_callee_shapes = saved
  end
end

CodeGen.prepend(TransposeDirect)
