#!/usr/bin/env ruby
# frozen_string_literal: true

# EXCEPTION_INIT (tools/bc2cpp/codegen_exception_init.rb): a `super` whose chain reaches Exception#initialize is that
# native, written directly: a message argument sets the message (mrb_exc_mesg_set), no argument leaves it. The prelude
# declares mrb_exc_mesg_set, so the emitted code compiles against the mruby headers. Needs MRBC and g++; without MRBC it
# prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/exception_init_check.rb

require 'open3'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('exception_init_check')
suite.require_mrbc!

SRC = <<~'RUBY'
  class Boom < StandardError
    def initialize(m = nil)
      super(m)
    end
  end

  class Quiet < RuntimeError
    def initialize
      super
    end
  end

  class Pair < StandardError
    def initialize(m, n)
      super(m, n)
    end
  end
RUBY

suite.compile(SRC) do |ireps, root|
  built = build_registry(ireps, root)
  world = ClosedWorld.new(ireps: ireps, registry: built[0], class_decls: built[7], walked: built[8] & ireps.keys,
                          native_paths: [], ruby_paths: [], module_names: built[11])
  gen = CodeGen.new(ireps, built[0], {}, {}, {}, {}, { 'Boom' => 'StandardError', 'Quiet' => 'RuntimeError', 'Pair' => 'StandardError' },
                    {}, {}, {}, {}, Set.new, nil, nil, {}, closed_world: world)
  label_of = ->(owner) { ireps.keys.find { |l| gen.instance_variable_get(:@owner_of)[l]&.owner == owner } }
  boom = gen.compile_method(label_of.call('Boom')).to_h[:code].to_s
  quiet = gen.compile_method(label_of.call('Quiet')).to_h[:code].to_s
  pair = gen.compile_method(label_of.call('Pair')).to_h[:code].to_s
  suite.check('a super with one argument sets the message through the exception init',
              boom.include?('bc2cpp_exc_init(M, self, r') && !boom.include?('unhandled opcode SUPER'))
  suite.check('a bare super leaves the message: the exception is returned as it is', quiet.include?('= self;'))
  suite.check('a super with two arguments stays by name (exc_initialize takes at most one)', !pair.include?('bc2cpp_exc_init('))
  helpers = gen.emit_exception_init_helpers([{ code: boom }])
  headers = %w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/numeric.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h]
  argc_helper = "static inline void bc2cpp_check_argc(mrb_state* M, mrb_int min, mrb_int max) {\n" \
                "  mrb_int argc = mrb_get_argc(M);\n" \
                "  if (M->c->ci->nk == 0 && (argc < min || (max >= 0 && argc > max))) mrb_argnum_error(M, argc, min, min);\n}\n"
  unit = +"#{headers.map { |h| "#include <#{h}>\n" }.join}#{TaggedFixnum::PRELUDE}#{argc_helper}#{helpers}#{gen.emit_owner_class_cache}"
  unit << boom << quiet
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "exception_init_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the emitted exception initializers compile with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
end

suite.finish!
