#!/usr/bin/env ruby
# frozen_string_literal: true

# EQQ_DIRECT (docs/adr/0293): `===` and `is_a?`/`kind_of?` reach their mruby bodies by direct C
# calls. A receiver the bytecode proves (a stable class/module constant, an Integer constant or
# literal, a String/nil/true/false literal) is decided by that class's own body; every other
# receiver calls the shared bc2cpp_eqq, a tag switch whose only by-name send is its default arm;
# a non-class argument of is_a?/kind_of? raises mrb_get_args' TypeError in place.
#
# 1. With MRBC: generated code. The positive closed world has no by-name `===` or `is_a?` send
#    outside bc2cpp_eqq's default arm; each negative world (a Ruby `===` anywhere a receiver can
#    reach, an installer, a prepend, an `extend`, a BasicObject subclass, an open world) keeps the
#    dispatch.
# 2. With MRBC, rake and g++: the same fixtures on real mruby, interpreted and compiled, must
#    answer alike -- case/when over every kind of pattern and value, is_a?/kind_of? with classes,
#    modules, singleton classes and non-class arguments (the exact TypeError text) -- and the
#    compiled run must make exactly the by-name dispatches the shared helper's default arm does.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir|BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/eqq_direct_check.rb

require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

# How many by-name sends of `name` a C++ text makes: bc2cpp_send by symbol index, or a literal funcall.
# `within` narrows the count to one function body; the symbol table is always the file's.
sends_of = lambda do |code, name, within = code|
  names = code[/bc2cpp_sym_names\[\d+\] = \{(.*?)\};/m, 1].to_s.scan(/"((?:[^"\\]|\\.)*)"/).flatten
  index = names.index(name)
  by_index = index ? within.scan(/bc2cpp_send\(M, [^,]+, #{index},/).size : 0
  by_index + within.scan(/mrb_funcall\(M, [^,]+, "#{Regexp.escape(name)}"/).size
end

WORLD = <<~RUBY
  module EqMix; end
  module EqPre; end
  class EqBase; include EqMix; end
  class EqKid < EqBase; end
  class EqPlain; end
  EQ_LOW = 12
  EQ_HI = 8
  class EqFx
    def sw(x)
      case x
      when EQ_LOW then :low
      when EQ_HI then :hi
      when -7 then :neg
      when 100000 then :big
      when :sym then :sym
      when "str" then :str
      when nil then :nil
      when true then :true
      when false then :false
      when Integer then :int
      when Float then :float
      when EqMix then :mix
      when EqBase then :base
      when Comparable then :cmp
      when 200..300 then :range
      else :else
      end
    end
    def pat(pattern, x)
      case x
      when pattern then :hit
      else :miss
      end
    end
    def isa(x, c); x.is_a?(c); end
    def kind(x, c); x.kind_of?(c); end
    def lit(x); [x.is_a?(EqBase), x.kind_of?(EqMix), x.is_a?(Comparable), x.is_a?(Kernel)]; end
  end
  class EqDrive
    def self.one
      yield
    rescue Exception => e
      [e.class, e.message]
    end
    def self.sw_all(fx, vals); vals.map { |v| one { fx.sw(v) } }; end
    def self.lit_all(fx, vals); vals.map { |v| one { fx.lit(v) } }; end
    def self.pat_all(fx, pats, vals); pats.map { |p| vals.map { |v| one { fx.pat(p, v) } } }; end
    def self.isa_all(fx, vals, classes)
      classes.map { |c| vals.map { |v| [one { fx.isa(v, c) }, one { fx.kind(v, c) }] } }
    end
  end
RUBY

# The whole file's by-name `===` sends sit in bc2cpp_eqq's default arm.
puts '-- generated code, positive closed world'
Dir.mktmpdir do |dir|
  code, = runtime.generate(WORLD, dir)
  sw = body_of.call(code, 'EqFx_sw')
  pat = body_of.call(code, 'EqFx_pat')
  isa = body_of.call(code, 'EqFx_isa')
  kind = body_of.call(code, 'EqFx_kind')
  lit = body_of.call(code, 'EqFx_lit')
  check.call('the methods are compiled', [sw, pat, isa, kind, lit].none?(&:empty?))
  check.call('case/when over constants and literals makes no by-name === (the Range literal and Comparable use the helper)',
             sends_of.call(code, '===', sw).zero? && sw.scan('= bc2cpp_eqq(M,').size == 2 && !sw.include?('mrb_funcall('))
  check.call('a stable class/module constant arm is mrb_obj_is_kind_of on the constant',
             sw.scan('EQQ_DIRECT class/module constant').size == 4 && sw.scan('mrb_obj_is_kind_of(M, r').size == 4)
  check.call('Integer constants and literals compare natively, anything else through mrb_equal',
             sw.scan('EQQ_DIRECT Integer constant/literal').size == 4 && sw.include?('mrb_fixnum(r') &&
               sw.scan('mrb_equal(M, r').size >= 4)
  check.call('String, nil, true and false literals take mrb_equal',
             %w[string nil true false].all? { |k| sw.include?("EQQ_DIRECT #{k} literal") })
  check.call('a receiver of unknown class is one call of the shared helper',
             pat.scan(/= bc2cpp_eqq\(M, r\d+, r\d+\);/).size == 1 && sends_of.call(code, '===', pat).zero?)
  check.call('the helper is emitted once, with the by-name send only in its default arm',
             code.scan(/^static mrb_value bc2cpp_eqq\(/).size == 1 && sends_of.call(code, '===') == 1 &&
               code[/^static mrb_value bc2cpp_eqq\(.*?^\}/m].to_s.include?('default:'))
  check.call('the helper answers class/module, Range and the Kernel#=== tags itself',
             %w[MRB_TT_CLASS MRB_TT_MODULE MRB_TT_SCLASS MRB_TT_RANGE MRB_TT_INTEGER MRB_TT_STRING MRB_TT_SYMBOL
                MRB_TT_ARRAY MRB_TT_HASH].all? { |t| code[/^static mrb_value bc2cpp_eqq\(.*?^\}/m].to_s.include?("case #{t}:") })
  [['is_a?', isa], ['kind_of?', kind]].each do |name, body|
    check.call("#{name} raises the TypeError in place, with no dispatch",
               body.match?(/mrb_raisef\(M, mrb_exc_get_id\(M, .*?\), "%v is not class\/module"/) && sends_of.call(code, name, body).zero? &&
                 body.include?('mrb_sclass_p('))
  end
  check.call('no by-name is_a?/kind_of? remains in the file', sends_of.call(code, 'is_a?').zero? && sends_of.call(code, 'kind_of?').zero?)
  check.call('constant arguments need no class test of their own beyond the argument check',
             lit.scan('mrb_obj_is_kind_of(M, r').size == 4)
end

# Each world changes one thing that could give a receiver another `===` / `is_a?`.
NEGATIVES = {
  'a Ruby === on a user class' => "class EqPlain; def ===(o); true; end; end\n",
  'a singleton === on a class constant' => "class EqPlain; def self.===(o); true; end; end\n",
  'a === in a singleton class body' => "class EqPlain; class << self; def ===(o); true; end; end; end\n",
  'a Ruby Integer#===' => "class Integer; def ===(o); true; end; end\n",
  'a Ruby String#===' => "class String; def ===(o); true; end; end\n",
  'a Ruby NilClass#===' => "class NilClass; def ===(o); true; end; end\n",
  'a Ruby Module#===' => "class Module; def ===(o); true; end; end\n",
  'a === in Kernel' => "module Kernel; def ===(o); true; end; end\n",
  'a === in a prepended module' => "module EqPre; def ===(o); true; end; end\nclass Integer; prepend EqPre; end\n",
  'a === in an included module' => "module EqPre; def ===(o); true; end; end\nclass EqPlain; include EqPre; end\n",
  'an alias_method of === on Integer' => "class Integer; alias_method :===, :equal?; end\n",
  'an alias keyword of === on Integer' => "class Integer; alias :=== :equal?; end\n",
  'an undef_method of === on Integer' => "class Integer; undef_method :===; end\n",
  'a Symbol-named define_method of === on Integer' => "class Integer; define_method(:===) { |o| true }; end\n",
  'a computed define_method name' => "class Integer; n = :\"===\"; define_method(n) { |o| true }; end\n",
  'an alias_method on a singleton class' => "class << EqBase; alias_method :===, :equal?; end\n",
  'a define_singleton_method(:===)' => "EqBase.define_singleton_method(:===) { |o| true }\n",
  'an extend' => "module EqExt; def ===(o); true; end; end\nEqBase.extend(EqExt)\n"
}.freeze

puts '-- generated code, negative worlds keep the dispatch'
NEGATIVES.each do |what, extra|
  Dir.mktmpdir do |dir|
    code, = runtime.generate(WORLD + extra, dir)
    sw = body_of.call(code, 'EqFx_sw')
    check.call("#{what}: case/when makes no EQQ_DIRECT arm", !sw.empty? && !sw.include?('EQQ_DIRECT'))
    check.call("#{what}: the dispatch stays", sends_of.call(code, '===') >= 1)
  end
end

# is_a?: a Ruby definition, an alias or undef, or a BasicObject subclass (no Kernel to answer), keeps the dispatch.
IS_A_NEGATIVES = {
  'a Ruby is_a?' => ["class EqPlain; def is_a?(c); true; end; end\n", %w[is_a?]],
  'a Ruby kind_of?' => ["class EqPlain; def kind_of?(c); true; end; end\n", %w[kind_of?]],
  'an alias_method of is_a?' => ["class Object; alias_method :is_a?, :equal?; end\n", %w[is_a?]],
  'an undef_method of kind_of?' => ["class Object; undef_method :kind_of?; end\n", %w[kind_of?]],
  'a BasicObject subclass' => ["class EqBare < BasicObject; end\n", %w[is_a? kind_of?]],
  'a class built from BasicObject' => ["EqDyn = Class.new(BasicObject)\n", %w[is_a? kind_of?]]
}.freeze
IS_A_NEGATIVES.each do |what, (extra, names)|
  Dir.mktmpdir do |dir|
    code, = runtime.generate(WORLD + extra, dir)
    bodies = { 'is_a?' => body_of.call(code, 'EqFx_isa'), 'kind_of?' => body_of.call(code, 'EqFx_kind') }
    names.each do |name|
      check.call("#{what}: #{name} does not raise the TypeError in place", !bodies[name].empty? && !bodies[name].include?('mrb_raisef'))
    end
    check.call("#{what}: the by-name send stays", sends_of.call(code, names.first, bodies[names.first]).positive?) if what.match?(/BasicObject|alias/)
    other = (%w[is_a? kind_of?] - names).first if names.size == 1
    check.call("#{what}: the other name still raises in place", bodies[other].include?('mrb_raisef')) if other && what.match?(/Ruby/)
  end
end

puts '-- generated code, open world'
Dir.mktmpdir do |dir|
  code, = runtime.generate(WORLD, dir, closed: false)
  sw = body_of.call(code, 'EqFx_sw')
  isa = body_of.call(code, 'EqFx_isa')
  check.call('an open world has no EQQ_DIRECT arm and keeps the TypeError dispatch',
             !sw.empty? && !sw.include?('EQQ_DIRECT') && !isa.include?('mrb_raisef') && sends_of.call(code, 'is_a?', isa) == 1)
end

full = runtime.full_or_build
if full.nil? || !runtime.compiler?
  puts '  SKIP run: needs rake, g++ and 3rd/mruby (or BC2CPP_MRUBY_FULL)'
else
  puts '-- fixtures on real mruby, interpreted and compiled'
  # Values and patterns are built after the bytecode loads, so singleton classes, lambdas and
  # runtime-made objects exist without the fixture's own Ruby spelling them.
  scenario = <<~CPP
    static mrb_value ev(mrb_state* M, const char* src) {
      mrb_value v = mrb_load_string(M, src);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
      mrb_gc_protect(M, v);
      return v;
    }
    // The call's value, or the exception class and message: the TypeError text is compared too.
    static void call_msg(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc, const mrb_value* argv) {
      dispatches = 0;
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      int made = dispatches;
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value msg = (mrb_funcall)(M, e, "message", 0);
        std::printf("%s => raised %s: %.*s\\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
      } else {
        show(M, label, r);
      }
      if (compiled) std::printf("  dispatches=%d\\n", made);
    }
    static int scenario(mrb_state* M) {
      mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "EqFx"), 0, nullptr);
      mrb_gc_protect(M, fx);
      mrb_value drive = mrb_obj_value(mrb_class_get(M, "EqDrive"));
      mrb_value vals = ev(M, "[3, 8, -7, 0, 100000, 3.0, 8.0, 5.5, 250, 250.5, 2**40, 2**70, :sym, :other, 'str', 'zzz', "
                             "nil, true, false, [], {}, 1..3, Object.new, EqBase.new, EqKid.new, EqPlain.new, "
                             "lambda { 1 }, Class, EqMix, Comparable, Struct.new(:a).new(1), RuntimeError.new('x'), "
                             "(o = Object.new; o.extend(EqMix); o), (o = EqPlain.new; class << o; def hi; end; end; o)]");
      mrb_value pats = ev(M, "[3, 8, -7, 100000, 3.0, 250.0, :sym, 'str', nil, true, false, Integer, Float, String, "
                             "EqMix, EqBase, EqKid, Comparable, Kernel, Object, BasicObject, Class, Module, 1..3, 200..300, "
                             "(1..), (..5), (1...3), ('a'..'z'), (1.0..2.5), [], {}, lambda { |v| v == :sym }, "
                             "proc { |v| v.nil? }, EqPlain.new, Object.new, Struct.new(:a), 2**70]");
      mrb_value classes = ev(M, "[EqBase, EqMix, EqKid, EqPlain, Kernel, Comparable, Integer, Object, BasicObject, Class, Module, "
                                "Proc, nil, 3, 'str', :sym, [EqBase], Object.new, EqPlain.new.singleton_class, "
                                "EqBase.singleton_class, Float, String]");
      mrb_value a2[2] = { fx, vals };
      call_msg(M, "sw_all", drive, "sw_all", 2, a2);
      call_msg(M, "lit_all", drive, "lit_all", 2, a2);
      mrb_value a3[3] = { fx, pats, vals };
      call_msg(M, "pat_all", drive, "pat_all", 3, a3);
      mrb_value b3[3] = { fx, vals, classes };
      call_msg(M, "isa_all", drive, "isa_all", 3, b3);
      std::printf("counts vals=%d pats=%d\\n", (int)RARRAY_LEN(vals), (int)RARRAY_LEN(pats));
      return 0;
    }
  CPP
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(WORLD, dir, closed: true, only_owners: %w[EqFx])
    built, output = runtime.run(dir, err, %w[EqFx], scenario, build: full, full: true, exact_arity: true)
    check.call('the fixture compiles and runs against real mruby', built)
    puts output unless built
    if built
      sections = runtime.sections(output)
      # Object#inspect text carries an address that differs per VM.
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') || l.start_with?('counts') }.map { |l| l.gsub(/0x\h+/, '0xADDR') } }
      interpreted = values.call('interpreted')
      compiled = values.call('compiled')
      check.call("compiled answers what the interpreter answers (#{interpreted.size} calls, #{interpreted.join.size} bytes)",
                 interpreted.size == 4 && interpreted == compiled)
      interpreted.zip(compiled).each { |i, c| puts "    interpreted: #{i[0, 600]}\n    compiled:    #{c.to_s[0, 600]}" unless i == c }
      check.call('the TypeError text for a non-class argument matches the interpreter',
                 interpreted.grep(/isa_all/).first.to_s.include?('is not class/module'))
      check.call('the case/when values really differ per value (the comparison is not vacuous)',
                 interpreted.grep(/sw_all/).first.to_s.scan(/:low|:hi|:neg|:big|:sym|:str|:nil|:true|:false|:int|:float|:mix|:base|:cmp|:range|:else/).uniq.size >= 12)
      counts = sections.fetch('compiled', []).grep(/\Acounts/).first.to_s.scan(/\d+/).map(&:to_i)
      vals, = counts
      per = sections.fetch('compiled', []).each_cons(2).select { |l, n| l.match?(/\A(sw_all|lit_all|pat_all|isa_all) =>/) && n.include?('dispatches=') }
                    .to_h { |l, n| [l[/\A\w+/], n[/dispatches=(\d+)/, 1].to_i] }
      check.call('case/when over constants and literals, and is_a?, make no dynamic dispatch',
                 per['sw_all'].zero? && per['lit_all'].zero? && per['isa_all'].zero?)
      # lambda, proc, EqPlain.new, Object.new and the bigint 2**70: the only default-arm receivers.
      check.call('a pattern the helper cannot answer dispatches exactly once per value',
                 per['pat_all'] == 5 * vals)
    end
  end

  # The same scenario where the Ruby program redefines `===`: the dispatch stays and still answers like the interpreter.
  NEGATIVES.each do |what, extra|
    next unless ['a Ruby === on a user class', 'a singleton === on a class constant', 'a Ruby Integer#===',
                 'a Ruby NilClass#===', 'a Ruby Module#===', 'a === in a prepended module',
                 'an alias_method of === on Integer', 'an undef_method of === on Integer',
                 'a Symbol-named define_method of === on Integer'].include?(what)

    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(WORLD + extra, dir, closed: true, only_owners: %w[EqFx])
      built, output = runtime.run(dir, err, %w[EqFx], scenario, build: full, full: true, exact_arity: true)
      sections = built ? runtime.sections(output) : {}
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') || l.start_with?('counts') }.map { |l| l.gsub(/0x\h+/, '0xADDR') } }
      check.call("#{what}: compiled answers what the interpreter answers",
                 built && values.call('interpreted').size == 4 && values.call('interpreted') == values.call('compiled'))
    end
  end
end

puts(failures.empty? ? 'bc2cpp_eqq_direct_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
