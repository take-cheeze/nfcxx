#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Equivalence check for mruby-lcf's schema blob (the wio build's replacement
# for mrblib/schema.rb, see mruby-lcf/gen_schema_blob.rb).
#
# Generates the blob under CRuby, then loads two copies of LCF::Schema in
# separate processes: the reference (mrblib/schema.rb) and the generated file.
# Each process prints one canonical line per top-level constant, and the two
# outputs must match exactly. The canonical form keeps every key of every field
# record (including `format:` and `enums:`), keeps the order of id-keyed
# sections and enum tables, and resolves the lazy `elements:` lambdas and the
# edition-dependent defaults to their values, so the two representations
# compare equal exactly when they mean the same thing.
#
# Usage: ruby scripts/bc2cpp/schema_blob_check.rb

require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
MRBLIB = File.join(ROOT, 'mruby-lcf', 'mrblib')
LCF_RB = File.join(MRBLIB, 'lcf.rb')
SCHEMA_RB = File.join(MRBLIB, 'schema.rb')
GENERATOR = File.join(ROOT, 'mruby-lcf', 'gen_schema_blob.rb')

# Canonical text for one value. Hashes keep their order when every key is an
# Integer (id-keyed sections, enum tables) and are sorted by key otherwise
# (field records, whose key order is not meaningful).
def norm(value)
  case value
  when Hash
    keys_ordered = value.keys.all? { |k| k.is_a?(Integer) }
    pairs = value.to_a
    pairs = pairs.sort_by { |k, _| k.inspect } unless keys_ordered
    "{#{pairs.map { |k, v| "#{k.inspect}=>#{norm_field(k, v)}" }.join(',')}}"
  when Array
    "[#{value.map { |v| norm(v) }.join(',')}]"
  when Proc
    norm(value.call)
  else
    value.inspect
  end
end

# A field's `default:` is either a literal or, for the two edition-dependent
# Symbols, a value LCF.edition_default resolves. The blob stores those as a
# lambda that returns the same value, so both sides resolve to the value.
def norm_field(key, value)
  return norm(LCF.edition_default(value)) if key == :default && value.is_a?(Symbol)

  norm(value)
end

# BLOB and Blob are the generated file's own storage and decoder; schema.rb
# defines neither, so they are not part of the comparison.
GENERATED_ONLY = %i[BLOB Blob].freeze

def dump(schema_file)
  require LCF_RB
  require schema_file
  (LCF::Schema.constants - GENERATED_ONLY).sort.map do |name|
    "#{name}: #{norm(LCF::Schema.const_get(name))}"
  end.join("\n")
end

if ARGV.first == '--dump'
  puts dump(ARGV.fetch(1))
  exit 0
end

failures = []
Dir.mktmpdir('schema-blob-check') do |dir|
  blob = File.join(dir, 'schema_blob.rb')
  gen_out, gen_status = Open3.capture2e(RbConfig.ruby, GENERATOR, SCHEMA_RB, blob)
  unless gen_status.success?
    failures << "generator failed:\n#{gen_out}"
    next
  end

  reference, ref_status = Open3.capture2e(RbConfig.ruby, __FILE__, '--dump', SCHEMA_RB)
  generated, gen_dump_status = Open3.capture2e(RbConfig.ruby, __FILE__, '--dump', blob)
  failures << "reference dump failed:\n#{reference}" unless ref_status.success?
  failures << "generated dump failed:\n#{generated}" unless gen_dump_status.success?

  if failures.empty?
    ref_lines = reference.lines
    gen_lines = generated.lines
    if ref_lines != gen_lines
      differing = (0...[ref_lines.size, gen_lines.size].max).reject { |i| ref_lines[i] == gen_lines[i] }
      differing.first(5).each do |i|
        failures << "constant #{i + 1} differs:\n  schema.rb: #{ref_lines[i].to_s.chomp[0, 300]}\n  blob:      #{gen_lines[i].to_s.chomp[0, 300]}"
      end
    else
      puts "schema_blob_check: #{ref_lines.size} constants equal (blob #{File.size(blob)} bytes of generated Ruby)"
    end
  end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
