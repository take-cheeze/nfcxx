#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_EMIT_GEM (tools/bc2cpp/codegen_class_body.rb, on unless BC2CPP_CLASS_BODY_EMIT=0): the top-level class and module
# units of a gem's root body. A class with a nil superclass and a module compile to a function that creates the class
# the way vm.c does and calls the body; a class with a named superclass, or a path opened twice, is left out. gem_init
# calls the units after the owner-class reset and before the registrations. TOP_LEVEL_RETURN: a top-level return ends
# the compiled statements as it ends the VM's run, and a class opened after one stops generation. Needs MRBC and g++;
# without MRBC it prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_body_unit_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'open3'
require 'set'
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = BC2CPP_WORLD_ROOT
suite = FixtureCheck.new('class_body_unit_check')
suite.require_mrbc!

UNITS = <<~'RUBY'
  class Router
    LIMIT = 3
  end
  module Mod
    NAME = 1
    LOW = -7
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
  suite.check('the module, the nil-superclass class and the named-superclass class each compile to a unit',
              paths.sort == %w[Mod Router Sub])
  router = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('a class unit creates the class over the Object base and calls its body',
              router.include?('static void bc2cpp_top_unit_Router_0(mrb_state* M)') &&
              router.include?('(void)mrb_vm_define_class(M, mrb_obj_value(M->object_class), mrb_nil_value(), mrb_intern_cstr(M, "Router"));') &&
              router.include?('(void)bc2cpp_class_body_Router_0(M);'))
  mod = units.find { |unit| unit[:path] == 'Mod' }.to_h[:code].to_s
  suite.check('a negative Integer constant (LOADINEG) compiles in a body', mod.include?('mrb_fixnum_value(-7)'))
  suite.check('a module unit creates the module and calls its body',
              mod.include?('(void)mrb_vm_define_module(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Mod"));') &&
              mod.include?('(void)bc2cpp_class_body_Mod_0(M);'))
  hooks = gen.emit_gem_hooks(class_units: units)
  suite.check('gem_init calls each unit after the owner-class reset and before the registrations',
              hooks.index('bc2cpp_top_unit_Router_0(M);') > hooks.index('bc2cpp_reset_owner_classes();') &&
              hooks.index('bc2cpp_top_unit_Router_0(M);') < hooks.index('bc2cpp_set_instance_tts(M);') &&
              hooks.include?('bc2cpp_top_unit_Mod_0(M);'))
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
  twice = gen.compile_top_class_units(ireps.fetch(root))
  suite.check('a path opened twice gets one unit per occurrence, each under its own name',
              twice.map { |u| u[:name] }.sort == %w[Router_0 Router_1])
end

# A constant built by a no-argument send: GETCONST Object then SEND0 :new, as core Enumerable's `NONE = Object.new`.
SEND0 = <<~'RUBY'
  module Sent
    NONE = Object.new
  end
RUBY

suite.compile(SEND0) do |ireps, root|
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = gen.compile_top_class_units(ireps.fetch(root)).find { |unit| unit[:path] == 'Sent' }.to_h[:code].to_s
  suite.check('a no-argument send compiles as the same plain funcall a send makes',
              code.match?(/mrb_funcall\(M, r\d+, "new", 0\)/))
  suite.check('the no-argument send sets the constant it built', code.include?('mrb_const_set('))
end

# CLASS_BODY_ALIAS_METHOD: `alias_method :new, :old` of a native method (mruby-io's `alias_method :eof, :eof?`) is
# Module#alias_method's own body in the unit, not a by-name send.
ALIASES = <<~'RUBY'
  class Aliaser
    alias_method :name_text, :to_s
  end
RUBY

