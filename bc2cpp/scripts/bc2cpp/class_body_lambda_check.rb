#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_EMIT, FREE_LAMBDA (tools/bc2cpp/codegen_class_body.rb): a lambda in a class body whose body reads nothing
# from the creating frame (no self, upvar, block or nested closure) is built as a free RProc over a
# direct entry (bc2cpp_block_thunk over an env of nil, the entry and a flag word) flagged strict as a lambda is, so a
# compiled call enters it with the arity check and no frame. A lambda that reads any of those refuses its body. The
# emitted units must compile with the mruby headers. Needs MRBC and g++; without MRBC it prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_body_lambda_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'open3'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = BC2CPP_WORLD_ROOT
suite = FixtureCheck.new('class_body_lambda_check')
suite.require_mrbc!

FREE = <<~'RUBY'
  class Router
    SCALE = ->(x) { x + 1 }
  end
RUBY

SELF_USE = <<~'RUBY'
  class Router
    ME = ->(x) { self }
  end
RUBY

UPVAR = <<~'RUBY'
  class Router
    y = 1
    ADD = ->(x) { x + y }
  end
RUBY

suite.compile(FREE) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  units = gen.compile_top_class_units(ireps.fetch(root))
  code = units.find { |unit| unit[:path] == 'Router' }.to_h[:code].to_s
  fn = 'bc2cpp_class_lambda_Router_lambda_fallback_0'
  suite.check('a free lambda compiles its body as a direct entry and makes the unit',
              units.map { |unit| unit[:path] } == %w[Router] &&
              code.include?("static mrb_value #{fn}_direct(mrb_state* M, struct REnv* bc2cpp_env, bool bc2cpp_strict,"))
  suite.check('the lambda is a thunk proc over its entry, flagged strict, stored in its register',
              code.include?('Bc2cppBlock bc2cpp_free_block(M, 3, bc2cpp_free_env);') &&
              code.include?("&#{fn}_direct") && code.include?('bc2cpp_free_lambda->flags |= MRB_PROC_STRICT;') &&
              !code.include?('mrb_proc_new_cfunc'))
  entry = code[/static mrb_value #{fn}_direct\(.*?\n\}\n/m].to_s
  suite.check('the entry checks the strict arity and reads no env slot but the nil self',
              entry.include?('if (bc2cpp_strict && bc2cpp_argc != 1) mrb_argnum_error(M, bc2cpp_argc, 1, 1);') &&
              !entry.include?('stack[1]') && !entry.include?('mrb_proc_cfunc_env_get'))
  suite.check('the constant is set to the lambda value',
              code.include?('mrb_const_set(M, mrb_obj_value(bc2cpp_owner_class_0(M)), mrb_intern_cstr(M, "SCALE"), r1);'))

  headers = %w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/numeric.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h]
  # Bc2cppBlock is the shared prelude's (bc2cpp.rb); declared here for the syntax check.
  stubs = "typedef mrb_value (*Bc2cppBlockEntry)(mrb_state*, struct REnv*, bool, mrb_int, const mrb_value*);\n" \
          "struct Bc2cppBlock { Bc2cppBlock(mrb_state*, mrb_int, mrb_value*); mrb_value proc(); };\n"
  unit = +"#{headers.map { |h| "#include <#{h}>\n" }.join}#{TaggedFixnum::PRELUDE}#{stubs}#{gen.emit_owner_class_cache}"
  unit << units.map { |u| u[:code] }.join
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_lambda_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the emitted unit with the free lambda compiles with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(12).join.strip}" unless status.success?
  File.delete(path)
end

suite.compile(SELF_USE) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  suite.check('a lambda that reads self is not free: its body is refused', gen.compile_top_class_units(ireps.fetch(root)).empty?)
end

suite.compile(UPVAR) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  suite.check('a lambda that reads a local of its frame is not free: its body is refused',
              gen.compile_top_class_units(ireps.fetch(root)).empty?)
end

suite.finish!
