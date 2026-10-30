#!/usr/bin/env ruby
# frozen_string_literal: true

# OPTIONAL_REST (tools/bc2cpp/codegen_method.rb, optional_rest_arg_table): a method with optional parameters and a rest
# parameter (`def m(a = 1, *r)`, as Enumerator#initialize has) compiles to an entry that reads the optionals with `|`
# and the rest with `*`, and passes the optionals, the rest and the count of supplied optionals to its body. Needs MRBC
# and g++; without MRBC it prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/optional_rest_check.rb

require 'open3'
require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

ROOT = File.expand_path('../..', __dir__)
suite = FixtureCheck.new('optional_rest_check')
suite.require_mrbc!

SRC = <<~'RUBY'
  class Router
    def m(a = 1, *r)
      [a, r]
    end
  end
RUBY

suite.compile(SRC) do |ireps, root|
  gen = CodeGen.new(ireps, build_registry(ireps, root)[0], {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
  label = ireps.keys.find { |l| ireps[l].enter && ireps[l].enter.enter_fields[2].positive? }
  code = gen.compile_method(label)
  text = code.to_h[:code].to_s
  suite.check('the optional-with-rest method compiles (no #error)', code && !text.include?('#error'))
  suite.check('its entry reads the optional with | and the rest with *',
              text.include?('mrb_get_args(M, "|o*", &a, &bc2cpp_rest_ptr, &bc2cpp_rest_len);'))
  suite.check('its body takes the optional, the rest and the count of supplied optionals',
              text.include?('mrb_value Router_m_impl(mrb_state* M, mrb_value self, mrb_value a, mrb_value r, mrb_int bc2cpp_given_opt)'))
  suite.check('the registration shape is optional and rest', code[:aspec] == 'MRB_ARGS_REQ(0) | MRB_ARGS_OPT(1) | MRB_ARGS_REST()')

  headers = %w[mruby.h mruby/array.h mruby/class.h mruby/hash.h mruby/numeric.h mruby/proc.h mruby/range.h mruby/string.h mruby/variable.h]
  helper = "static inline void bc2cpp_check_argc(mrb_state* M, mrb_int min, mrb_int max) {\n" \
           "  mrb_int argc = mrb_get_argc(M);\n" \
           "  if (M->c->ci->nk == 0 && (argc < min || (max >= 0 && argc > max))) mrb_argnum_error(M, argc, min, min);\n}\n"
  unit = +"#{headers.map { |h| "#include <#{h}>\n" }.join}#{TaggedFixnum::PRELUDE}#{helper}#{gen.emit_owner_class_cache}#{text}"
  path = File.join(ENV.fetch('TMPDIR', '/tmp'), "optional_rest_#{$$}.cc")
  File.write(path, unit)
  out, status = Open3.capture2e('g++', '-std=c++17', '-fsyntax-only', '-w',
                                "-I#{ROOT}/3rd/mruby/include",
                                "-I#{ENV.fetch('BC2CPP_BUILD_INCLUDE', "#{ROOT}/build-closed-bc2cpp/closed/include")}", path)
  suite.check('the emitted method compiles with the mruby headers', status.success?)
  puts "    g++: #{out.lines.first(3).join.strip}" unless status.success?
  File.delete(path)
end

suite.finish!
