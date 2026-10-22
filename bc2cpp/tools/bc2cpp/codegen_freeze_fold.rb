# frozen_string_literal: true

require 'shellwords'
require_relative 'numeric_flow'

# FREEZE_FOLD (ADR 0536 consumer): `nil?`, `is_a?`, `kind_of?`, `instance_of?` and `frozen?` whose answer the NumericFlow
# class set of the receiver proves are emitted as their bool, with no dispatch. BC2CPP_FREEZE_FOLD=1 turns it on; the
# default is off, so the output is unchanged.
#
# A class test answers the same on every path when every bit of the mask passes it (or every bit fails it); the
# verdicts are the ones class narrowing already uses, and OTHER passes neither, so an unknown receiver keeps its send.
# `frozen?` is true only for a mask of nil and frozen table literals (and Symbols, which are immediates): an unfrozen
# Array or Hash of the same class can share the ARR/HSH bit, so no false answer is claimed.
class CodeGen
  FREEZE_FOLD_CLASS_TESTS = %w[nil? is_a? kind_of? instance_of?].freeze
  # mruby's Kernel#frozen? (kernel.c mrb_obj_frozen): immediates and frozen objects answer true.
  KERNEL_FROZEN_BODY = /mrb_obj_frozen\(mrb_state \*mrb, mrb_value self\)\s*\{\s*return mrb_bool_value\(mrb_immediate_p\(self\) \|\| mrb_frozen_p\(mrb_basic_ptr\(self\)\)\);/m
  KERNEL_FROZEN_OUTSIDE = /MRB_SYM_Q\(frozen\)|"frozen\?"|\bfrozen\?|mrb_obj_frozen\b/

  def freeze_fold_enabled?
    ENV['BC2CPP_FREEZE_FOLD'] == '1'
  end

  # The C line that replaces the send of +name+ on the receiver register +reg+ (the SEND's own register, +dest+ the
  # register it writes), or nil when the flow does not decide it. +index+ is the send's instruction index.
  def freeze_fold_code(name, dest, irep, index, insn, reg, owner_def)
    return nil unless freeze_fold_enabled? && irep && index && reg && owner_def
    return nil unless insn.reg.to_s == reg.to_s && (FREEZE_FOLD_CLASS_TESTS.include?(name) || name == 'frozen?')

    mask = numeric_raw_mask(irep, index, reg.to_s, owner_def)
    return nil unless mask.is_a?(Integer) && mask.positive?

    answer = if name == 'frozen?'
               freeze_fold_frozen(mask)
             else
               freeze_fold_class_test(irep, index, insn, mask)
             end
    return nil if answer.nil?

    "  // FREEZE_FOLD :#{name} -- receiver class set #{numeric_mask_name(mask)} decides the answer on every path\n" \
      "  r#{dest} = #{answer ? 'mrb_true_value()' : 'mrb_false_value()'};\n"
  end

  private

  # true or false when every bit of +mask+ passes (or fails) the test, else nil. Frozen table shapes carry an Array or
  # Hash class the core partition does not name, so their verdict is taken per shape.
  def freeze_fold_class_test(irep, index, insn, mask)
    found = class_test_for(irep, index, insn)
    return nil unless found && found[0].zero?

    test = found[1]
    pass, fail = class_test_partition(test)
    table_pass = 0
    table_fail = 0
    @frozen_tables&.shapes&.each do |shape|
      verdict = class_test_verdict(test, shape.array? ? 'Array' : 'Hash')
      if verdict then table_pass |= shape.bit
      elsif verdict == false then table_fail |= shape.bit
      end
    end
    return true if (mask & ~(pass | table_pass)).zero?
    return false if (mask & ~(fail | table_fail)).zero?

    nil
  end

  def freeze_fold_frozen(mask)
    return nil unless freeze_fold_frozen_safe?

    # Every bit here is an immediate or a frozen literal shape; INT is not (a bignum is a heap object, unfrozen).
    allowed = NumericFlow::NIL | (@frozen_tables ? @frozen_tables.mask : 0) | (frozen_symbol_bit || 0)
    (mask & ~allowed).zero? ? true : nil
  end

  def freeze_fold_frozen_safe?
    return @freeze_fold_frozen_safe if defined?(@freeze_fold_frozen_safe)

    @freeze_fold_frozen_safe = compute_freeze_fold_frozen_safe
  end

  # Kernel#frozen? is mruby's own on every instance: no Ruby definition, installer or devirtualization block, the
  # kernel.c body as read, and no other native source that spells it.
  def compute_freeze_fold_frozen_safe
    world = block_core_world
    installed = symbol_installed_names
    return false unless world && @closed_world&.exact_instances_singleton_free? && @native_name_sources && installed
    return false unless world.instance_native_dispatch_safe?('frozen?') && !installed.include?('frozen?')
    return false if devirt_blocked_name?('frozen?')

    kernel = File.expand_path('../../3rd/mruby/src/kernel.c', __dir__)
    return false unless File.file?(kernel) && File.binread(kernel).match?(KERNEL_FROZEN_BODY)

    outside = (Shellwords.split(ENV.fetch('NATIVE_SRCS', '')) + world.native_paths_spelling('frozen?')).uniq
    outside.reject { |path| File.expand_path(path) == kernel }.none? { |path| File.binread(path).match?(KERNEL_FROZEN_OUTSIDE) }
  end
end
