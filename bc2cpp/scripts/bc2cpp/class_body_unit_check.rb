#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_EMIT_GEM (tools/bc2cpp/codegen_class_body.rb, on unless BC2CPP_CLASS_BODY_EMIT=0): the top-level class and module
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

DEFS = <<~'RUBY'
  class Router
    def route(x)
      x
    end

    def self.make
      1
    end
  end
RUBY

suite.compile(DEFS) do |ireps, root|
  body = ireps.values.find { |irep| BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :TDEF } }
  registry = build_registry(ireps, root)[0]
  bare = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  refused = bare.compile_top_class_units(ireps.fetch(root))
  suite.check('a body with kept defs and no compiled entry is refused', refused.empty?)

  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  compiled = BytecodeIR.for(body).each_source.filter_map do |insn, _|
    next unless %i[TDEF SDEF].include?(insn.op)

    label = body.reps[insn.def_child_index]
    method = gen.compile_method(label)
    [label, method.merge(label: label)] if method
  end.to_h
  gen.compiled_methods = compiled
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('the kept instance method is registered on the body class',
              code.match?(/mrb_define_method\(M, mrb_class_ptr\(self\), "(\\x[0-9a-f]{2})+", \w+, MRB_ARGS_REQ\(1\)\);/))
  suite.check('the singleton method is registered on the body singleton class',
              code.match?(/mrb_define_class_method\(M, mrb_class_ptr\(self\), "(\\x[0-9a-f]{2})+", \w+, MRB_ARGS_NONE\(\)\);/))
  suite.check('each def leaves its symbol in its register, as the VM does',
              code.include?('mrb_symbol_value(mrb_intern_cstr(M, "route"))') && code.include?('mrb_symbol_value(mrb_intern_cstr(M, "make"))'))
end

ALIASED = <<~'RUBY'
  class Router
    def route(x)
      x
    end
    alias path route
  end
RUBY

INHERITED = <<~'RUBY'
  class Router
    alias append push
  end
RUBY

suite.compile(ALIASED) do |ireps, root|
  body = ireps.values.find { |irep| BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :TDEF } }
  registry = build_registry(ireps, root)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  gen.compiled_methods = BytecodeIR.for(body).each_source.filter_map do |insn, _|
    next unless insn.op == :TDEF

    label = body.reps[insn.def_child_index]
    method = gen.compile_method(label)
    [label, method.merge(label: label)] if method
  end.to_h
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  alias_line = code.index('mrb_alias_method(M, mrb_class_ptr(self), ')
  define_line = code.index('mrb_define_method(M, mrb_class_ptr(self), ')
  suite.check('an alias of a method the body registered earlier is a call after that registration',
              alias_line && define_line && alias_line > define_line &&
              code.match?(/mrb_alias_method\(M, mrb_class_ptr\(self\), mrb_intern_cstr\(M, "(\\x[0-9a-f]{2})+"\), mrb_intern_cstr\(M, "(\\x[0-9a-f]{2})+"\)\);/))
end

suite.compile(INHERITED) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  suite.check('an alias of a method the body does not register is refused', gen.compile_top_class_units(ireps.fetch(root)).empty?)
end

FROZEN = <<~'RUBY'
  class Router
    attr_reader :x
    LIMIT = [1, 2].freeze
    MAX = 3
  end
RUBY

suite.compile(FROZEN) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('a self send is left to the VM and a literal freeze is a direct freeze',
              code.include?('left to the VM') && code.include?('r1 = mrb_obj_freeze(M, r1);') && !code.include?('owner_call'))
end

suite.compile(DEFS) do |ireps, root|
  body = ireps.values.find { |irep| BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :TDEF } }
  registry = build_registry(ireps, root)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  gen.compiled_methods = BytecodeIR.for(body).each_source.filter_map do |insn, _|
    next unless %i[TDEF SDEF].include?(insn.op)

    label = body.reps[insn.def_child_index]
    method = gen.compile_method(label)
    [label, method.merge(label: label)] if method
  end.to_h
  gen.define_singleton_method(:unregistered_keys) { Set['Router.singleton#make', 'Router#route'] }
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('a def the tables leave out is skipped, not a refusal of its body',
              units.any? && code.include?('left out of the method tables') && !code.include?('mrb_define_class_method(M, mrb_class_ptr(self), "') &&
              !code.include?('mrb_define_method(M, mrb_class_ptr(self), "'))
end

EMPTY_NESTED = <<~'RUBY'
  class Router
    class Problem < StandardError; end
    LIMIT = 3
  end
RUBY

suite.compile(EMPTY_NESTED) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('an empty nested class is created with its superclass, and the body compiles',
              code.include?('mrb_vm_define_class(M, (mrb_nil_p(r') && code.include?('"Problem"') && code.include?('bc2cpp_class_body_Router'))
end

suite.finish!
