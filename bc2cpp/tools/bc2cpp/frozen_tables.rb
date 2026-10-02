# frozen_string_literal: true

require 'set'
require_relative 'numeric_flow'

# FROZEN_TABLES (docs/adr/0306): element classes for an Array or Hash that is a frozen literal.
#
# A literal `[1, 2, 3].freeze` / `{ 8 => 0 }.freeze` has no writer after the `freeze`, so its slots are
# whatever the literal stored and no alias or escape analysis is needed: the table itself is the
# proof. Each distinct shape (container, per-slot class sets, literal keys) is one NumericFlow object
# kind, so the shape rides pooled constants, arguments, ivars and return values like an LCF kind
# (ADR 0294) and `recv[i]` / `recv.first` read the shape back.
#
# A slot's class set is syntactic (literal ops only), never a flow result, so it cannot depend on the
# fixpoint it feeds. OTHER stays OTHER: the shape only narrows what the literal states.
module FrozenTables
  # LCF kinds take OBJECT_KIND_BASE..+255 (CodeGen#setup_frozen_tables refuses to overlap them).
  FIRST_BIT = NumericFlow::OBJECT_KIND_BASE + 256

  Shape = Struct.new(:container, :slots, :keys, :bit, keyword_init: true) do
    def array? = container == :array
    def size = slots.size

    # Join of every slot; 0 for an empty literal.
    def joined
      slots.reduce(0) { |m, s| m | s }
    end
  end

  # Interns shapes and answers the index/read questions. Bits are allocated in first-use order, which
  # follows the (sorted) scan order of the irep table, so two runs of one tree agree.
  class Registry
    attr_reader :shapes

    def initialize
      @by_key = {}
      @by_bit = {}
      @shapes = []
    end

    def intern(container, slots, keys)
      key = [container, slots, keys]
      @by_key[key] ||= begin
        shape = Shape.new(container: container, slots: slots.freeze, keys: keys&.freeze, bit: 1 << (FIRST_BIT + @shapes.size))
        @shapes << shape
        @by_bit[shape.bit] = shape
        @mask = nil
        shape
      end
    end

    def mask
      @mask ||= @shapes.sum(&:bit)
    end

    def tables(mask)
      mask & self.mask
    end

    def each_shape_in(mask)
      @shapes.each { |s| yield s if mask.anybits?(s.bit) }
    end

    def shape(bit)
      @by_bit[bit]
    end

    # The class set of `table[key]`. +key+ is the literal Integer/Symbol index when the site has one;
    # +key_int+ says the index register provably holds an Integer. nil: nothing is proven (OTHER).
    #   Array: a literal index in range reads exactly that slot, one out of range is nil; a proven
    #   Integer index reads any slot or nil. Anything else may be a Range (an Array result).
    #   Hash: Hash#[] answers a stored value or the default, and a frozen literal's default is nil
    #   (defaults are set after construction, which `freeze` ends).
    def read(shape, key, key_int)
      if shape.array?
        return array_read(shape, key) if key.is_a?(Integer)
        return NumericFlow::OTHER unless key_int

        shape.joined | NumericFlow::NIL
      else
        hash_read(shape, key)
      end
    end

    # `first` / `last` / `sample` without arguments.
    def end_read(shape, name)
      return NumericFlow::NIL if shape.size.zero?

      case name
      when 'first' then shape.slots.first
      when 'last' then shape.slots.last
      else shape.joined
      end
    end

    def name(bit)
      shape = @by_bit[bit] or return nil
      runs = shape.slots.map { |s| slot_name(s) }.chunk_while { |x, y| x == y }.map { |run| run.size > 1 ? "#{run.first}*#{run.size}" : run.first }
      "FROZEN:#{shape.array? ? 'Array' : 'Hash'}[#{runs.join(',')}]"
    end

    private

    def array_read(shape, index)
      n = shape.size
      return NumericFlow::NIL unless index.between?(-n, n - 1)

      shape.slots[index]
    end

    def hash_read(shape, key)
      return shape.joined | NumericFlow::NIL unless shape.keys && (key.is_a?(Integer) || key.is_a?(Symbol))

      # The last equal key wins, as in Hash literal construction.
      pos = shape.keys.rindex(key)
      pos ? shape.slots[pos] : NumericFlow::NIL
    end

    SLOT_NAMES = { NumericFlow::INT => 'INT', NumericFlow::FLT => 'FLT', NumericFlow::ARR => 'ARR', NumericFlow::HSH => 'HSH',
                   NumericFlow::STR => 'STR', NumericFlow::NIL => 'NIL', NumericFlow::RNG => 'RNG',
                   NumericFlow::OTHER => 'OTHER' }.freeze

    def slot_name(mask)
      SLOT_NAMES.filter_map { |bit, n| n if mask.anybits?(bit) }.join('|')
    end
  end
end