suite.compile(ALIASES) do |ireps, root|
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Aliaser' }.to_h[:code].to_s
  suite.check('an alias_method of a native method is mrb_alias_method and the method_added hook, no by-name send',
              code.include?('mrb_alias_method(M, mrb_class_ptr(self), ') &&
              code.include?('mrb_method_added(M, mrb_class_ptr(self), ') &&
              code.include?(CodeGen.new({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new).c_string_literal('name_text')) &&
              !code.include?('bc2cpp_ssend'))
  headers = %w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h]
  unit = +"#{headers.map { |h| "#include <#{h}>\n" }.join}#{CodeGen::CLASS_UNIT_DECLS}#{gen.emit_owner_class_cache}"
  unit << units.map { |u| u[:code] }.join
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_alias_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the alias unit compiles with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
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
  AliasSites.settle(registry, ireps, closed: false, method_trusted: false)
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
  registry = build_registry(ireps, root)[0]
  # closed: false drops every alias site, so the unit decides each alias itself.
  AliasSites.settle(registry, ireps, closed: false, method_trusted: false)
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = gen.compile_top_class_units(ireps.fetch(root)).find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('an alias of a native method is copied in the unit: the native exists before any gem_init runs',
              code.match?(/mrb_alias_method\(M, mrb_class_ptr\(self\), mrb_intern_cstr\(M, "(\\x[0-9a-f]{2})+"\), mrb_intern_cstr\(M, "(\\x[0-9a-f]{2})+"\)\);/))
end

# A Ruby method the gem registers after the units is not there when a unit runs, so an alias of it is refused.
RUBY_OLD = <<~'RUBY'
  class Base
    def helper
    end
  end
  class Router < Base
    alias again helper
  end
RUBY

suite.compile(RUBY_OLD) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  AliasSites.settle(registry, ireps, closed: false, method_trusted: false)
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  suite.check('an alias of a Ruby method is refused, since the gem registers that method after the units',
              gen.compile_top_class_units(ireps.fetch(root)).find { |unit| unit[:path] == 'Router' }.nil?)
end

# An alias the settled registry defines is handled by the bytecode IR: the body compiles with no alias call in the unit.
suite.compile(INHERITED) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  AliasSites.settle(registry, ireps, closed: true, method_trusted: true)
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = gen.compile_top_class_units(ireps.fetch(root)).find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('an alias the registry settles is skipped in the unit, not refused',
              code.include?('alias handled by the bytecode IR') && !code.include?('mrb_alias_method('))
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
  suite.check('attr_reader is a direct helper call on self and a literal freeze is a direct freeze',
              code.include?('bc2cpp_mod_attr(M, self, true, false, {') && !code.include?('left to the VM') &&
              code.include?('r1 = mrb_obj_freeze(M, r1);') && !code.include?('owner_call'))
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
              units.any? && (code.include?('left out of the method tables') || code.include?('statically dispatched only')) && !code.include?('mrb_define_class_method(M, mrb_class_ptr(self), "') &&
              !code.include?('mrb_define_method(M, mrb_class_ptr(self), "'))
end

EMPTY_NESTED = <<~'RUBY'
  class Router
    class Problem; end
    LIMIT = 3
  end
RUBY

NAMED_SUPER = <<~'RUBY'
  class Router
    class Problem < StandardError; end
  end
RUBY

suite.compile(EMPTY_NESTED) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('an empty nested class with no superclass is created, and the body compiles',
              code.include?('mrb_vm_define_class(M, (mrb_nil_p(r') && code.include?('"Problem"') && code.include?('bc2cpp_class_body_Router'))
end

suite.compile(NAMED_SUPER) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = gen.compile_top_class_units(ireps.fetch(root)).find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  suite.check('a nested class with a named superclass is created with that superclass',
              code.include?('mrb_vm_define_class(M, (mrb_nil_p(r') && code.include?('"Problem"'))
end

# A gem's gem_init runs only the units of the owners it emits (owned_class_units), so core never runs RPG2k's body.
suite.compile(UNITS) do |ireps, root|
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  suite.check('a run for every owner keeps every unit', gen.owned_class_units(units, nil).map { |u| u[:path] }.sort == %w[Mod Router Sub])
  suite.check('an owner nested under a unit path keeps that unit',
              gen.owned_class_units(units, ['Router::Inner']).map { |u| u[:path] } == %w[Router])
  suite.check('a singleton owner keeps its class unit', gen.owned_class_units(units, ['Router.singleton']).map { |u| u[:path] } == %w[Router])
  suite.check('a gem whose owners are elsewhere gets no unit of this class', gen.owned_class_units(units, ['Other']).empty?)
  suite.check('a name that only shares a prefix is not an owner of the unit',
              gen.owned_class_units(units, ['RouterX']).empty?)
