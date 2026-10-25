#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative 'check_support'

suite = FixtureCheck.new('name_strings_check')
operand = OperandSchema::Operand
method_name = String.new('shared_name')
first = operand.new(:sym, method_name)
second = operand.new(:name, String.new('shared_name'))
constant = operand.new(:mcnst, [3, String.new('shared_name')])
suite.check('name kinds share one frozen String', first.value.is_a?(String) && first.value.frozen? &&
            first.value.equal?(second.value) && first.value.equal?(constant.value[1]))
suite.check('canonicalization does not freeze or mutate the caller String', !method_name.frozen? && method_name == 'shared_name')
method_name.replace('caller_changed')
suite.check('later caller mutation cannot change an operand name', first.value == 'shared_name')
suite.check('qualified constants preserve the scope register', constant.value[0] == 3)
plain = operand.new(:rest, String.new('shared_name'))
suite.check('diagnostic text is not interned', !plain.value.frozen? && !plain.value.equal?(first.value))
number = operand.new(:reg, 3)
suite.check('numeric operands retain their type and value', number.value == 3)
utf8 = operand.new(:sym, String.new('名前'))
other_utf8 = operand.new(:name, String.new('名前'))
suite.check('non-ASCII name bytes and encoding survive', utf8.value == '名前' && utf8.value.encoding == Encoding::UTF_8 && utf8.value.equal?(other_utf8.value))
binary = operand.new(:sym, "\xff".b)
suite.check('binary name encoding survives', binary.value.bytes == [255] && binary.value.encoding == Encoding::BINARY)

rows = [['SEND0', 'R1 :shared_name'], ['GETCONST', 'R2 shared_name'], ['GETMCNST', 'R3 (R3)::shared_name']]
body = Irep.new(label: 'names', nregs: 4, nlocals: 1, catch_handlers: [], reps: [], pool: [],
                instructions: rows.each_with_index.map { |(op, args), index| Insn.new(op: op, args: args, addr: index) })
names = ->(irep) { irep.instructions.map { |insn| insn.first_of(:sym, :name, :mcnst).value }.map { |value| value.is_a?(Array) ? value[1] : value } }
suite.check('synthetic operands share names across opcode kinds', names.call(body).all? { |name| name.equal?(first.value) })
Dir.mktmpdir('name_strings_cache') do |dir|
  path = File.join(dir, 'tree.marshal')
  snapshot = Marshal.dump([{ 'names' => body }, 'names'])
  File.binwrite(path, "#{Digest::SHA256.hexdigest(snapshot)}\n#{snapshot}")
  restored = IrepCache.read_snapshot(path).first.fetch('names')
  restored_names = names.call(restored)
  suite.check('cache restoration recanonicalizes names', restored_names.all? { |name| name.frozen? && name.equal?(first.value) })
  suite.check('cache restoration preserves operand text', restored.instructions.map { |i| OperandSchema.to_text(i.typed) } == body.instructions.map { |i| OperandSchema.to_text(i.typed) })
end

if ENV['MRBC']
  suite.require_mrbc!
  suite.compile("class NameStringsProbe\n def work; shared_name; shared_name; end\nend\n") do |ireps, _root, _dir|
    calls = ireps.values.flat_map(&:instructions).select { |i| i.sym == 'shared_name' }
    suite.check('binary decoder shares repeated method names', calls.size == 2 && calls.all? { |i| i.sym.frozen? && i.sym.equal?(first.value) })
  end
end
suite.finish!
