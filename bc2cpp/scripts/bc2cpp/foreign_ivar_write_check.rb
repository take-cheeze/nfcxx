#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0279: an ivar keeps a typed slot (mrb_int, mrb_sym, mrb_bool, Integer-or-nil) only when
# every writer is one the compiler sees and has typed. A typed slot raises TypeError for any
# other value, where the interpreter stores it, so an ivar that
#   - an attr_writer/attr_accessor hands a value the compiler did not type (one call site passes a
#     String, `obj.count += 1` passes an arithmetic result that may be a bignum),
#   - a computed-name send reaches (`send("#{field}=", v)`),
#   - reflection names ('@x' Symbol/String literal for instance_variable_set/get),
#   - instance_variable_set with a computed name or a foreign source can write
# stays a boxed slot. Control ivars written only by typed sources keep their typed slot.
#
# 1. With MRBC: the generated layout (closed world), positive and negative cases.
# 2. With a mruby build and g++: interpreted and compiled answers agree, including the
#    writes that used to raise TypeError.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/foreign_ivar_write_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

# Typed sources only: the control. Its accessor is called with an Integer literal at its one site.
TYPED = <<~RUBY
  class FwTyped
    attr_accessor :fw_typed
    def initialize
      @fw_typed = 0
      @fw_plain = 0
      @fw_sym = :a
      @fw_flag = true
    end

    def fw_plain_read; @fw_plain; end
    def fw_plain_write; @fw_plain = 9; end
    def fw_sym_read; @fw_sym; end
    def fw_flag_read; @fw_flag; end
    def fw_typed_read; @fw_typed; end
  end

  class FwTypedDriver
    def fw_go
      b = FwTyped.new
      b.fw_typed = 5
      b
    end
  end
RUBY

# Writers the compiler cannot type: a String through an attr_writer, an arithmetic result
# through `+=`.
FOREIGN = <<~RUBY
  class FwBox
    attr_accessor :fw_str, :fw_inc
    def initialize
      @fw_str = 0
      @fw_inc = 0
    end

    def fw_str_read; @fw_str; end
    def fw_inc_read; @fw_inc; end
  end

  class FwDriver
    def fw_go
      b = FwBox.new
      b.fw_str = "text"
      b.fw_inc += 1
      b
    end
  end
RUBY

# Reflection by a literal name. (Layout only: the plain core has no instance_variable_set.)
LITERAL = <<~RUBY
  class FwLit
    def initialize
      @fw_lit = 0
      @fw_get = 0
    end

    def fw_lit_set; instance_variable_set(:@fw_lit, "s"); end
    def fw_lit_get; @fw_lit; end
    def fw_get_peek; instance_variable_get(:@fw_get); end
    def fw_get_read; @fw_get; end
  end
RUBY

# A setter reached by a computed name.
DYNAMIC = <<~RUBY
  class FwDyn
    attr_accessor :fw_dyn
    def initialize
      @fw_dyn = 0
    end

    def fw_dyn_read; @fw_dyn; end
  end

  class FwDynDriver
    def fw_go
      b = FwDyn.new
      field = "fw_dyn"
      b.__send__("\#{field}=", "computed")
      b
    end
  end
RUBY

REFLECTIVE = <<~RUBY
  class FwWild
    def initialize
      @fw_wild = 0
    end

    def fw_wild_read; @fw_wild; end

    def fw_poke(name, value)
      instance_variable_set(name, value)
    end
  end
RUBY

