# frozen_string_literal: true

# Fixture checks for ADR 0402: a compact class definition (`class Outer::Name`)
# is named by its resolved outer constant, and only an unresolvable one keeps the
# closed-world refusal.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/compact_class_check.rb
#
# Exits non-zero on the first failure. Each fixture is compiled as a closed world
# of the wio gems, the same way scripts/bc2cpp/nomethod_reviewed_check.rb does.
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
mrbc = ENV['MRBC'] || 'mrbc'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

$failures = 0
def check(name, cond)
  if cond
    puts "  ok   #{name}"
  else
    $failures += 1
    puts "  FAIL #{name}"
  end
end

gems_env = Shellwords.join(NomethodReviewedProbe.wio_gems(root).map { |n, d| "#{n}=#{d}" })

# A top-level compact definition: its outer `Cw` is a global name.
TOP_LEVEL = <<~'RUBY'
  module Cw
    class Pet
      def speak; 1; end
    end
  end
  class Cw::Robot < Cw::Pet
    def speak; 2; end
  end
  class Cw::Caller
    def talk(x); x.speak; end
  end
RUBY

# A namespaced compact definition whose outer module is declared earlier in the file.
NAMESPACED = <<~'RUBY'
  module Outer
    module Inner
      def self.tag; 0; end
    end
    class Inner::Thing
      def go; 3; end
    end
    class Caller2
      def run(x); x.go; end
    end
  end
RUBY

# A namespaced compact definition whose outer module is not declared in this file:
# it must still be refused.
UNRESOLVED = <<~'RUBY'
  module M
    class Other::Thing
      def go; 5; end
    end
  end
RUBY

def compile(root, mrbc, gems_env, source)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'cc_fixture.rb')
    File.write(path, source)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'cc_fixture', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio', 'BC2CPP_BUILD_GEMS' => gems_env }
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), path)
    [out, err, status]
  end
end

REFUSAL = 'global refusal: qualified_class_definition'

puts '== compact class outer resolution (ADR 0402)'
_out, err, status = compile(root, mrbc, gems_env, TOP_LEVEL)
check('a top-level compact class generates (exit 0)', status.success?)
check('no qualified-class refusal for a resolvable top-level compact class', !err.include?(REFUSAL))
check('the compact class is named Cw::Caller, not Caller', err.include?('Cw::Caller#talk'))

_out, err, status = compile(root, mrbc, gems_env, NAMESPACED)
check('a namespaced compact class generates (exit 0)', status.success?)
check('no qualified-class refusal for a namespaced compact class declared earlier', !err.include?(REFUSAL))
check('the compact class is named Outer::Inner::Thing', err.include?('Outer::Inner::Thing#go'))
check('the method beside it is named Outer::Caller2', err.include?('Outer::Caller2#run'))

_out, err, _status = compile(root, mrbc, gems_env, UNRESOLVED)
check('an unresolved namespaced compact class keeps the refusal', err.include?(REFUSAL))

exit 1 if $failures.positive?
puts 'bc2cpp_compact_class_check: ok'
