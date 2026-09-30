# frozen_string_literal: true

# Prints the resolved LCF schema as JSON on stdout, for LcfSchemaOracle.
# Loaded under CRuby only, exactly as mruby-lcf/gen_schema_blob.rb loads it: schema.rb is plain data plus two
# edition-dependent defaults that lcf.rb defines, so nothing here reflects on the running program.
#
# Usage: ruby lcf_schema_dump.rb path/to/mruby-lcf/mrblib

require 'json'
require 'stringio'

$VERBOSE = nil
dir = ARGV.fetch(0)
load File.join(dir, 'lcf.rb')
load File.join(dir, 'schema.rb')

# One entry per (schema node path, field name); `elements` recurse so DATABASE/item/... paths are kept.
def describe(fields, path, out)
  fields = fields.call if fields.respond_to?(:call)
  fields.each do |id, field|
    next unless field.is_a?(Hash) && field[:name]

    default = field[:default]
    default = default.call if default.respond_to?(:call)
    node = "#{path}/#{field[:name]}"
    out << { path: node, id: id, name: field[:name].to_s, type: field[:type].to_s, has_default: field.key?(:default),
             default_class: field.key?(:default) ? default.class.to_s : nil, order: field[:order]&.map(&:to_s),
             enums: field[:enums]&.keys, computed_default: field[:default].respond_to?(:call) }
    describe(field[:elements], node, out) if field[:elements]
  end
end

out = []
LCF::Schema.constants.sort.each do |const|
  value = LCF::Schema.const_get(const)
  if value.is_a?(Hash) && value[:elements] && value[:type]
    describe(value[:elements], const.to_s, out)
  elsif value.is_a?(Hash) && !value.empty? && value.keys.all?(Integer)
    describe(value, const.to_s, out)
  elsif value.is_a?(Array)
    value.each { |section| describe(section[:elements], "#{const}/#{section[:name]}", out) if section.is_a?(Hash) && section[:elements] }
  end
end
puts JSON.generate(out)
