# frozen_string_literal: true

require 'set'
require_relative 'lcf_schema_oracle'
require_relative 'numeric_flow'

# LCF_ROW_FLOW: the kinds of object an LCF file reads out of itself, as extra bits of
# NumericFlow's class-set lattice, and what `[]` on each returns.
#
#   FILE(LCF::Database)  exactly a Database (made by `LCF::Database.new`)
#   ROW(path)            exactly an LCF::Array1D whose schema elements are the table at `path`
#   TBL(path)            exactly an LCF::Array2D whose rows are ROW(path)
#
# `db[:name]` is `LCF::File#[]` -> `@root[:name]`, `row[:name]` is `Array1D#[]` -> `LCF.to_rb` by the
# field's `type`, and `tbl[i]` is `Array2D#[]` -> nil or the decoded row. The class of each result is
# fixed by the schema data (LcfSchemaOracle) alone, because
#   - Array1D#[]= re-encodes any value to bytes and Array1D#[] decodes bytes by `type`;
#   - Array2D#[]= keeps only nil, bytes or an Array1D over the table's own elements (mruby-lcf/mrblib/lcf.rb);
#   - a row's and a table's `@schema` are assigned once, in #initialize.
# Whether a given receiver is one of these objects is the dataflow's business: a bit is only ever
# produced by a construction the compiler sees (`Klass.new` of a stable class) or by `[]` on a receiver
# that already carries one, so a value from anywhere else is OTHER and proves nothing.
module LcfRowFlow
  FIRST_BIT = NumericFlow::OBJECT_KIND_BASE
  FILE_OWNER = 'LCF::File'
  ROW_OWNER = 'LCF::Array1D'
  TABLE_OWNER = 'LCF::Array2D'

  Kind = Struct.new(:role, :path, :bit, :owner, :file_class, :position, keyword_init: true)

  FIELD_CLASS_BITS = {
    'Integer' => NumericFlow::INT, 'Float' => NumericFlow::FLT, 'String' => NumericFlow::STR,
    'Array' => NumericFlow::ARR, 'Hash' => NumericFlow::HSH, 'NilClass' => NumericFlow::NIL
  }.freeze

  # The kinds and the per-path field table.
  class Model
    attr_reader :kinds, :mask

    def initialize(facts, roots)
      @kinds = []
      @files = {}
      @rows = {}
      @tables = {}
      @fields = Hash.new { |h, k| h[k] = {} }
      @by_id = Hash.new { |h, k| h[k] = {} }
      next_bit = FIRST_BIT
      alloc = lambda do |role, path, owner, file_class = nil|
        kind = Kind.new(role: role, path: path, bit: 1 << next_bit, owner: owner, file_class: file_class, position: next_bit)
        next_bit += 1
        @kinds << kind
        kind
      end
      roots.sort.each do |klass, const|
        @files[klass] = alloc.call(:file, const, FILE_OWNER, klass)
        @rows[const] = alloc.call(:row, const, ROW_OWNER)
      end
      facts.sort_by(&:path).each do |f|
        parent = f.path.rpartition('/').first
        @fields[parent][f.name] = f
        @by_id[parent][f.id] = f
        next unless f.has_elements

        @rows[f.path] ||= alloc.call(:row, f.path, ROW_OWNER) if f.type == 'Array1D'
        next unless f.type == 'Array2D'

        @tables[f.path] ||= alloc.call(:table, f.path, TABLE_OWNER)
        @rows[f.path] ||= alloc.call(:row, f.path, ROW_OWNER)
      end
      @by_bit = @kinds.to_h { |k| [k.bit, k] }
      @mask = @kinds.sum(&:bit)
      # The kind table is fixed, so foreign-class predicates can share these complements.
      @non_lcf_mask = ~@mask
      @non_lcf_non_nil_mask = ~(@mask | NumericFlow::NIL)
      @field_masks = {}
    end

    def file_bit(class_name)
      @files[class_name]&.bit
    end

    def kind(bit)
      @by_bit[bit]
    end

    def lcf_bits(mask)
      mask & @mask
    end

    # The class name a mask that is exactly one LCF kind stands for, else nil.
    def exact_owner(mask)
      kind = @by_bit[mask]
      kind && (kind.file_class || kind.owner)
    end

    # The field names the schema at +path+ declares (what sym2idx can resolve for a row or table there);
    # nil when the model has no fields for that path, so the caller cannot tell and must not judge.
    def field_names(path)
      @fields.key?(path) ? @fields[path].keys : nil
    end

    def name(bit)
      k = @by_bit[bit]
      k && "#{k.role.to_s.upcase}:#{k.file_class || k.path}"
    end

    # The class set of `recv[key]`. +key+ is a Symbol (field name), an Integer (chunk id) or nil (not a
    # literal). A receiver bit that is not an LCF kind contributes OTHER: it is some other class's `[]`.
    # nil contributes nothing when +nil_raises+ (`nil[]` raises NoMethodError).
    def index(recv_mask, key, nil_raises: false)
      result = 0
      foreign = nil_raises ? @non_lcf_non_nil_mask : @non_lcf_mask
      result |= NumericFlow::OTHER if recv_mask.anybits?(foreign)
      @kinds.each do |k|
        # Each kind owns one bit; indexing avoids a temporary bignum intersection.
        next unless recv_mask[k.position] == 1

        result |= case k.role
                  when :file, :row then field_mask(k.path, key)
                  when :table then NumericFlow::NIL | @rows.fetch(k.path).bit
                  end
      end
      result
    end

    private

    def field_mask(path, key)
      fact = case key
             when Symbol then @fields.dig(path, key.to_s)
             when Integer then @by_id.dig(path, key)
             end
      return NumericFlow::OTHER unless fact

      @field_masks[fact.path] ||= fact.classes.reduce(0) { |m, c| m | class_mask(fact, c) }
    end

    def class_mask(fact, klass)
      return FIELD_CLASS_BITS.fetch(klass) if FIELD_CLASS_BITS.key?(klass)
      return @rows[fact.path]&.bit || NumericFlow::OTHER if klass == ROW_OWNER
      return @tables[fact.path]&.bit || NumericFlow::OTHER if klass == TABLE_OWNER

      NumericFlow::OTHER
    end
  end

  module_function

  # nil when the schema cannot be modelled (no silent empty model: the caller reports why).
  def model(mrblib_dir)
    Model.new(LcfSchemaOracle.facts(mrblib_dir), LcfSchemaOracle.roots(mrblib_dir))
  end
end
