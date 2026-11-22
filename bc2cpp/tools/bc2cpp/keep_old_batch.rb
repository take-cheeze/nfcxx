# frozen_string_literal: true

# KEEP_OLD_BATCH: a straight run of embedded-slot stores on self, each rooting the value it replaces
# (GC_KEEP_OVERWRITTEN), roots them all with one bc2cpp_keep_olds2/3 call at the run's first keep. Sound because only
# lines that run no Ruby code, restore no arena and cannot be jumped into sit between (blank and comment lines,
# immediate loads into a register, stores into self's fields): every replaced value is still in its slot when the
# batch reads it, unless an earlier store of the run wrote that slot, which ends the run. Rooting earlier only roots
# longer. BC2CPP_KEEP_OLD_BATCH=0 leaves the text.
module KeepOldBatch
  KEEP = /\A(\s*)bc2cpp_keep_old\(M, (\(\(\w+\*\)DATA_PTR\(self\)\)->\w+)\);\n\z/
  STORE = /\A\s*(\(\(\w+\*\)DATA_PTR\(self\)\)->\w+) = r\d+;\n\z/
  NEUTRAL = [
    /\A\s*\n\z/,
    %r{\A\s*/\*[^\n]*?\*/\s*\n\z},
    %r{\A\s*//[^\n]*\n\z},
    /\A\s*r\d+ = mrb_(?:nil|true|false)_value\(\);\n\z/,
    /\A\s*r\d+ = mrb_fixnum_value\(-?\d+\);\n\z/,
    /\A\s*r\d+ = mrb_symbol_value\(MRB_SYM(?:_[QBE])?\(\w+\)\);\n\z/,
    # A symbol lookup interns at most: no Ruby code, no arena change.
    /\A\s*r\d+ = mrb_symbol_value\(bc2cpp_sym\(M, \d+\)\);\n\z/,
    /\A\s*r\d+ = mrb_symbol_value\(mrb_intern_(?:cstr|lit|static)\(M, "\w*"\)\);\n\z/
  ].freeze

  def self.enabled?
    ENV['BC2CPP_KEEP_OLD_BATCH'] != '0' && ENV['BC2CPP_GC_KEEP_OVERWRITTEN'] != '0'
  end

  def self.apply(text)
    return text unless enabled? && text.include?('bc2cpp_keep_old(M, ((')

    lines = text.lines
    out = []
    run = nil # { at: index in out of the first keep, indent:, fields: [], stored: Set-like Array }
    flush = lambda do
      if run && run[:fields].size > 1
        out[run[:at]] = batch_text(run[:indent], run[:fields])
      elsif run
        out[run[:at]] = "#{run[:indent]}bc2cpp_keep_old(M, #{run[:fields].first});\n"
      end
      run = nil
    end
    lines.each do |line|
      if (m = KEEP.match(line))
        field = m[2]
        flush.call if run && (run[:stored].include?(field) || run[:fields].include?(field))
        if run
          run[:fields] << field
        else
          out << nil
          run = { at: out.size - 1, indent: m[1], fields: [field], stored: [] }
        end
        next
      end
      if run
        if (s = STORE.match(line))
          run[:stored] << s[1]
        elsif NEUTRAL.none? { |re| re.match?(line) }
          flush.call
        end
      end
      out << line
    end
    flush.call
    out.join
  end

  def self.batch_text(indent, fields)
    fields.each_slice(3).map do |group|
      call = group.size == 1 ? 'bc2cpp_keep_old' : "bc2cpp_keep_olds#{group.size}"
      args = group.size == 1 ? "M, #{group.first}" : "#{group.join(', ')}, M"
      "#{indent}#{call}(#{args});\n"
    end.join
  end
end
