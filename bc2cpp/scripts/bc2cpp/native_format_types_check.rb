#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/native_format_types.rb: each conversion in its table is the one 3rd/mruby/src/class.c performs for
# that letter, and every mrb_get_args format in the native sources is modelled. Host only, a few seconds.
#
#   ruby scripts/bc2cpp/native_format_types_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/native_format_types'

ROOT = File.expand_path('../..', __dir__)
CLASS_C = File.join(ROOT, '3rd/mruby/src/class.c')
NATIVE_DIRS = %w[mruby-rgss/src mruby-rpg2k/src mruby-lcf/src mruby-mvjs/src mruby-wolf/src].freeze
# The token class.c's case body for each letter must contain: a check or a coercion.
EVIDENCE = {
  'S' => 'mrb_ensure_string_type', 'z' => 'mrb_ensure_string_type', 's' => 'mrb_ensure_string_type',
  'A' => 'mrb_ensure_array_type', 'a' => 'mrb_ensure_array_type', 'H' => 'mrb_ensure_hash_type',
  'C' => 'ensure_class_type', 'i' => 'mrb_as_int', 'f' => 'mrb_as_float', 'n' => 'to_sym',
  'b' => 'mrb_test', 'o' => 'pickarg', 'd' => 'mrb_data_get_ptr'
}.freeze

failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The body of the `case 'X':` arm of class.c's argument reader: the run of labels it shares (`case 'o': case 'S': ...`),
# then the lines up to the next label.
def arm_of(text, letter)
  lines = text.lines
  index = lines.index { |l| l.match?(/^ {4}case '#{letter}':/) }
  return nil unless index

  index += 1 while index < lines.size && lines[index].match?(/^ {4}case '/)
  body = []
  while index < lines.size && !lines[index].match?(/^ {4}case '/)
    body << lines[index]
    index += 1
  end
  body.join
end

puts '== conversions against class.c'
text = File.read(CLASS_C, encoding: 'UTF-8')
NativeFormatTypes::ENTRIES.each do |entry|
  arm = arm_of(text, entry.letter)
  check.call("#{entry.letter}: class.c's arm contains #{EVIDENCE.fetch(entry.letter)}",
             !arm.nil? && arm.include?(EVIDENCE.fetch(entry.letter)))
end
check.call('the check letters name a class with an RBS type', NativeFormatTypes::ENTRIES
  .select { |e| e.conversion == :check }.all? { |e| e.rbs && e.rbs.match?(/\A[A-Z]\w*\z/) })
check.call('the coercion letters name no RBS type (they accept values that are not the class)',
           NativeFormatTypes::ENTRIES.select { |e| e.conversion == :coerce }.all? { |e| e.rbs.nil? })

puts '== every native format is modelled'
formats = NATIVE_DIRS.flat_map do |dir|
  Dir[File.join(ROOT, dir, '**', '*.{c,cc,cpp,cxx}')].flat_map do |path|
    File.read(path, encoding: 'UTF-8').scan(/mrb_get_args\s*\(\s*\w+\s*,\s*"([^"]*)"/).flatten
  end
end
unmodelled = formats.reject { |f| NativeFormatTypes.positions(f) }
check.call("#{formats.size} native formats, #{unmodelled.size} unmodelled (#{unmodelled.uniq.join(' ')})", unmodelled.empty?)

if failures.empty?
  puts "native format types check: #{checks} checks passed"
else
  abort "native format types check: #{failures.size} failure(s)"
end
