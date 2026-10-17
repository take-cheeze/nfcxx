# frozen_string_literal: true

# NativeFormatTypes: the Ruby-visible type of each argument an `mrb_get_args` format string reads, and how mruby
# converts it (3rd/mruby/src/class.c, the case for each letter). An RBS signature for a native method may name a type
# only where the conversion is a check: a value that is not an instance of the class raises TypeError, so the declared
# class holds for every call that returns. A coercion (`i`, `f`, `n`) accepts a value that is not the class and converts
# it, so its declaration would be a lie about the callers; it is `untyped`. See scripts/bc2cpp/native_format_types_check.rb.
module NativeFormatTypes
  # rbs: the RBS type a call guarantees (nil: none). conversion: :check (TypeError otherwise), :coerce (converted by
  # mruby), :any (no check), :truthy (mrb_test), :class (ensure_class_type).
  Entry = Struct.new(:letter, :rbs, :conversion, keyword_init: true)

  ENTRIES = [
    Entry.new(letter: 'o', rbs: nil, conversion: :any),
    Entry.new(letter: 'C', rbs: 'Class', conversion: :class),
    Entry.new(letter: 'S', rbs: 'String', conversion: :check),
    Entry.new(letter: 'z', rbs: 'String', conversion: :check),
    Entry.new(letter: 's', rbs: 'String', conversion: :check),
    Entry.new(letter: 'A', rbs: 'Array', conversion: :check),
    Entry.new(letter: 'a', rbs: 'Array', conversion: :check),
    Entry.new(letter: 'H', rbs: 'Hash', conversion: :check),
    Entry.new(letter: 'i', rbs: nil, conversion: :coerce),
    Entry.new(letter: 'f', rbs: nil, conversion: :coerce),
    Entry.new(letter: 'n', rbs: nil, conversion: :coerce),
    Entry.new(letter: 'b', rbs: nil, conversion: :truthy),
    Entry.new(letter: 'd', rbs: nil, conversion: :any)
  ].freeze

  TABLE = ENTRIES.to_h { |entry| [entry.letter, entry] }.freeze

  # A format string as the positional arguments it reads: [{ letter:, optional: }] in order, or nil when the format has
  # a letter this table does not model (the caller then keeps the method untyped). `|` makes the rest optional; `*`
  # and `&` read no positional argument; `:` (keywords) is not modelled.
  def self.positions(format)
    optional = false
    out = []
    format.each_char do |c|
      case c
      when '|' then optional = true
      when '*', '&' then next
      else
        entry = TABLE[c]
        return nil unless entry

        out << { letter: c, optional: optional }
      end
    end
    out
  end

  # The RBS parameter type for a position: the class when the conversion is a check, else nil (untyped).
  def self.rbs_of(letter)
    TABLE.fetch(letter).rbs
  end
end
