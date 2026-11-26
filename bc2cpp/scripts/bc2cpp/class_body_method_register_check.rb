#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_REGISTER (prototype): a kept method a class body defines (its TDEF) is compiled by the method compiler,
# and its registration call (the one emit_owner_registration_lines makes) names the compiled entry and aspec.
# ROM_CLASS_BODY_DEFS (codegen_class_body.rb): with ROM_METHOD_TABLES, a unit's def or attr_* accessor its owner's ROM
# table holds installs that table in place of a registration, once per function, class and owner, and a verify build
# (BC2CPP_UNREGISTERED_VERIFY) checks the install gives the function and visibility the call would have; anything else
# keeps its call, and BC2CPP_ROM_CLASS_BODY_DEFS=0 keeps every call. Needs MRBC.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_body_method_register_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = BC2CPP_WORLD_ROOT
suite = FixtureCheck.new('class_body_method_register_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Foo
    def add(a, b)
      a + b
    end
  end
RUBY

suite.compile(SOURCE) do |ireps, root|
  registry = build_registry(ireps, root)[0]
  body = ireps.values.find { |irep| BytecodeIR.class_bodies(irep, :CLASS, :MODULE, :SCLASS).empty? && BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :TDEF } }
  tdef = BytecodeIR.for(body).each_source.find { |insn, _| insn.op == :TDEF }.first
  child = body.reps[tdef.def_child_index]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code, define = gen.class_body_method_registration('Foo', child)
  suite.check('a kept method compiles and gets a registration call', code && define&.match?(/mrb_define_method\(M, bc2cpp_owner_reg, .*, Foo_add, MRB_ARGS_REQ\(2\)\);/))
  # The method's C++ needs the gem's own prelude (fixnum helpers, owner class helpers) to compile, so it is checked
  # on the generated gem output (the integration step), not in this unit.
end


ROUTER = <<~'RUBY'
  class Router
    def each
      1
    end

    def size
      2
    end

    private

    def hidden
      3
    end
  end
RUBY

# The unit text and the registration text of ROUTER's class, with the ROM_DEF sites resolved as bc2cpp.rb does.
def router_texts(ireps, root, drop: nil)
  registry = build_registry(ireps, root)[0]
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  body = ireps.values.find { |irep| BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :TDEF } }
  compiled = BytecodeIR.for(body).each_source.filter_map do |insn, _|
    next unless insn.op == :TDEF

    label = body.reps[insn.def_child_index]
    method = gen.compile_method(label)
    method&.merge(label: label)
  end
  gen.compiled_methods = compiled.to_h { |m| [m[:label], m] }
  unit = gen.compile_top_class_units(ireps.fetch(root)).find { |u| u[:path] == 'Router' }.to_h[:code].to_s
  registration = gen.emit_owner_registrations(compiled.reject { |m| m[:name] == drop }, ['Router'])
  [unit, gen.rom_class_body_defs(unit), registration]
end

suite.compile(ROUTER) do |ireps, root|
  ENV['BC2CPP_ROM_METHOD_TABLES'] = '1'
  unit, resolved, registration = router_texts(ireps, root)
  table = registration[/static const mrb_mt_entry (bc2cpp_mt_\w+_Router)\[\]/, 1]
  suite.check('the owner registration makes a ROM table', table)
  suite.check('each registered def of the unit carries a ROM_DEF site', unit.scan('//@@ROM_DEF ').size == 3)
  suite.check('a resolved unit has no site marker left', !resolved.include?('@@ROM_DEF'))
  suite.check('a resolved unit registers no method of its table', !resolved.match?(/mrb_define_(?:private_)?method\(/))
  suite.check('the unit installs its owner\'s table once',
              resolved.scan("bc2cpp_mt_chain(M, mrb_class_ptr(self), #{table}, ").size == 1)
  install = resolved.index('bc2cpp_mt_chain(')
  suite.check('the install sits where the first def registered', install && install < resolved.index('Router#each'))
  suite.check('a verify build checks each def against the install, with its visibility',
              resolved.scan(/^#ifdef BC2CPP_UNREGISTERED_VERIFY\n  bc2cpp_rom_def_check\(M, mrb_class_ptr\(self\), false, "[^"]+", Router_\w+, (true|false)\);\n#endif\n/)
                      .flatten.sort == %w[false false true])

  _, kept, = router_texts(ireps, root, drop: 'size')
  suite.check('a def whose row the table lacks keeps its registration call',
              kept.match?(/^  mrb_define_method\(M, mrb_class_ptr\(self\), "[^"]+", Router_size, /) &&
              kept.include?('bc2cpp_mt_chain('))

  ENV['BC2CPP_ROM_CLASS_BODY_DEFS'] = '0'
  off, off_resolved, = router_texts(ireps, root)
  suite.check('BC2CPP_ROM_CLASS_BODY_DEFS=0 keeps every registration call',
              !off.include?('@@ROM_DEF') && off_resolved == off && off.scan(/mrb_define_(?:private_)?method\(/).size == 3)
ensure
  ENV.delete('BC2CPP_ROM_CLASS_BODY_DEFS')
  ENV.delete('BC2CPP_ROM_METHOD_TABLES')
end

ATTRS = <<~'RUBY'
  class Router
    attr_reader :a, :b
    attr_accessor
  end
RUBY

suite.compile(ATTRS) do |ireps, root|
  ENV['BC2CPP_ROM_METHOD_TABLES'] = '1'
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  gen.compiled_methods = {}
  unit = gen.compile_top_class_units(ireps.fetch(root)).find { |u| u[:path] == 'Router' }.to_h[:code].to_s
  gen.record_rom_table('Router', 'bc2cpp_mt_program_Router', [{ name: 'a', entry: 'Router_a' }])
  resolved = gen.rom_class_body_defs(unit)
  calls = resolved.scan(/bc2cpp_mod_attr\(M, self, true, false, \{(.*?)\}\)/).flatten
  suite.check('an attr_reader pass defines only the accessors the table lacks', calls.size == 1 && !calls[0].include?(','))
  suite.check('an attr whose accessor is a row installs the table', resolved.include?('bc2cpp_mt_chain(M, mrb_class_ptr(self), bc2cpp_mt_program_Router, '))
  suite.check('an attr_* send with no names makes no call', resolved.scan('bc2cpp_mod_attr(').size == 1)
ensure
  ENV.delete('BC2CPP_ROM_METHOD_TABLES')
end

suite.finish!
