# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'irep'

module BytecodeIR
  # Exact decoded-tree matching keeps this initializer specialization closed to
  # changed bounds, arithmetic, captured variables and exception handlers.
  class TileLUT
    def self.signature(irep)
      return nil unless irep && irep.tree

      program = BytecodeIR.for(irep)
      return nil unless program.resolved? && Array(irep.catch_handlers).empty?

      children = Array(irep.reps).map { |label| signature(irep.tree.fetch(label)) }
      return nil if children.any?(&:nil?)

      instructions = program.instructions.map do |instruction|
        [instruction.op, instruction.source.typed.map { |operand| [operand.kind, operand.value] }]
      end
      [irep.nlocals, irep.nregs, irep.pool, irep.syms, instructions, children]
    end

    def self.build(candidate, reference)
      new if signature(candidate) && signature(candidate) == signature(reference)
    end

    def emit
      <<~CPP
        static mrb_value optcarrot_ir_tile_lut_build(mrb_state* M, mrb_value) {
          int arena = mrb_gc_arena_save(M);
          mrb_value tables = mrb_ary_new_capa(M, 4);
          for (mrb_int attr = 0; attr <= 12; attr += 4) {
            mrb_value table = mrb_ary_new_capa(M, 65536);
            mrb_ary_push(M, tables, table);
            mrb_gc_arena_restore(M, arena);
            mrb_gc_protect(M, tables);
            for (mrb_int pattern = 0; pattern < 65536; ++pattern) {
              mrb_value base = attr == 0 ? mrb_nil_value() : mrb_ary_ref(M, mrb_ary_ref(M, tables, 0), pattern);
              mrb_value row = mrb_ary_new_capa(M, 8);
              for (mrb_int pixel = 0; pixel < 8; ++pixel) {
                mrb_int color = attr == 0
                  ? ((pattern >> (15 - pixel)) & 1) * 2 + ((pattern >> (7 - pixel)) & 1)
                  : mrb_fixnum(mrb_ary_ref(M, base, pixel));
                mrb_ary_push(M, row, mrb_fixnum_value(color ? attr | color : 0));
              }
              mrb_ary_push(M, table, row);
              mrb_gc_arena_restore(M, arena);
              mrb_gc_protect(M, tables);
            }
          }
          mrb_gc_arena_restore(M, arena);
          return tables;
        }
      CPP
    end
  end
end
