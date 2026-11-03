#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bc2cpp'
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

lookup = Insn.new(op: :MOVE, args: 'R1 R2')
peer = Insn.new(op: :MOVE, args: 'R3 R4')
peer.typed
suite.check('schema indexes share storage without sharing operand values', lookup.first_kind(:reg).value == 1 &&
            peer.first_kind(:reg).value == 3 &&
            lookup.instance_variable_get(:@kind_positions).equal?(peer.instance_variable_get(:@kind_positions)))
suite.check('shared schema indexes are frozen', peer.instance_variable_get(:@kind_positions).frozen?)
suite.check('single-kind lookup returns the earliest duplicate', lookup.first_kind(:reg).equal?(lookup.typed.first))
suite.check('single-kind lookup returns nil for absent kinds', lookup.first_kind(:sym).nil?)
suite.check('empty operand lists support lookup', Insn.new(op: :NOP, args: '').first_kind(:reg).nil?)
lookup.typed = [operand.new(:name, 'replacement')]
suite.check('replacing typed operands updates lookup', lookup.first_kind(:reg).nil? && lookup.first_kind(:name).value == 'replacement')

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

puts '-- derived code-generation names'
generator = CodeGen.allocate
old_sanitize = lambda do |name|
  name.gsub(/[^a-zA-Z0-9_]/) { |char| ':.'.include?(char) ? '_' : format('$%02x', char.ord) }
end
%w[Box RGSS::Rect Widget.singleton].product(%w[update []= < <= === +@ name?]).each do |owner, name|
  suite.check("#{owner}##{name}: mangling bytes stay unchanged", generator.cpp_name(owner, name) == old_sanitize.call("#{owner}_#{name}"))
end
cpp = generator.cpp_name('Box', 'update')
suite.check('equal owner/method contents reuse an immutable generated name', cpp.frozen? && generator.cpp_name(+'Box', +'update').equal?(cpp))
mutable_owner = +'Mutable'
mutable_method = +'first'
first_cpp = generator.cpp_name(mutable_owner, mutable_method)
mutable_owner.replace('Other')
mutable_method.replace('second')
suite.check('mutating caller owner/method strings cannot corrupt earlier cache keys',
            first_cpp == 'Mutable_first' && generator.cpp_name('Mutable', 'first').equal?(first_cpp) &&
            generator.cpp_name(mutable_owner, mutable_method) == 'Other_second')
ivar = generator.ivar_field_name('@value')
suite.check('ivar fields reuse immutable names without sharing the method-name namespace',
            ivar.frozen? && generator.ivar_field_name(+'@value').equal?(ivar) && generator.cpp_name('ivar', '@value') == ivar)
suite.check('identifier families keep separate namespaces for equal input keys',
            generator.ivar_field_name('Box') == 'ivar_Box' && generator.struct_name('Box') == 'Box_ivars' &&
            generator.type_var('Box') == 'Box_ivars_type' && generator.lexical_scope_path('Box') == ['Box'])
mutable_ivar = +'@item'
first_ivar = generator.ivar_field_name(mutable_ivar)
mutable_ivar.replace('@other')
suite.check('ivar cache keys snapshot mutable input content', first_ivar == 'ivar_$40item' && generator.ivar_field_name('@item').equal?(first_ivar) && generator.ivar_field_name(mutable_ivar) == 'ivar_$40other')
struct = generator.struct_name('Child')
type = generator.type_var('Child')
generator.instance_variable_set(:@embed_root_of, { 'Child' => 'Parent' })
suite.check('struct/type names resolve the current embedding owner before cache lookup',
            struct == 'Child_ivars' && type == 'Child_ivars_type' && generator.struct_name('Child') == 'Parent_ivars' &&
            generator.type_var('Child') == 'Parent_ivars_type' && generator.struct_name('Child').equal?(generator.struct_name('Parent')))
generator.instance_variable_set(:@embed_root_of, {})
suite.check('removing an embedding family restores its own cached names', generator.struct_name('Child').equal?(struct) && generator.type_var('Child').equal?(type))
path = generator.lexical_scope_path('RGSS::Rect.singleton')
suite.check('lexical paths reuse deeply immutable segments with singleton suffix stripped',
            path == %w[RGSS Rect] && path.frozen? && path.all?(&:frozen?) && generator.lexical_scope_path(+'RGSS::Rect.singleton').equal?(path))
mutable_scope = +'Game::Actor'
generator.lexical_scope_path(mutable_scope)
mutable_scope.replace('Game::Enemy.singleton')
suite.check('lexical cache keys snapshot input content', generator.lexical_scope_path('Game::Actor') == %w[Game Actor] && generator.lexical_scope_path(mutable_scope) == %w[Game Enemy])
owner_fn = generator.owner_class_fn_name('Box')
suite.check('owner helper names reuse their existing slot and immutable spelling',
            owner_fn == 'bc2cpp_owner_class_0' && owner_fn.frozen? && generator.owner_class_fn_name(+'Box').equal?(owner_fn))
other = CodeGen.allocate
suite.check('each generator retains independent owner helper numbering', other.owner_class_fn_name('Other') == 'bc2cpp_owner_class_0' && other.owner_class_fn_name('Box') == 'bc2cpp_owner_class_1')
count_before = generator.instance_variable_get(:@cpp_name_count)
generator.without_probe_side_effects do
  generator.cpp_name('Box', 'probe_only')
  generator.owner_class_fn_name('ProbeOnly')
end
suite.check('probe rollback restores immutable nested name tables and counters',
            generator.instance_variable_get(:@cpp_name_count) == count_before &&
            !generator.instance_variable_get(:@cpp_names).fetch('Box').key?('probe_only') &&
            !generator.instance_variable_get(:@owner_class_cache).key?('ProbeOnly'))
limited = CodeGen.allocate
(CodeGen::DERIVED_NAME_CACHE_MAX + 1).times do |index|
  limited.cpp_name("Owner#{index}", 'work')
  limited.ivar_field_name("@field#{index}")
  limited.struct_name("Owner#{index}")
  limited.type_var("Owner#{index}")
  limited.lexical_scope_path("Owner#{index}")
end
suite.check('all derived-name caches retain their configured bounds',
            limited.instance_variable_get(:@cpp_name_count) == CodeGen::DERIVED_NAME_CACHE_MAX &&
            %i[@cpp_names @ivar_field_names @struct_names @type_var_names @lexical_scope_paths].all? do |cache|
              limited.instance_variable_get(cache).size == CodeGen::DERIVED_NAME_CACHE_MAX
            end)
suite.check('exceeding a cache cap preserves fallback name generation',
            limited.cpp_name('Beyond::Cap', '[]=') == 'Beyond__Cap_$5b$5d$3d' && limited.ivar_field_name('@beyond') == 'ivar_$40beyond' &&
            limited.struct_name('Beyond::Cap') == 'Beyond__Cap_ivars' && limited.type_var('Beyond::Cap') == 'Beyond__Cap_ivars_type' &&
            limited.lexical_scope_path('Beyond::Cap.singleton') == %w[Beyond Cap])

if ENV['MRBC']
  suite.require_mrbc!
  suite.compile("class NameStringsProbe\n def work; shared_name; shared_name; end\nend\n") do |ireps, _root, _dir|
    calls = ireps.values.flat_map(&:instructions).select { |i| i.sym == 'shared_name' }
    suite.check('binary decoder shares repeated method names', calls.size == 2 && calls.all? { |i| i.sym.frozen? && i.sym.equal?(first.value) })
  end
end
suite.finish!
