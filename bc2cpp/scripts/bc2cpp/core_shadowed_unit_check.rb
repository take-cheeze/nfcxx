#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative '../../tools/mrbc_rb/mrbc_default.rb'

# CORE_SHADOWED_UNIT: with MRB_CORE_CLASS_UNITS the closed build runs a core class body only as its class unit. A core
# def a later definition replaces (mruby-enum-ext's Enumerable#all?) registers nothing in the unit, but must not refuse
# it: the body's other statements (`NONE = Object.new`, `include Enumerable`) run nowhere else, and a refused path drops
# every unit of that class. A def with no compiled body and no native method still refuses its body.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/core_shadowed_unit_check.rb

require 'fileutils'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('core_shadowed_unit_check')
suite.require_mrbc!

CORE = <<~'RUBY'
  module Enumerable
    NONE = Object.new
    def all?
      true
    end
  end
RUBY

EXT = <<~'RUBY'
  module Enumerable
    def all?(pat = NONE)
      pat
    end
  end
RUBY

UNCOMPILED = <<~'RUBY'
  module Enumerable
    NONE = Object.new
    def none_compiled?
      true
    end
  end
RUBY

units = lambda do |core_source|
  Dir.mktmpdir('core-shadowed-unit') do |directory|
    paths = { '3rd/mruby/mrblib/enum.rb' => core_source, '3rd/mruby/mrbgems/mruby-enum-ext/mrblib/enum.rb' => EXT }
    files = paths.map do |relative, source|
      path = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      path
    end
    ireps, root = compile_ireps(files, 'core_shadowed_unit', directory, mrbc: MrbcRbDefault.from_env)
    registry = build_registry(ireps, root)[0]
    shadowed_before = CodeGen.shadowed_labels
    CodeGen.shadowed_labels = CoreDefs.shadowed_labels(registry, ireps)
    begin
      gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
      # The replacing def is the gem's compiled method; the core one has none (it is shadowed).
      later = registry.fetch('all?').select { |d| d.owner == 'Enumerable' && d.irep }.last
      gen.compiled_methods = { later.irep => { owner: 'Enumerable', name: 'all?', entry: 'Enumerable_all$3f',
                                               aspec: 'MRB_ARGS_OPT(1)', visibility: :public } }
      gen.compile_top_class_units(ireps.fetch(root))
    ensure
      CodeGen.shadowed_labels = shadowed_before
    end
  end
end

shadowed = units.call(CORE)
core_unit = shadowed.find { |unit| unit[:path] == 'Enumerable' && unit[:file].to_s.include?('/3rd/mruby/mrblib/') }
code = core_unit.to_h[:code].to_s
suite.check('a core body whose def is shadowed still compiles to a unit', !code.empty?)
suite.check('the unit still binds its constant', code.include?('NONE'))
suite.check('the shadowed def registers nothing in the core unit',
            code.include?('CORE_SHADOWED') && !code.include?('Enumerable_all$3f'))
suite.check('the replacing definition keeps its own unit',
            shadowed.count { |unit| unit[:path] == 'Enumerable' } == 2)
suite.check('a core def with no compiled body still refuses the path', units.call(UNCOMPILED).none? { |unit| unit[:path] == 'Enumerable' })
suite.finish!
