#!/usr/bin/env ruby
# frozen_string_literal: true

# ENTRY_ARG_CALLSITE_PROOF / NUMERIC_ENTRY_ARG_PROOF (docs/adr/0276) must treat
# both names of `alias new old` as reaching old's body: a call through `new` is a
# site the index never sees, so a parameter proven Integer from the visible calls
# to `old` would be wrong for `new("str")`.
#
# Needs MRBC (generated code); with BC2CPP_MRUBY_CORE and g++ the fixture also
# runs on real mruby, interpreted and compiled.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/entry_arg_alias_check.rb

require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (and BC2CPP_MRUBY_CORE for the run)'
  puts 'bc2cpp entry arg alias check: PASS'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime

fixture = <<~RUBY
  class EaBox
    # Positive control: only Integers reach it, no alias.
    def ea_plain(x)
      x + 1
    end

    def ea_old(x)
      x + 1
    end
    alias ea_new ea_old

    def ea_am_old(x)
      x + 1
    end
    alias_method :ea_am_new, :ea_am_old

    def ea_run
      out = []
      out << ea_plain(1)
      out << ea_old(2)
      out << (ea_new("s") rescue "err")
      out << ea_am_old(3)
      out << (ea_am_new("s") rescue "err")
      out
    end
  end
RUBY

retained_tag = %r{// (?:FIXNUM_ARITHMETIC|FIXNUM_COMPARE|FLOAT_DIV_RECEIVER) :}
chunk_of = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end

puts '-- generated code (closed world)'
code = nil
Dir.mktmpdir { |dir| code, = runtime.generate(fixture, dir, closed: true) }
proven = lambda do |m|
  c = chunk_of.call(code, m)
  !c.empty? && !c.match?(retained_tag)
end
kept = lambda do |m|
  c = chunk_of.call(code, m)
  !c.empty? && c.match?(retained_tag)
end
check.call('control: a method called only with Integers and never aliased is proven', proven.call('EaBox#ea_plain'))
check.call('NEG: `alias new old` with new("s") keeps the send in old', kept.call('EaBox#ea_old'))
check.call('NEG: `alias_method :new, :old` keeps the send in old', kept.call('EaBox#ea_am_old'))

core = runtime.core
full = runtime.full
if (full.nil? && core.nil?) || !runtime.compiler?
  puts '  SKIP run: set BC2CPP_MRUBY_CORE (or BC2CPP_MRUBY_FULL) and have g++'
else
  puts '-- fixture on real mruby, interpreted and compiled'
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(fixture, dir, closed: true, only_owners: %w[EaBox])
    body = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value box = mrb_obj_new(M, mrb_class_get(M, "EaBox"), 0, nullptr);
        call(M, "run", box, "ea_run");
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, %w[EaBox], body, build: full || core, full: !full.nil?)
    check.call('the fixture compiles and runs against real mruby', built)
    puts output unless built
    if built
      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      check.call('compiled answers what the interpreter answers, exceptions included',
                 !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
      puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
    end
  end
end

if failures.empty?
  puts 'bc2cpp entry arg alias check: PASS'
else
  warn "bc2cpp entry arg alias check: #{failures.size} failure(s)"
  exit 1
end