def slot_type(code, owner, field)
  struct = code[/struct #{owner}_ivars \{\n(.*?)\n\};/m, 1].to_s
  struct[/^\s*(\S+) ivar_#{field};/, 1]
end

def layout_of(runtime, source, owners)
  Dir.mktmpdir do |dir|
    code, = runtime.generate(source, dir, closed: true, only_owners: owners)
    yield code
  end
end

if ENV['MRBC']
  puts '-- generated layout (closed world)'
  layout_of(runtime, TYPED, %w[FwTyped FwTypedDriver]) do |code|
    { 'fw_plain' => 'mrb_int', 'fw_sym' => 'mrb_sym', 'fw_flag' => 'mrb_bool', 'fw_typed' => 'mrb_int' }.each do |field, type|
      check.call("@#{field}, written only by typed sources, keeps its #{type} slot", slot_type(code, 'FwTyped', field) == type)
    end
  end
  layout_of(runtime, FOREIGN, %w[FwBox FwDriver]) do |code|
    { 'fw_str' => 'a String through the attr_writer', 'fw_inc' => '`obj.x += 1` (an arithmetic result)' }.each do |field, why|
      check.call("NEG: @#{field} (#{why}) is a boxed slot", slot_type(code, 'FwBox', field) == 'mrb_value')
    end
  end
  layout_of(runtime, LITERAL, %w[FwLit]) do |code|
    { 'fw_lit' => 'a literal instance_variable_set', 'fw_get' => 'a literal instance_variable_get' }.each do |field, why|
      check.call("NEG: @#{field} (#{why}) is a boxed slot", slot_type(code, 'FwLit', field) == 'mrb_value')
    end
  end
  layout_of(runtime, DYNAMIC, %w[FwDyn FwDynDriver]) do |code|
    check.call('NEG: a setter reached by a computed-name send is a boxed slot', slot_type(code, 'FwDyn', 'fw_dyn') == 'mrb_value')
  end
  layout_of(runtime, TYPED + "\n" + REFLECTIVE, %w[FwTyped FwTypedDriver FwWild]) do |code|
    check.call('NEG: a computed instance_variable_set boxes every typed slot of the program',
               slot_type(code, 'FwTyped', 'fw_plain') == 'mrb_value' && slot_type(code, 'FwWild', 'fw_wild') == 'mrb_value')
  end
else
  puts '-- SKIP generated layout: set MRBC'
end

build = runtime.full || runtime.core
if ENV['MRBC'] && build && runtime.compiler?
  puts '-- fixture on real mruby, interpreted and compiled'
  Dir.mktmpdir do |dir|
    owners = %w[FwBox FwDriver FwDyn FwDynDriver FwTyped FwTypedDriver]
    _code, err = runtime.generate([FOREIGN, DYNAMIC, TYPED].join("\n"), dir, closed: true, only_owners: owners)
    body = <<~CPP
      static void reads(mrb_state* M, const char* tag, mrb_value obj, std::initializer_list<const char*> names) {
        for (const char* r : names) {
          std::string label = std::string(tag) + " " + r;
          call(M, label.c_str(), obj, r);
        }
      }
      // The driver's object is not shown: a compiled RData instance does not list its slots in #inspect.
      static mrb_value drive(mrb_state* M, const char* klass) {
        mrb_value r = mrb_funcall(M, mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr), "fw_go", 0);
        if (M->exc) { show_exc(M, klass); return mrb_nil_value(); }
        std::printf("%s ok\\n", klass);
        return r;
      }
      static int scenario(mrb_state* M) {
        mrb_value box = drive(M, "FwDriver");
        if (!mrb_nil_p(box)) reads(M, "box", box, { "fw_str_read", "fw_inc_read" });
        mrb_value dyn = drive(M, "FwDynDriver");
        if (!mrb_nil_p(dyn)) reads(M, "dyn", dyn, { "fw_dyn_read" });
        mrb_value typed = drive(M, "FwTypedDriver");
        if (!mrb_nil_p(typed)) {
          reads(M, "typed", typed, { "fw_typed_read", "fw_plain_read", "fw_sym_read", "fw_flag_read" });
          call(M, "typed fw_plain_write", typed, "fw_plain_write");
          reads(M, "typed after write", typed, { "fw_plain_read" });
        }
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, owners, "#include <string>\n#include <initializer_list>\n" + body, build: build,
                                                                                                          full: File.exist?("#{build}/lib/libmruby.a"))
    check.call('the fixture compiles and runs against real mruby', built)
    puts output unless built
    if built
      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      check.call('every read answers what the interpreter answers, writes that used to raise TypeError included',
                 !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
      puts output if values.call('interpreted') != values.call('compiled') || ENV['BC2CPP_CHECK_VERBOSE']
      check.call('the interpreter really stored the Strings',
                 %w["text" "computed"].all? { |v| values.call('interpreted').any? { |l| l.include?(v) } })
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_CORE (or _FULL) and have g++'
end

if failures.empty?
  puts 'bc2cpp foreign ivar write check: PASS'
else
  warn "bc2cpp foreign ivar write check: #{failures.size} failure(s)"
  exit 1
end
