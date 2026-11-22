#!/usr/bin/env ruby
# frozen_string_literal: true

# LITERAL_TABLES (tools/bc2cpp/codegen_literal_tables.rb): a constant Hash/Array literal in a class body or a free
# lambda's body is a word table that bc2cpp_lit_build builds, and BC2CPP_LITERAL_TABLES=0 keeps the pair-by-pair code.
# Array keys and proved Integer constants are table words too (BC2CPP_LITERAL_ARRAY_KEYS=0, BC2CPP_LITERAL_CONST_INTS=0).
#
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

# LITERAL_TABLES (tools/bc2cpp/codegen_literal_tables.rb): constant literals in the body and in a free lambda's body.
# Its Symbols are core method names, so mruby's own presym table has them.
LITERALS = <<~'RUBY'
  class Router
    LIMIT = 3
    TABLE = {
      1 => { name: :inspect, size: :to_s, default: '' },
      2 => { name: :to_s, size: :size, default: -70_000, last: [nil, true, false, 4096] },
      3 => { name: :default, first: LIMIT },
    }
    LAZY = -> { { 1 => { name: :name, size: :first }, 2 => { name: :last, size: :inspect, default: 'x' } } }
  end
RUBY

# LITERAL_ARRAY_KEYS and LITERAL_CONST_INTS (tools/bc2cpp/codegen_literal_tables.rb): Array keys, and a constant
# INTEGER_CONSTANT_VALUE_PROOF proved, are table words.
KEYED = <<~'RUBY'
  class Router
    N = -1
    TURNS = { [2, 4] => [6, N], [4, 2] => [2, 6], [6, 8] => [N, 4] }
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

# The units of LITERALS with presym-spelled Symbols, as a real gem build spells them (PRESYM_ALL).
literal_units = lambda do |ireps, root|
  saved = SymbolCache.presym_all
  SymbolCache.presym_all = true
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  [gen, gen.compile_top_class_units(ireps.fetch(root))]
ensure
  SymbolCache.presym_all = saved
end

suite.compile(LITERALS) do |ireps, root|
  gen, units = literal_units.call(ireps, root)
  code = units.map { |u| u[:code] }.join
  suite.check('both constant literals are word tables built by bc2cpp_lit_build, with no mrb_hash_set left',
              code.scan('bc2cpp_lit_build(M, bc2cpp_lit,').size == 2 && !code.include?('mrb_hash_set'))
  suite.check('Symbols are presym ids, Strings are fresh-String slots, the constant read is handed over',
              code.include?('(uint16_t)MRB_SYM(name)') && code.include?('BC2CPP_LIT_STR("")') &&
              code.match?(/const mrb_value bc2cpp_lit_d\[\] = \{ r\d+ \};/) && code.include?('0x9000, 0xee90, 0xfffe'))
  headers = %w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/numeric.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h]
  stubs = "typedef mrb_value (*Bc2cppBlockEntry)(mrb_state*, struct REnv*, bool, mrb_int, const mrb_value*);\n" \
          "struct Bc2cppBlock { Bc2cppBlock(mrb_state*, mrb_int, mrb_value*); mrb_value proc(); };\n" \
          "mrb_value bc2cpp_const_scope_0(mrb_state*, mrb_sym);\n"
  unit = +"#{headers.map { |h| "#include <#{h}>\n" }.join}#{TaggedFixnum::PRELUDE}#{SymbolCache::LITERAL_TABLES_PRELUDE}#{stubs}"
  unit << gen.emit_owner_class_cache << code
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "class_body_literals_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the units with the word tables compile with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(12).join.strip}" unless status.success?
  File.delete(path)
end

begin
  ENV['BC2CPP_LITERAL_TABLES'] = '0'
  suite.compile(LITERALS) do |ireps, root|
    code = literal_units.call(ireps, root)[1].map { |u| u[:code] }.join
    suite.check('BC2CPP_LITERAL_TABLES=0 keeps one mrb_hash_set per pair',
                !code.include?('bc2cpp_lit_build(M') && code.include?('mrb_hash_set(M, h, '))
  end
ensure
  ENV.delete('BC2CPP_LITERAL_TABLES')
end

keyed_code = lambda do |ireps, root, env|
  saved = CodeGen.integer_constant_values
  CodeGen.integer_constant_values = { 'N' => -1 }
  env.each { |key, value| ENV[key] = value }
  literal_units.call(ireps, root)[1].map { |u| u[:code] }.join
ensure
  env.each_key { |key| ENV.delete(key) }
  CodeGen.integer_constant_values = saved
end

suite.compile(KEYED) do |ireps, root|
  code = keyed_code.call(ireps, root, {})
  suite.check('Array keys and the proved constant are one word table with no kept read',
              code.scan('bc2cpp_lit_build(M, bc2cpp_lit,').size == 1 && !code.include?('mrb_hash_set') &&
              code.include?('0xa003, 0xb002, 0x8002, 0x8004, 0xb002, 0x8006, 0x9000, 0xffff, 0xffff') &&
              !code.include?('bc2cpp_lit_d'))
  suite.check('BC2CPP_LITERAL_ARRAY_KEYS=0 keeps one mrb_hash_set per pair',
              keyed_code.call(ireps, root, { 'BC2CPP_LITERAL_ARRAY_KEYS' => '0' }).include?('mrb_hash_set(M, h, '))
  suite.check('BC2CPP_LITERAL_CONST_INTS=0 hands the constant read over',
              keyed_code.call(ireps, root, { 'BC2CPP_LITERAL_CONST_INTS' => '0' }).include?('const mrb_value bc2cpp_lit_d[]'))
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
