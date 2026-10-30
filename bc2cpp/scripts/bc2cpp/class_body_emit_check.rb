#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_EMIT prototype (tools/bc2cpp/codegen_class_body.rb): a class body made only of constant writes compiles to
# one C++ function whose text names the body's class and compiles with the mruby headers; a body with a def is refused
# whole and names the opcode that refused it. Needs MRBC and g++; without MRBC it prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_body_emit_check.rb

require 'open3'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('class_body_emit_check')
suite.require_mrbc!

CONSTS = <<~'RUBY'
  class Router
    LIMIT = 3
    MAX = 99
  end
RUBY

WITH_DEF = <<~'RUBY'
  class Router
    LIMIT = 3
    def route(x) = x + LIMIT
  end
RUBY

# The class body irep of the fixture: the one holding SETCONST (the root has none).
def class_body_of(ireps)
  ireps.values.find { |irep| BytecodeIR.for(irep).each_source.any? { |insn, _| insn.op == :SETCONST } }
end

suite.compile(CONSTS) do |ireps, _root|
  body = class_body_of(ireps)
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code, refused = gen.compile_class_body(body, 'Router')
  suite.check('a constant-only class body compiles', code && refused.nil?)
  suite.check('it names the class and writes both constants',
              code.to_s.include?('mrb_obj_value(bc2cpp_owner_class_0(M))') &&
              code.to_s.include?('mrb_intern_cstr(M, "LIMIT")') && code.to_s.include?('mrb_intern_cstr(M, "MAX")'))
  unit = +"#{%w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h].map { |h| "#include <#{h}>\n" }.join}#{gen.emit_owner_class_cache}#{code}"
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_emit_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include", "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', ROOT + '/build-closed-bc2cpp/closed/include')}", path)
  suite.check('the emitted class body compiles with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
end

suite.compile(WITH_DEF) do |ireps, _root|
  body = class_body_of(ireps)
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code, refused = gen.compile_class_body(body, 'Router')
  suite.check('a class body with a def is refused whole', code.nil? && refused.include?(:TDEF))
end

# An omitted def (named by BC2CPP_UNREGISTERED_EXTRA, as the build's leave-out lists would name it) compiles as its
# register write; the body compiles with g++ accepted, and the same body without the omission is still refused.
previous = ENV['BC2CPP_UNREGISTERED_EXTRA']
begin
  ENV['BC2CPP_UNREGISTERED_EXTRA'] = 'Router#route'
  suite.compile(WITH_DEF) do |ireps, _root|
    body = class_body_of(ireps)
    gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    code, refused = gen.compile_class_body(body, 'Router')
    suite.check('an omitted def compiles as a register write, not a refusal',
                code && refused.nil? && code.include?('statically dispatched only') &&
                code.include?('mrb_symbol_value(mrb_intern_cstr(M, "route"))'))
    unit = +"#{%w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h].map { |h| "#include <#{h}>\n" }.join}#{gen.emit_owner_class_cache}#{code}"
    path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_omit_#{$$}.cc")
    File.write(path, unit)
    out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w', "-I#{ROOT}/3rd/mruby/include",
                                  "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', ROOT + '/build-closed-bc2cpp/closed/include')}", path)
    suite.check('the body with an omitted def compiles with the mruby headers', status.success?)
    puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
    File.delete(path)
  end
ensure
  ENV['BC2CPP_UNREGISTERED_EXTRA'] = previous
end

# A nested class is one unit: CLASS plus its EXEC create the class the VM way and call the child's compiled function.
# The parent's text carries the child's function first, and the whole unit compiles with g++.
NESTED = <<~RUBY
  class Outer
    LIMIT = 3
    class Inner
      MAX = 9
    end
  end
RUBY

suite.compile(NESTED) do |ireps, _root|
  outer = ireps.values.find { |irep| BytecodeIR.class_bodies(irep, :CLASS, :MODULE).any? }
  gen = CodeGen.new(ireps, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  code, refused = gen.compile_class_body(outer, 'Outer')
  suite.check('a class with a nested class compiles as one unit', code && refused.nil?)
  suite.check('the unit creates the nested class and calls its function',
              code.to_s.include?('mrb_vm_define_class(M, r') && code.to_s.include?('mrb_intern_cstr(M, "Inner")') &&
              code.to_s.scan('static mrb_value bc2cpp_class_body_').size == 2)
  unit = +"#{%w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h].map { |h| "#include <#{h}>\n" }.join}#{gen.emit_owner_class_cache}#{code}"
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_nested_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w', "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', ROOT + '/build-closed-bc2cpp/closed/include')}", path)
  suite.check('the nested class unit compiles with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
end

suite.finish!
