#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks scripts/bc2cpp/base_rbs.rb: a superclass named in a class body is resolved the way Ruby resolves it (innermost
# enclosing namespace first), so the stub's `class X < Y` means the same class in RBS. Also checks the native
# textual scanner's body boundaries and core-owner matches. Host only, a few seconds.
#
#   ruby scripts/bc2cpp/base_rbs_check.rb

require 'rbs'
require 'tmpdir'
require_relative 'base_rbs' unless defined?(BaseRbs)

ROOT = File.expand_path('../..', __dir__)
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~RUBY
  module RPG
    class BaseItem; end
    class Actor < BaseItem; end
    class Armor < ::RPG::BaseItem; end
  end
  module RPG2k
    module Scene
      class Base; end
      class Battle < Base; end
      class Map < ::RPG::Actor; end
      class Menu < Helper; end
    end
    class Scene::Title < Scene::Base; end
  end
  class Standalone < File; end
  class Plain < Object; end
  class Implicit; end
RUBY

require_relative 'base_rbs_native'

puts '== native textual scanning'
body = "{ if (true) { return mrb_fixnum_value(1); } return mrb_nil_value(); }"
text = "void before() {}\nmrb_value result() #{body}\nvoid after() {}"
check.call('nested bodies stop before the following function', BaseRbsNative.function_body_of(text, 'result') == body)
check.call('a missing function has no body', BaseRbsNative.function_body_of(text, 'missing').nil?)
check.call('a prototype has no body', BaseRbsNative.function_body_of('mrb_value result();', 'result').nil?)
check.call('an unterminated body stays empty', BaseRbsNative.function_body_of('mrb_value result() { if (true) { }', 'result') == '')
check.call('a nonidentifier function is refused', BaseRbsNative.function_body_of(text, 'result()').nil?)
unicode_body = "{ /* 日本語 */ if (true) { return mrb_nil_value(); } }"
unicode = "// café 日本語\nmrb_value result() #{unicode_body}\nvoid next() {}"
check.call('Unicode before and inside the body preserves character offsets',
           BaseRbsNative.function_body_of(unicode, 'result') == unicode_body)
large_body = "{ /* #{'nonbrace ' * 20_000} */ { return mrb_nil_value(); } }"
check.call('a long body retains every character', BaseRbsNative.function_body_of("mrb_value result() #{large_body}", 'result') == large_body)

# Reference semantics count every textual brace, including braces in strings and comments.
reference_body = lambda do |source, open|
  depth = 0
  result = ''
  (open...source.length).each do |i|
    depth += 1 if source[i] == '{'
    depth -= 1 if source[i] == '}'
    if depth.zero?
      result = source[open..i]
      break
    end
  end
  result
end
rng = Random.new(20_261_018)
pieces = ['{', '}', 'x', ' ', "\n", 'é', '日本語', '"{"', '/* } */', '\\']
same = 500.times.all? do
  prefix = ['é', '日本語', 'x'].sample(random: rng)
  source = prefix + '{' + Array.new(rng.rand(0..80)) { pieces.sample(random: rng) }.join
  BaseRbsNative.function_body(source, prefix.length) == reference_body.call(source, prefix.length)
end
check.call('500 random bodies retain the previous textual brace semantics', same)

owner_assignments = [
  'krn = mrb->kernel_module;', 'integer = M->fixnum_class;',
  'long_identifier = mrb->object_class;', 'prefixkrn = M->kernel_module;',
  'x = mrb->string_class ;', 'x == mrb->string_class;',
  'x = mrb->string_class_extra;', 'x = other->string_class;', 'x = mrb->string_class'
]
owner_same = 500.times.all? do
  source = Array.new(rng.rand(1..15)) { owner_assignments.sample(random: rng) }.join("\n")
  source.scan(/(\w+)\s*=\s*((?:M|mrb)->\w+_(?:class|module))\s*;/) ==
    source.scan(/(?<!\w)(\w+)\s*=\s*((?:M|mrb)->\w+_(?:class|module))\s*;/)
end
check.call('500 mixed assignment texts preserve core-owner matches', owner_same)
source = <<~CPP
  krn = mrb->kernel_module;
  mrb_value count(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value(1); }
  mrb_define_method(mrb, krn, "count", count, 0);
CPP
kinds, supers, methods, skipped = BaseRbsNative.scan(source)
check.call('core-owner assignments still attach method signatures',
           kinds.empty? && supers.empty? && methods == [['Kernel', false, 'count', '() -> Integer']] && skipped.empty?)

puts '== superclass resolution'
Dir.mktmpdir('base-rbs-check') do |dir|
  src = File.join(dir, 'fixture.rb')
  File.write(src, FIXTURE)
  out = File.join(dir, 'out')
  files, = BaseRbs.run(out, [src])
  text = files.to_h { |path| [File.basename(path), File.read(path)] }
  lines = text.values.join.lines.map(&:strip)

  check.call('a sibling superclass resolves inside its namespace (RPG::Actor < RPG::BaseItem)',
             lines.include?('class RPG::Actor < RPG::BaseItem'))
  check.call('an absolute superclass is written as its full name (RPG::Armor < RPG::BaseItem)',
             lines.include?('class RPG::Armor < RPG::BaseItem'))
  check.call('a superclass in an inner namespace resolves to the outer one (RPG2k::Scene::Battle < RPG2k::Scene::Base)',
             lines.include?('class RPG2k::Scene::Battle < RPG2k::Scene::Base'))
  check.call('an absolute superclass defined elsewhere keeps its full name (RPG2k::Scene::Map < RPG::Actor)',
             lines.include?('class RPG2k::Scene::Map < RPG::Actor'))
  check.call('a compact nested name resolves from the enclosing namespace (RPG2k::Scene::Title < RPG2k::Scene::Base)',
             lines.include?('class RPG2k::Scene::Title < RPG2k::Scene::Base'))
  check.call('a name the sources do not define is written as it is (Standalone < File)',
             lines.include?('class Standalone < File'))
  check.call('an undefined name inside a namespace stays as written (RPG2k::Scene::Menu < Helper)',
             lines.include?('class RPG2k::Scene::Menu < Helper'))
  check.call('an explicit Object superclass is left out, as a class with none is (Plain, Implicit)',
             lines.include?('class Plain') && lines.include?('class Implicit') && lines.none? { |l| l.end_with?('< Object') })

  puts '== the output parses as RBS'
  text.each do |name, content|
    RBS::Parser.parse_signature(RBS::Buffer.new(name: name, content: content))
    check.call("#{name} parses", true)
  end
end


if failures.empty?
  puts "base rbs check: #{checks} checks passed"
else
  abort "base rbs check: #{failures.size} failure(s)"
end