end

# An explicit-receiver send with no arguments (SEND0) refuses its body: a unit's plain mrb_funcall would be a dynamic
# lookup by name, which keeps that name in the method table. A `freeze` on the register is still a direct call.
LITERAL_LENGTH = <<~'RUBY'
  class Router
    N = "ab".length
  end
RUBY

RANGE_TO_A = <<~'RUBY'
  class Router
    R = (1..2).to_a
  end
RUBY

# A `length` on a String literal folds to the literal's count: the byte count without MRB_UTF8_STRING, the character
# count with it (the preprocessor picks the arm). "ab" is two of both, so the fold is checked on a non-ASCII literal too.
LITERAL_LENGTH_UTF8 = <<~'RUBY'
  class Router
    N = "あb".length
  end
RUBY

suite.compile(LITERAL_LENGTH) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  suite.check('a length on a String literal folds into the unit (no dynamic send)',
              units.map { |unit| unit[:path] } == %w[Router] && units.first[:code].include?('mrb_int_value(M, 2);') &&
              !units.first[:code].include?('"length"'))
end

suite.compile(LITERAL_LENGTH_UTF8) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = gen.compile_top_class_units(ireps.fetch(root)).first&.dig(:code).to_s
  suite.check('a length on a non-ASCII literal folds to both the byte and the character count',
              code.include?('#ifdef MRB_UTF8_STRING') && code.include?('mrb_int_value(M, 2);') &&
              code.include?('mrb_int_value(M, 4);'))
end

suite.compile(RANGE_TO_A) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  # The fixture has no core sources, so Range#to_a has no compiled body here and the send keeps mrb_funcall; the closed
  # build (core registered) takes the direct call.
  suite.check('a Range literal to_a compiles in the unit (direct when the core body is registered)',
              gen.compile_top_class_units(ireps.fetch(root)).map { |unit| unit[:path] } == %w[Router])
end

# UNIT_TAG: a body that opens one class path twice (`module G; class A; end; class A; end; end`, and the same one level
# deeper) gives each opening its own function. The VM-free run (no bytecode loaded) builds every class from the units, so
# the compiled run equals the interpreted one only when both openings ran.
REOPEN_NESTED = <<~'RUBY'
  module CbuG
    class Actor
      A = 1
      def a = A
    end
    class Actor
      B = 2
      def b = B
    end
  end
  module CbuTop
    module Mid
      class Leaf
        P = 3
      end
    end
    module Mid
      class Leaf
        Q = 4
      end
    end
  end
RUBY
REOPEN_OWNERS = %w[CbuG CbuG::Actor CbuTop CbuTop::Mid CbuTop::Mid::Leaf].freeze

