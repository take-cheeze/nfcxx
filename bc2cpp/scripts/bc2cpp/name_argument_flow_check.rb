#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('name_argument_flow_check')
suite.require_mrbc!

world_for = lambda do |source, &block|
  suite.compile(source) do |ireps, _root, _dir|
    world = ClosedWorld.new(ireps: ireps, registry: {}, class_decls: {}, walked: Set.new,
                            native_paths: [], ruby_paths: [])
    block.call(world)
  end
end

# An unrelated name must retain its proof: merely disabling every optimization
# would satisfy the positive assertions while defeating this migration.
{
  'moved visibility' => ['name = :hidden; alias_name = name; private alias_name', %w[hidden]],
  'joined visibility' => ['name = flag ? :left : :right; private name', %w[left right]],
  'loop visibility' => ['name = :left; while flag; name = :right; end; private name', %w[left right]],
  'overwritten visibility' => ['name = :stale; name = :hidden; private name', %w[hidden]],
  'definition visibility' => ['private def hidden; end', %w[hidden]],
  'multiple visibility arguments' => ['a = :left; b = :right; private a, b', %w[left right]],
  'definition result move' => ['name = (def hidden; end); private name', %w[hidden]],
  'handler visibility' => ['name = :left; begin; risky; rescue; name = :right; end; private name', %w[left right]]
}.each do |label, (body, names)|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check(label, names.all? { |name| !world.visibility_stable?(name) } && world.visibility_stable?('unrelated'))
    suite.check('overwritten visibility excludes stale name', world.visibility_stable?('stale')) if label.start_with?('overwritten')
  end
end

{
  'moved removal' => ['name = :hidden; alias_name = name; remove_method alias_name', %w[hidden]],
  'joined removal' => ['name = flag ? :left : :right; undef_method name', %w[left right]],
  'loop removal' => ['name = :left; while flag; name = :right; end; remove_method name', %w[left right]],
  'overwritten removal' => ['name = :stale; name = :hidden; remove_method name', %w[hidden]],
  'forwarded operation join' => ['op = flag ? :remove_method : :ordinary; name = :hidden; send op, name', %w[hidden]],
  'forwarded name join' => ['name = flag ? :left : :right; send :remove_method, name', %w[left right]],
  'adjacent String removal' => ['remove_method "hidden"', %w[hidden]],
  'handler removal' => ['name = :left; begin; risky; rescue; name = :right; end; remove_method name', %w[left right]]
}.each do |label, (body, names)|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check(label, names.all? { |name| world.method_removed?(name) } && !world.method_removed?('unrelated'))
    suite.check('overwritten removal excludes stale name', !world.method_removed?('stale')) if label.start_with?('overwritten')
  end
end

{
  'moved installer' => 'name = :hidden; attr_reader name',
  'joined installer' => 'name = flag ? :hidden : :other; attr_accessor name'
}.each do |label, body|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check(label, world.exact_arm_refusal('hidden', Set.new) == :unknown_definer &&
                       world.exact_arm_refusal('unrelated', Set.new).nil?)
  end
end

[
  'name = flag ? :known : computed; private name',
  'name = :known; begin; risky; rescue; name = computed; end; private name',
  'private uninitialized',
  'name = :known; callback { name = computed }; private name'
].each do |body|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check("unknown visibility: #{body}", !world.visibility_stable?('unrelated'))
  end
end

[
  'name = flag ? :known : computed; remove_method name',
  'name = :known; begin; risky; rescue; name = computed; end; remove_method name',
  'name = flag ? "known" : "other"; remove_method name',
  'name = "known"; name.replace("other"); remove_method name',
  'name = "known"; alias_name = name; alias_name.replace("other"); remove_method name',
  'op = flag ? :remove_method : :send; send op, :known',
  'op = flag ? :remove_method : computed; send op, :known',
  'name = :known; callback { name = computed }; remove_method name'
].each do |body|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check("unknown removal: #{body}", world.method_removed?('unrelated'))
  end
end

# 15+ arguments arrive packed in one ARRAY: the array's only read must be the splat, and each element one Symbol.
packed = (1..15).map { |i| ":p#{i}" }.join(', ')
{
  'moved packed visibility' => "names = [#{packed}]; alias_names = names; private(*alias_names)",
  'adjacent packed visibility' => "private(*[#{packed}])"
}.each do |label, body|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check(label, (1..15).all? { |i| !world.visibility_stable?("p#{i}") } && world.visibility_stable?('unrelated'))
  end
end

[
  "names = [#{packed.sub(':p8', 'flag ? :p8 : :q8')}]; private(*names)",
  "names = [#{packed}]; names << :extra; private(*names)",
  "names = [#{packed}]; private(*names); names << :extra"
].each do |body|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check("unknown packed visibility: #{body[0, 40]}", !world.visibility_stable?('unrelated'))
  end
end

# A probe's name is the value reaching its argument, not a Symbol loaded near it.
{
  'moved probe' => ['name = :hidden; alias_name = name; respond_to? alias_name', %w[hidden]],
  'overwritten probe' => ['name = :stale; name = :hidden; respond_to? name', %w[hidden]],
  'adjacent probe' => ['respond_to?(:hidden)', %w[hidden]]
}.each do |label, (body, names)|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check(label, names.all? { |name| world.probed_name?(name) } && !world.probed_name?('unrelated'))
    suite.check('overwritten probe excludes stale name', !world.probed_name?('stale')) if label.start_with?('overwritten')
  end
end

# A Symbol loaded near a probe but not passed to it is not probed (the window rule's over-approximation).
world_for.call('class Probe; near = :hidden; x = :other; respond_to? x; end') do |world|
  suite.check('a nearby Symbol that is not the probe name stays unprobed', !world.probed_name?('hidden') && world.probed_name?('other'))
end

# More than one possible name at a probe is not a single proven Symbol: every miss is kept.
[
  'name = flag ? :left : :right; method_defined? name',
  'name = :left; while flag; name = :right; end; respond_to? name',
  'name = :left; begin; risky; rescue; name = :right; end; respond_to? name',
  'name = flag ? :known : computed; respond_to? name',
  'name = "known"; respond_to? name',
  'respond_to?',
  'name = :known; callback { name = computed }; method_defined? name'
].each do |body|
  world_for.call("class Probe; #{body}; end") do |world|
    suite.check("unknown probe name makes every miss unprovable: #{body}", world.probed_name?('unrelated'))
  end
end

# Bytecode can re-enter a textually adjacent send without reloading its String.
# Mutating an alias leaves the String's register definition unchanged.
ops = [
  ['STRING', 'R1 L[0]'],
  ['SEND', 'R0 :remove_method n=1'],
  ['MOVE', 'R3 R1'],
  ['SEND', 'R3 :clear n=0'],
  ['JMP', '1']
].each_with_index.map do |(op, args), index|
  Insn.new(lineno: 1, addr: index, op: op, args: args, raw: "#{op} #{args}")
end
body = Irep.new(label: 'backedge', instructions: ops, catch_handlers: [], nregs: 6, nlocals: 1, reps: [], pool: ['known'])
world = ClosedWorld.new(ireps: { body.label => body }, registry: {}, class_decls: {}, walked: Set.new,
                        native_paths: [], ruby_paths: [])
suite.check('a String load adjacent to a re-entered call remains unknown', world.method_removed?('unrelated'))

suite.finish!
