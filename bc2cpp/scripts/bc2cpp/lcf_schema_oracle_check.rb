#!/usr/bin/env ruby
# frozen_string_literal: true

# LCF_SCHEMA_ORACLE (docs/adr/0285): the classes tools/bc2cpp/lcf_schema_oracle.rb derives from the
# schema table must be what mruby-lcf/mrblib/lcf.rb really returns. The check loads the reader under
# CRuby (as every scripts/**/*_check.rb does), then for every record schema (DATABASE's rows included) reads each field once
# absent (the default / nil arm) and once after a `[]=` of a sample value (the decode arm), and
# requires the class, and the range of an :int, to be inside the oracle's fact.
#
# Usage: ruby scripts/bc2cpp/lcf_schema_oracle_check.rb

require 'stringio'
require_relative '../../tools/bc2cpp/lcf_schema_oracle'

MRBLIB = File.expand_path('../../mruby-lcf/mrblib', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

puts '-- oracle table'
facts = LcfSchemaOracle.facts(MRBLIB)
names = LcfSchemaOracle.by_name(facts)
check.call('every schema field has a fact', facts.size > 1000 && facts.all? { |f| !f.classes.empty? })
check.call('an :int field reads Integer in the signed 32-bit range',
           facts.select { |f| f.type == 'int' }.all? { |f| f.classes.include?('Integer') && f.range == [-0x8000_0000, 0x7fff_ffff] })
check.call('a field without a default can read nil', facts.select { |f| !f.nilable }.none? { |f| f.classes.include?('NilClass') })
attribute_set = names.fetch('attribute_set')
check.call('attribute_set is an int8_array that reads Array or nil',
           attribute_set[:types] == ['int8_array'] && attribute_set[:classes] == Set['Array', 'NilClass'])
check.call('a lambda default is called for its class (max_level reads Integer)',
           facts.find { |f| f.name == 'max_level' }.classes == Set['Integer'])
check.call('a name several schemas spell with different types has no single type',
           names.fetch('level')[:types].sort == %w[int string])
check.call('most names have a single type', names.count { |_, v| v[:types].size == 1 } > 700)

puts '-- oracle against the real reader'
$VERBOSE = nil
load File.join(MRBLIB, 'lcf.rb')
load File.join(MRBLIB, 'schema.rb')
module LCF
  def self.cp932_to_utf8(s) = s.dup.force_encoding('Windows-31J').encode('UTF-8')
  def self.utf8_to_cp932(s) = s.encode('Windows-31J').b
end

SAMPLES = {
  'int' => [7, -3, 0x7fff_ffff, -0x8000_0000], 'uint8' => [200], 'bool' => [true, false], 'string' => ['abc'],
  'double' => [1.5], 'int8_array' => [[1, 2]], 'int16_array' => [[1, -2, 3, -4, 5, -6]], 'int32_array' => [[1, -2]],
  'bool_array' => [[true, false]]
}.freeze

# [path prefix, element table] for every record schema, DATABASE's nested rows included.
def record_schemas
  out = []
  walk = lambda do |fields, path|
    fields = fields.call if fields.respond_to?(:call)
    out << [path, fields]
    fields.each_value { |f| walk.call(f[:elements], "#{path}/#{f[:name]}") if f.is_a?(Hash) && f[:elements] }
  end
  LCF::Schema.constants.sort.each do |const|
    value = LCF::Schema.const_get(const)
    if value.is_a?(Hash) && value[:elements] && value[:type] then walk.call(value[:elements], const.to_s)
    elsif value.is_a?(Hash) && !value.empty? && value.keys.all?(Integer) then walk.call(value, const.to_s)
    end
  end
  out
end

by_path = facts.to_h { |f| [f.path, f] }
checked = 0
mismatches = []
record_schemas.each do |path, fields|
  fields.each_value do |field|
    fact = by_path["#{path}/#{field[:name]}"] or (mismatches << "#{path}/#{field[:name]}: no fact"; next)
    row = LCF::Array1D.new(String.new, { elements: fields })
    absent = row[field[:name]]
    checked += 1
    mismatches << "#{fact.path}: absent read #{absent.class}" unless fact.classes.include?(absent.class.to_s)
    (SAMPLES[fact.type] || []).each do |sample|
      row[field[:name]] = sample
      got = row[field[:name]]
      checked += 1
      unless fact.classes.include?(got.class.to_s) || (got == true && fact.classes.include?('TrueClass')) ||
             (got == false && fact.classes.include?('FalseClass'))
        mismatches << "#{fact.path}: #{sample.inspect} read back as #{got.class}"
      end
      if fact.range && got.is_a?(Integer) && !(fact.range.first..fact.range.last).cover?(got)
        mismatches << "#{fact.path}: #{got} outside #{fact.range}"
      end
    end
  end
end
puts mismatches.first(10).map { |m| "    #{m}" }
check.call("#{checked} reads of #{record_schemas.size} record schemas fall inside the oracle's classes and ranges",
           mismatches.empty? && checked > 2000)

if failures.empty?
  puts 'bc2cpp lcf schema oracle check: PASS'
else
  warn "bc2cpp lcf schema oracle check: #{failures.size} failure(s)"
  exit 1
end
