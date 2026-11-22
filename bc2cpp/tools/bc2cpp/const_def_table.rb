# frozen_string_literal: true

# CONST_DEF_TABLE: a run of two or more class-body Fixnum constant writes to one owner, with nothing between them but
# the register loads that feed them, becomes one ROM table {symbol, value} and one call that makes the same
# mrb_const_set calls in the same order (so redefinition, the frozen check and the const_added hook are unchanged). The
# registers are left holding what the last write of each left them. Only compile-time symbols (MRB_SYM, a presym
# build) are tabled. BC2CPP_CONST_DEF_TABLE=0 keeps the inline writes.
module ConstDefTable
  PAIR = /^  (r\d+) = mrb_fixnum_value\((-?\d+)\);\n  mrb_const_set\(M, mrb_obj_value\((bc2cpp_owner_class_\d+)\(M\)\), (MRB_SYM(?:_[QBE])?\(\w+\)), \1\);\n/
  RUN = /(?:#{PAIR}){2,}/
  HELPER = <<~CPP
    struct bc2cpp_const_row { mrb_sym name; mrb_int value; };
    [[gnu::noinline]] static void bc2cpp_const_rows(mrb_state* M, struct RClass* c, const bc2cpp_const_row* rows, int n) {
      for (int i = 0; i < n; ++i) mrb_const_set(M, mrb_obj_value(c), rows[i].name, mrb_fixnum_value(rows[i].value));
    }
  CPP

  class << self
    # Writes tabled so far in this run.
    attr_accessor :count
  end
  self.count = 0

  module_function

  # The C++ of one owner's consecutive writes: inline when alone, else one table call.
  def table(pairs)
    if pairs.size == 1
      reg, value, owner, sym = pairs.first
      return "  #{reg} = mrb_fixnum_value(#{value});\n  mrb_const_set(M, mrb_obj_value(#{owner}(M)), #{sym}, #{reg});\n"
    end

    ConstDefTable.count += pairs.size
    rows = pairs.map { |_reg, value, _owner, sym| "{#{sym}, #{value}}" }.join(', ')
    last = pairs.reverse.uniq(&:first).map { |reg, value, _, _| "  #{reg} = mrb_fixnum_value(#{value});\n" }.join
    "  { static const bc2cpp_const_row rows[] = {#{rows}};\n" \
      "    bc2cpp_const_rows(M, #{pairs.first[2]}(M), rows, #{pairs.size}); }\n#{last}"
  end

  def enabled?
    ENV['BC2CPP_CONST_DEF_TABLE'] != '0'
  end

  def rewrite(code)
    return code unless enabled?

    code.gsub(RUN) do |run|
      groups = []
      run.scan(PAIR).each { |pair| groups.last&.last&.at(2) == pair[2] ? groups.last << pair : groups << [pair] }
      groups.map { |pairs| table(pairs) }.join
    end
  end
end