Dir.mktmpdir('bc2cpp-class-body-reopen') do |dir|
  # The fixture is its own closed world: the repository signatures name classes it lacks.
  saved = %w[BC2CPP_VM_FREE BC2CPP_SIG_DIRS].to_h { |k| [k, ENV[k]] }
  ENV['BC2CPP_VM_FREE'] = '1'
  ENV['BC2CPP_SIG_DIRS'] = ''
  code, err = begin
    Bc2cppFixtureRuntime.generate(REOPEN_NESTED, dir, core: true, only_owners: REOPEN_OWNERS)
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
  bodies = code.scan(/^static mrb_value (bc2cpp_class_body_(?:CbuG__Actor|CbuTop__Mid__Leaf)\w*)\(/).flatten
  suite.check("UNIT_TAG: each opening of a reopened nested path is its own function (#{bodies.inspect})",
              bodies.size == 4 && bodies.uniq.size == 4)
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP reopened class body behaviour: needs a full-core libmruby'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value actor = mrb_obj_new(M, mrb_class_get_under(M, mrb_module_get(M, "CbuG"), "Actor"), 0, nullptr);
        call(M, "a", actor, "a");
        call(M, "b", actor, "b");
        mrb_value leaf = mrb_obj_value(mrb_class_get_under(M, mrb_module_get_under(M, mrb_module_get(M, "CbuTop"), "Mid"), "Leaf"));
        show(M, "P", mrb_const_get(M, leaf, mrb_intern_lit(M, "P")));
        show(M, "Q", mrb_const_get(M, leaf, mrb_intern_lit(M, "Q")));
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, REOPEN_OWNERS, scenario, build: build, full: true, compiled_load: false)
    suite.check('UNIT_TAG: the reopened bodies build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('UNIT_TAG: the interpreter sees both openings', interpreted == ['a => 1', 'b => 2', 'P => 3', 'Q => 4'])
    suite.check('UNIT_TAG: interpreted and compiled runs print the same', interpreted == compiled)
    interpreted.zip(compiled).reject { |a, b| a == b }.each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    puts output.lines.last(15).join unless built
  end
end

# TOP_LEVEL_RETURN (compile_top_level_statements): a top-level `return` ends the file in the VM, so the compiled
# statements stop there too; a class opened after one is refused, since its unit would run before the return.
TOP_RETURN = <<~'RUBY'
  class TrProbe
    def b = TR_B
  end
  TR_A = 1
  return if TR_A == 2
  TR_B = 2
  TR_C = TR_B + 1
  return if TR_C == 3
  TR_D = 4
RUBY

TOP_RETURN_CLASS = <<~'RUBY'
  TR_A = 1
  return if TR_A == 1
  class TrLate
    X = 1
  end
RUBY

suite.compile(TOP_RETURN) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code = gen.compile_top_level_statements(ireps.fetch(root))
  suite.check('TOP_LEVEL_RETURN: a top-level return ends the statements function (no value return in it)',
              code.scan('return;').size == 2 && !code.include?('return mrb_'))
end

suite.compile(TOP_RETURN_CLASS) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  raised = begin
    gen.compile_top_class_units(ireps.fetch(root))
    nil
  rescue RuntimeError => e
    e.message
  end
  suite.check('TOP_LEVEL_RETURN: a class opened after a top-level return stops generation',
              raised.to_s.start_with?('TOP_LEVEL_RETURN: TrLate'))
end

Dir.mktmpdir('bc2cpp-top-level-return') do |dir|
  saved = %w[BC2CPP_VM_FREE BC2CPP_SIG_DIRS].to_h { |k| [k, ENV[k]] }
  ENV['BC2CPP_VM_FREE'] = '1'
  ENV['BC2CPP_SIG_DIRS'] = ''
  code, err = begin
    Bc2cppFixtureRuntime.generate(TOP_RETURN, dir, core: true, only_owners: %w[TrProbe])
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
  suite.check('TOP_LEVEL_RETURN: the gem runs the top-level statements', code.include?('bc2cpp_top_level_statements(M);'))
  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP top-level return behaviour: needs a full-core libmruby'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value top = mrb_obj_value(M->object_class);
        for (const char* name : {"TR_A", "TR_B", "TR_C", "TR_D"}) {
          mrb_sym sym = mrb_intern_cstr(M, name);
          if (mrb_const_defined(M, top, sym)) show(M, name, mrb_const_get(M, top, sym));
          else std::printf("%s => undefined\\n", name);
        }
        call(M, "b", mrb_obj_new(M, mrb_class_get(M, "TrProbe"), 0, nullptr), "b");
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, %w[TrProbe], scenario, build: build, full: true, compiled_load: false)
    suite.check('TOP_LEVEL_RETURN: the fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('TOP_LEVEL_RETURN: the interpreter stops at the taken return',
                interpreted == ['TR_A => 1', 'TR_B => 2', 'TR_C => 3', 'TR_D => undefined', 'b => 2'])
    suite.check('TOP_LEVEL_RETURN: interpreted and compiled runs print the same', built && interpreted == compiled)
    interpreted.zip(compiled).reject { |a, b| a == b }.each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    puts output.lines.last(15).join unless built
  end
end

suite.finish!
