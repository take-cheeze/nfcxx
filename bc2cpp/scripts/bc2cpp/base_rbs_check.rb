#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks scripts/bc2cpp/base_rbs.rb: a superclass named in a class body is resolved the way Ruby resolves it (innermost
# enclosing namespace first), so the stub's `class X < Y` means the same class in RBS. Host only, a few seconds.
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
