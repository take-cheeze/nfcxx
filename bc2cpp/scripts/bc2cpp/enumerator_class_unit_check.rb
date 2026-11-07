#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUMERATOR_CLASS_UNIT: the closed build loads no mrblib bytecode, so `class Enumerator` exists only as the class unit
# of mruby-enumerator's mrblib, and the compiled Enumerator methods register on it. A def of that file the compiler
# cannot express (Enumerator#initialize_copy: an instance_eval block) has no compiled body; it must not refuse the whole
# unit, or no unit creates Enumerator and the core registration's `const_get "Enumerator"` raises NameError at gem init,
# which skipped every later registration (IO.open: "undefined method 'open' for Class" on every scenario and map).
# A def of any other file with no compiled body still refuses its body.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/enumerator_class_unit_check.rb

require 'fileutils'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('enumerator_class_unit_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Enumerator
    LIMIT = 3
    def unsupported_copy(x)
      x
    end
  end
RUBY

units = lambda do |relative|
  Dir.mktmpdir('enumerator-class-unit') do |directory|
    path = File.join(directory, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, SOURCE)
    ireps, root = compile_ireps([path], 'enumerator_class_unit', directory, mrbc: ENV.fetch('MRBC'))
    registry = build_registry(ireps, root)[0]
    CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new).compile_top_class_units(ireps.fetch(root))
  end
end

enumerator = units.call('3rd/mruby/mrbgems/mruby-enumerator/mrblib/enumerator.rb')
code = enumerator.find { |unit| unit[:path] == 'Enumerator' }.to_h[:code].to_s
suite.check('an uncompiled mruby-enumerator def leaves the class unit in place', !code.empty?)
suite.check('the unit still runs the body and registers nothing for that def',
            code.include?('LIMIT') && code.include?('has no compiled body') && !code.include?('"unsupported_copy", '))
suite.check('another file with an uncompiled def still refuses its body', units.call('fixture/other.rb').empty?)
suite.finish!
