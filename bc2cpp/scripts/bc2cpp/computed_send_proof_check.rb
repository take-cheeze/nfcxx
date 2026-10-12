#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0279: ENTRY_ARG_CALLSITE_PROOF and FIXNUM_RETURN_PROOF enumerate call sites, and a
# computed-name send (`send(name, v)`, `__send__("#{field}=", v)`, `define_method(name)`) is a
# call or a definition the enumeration never sees: it can pass a non-Integer to a method whose
# visible call sites all pass Integers, or install another body under a method the return
# proof took for a Fixnum-returning one. Both proofs now refuse every name such a send could
# build (DynamicNames, the rule ADR 0276 applies to pooled numeric arguments).
#
# 1. With MRBC: the generated code of a closed-world fixture. The methods a computed send can
#    reach must not be emitted with an unchecked `mrb_fixnum()` operand; the controls with the
#    same shape and no computed reach keep their proof.
# 2. With a mruby build and g++: interpreted and compiled answers agree (the compiled build used
#    to read a String as a Fixnum and answer garbage).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/computed_send_proof_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

FIXTURE = <<~RUBY
  class CsArg
    def cs_twice(n) = n + n
    def cs_control(n) = n + n
    def cs_sum(a, b) = a * b

    def cs_go
      cs_twice(3)
      cs_control(4)
      cs_sum(2, 3)
      name = "cs_twice"
      __send__(name, "ab")
    end
  end

  class CsSet
    def cs_val=(v)
      @cs_seen = v + v
    end

    def cs_plain=(v)
      @cs_plain_seen = v + v
    end

    def cs_seen; @cs_seen; end
    def cs_plain_seen; @cs_plain_seen; end

    def cs_go
      self.cs_val = 5
      self.cs_plain = 6
      field = "cs_val"
      __send__("\#{field}=", "x")
      [cs_seen, cs_plain_seen]
    end
  end

  class CsRet
    def cs_num; 41; end
    def cs_control_num; 42; end
    def cs_use; cs_num + cs_num; end
    def cs_control_use; cs_control_num + cs_control_num; end

    def self.cs_patch(name)
      define_method(name) { "ab" }
    end

    # Never called: the compiler must still assume it can replace #cs_num.
    def cs_never_called
      CsRet.cs_patch("cs_num")
    end

    def cs_go
      [cs_use, cs_control_use]
    end
  end
RUBY

OWNERS = %w[CsArg CsSet CsRet].freeze

if ENV['MRBC']
  puts '-- generated code (closed world)'
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS)
    chunk = lambda do |owner_method|
      code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
    end
    proven = ->(method) { chunk.call(method).include?('operands proven Fixnum') }
    check.call('the fixture compiled', !chunk.call('CsArg#cs_control').empty?)
    check.call('the control argument (visible Integer sites only) is a proven Fixnum', proven.call('CsArg#cs_control'))
    check.call('NEG: an argument a `__send__(name, "ab")` can reach is not a proven Fixnum', !proven.call('CsArg#cs_twice'))
    check.call('the control keeps its proof while a computed send exists elsewhere', proven.call('CsArg#cs_sum'))
    check.call('NEG: a setter a computed `__send__("#{field}=", v)` can reach is not a proven Fixnum',
               !proven.call('CsSet#cs_val=') && !chunk.call('CsSet#cs_val=').empty?)
    check.call('the control setter keeps its proof', proven.call('CsSet#cs_plain='))
    check.call('the control method proves Fixnum-returning', proven.call('CsRet#cs_control_use'))
    check.call('NEG: a method a computed define_method can replace is not a proven Fixnum return',
               !proven.call('CsRet#cs_use'))
    listed = err.lines.grep(/^  RET /).map { |l| l.split.last }
    check.call('the diagnostic lists the control return and not the reachable one',
               listed.include?('cs_control_num') && !listed.include?('cs_num'))
  end
else
  puts '-- SKIP generated code: set MRBC'
end

build = runtime.full || runtime.core
if ENV['MRBC'] && build && runtime.compiler?
  puts '-- fixture on real mruby, interpreted and compiled'
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        for (const char* klass : { "CsArg", "CsSet", "CsRet" }) {
          mrb_value obj = mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
          call(M, klass, obj, "cs_go");
        }
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, OWNERS, body, build: build, full: File.exist?("#{build}/lib/libmruby.a"))
    check.call('the fixture compiles and runs against real mruby', built)
    puts output unless built
    if built
      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      check.call('every method answers what the interpreter answers', !values.call('interpreted').empty? &&
                                                                       values.call('interpreted') == values.call('compiled'))
      puts output if values.call('interpreted') != values.call('compiled') || ENV['BC2CPP_CHECK_VERBOSE']
      check.call('the interpreter really added the Strings', values.call('interpreted').any? { |l| l.include?('"abab"') })
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_CORE (or _FULL) and have g++'
end

if failures.empty?
  puts 'bc2cpp computed send proof check: PASS'
else
  warn "bc2cpp computed send proof check: #{failures.size} failure(s)"
  exit 1
end
