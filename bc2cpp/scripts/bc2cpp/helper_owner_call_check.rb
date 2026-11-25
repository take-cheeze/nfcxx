#!/usr/bin/env ruby
# frozen_string_literal: true

# Check HELPER_OWNER_CALL (tools/bc2cpp/codegen_outside_owner_call.rb) on a closed-world fixture:
#   1. generated code: the numeric slow helpers' last-resort by-name send (`bc2cpp_funcall_keep(M, a, "<<", ...)`,
#      the rooted mrb_funcall) becomes the owner call over the name's owner set, so a non-Integer `a << b` (String,
#      Array) is one checked lookup the call's inline cache answers, not a by-name send each time;
#   2. run on a full-core mruby, compiled against interpreted: Integer, String, Array and a program class answer `<<`,
#      `+` and `-` the same, and nil raises the same NoMethodError.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/helper_owner_call_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'tmpdir'
require_relative 'fixture_runtime'

require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_outside_owner_call'
require_relative '../../tools/bc2cpp/codegen_send'
require_relative '../../tools/bc2cpp/presym_spelling'
require_relative '../../tools/bc2cpp/symbol_cache'

module OutsideOwnerFallbackCheck
  class World
    attr_accessor :lifted

    def with_outside_owner_call(_name)
      @lifted = true
      yield
    ensure
      @lifted = false
    end
  end

  class Base
    def guarded_fallback_line(*)
      @closed_world.lifted ? @lifted : 'dispatch(); /* CLOSED_WORLD kept: core_or_native */'
    end
  end

  class Emitter < Base
    include OutsideOwnerCall

    def initialize(lifted)
      @closed_world = World.new
      @lifted = lifted
    end

    def outside_owner_call_owners(*) = ['Object']

    def outside_owner_call_line(*)
      # mruby-onig reuses a match region: the caller must save its boundary first.
      /.+/.match('a different match region')
      'OWNER_CALL'
    end
  end

  cases = 0
  ['self', 'r12', 'values[index + 1]', 'é_receiver'].product(['work', '[]=', 'a.b?', 'méthode']).each do |recv, name|
    prefix = "r7 = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\""
    error = %r{r7 = bc2cpp_nomethod_named\(M, #{Regexp.escape(recv)}, "#{Regexp.escape(name)}"[^\n]*?\); /\* CLOSED_WORLD nomethod: (?:self|recv)\.\S+ @ \S+ \*/}
    ['', ', 2, r8, r9'].product(['self', 'recv']).each do |args, kind|
      call = "#{prefix}#{args}); /* CLOSED_WORLD nomethod: #{kind}.#{name} @ source.rb:12 */"
      [call, "é before\n  #{call}\n after", "#{call}\n#{call}",
       "#{prefix}\n#{call}", "#{prefix}\nnot a marker", "#{prefix}); /* wrong marker */\n#{call}",
       call.sub('r7 =', 'r70 ='), call.sub('nomethod:', 'kept:'), call.sub('); /*', ");\n/*")].each do |lifted|
        expected = lifted.sub(error) { 'OWNER_CALL' }
        actual = Emitter.new(lifted).guarded_fallback_line(7, recv, name, [], [], {})
        raise "fallback replacement changed: #{[lifted, expected, actual].inspect}" unless actual == expected

        cases += 1
      end
    end
  end
  puts "outside owner fallback: #{cases} replacement comparisons passed"
end

# PROGRAM_OWNER_SITES (symbol_cache.rb): with a presym id for the name, a helper's owner call and proven nomethod name
# no slot of the gem's symbol table, so two gems print the same text; a fiber runtime name, a name with no presym id
# and BC2CPP_HELPER_PROGRAM_SITES=0 keep the gem's slot.
module ProgramSitesCheck
  class Emitter
    include OutsideOwnerCall

    def name_owner_set(_name) = %w[Integer String].freeze
  end

  helper = "if (x) return bc2cpp_funcall_keep(M, a, \"<<\", 1, b);\n" \
           "if (y) return bc2cpp_funcall_keep(M, a, \"resume\", 0);\n" \
           "if (z) return bc2cpp_nomethod_named(M, a, \"-@\", 0);\n" \
           "return bc2cpp_nomethod_named(M, a, \"^\", 1, b);\n"
  gem = lambda do |taken|
    table = SymbolCache::Table.new
    taken.each { |name| table.index_for(%("#{name}")) }
    [SymbolCache.rewrite(Emitter.new.helper_owner_calls(helper), table), table]
  end
  failures = []
  expect = ->(what, ok) { failures << what unless ok }
  SymbolCache.presym_all = true
  a, table = gem.call([])
  b, = gem.call(%w[x y z])
  expect.call('the owner call names its presym id and a program-wide set',
              a.include?('bc2cpp_owner_call_pw1(M, a, BC2CPP_OWNERS_PW(MRB_OPSYM(lshift), "Integer", "String"), b)'))
  expect.call('the proven nomethod names its presym id',
              a.include?('bc2cpp_nomethod_pw(M, a, MRB_OPSYM(minus))') && a.include?('bc2cpp_nomethod_pw(M, a, MRB_OPSYM(xor), b)'))
  expect.call('a fiber runtime name keeps the gem slot', a.match?(/bc2cpp_owner_call\(M, a, BC2CPP_OWNERS\(\d+, 0,/))
  expect.call('two gems with other symbol tables print the same program-wide text',
              a.lines.reject { |l| l.include?('resume') } == b.lines.reject { |l| l.include?('resume') })
  expect.call('the gem emits the owner call and nomethod bodies', table.owner_call_used && table.nomethod_used)
  emitted = SymbolCache.emit(table)
  expect.call('the program state is included and every symbol reset bumps its epoch',
              emitted.include?(%(#include "#{SymbolCache::PROGRAM_STATE_HEADER}")) && emitted.include?('++bc2cpp_program_owner_epoch;'))
  expect.call('the program-wide entry checks the calling VM before the set',
              emitted.match?(/bc2cpp_owner_call_pw_argv\(.*?\n  if \(bc2cpp_program_owner_vm != M\) \{\n    bc2cpp_program_owner_vm = M;\n    \+\+bc2cpp_program_owner_epoch;/m))
  ENV['BC2CPP_HELPER_PROGRAM_SITES'] = '0'
  off, off_table = gem.call([])
  expect.call('BC2CPP_HELPER_PROGRAM_SITES=0 keeps the gem slots',
              !off.include?('_pw') && !SymbolCache.emit(off_table).include?('bc2cpp_program_owner'))
  ENV.delete('BC2CPP_HELPER_PROGRAM_SITES')
  SymbolCache.presym_all = false
  expect.call('an operator with no presym id keeps the gem slot', !gem.call([]).first.include?('_pw'))
  abort "program-wide helper sites FAILED: #{failures.join(', ')}" unless failures.empty?
  puts 'program-wide helper sites: 9 checks passed'
end

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class Acc
    def initialize; @n = 0; end
    def <<(x); @n += x; self; end
    def +(x); [:acc_plus, x]; end
    def -(x); [:acc_minus, x]; end
    def inspect; "#<Acc \#{@n}>"; end
  end
  class Probe
    def sh(a, b); a << b; end
    def pl(a, b); a + b; end
    def mi(a, b); a - b; end
  end
RUBY
OWNERS = %w[Acc Probe].freeze

Dir.mktmpdir('helper-owner-call') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'helper_owner_call.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  helper = code[/static mrb_value bc2cpp_slow_lshift\(mrb_state\* M.*?\n\}\n/m].to_s
  check.call('the << slow helper is emitted', !helper.empty?)
  check.call('its fallback is the owner call over the << owner set',
             helper.match?(/bc2cpp_owner_call\(M, a, BC2CPP_OWNERS\(\d+, 0, [^)]*"Acc"[^)]*\), mrb_nil_value\(\), 1, b\)/))
  check.call('no by-name fallback left in the numeric slow helpers',
             !code.match?(/bc2cpp_funcall_keep\(M, a, "(?:<<|\+|-)"/))

  unless ENV['CC_GENERATED_ONLY'] == '1'
    harness = <<~'CPP'
      #include <mruby/error.h>
      #include <string>
      struct Call { mrb_value obj; mrb_sym mid; mrb_value argv[2]; };
      static mrb_value call_body(mrb_state* M, void* ud) {
        Call* c = (Call*)ud;
        return mrb_funcall_argv(M, c->obj, c->mid, 2, c->argv);
      }
      static void row(mrb_state* M, const char* label, const char* meth, mrb_value a, mrb_value b) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
        Call c = { probe, mrb_intern_cstr(M, meth), { a, b } };
        mrb_bool raised = FALSE;
        mrb_value v = mrb_protect_error(M, call_body, &c, &raised);
        std::string out;
        if (raised) {
          mrb_value msg = mrb_funcall(M, v, "message", 0);
          out = std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
        } else {
          mrb_value s = mrb_inspect(M, v);
          out = std::string(RSTRING_PTR(s), RSTRING_LEN(s));
        }
        std::printf("%s => %s\n", label, out.c_str());
      }
      static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
      static int scenario(mrb_state* M) {
        mrb_value three = mrb_int_value(M, 3);
        for (int k = 0; k < 2; ++k) {  // the second round runs on the owner call's inline cache
          row(M, "int << 3", "sh", mrb_int_value(M, 1), three);
          row(M, "str << 3", "sh", eval(M, "+'ab'"), three);
          row(M, "ary << 3", "sh", eval(M, "[1]"), three);
          row(M, "acc << 3", "sh", eval(M, "Acc.new"), three);
          row(M, "nil << 3", "sh", mrb_nil_value(), three);
          row(M, "str + str", "pl", eval(M, "'ab'"), eval(M, "'cd'"));
          row(M, "acc + 3", "pl", eval(M, "Acc.new"), three);
          row(M, "ary - ary", "mi", eval(M, "[1, 2]"), eval(M, "[2]"));
          row(M, "acc - 3", "mi", eval(M, "Acc.new"), three);
        }
        return 0;
      }
    CPP
    build = runtime.full_or_build
    if build
      built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
      sections = runtime.sections(output)
      compiled = sections['compiled'].to_a
      interpreted = sections['interpreted'].to_a
      check.call('built and ran', built)
      check.call('runtime parity (every row)', !compiled.empty? && compiled == interpreted)
      check.call('String#<< through the owner call', compiled.any? { |l| l.start_with?('str << 3') && l.include?('"ab\\x03"') })
      check.call('a program class answers <<', compiled.any? { |l| l.start_with?('acc << 3') && l.include?('#<Acc 3>') })
      check.call('nil still raises NoMethodError', compiled.any? { |l| l.start_with?('nil << 3') && l.include?('NoMethodError') })
      warn output unless failures.empty?
    else
      puts '  SKIP run: no full-core mruby build'
    end
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp helper owner call check: PASS'
