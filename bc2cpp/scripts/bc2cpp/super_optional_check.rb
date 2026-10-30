#!/usr/bin/env ruby
# frozen_string_literal: true

# SUPER_OPTIONAL (tools/bc2cpp/codegen_insn.rb, super_target): a `super` whose target takes optional arguments is a
# direct call to the target's `_impl`, which takes every optional, pads the omitted ones with nil and passes the count
# of supplied optionals (direct_call_args). A call with an argument count the target does not accept stays by name.
# Needs MRBC and g++; without MRBC it prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/super_optional_check.rb

require 'open3'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('super_optional_check')
suite.require_mrbc!

SRC = <<~'RUBY'
  class Base
    def initialize(m = nil, n = nil)
      [m, n]
    end
  end

  class Kid < Base
    def initialize(m)
      super(m)
    end
  end

  class Odd < Base
    def initialize(m, n, o)
      super(m, n, o)
    end
  end
RUBY

suite.compile(SRC) do |ireps, root|
  # A closed world turns on the caller facts the direct super call needs (no caller of initialize passes a block).
  built = build_registry(ireps, root)
  world = ClosedWorld.new(ireps: ireps, registry: built[0], class_decls: built[7], walked: built[8] & ireps.keys,
                          native_paths: [], ruby_paths: [], module_names: built[11])
  gen = CodeGen.new(ireps, built[0], {}, {}, {}, {}, { 'Kid' => 'Base', 'Odd' => 'Base' }, {}, {}, {}, {}, Set.new,
                    nil, nil, {}, closed_world: world)
  label_of = ->(owner) { ireps.keys.find { |l| gen.instance_variable_get(:@owner_of)[l]&.owner == owner } }
  kid = gen.compile_method(label_of.call('Kid'))
  odd = gen.compile_method(label_of.call('Odd'))
  base = gen.compile_method(label_of.call('Base'))
  kid_text = kid.to_h[:code].to_s
  suite.check('the subclass with a one-argument super compiles', kid && !kid_text.include?('unhandled opcode SUPER'))
  suite.check('super passes the optional target its argument, a nil placeholder and the given count',
              kid_text.match?(/Base_initialize_impl\(M, self, r\d+, mrb_nil_value\(\), 1\)/))
  suite.check('a super with more arguments than the target takes is not a direct call',
              !odd.to_h[:code].to_s.include?('Base_initialize_impl(M, self'))
  headers = %w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/numeric.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h]
  helper = "static inline void bc2cpp_check_argc(mrb_state* M, mrb_int min, mrb_int max) {\n" \
           "  mrb_int argc = mrb_get_argc(M);\n" \
           "  if (M->c->ci->nk == 0 && (argc < min || (max >= 0 && argc > max))) mrb_argnum_error(M, argc, min, min);\n}\n"
  unit = +"#{headers.map { |h| "#include <#{h}>\n" }.join}#{TaggedFixnum::PRELUDE}#{helper}#{gen.emit_owner_class_cache}"
  unit << base.to_h[:code].to_s << kid_text
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "super_optional_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the optional base and the direct super call compile with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
end

suite.finish!
