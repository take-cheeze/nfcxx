#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative '../../tools/mrbc_rb/mrbc_default.rb'

# CORE_OWN_UNIT: with MRB_CORE_CLASS_UNITS the core's class bodies run only as units. (1) Another gem's reopening of a
# core class (mruby-rgss's `class Array; def sort`) has no compiled method in the core run and refuses there; it must
# not drop the core's own Array unit (`include Enumerable`). (2) FOREIGN_CORE_UNITS: the core file kept out of the
# compiled world (10error.rb) still runs, as units of its attr_* calls, its defs registered by their program redefinition.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/core_own_unit_check.rb

require 'fileutils'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('core_own_unit_check')
suite.require_mrbc!

CORE = <<~'RUBY'
  class Array
    def own_each
      self
    end
    LIMIT = 3
  end
RUBY

GEM = <<~'RUBY'
  class Array
    def gem_sort
      self
    end
  end
RUBY

units = lambda do |own_file|
  Dir.mktmpdir('core-own-unit') do |directory|
    paths = { '3rd/mruby/mrblib/array.rb' => CORE, 'mruby-rgss/mrblib/array_sort.rb' => GEM }
    files = paths.map do |relative, source|
      path = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      path
    end
    ireps, root = compile_ireps(files, 'core_own_unit', directory, mrbc: MrbcRbDefault.from_env)
    registry = build_registry(ireps, root)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    # The core run compiles the core def; the gem's def is compiled in the gem's own run.
    core = registry.fetch('own_each').find(&:irep)
    gen.compiled_methods = { core.irep => { owner: 'Array', name: 'own_each', entry: 'Array_own_each',
                                            aspec: 'MRB_ARGS_NONE()', visibility: :public } }
    gen.compile_top_class_units(ireps.fetch(root), own_file: own_file)
  end
end

core_run = units.call(bc2cpp_own_unit_file('core_compiled', '/mruby-core/mrblib/'))
core_unit = core_run.find { |unit| unit[:path] == 'Array' && unit[:file].to_s.include?('/3rd/mruby/mrblib/') }
code = core_unit.to_h[:code].to_s
suite.check("another gem's refused reopening leaves the core's own unit", code.include?('LIMIT') && code.include?('Array_own_each'))
suite.check("the other gem's reopening is not emitted by the core run", core_run.count { |unit| unit[:path] == 'Array' } == 1)
suite.check('a refused own occurrence still drops the path', units.call(nil).none? { |unit| unit[:path] == 'Array' })
rgss_own = bc2cpp_own_unit_file('rgss_compiled', '/mruby-rgss/mrblib/')
suite.check("an engine gem's own files are its mrblib only",
            rgss_own.call('/w/mruby-rgss/mrblib/a.rb') && !rgss_own.call('/w/3rd/mruby/mrblib/array.rb'))
suite.check('a run that is no shipped gem counts every file', bc2cpp_own_unit_file('probe', '/mruby-probe/mrblib/').nil?)

ERRORS = <<~'RUBY'
  class NameError < StandardError
    attr_accessor :name
    def initialize(message = nil, name = nil)
      @name = name
      super(message)
    end
  end

  class Unredefined < StandardError
    def other
    end
  end
RUBY

foreign = Dir.mktmpdir('foreign-core-units') do |directory|
  path = File.join(directory, '10error.rb')
  File.write(path, ERRORS)
  ForeignCoreUnits.units([path], ->(owner, name) { owner == 'NameError' && name == 'initialize' })
end
name_error = foreign.find { |unit| unit[:path] == 'NameError' }.to_h[:code].to_s
suite.check('an excluded core class becomes a unit under its superclass',
            name_error.include?('"StandardError"') && name_error.include?('mrb_vm_define_class('))
suite.check('its attr_accessor is defined by the unit',
            name_error.include?('bc2cpp_mod_attr(M, self, true, true, {mrb_symbol_value(mrb_intern_cstr(M, "name"))})'))
suite.check('a def a program file redefines registers nothing there', name_error.include?('registered by its program definition'))
suite.check('a def nothing redefines leaves its class out', foreign.none? { |unit| unit[:path] == 'Unredefined' })
suite.check("the world's excluded core file is 10error.rb",
            ForeignCoreUnits.files(BC2CPP_WORLD_ROOT).map { |p| File.basename(p) } == %w[10error.rb])
suite.finish!
