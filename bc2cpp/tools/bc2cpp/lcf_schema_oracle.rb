# frozen_string_literal: true

require 'json'
require 'open3'
require 'set'

# LCF_SCHEMA_ORACLE (docs/adr/0285): what `LCF::Array1D#[]` can return for a schema field, from the schema
# data alone. mruby-lcf/mrblib/schema.rb is a static table (chunk id => {name:, type:, default:, elements:});
# Array1D#[] decodes the stored bytes through LCF.to_rb, so the class of a read is fixed by the field's
# `type` and, for an absent chunk, by its `default`, whatever any writer stores (LCF.encode turns every
# write into bytes). This module is the data half: it does not say which receiver a call site has.
#
# Reading rules (mruby-lcf/mrblib/lcf.rb, LCF.to_rb / read_ber / elements_of):
#   :int -> Integer in [-2^31, 2^31 - 1] (read_ber reinterprets the low 32 bits as signed);
#   :uint8 -> Integer in [0, 255]; :bool -> true/false; :string -> String; :double -> Float;
#   :Array1D/:Array2D -> LCF::Array1D/LCF::Array2D; :Tree -> LCF::Tree;
#   :int8_array/:int32_array/:bool_array/:event/:move_commands -> Array; :int16_array -> Array, or Hash when
#   the field has an `order`. `enums:` is documentation: to_rb never maps an Integer to its Symbol.
#   An absent chunk reads the schema `default` (an Integer default that is a lambda is called) and nil
#   when the field has none.
module LcfSchemaOracle
  Fact = Struct.new(:path, :name, :type, :classes, :range, :nilable, keyword_init: true)

  TYPE_CLASSES = {
    'int' => %w[Integer], 'uint8' => %w[Integer], 'bool' => %w[TrueClass FalseClass], 'string' => %w[String],
    'double' => %w[Float], 'Array1D' => %w[LCF::Array1D], 'Array2D' => %w[LCF::Array2D], 'Tree' => %w[LCF::Tree],
    'int8_array' => %w[Array], 'int32_array' => %w[Array], 'bool_array' => %w[Array], 'event' => %w[Array],
    'move_commands' => %w[Array], 'int16_array' => %w[Array]
  }.freeze
  TYPE_RANGES = { 'int' => [-0x8000_0000, 0x7fff_ffff], 'uint8' => [0, 255] }.freeze
  DUMP = File.expand_path('lcf_schema_dump.rb', __dir__)

  module_function

  # All facts, one per (schema path, field). Raises when the dump fails: no silent empty oracle.
  def facts(mrblib_dir)
    out, err, status = Open3.capture3(RbConfig.ruby, DUMP, mrblib_dir)
    raise "lcf_schema_dump failed: #{err}" unless status.success?

    JSON.parse(out).map { |row| fact(row) }
  end

  def fact(row)
    type = row['type']
    classes = TYPE_CLASSES.fetch(type) { raise "LcfSchemaOracle: unmodelled field type #{type} at #{row['path']}" }.to_set
    classes = Set['Hash'] if type == 'int16_array' && row['order']
    absent = row['has_default'] ? row['default_class'] : 'NilClass'
    Fact.new(path: row['path'], name: row['name'], type: type, classes: (classes | [absent]).freeze,
             range: TYPE_RANGES[type], nilable: !row['has_default'] || row['default_class'] == 'NilClass')
  end

  # field name => the union over every schema position that spells it. A name whose facts agree is
  # receiver-independent *for an LCF row*; it still says nothing about which object a call site indexes.
  def by_name(facts)
    facts.group_by(&:name).transform_values do |list|
      { classes: list.flat_map { |f| f.classes.to_a }.to_set, types: list.map(&:type).uniq, paths: list.map(&:path),
        nilable: list.any?(&:nilable) }
    end
  end
end
