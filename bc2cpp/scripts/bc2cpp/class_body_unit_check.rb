#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_EMIT_GEM (tools/bc2cpp/codegen_class_body.rb, BC2CPP_CLASS_BODY_EMIT=1): the top-level class and module
# units of a gem's root body. A class with a nil superclass and a module compile to a function that creates the class
# the way vm.c does and calls the body; a class with a named superclass, or a path opened twice, is left out. gem_init
# calls the units after the owner-class reset and before the registrations. Needs MRBC and g++; without MRBC it prints
# SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_body_unit_check.rb

require 'open3'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('class_body_unit_check')
suite.require_mrbc!

UNITS = <<~'RUBY'
  class Router
    LIMIT = 3
  end
  module Mod
    NAME = 1
  end
  class Sub < Object
    Y = 2
  end
RUBY

TWICE = <<~'RUBY'
  class Router
    LIMIT = 3
  end
  class Router
    MAX = 9
  end
RUBY

suite.compile(UNITS) do |ireps, root|
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  paths = units.map { |unit| unit[:path] }
  suite.check('the class with a nil superclass and the module compile; the named superclass is left out',
              paths.sort == %w[Mod Router])
  router = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('a class unit creates the class over the Object base and calls its body',
              router.include?('static void bc2cpp_top_unit_Router(mrb_state* M)') &&
              router.include?('(void)mrb_vm_define_class(M, mrb_obj_value(M->object_class), mrb_nil_value(), mrb_intern_cstr(M, "Router"));') &&
              router.include?('(void)bc2cpp_class_body_Router(M);'))
  mod = units.find { |unit| unit[:path] == 'Mod' }.to_h[:code].to_s
  suite.check('a module unit creates the module and calls its body',
              mod.include?('(void)mrb_vm_define_module(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Mod"));') &&
              mod.include?('(void)bc2cpp_class_body_Mod(M);'))
  hooks = gen.emit_gem_hooks(class_units: units)
  suite.check('gem_init calls each unit after the owner-class reset and before the registrations',
              hooks.index('bc2cpp_top_unit_Router(M);') > hooks.index('bc2cpp_reset_owner_classes();') &&
              hooks.index('bc2cpp_top_unit_Router(M);') < hooks.index('bc2cpp_set_instance_tts(M);') &&
              hooks.include?('bc2cpp_top_unit_Mod(M);'))
  suite.check('no unit means no call', !gen.emit_gem_hooks(class_units: []).include?('bc2cpp_top_unit_'))

  headers = %w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h]
  unit = +"#{headers.map { |h| "#include <#{h}>\n" }.join}#{gen.emit_owner_class_cache}"
  unit << units.map { |u| u[:code] }.join
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_unit_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the emitted units compile with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
end

suite.compile(TWICE) do |ireps, root|
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  suite.check('a path opened twice gets no unit', gen.compile_top_class_units(ireps.fetch(root)).empty?)
end

suite.finish!
