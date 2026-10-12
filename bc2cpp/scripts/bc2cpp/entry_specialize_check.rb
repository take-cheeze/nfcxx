#!/usr/bin/env ruby
# frozen_string_literal: true

# Check ENTRY_GUARDED_SPECIALIZATION (docs/adr/0380): BC2CPP_SPECIALIZE=<plan> compiles a second body of a
# listed method under "these parameters are exactly these classes" and puts one entry check in front of the
# original body, which is otherwise untouched.
#
# 1. Generated code (needs MRBC):
#    * gate off (unset, empty, `0`, an empty plan): no specialized function, no guard, the same bytes;
#    * gate on: the specialized body resolves the sends the generic body dispatches by name, the guard tests
#      the exact class (the object's own class pointer; fixnum only for Integer), and the generic `_impl` is
#      byte-for-byte what the gate-off build emitted apart from the guard line;
#    * an identity clone (a plan line with no parameter) reproduces the generic body, which is what shows the
#      clone path misses no label-keyed table;
#    * negatives: blocks, rescue, optional/keyword/block parameters, a class with no exact test, a parameter
#      that is not positional, an unknown class, a world with a singleton maker and the open world all keep
#      the generic body only, and say why on stderr.
# 2. Behaviour on real mruby: every call, guard hit or guard miss, answers what the interpreter answers; a hit
#    makes fewer dynamic dispatches than a miss of the same method.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/entry_specialize_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

SOURCE = <<~RUBY
  class SpBox
    def initialize; @n = 3; end
    def tag; :box; end
    def val; @n; end
  end

  class SpSub < SpBox
    def tag; :sub; end
    def val; 100; end
  end

  class SpOther
    def tag; :other; end
    def val; 9; end
  end

  class SpHash < Hash
    def key?(k); :sub_key; end
    def [](k); :sub_get; end
  end

  class SpHost
    # -- eligible: one required positional parameter assumed to be one class
    def use_box(b, k); b.tag; end
    def use_val(b); b.val + 1; end
    def use_hash(h, k); h.key?(k) ? h[k] : 0; end
    def use_int(n); n == 3 ? 1 : (n < 10 ? 2 : 3); end
    def use_int_math(n); n * 2 + 1; end
    def use_float(f); f + 0.5; end
    # nil alone proves nothing the flow uses (only nil-or-one-class does, ADR 0296): not a specializable class
    def use_nil(x); x.nil? ? :nil : x.tag; end
    def use_two(h, n); h.key?(n) ? n + 1 : 0; end
    def use_str(s); s.empty? ? :empty : :full; end
    def use_ary(a); a.empty? ? :empty : :full; end
    def use_range(r); r.first; end

    # -- not eligible
    def with_block(b); [1].each { |i| b.tag }; end
    def with_opt(b, c = 1); b.tag; end
    def with_kw(b, k: 1); b.tag; end
    def with_rescue(b); b.tag; rescue; :r; end
    def with_yield(b); yield b.tag; end
    def with_amp(b, &blk); b.tag; end
    def with_rest(b, *r); b.tag; end

    # -- a plan line the compiler must refuse
    def use_sym(s); s.to_s; end
    # the assumption resolves nothing here: the specialized body would equal the generic one, so it is dropped
    def use_noop(h); 42; end
    def use_zz(b, k); b.tag; end

    # -- same body twice: the unlisted one is the control that nothing leaks into
    def plain_box(b); b.tag; end

    # -- every call site passes a SpBox, so the call-site pools already make it exact: the control that the clone
    # carries what the generic body knows (the identity clone must compile to the same exact call)
    def use_exact(b); b.tag; end

    # Every listed method has call sites of other classes too, so no call-site proof makes the parameter exact
    # and only the entry check can.
    def drive(x)
      [use_box(SpBox.new, 1), use_box(SpSub.new, 1), use_box(SpOther.new, 2), use_box(x, 3),
       use_val(SpBox.new), use_val(SpOther.new), use_val(x), use_zz(SpBox.new, 1),
       use_hash({ 1 => 2 }, 1), use_hash(x, 1), use_hash([1], 1), use_int(3), use_int(1.5), use_int(x),
       use_int_math(4), use_int_math(x), use_float(1.5), use_float(x), use_nil(nil), use_nil(SpBox.new), use_nil(x),
       use_two({ 1 => 2 }, 1), use_two(x, x), use_str('a'), use_str(x), use_ary([1]), use_ary(x),
       use_range(1..2), use_range(x), plain_box(SpBox.new), plain_box(x), use_exact(SpBox.new), use_noop(x)]
    end
  end
RUBY

PLAN = <<~PLAN
  # a comment
  SpHost#use_box b=SpBox
  SpHost#use_val b=SpBox
  SpHost#use_hash h=Hash
  SpHost#use_int n=Integer
  SpHost#use_int_math n=Integer
  SpHost#use_float f=Float
  SpHost#use_nil x=NilClass
  SpHost#use_two h=Hash n=Integer
  SpHost#use_str s=String
  SpHost#use_ary a=Array
  SpHost#use_range r=Range
  SpHost#with_block b=SpBox
  SpHost#with_opt b=SpBox
  SpHost#with_kw b=SpBox
  SpHost#with_rescue b=SpBox
  SpHost#with_yield b=SpBox
  SpHost#with_amp b=SpBox
  SpHost#with_rest b=SpBox
  SpHost#use_sym s=Symbol
  SpHost#use_noop h=Hash
  SpHost#plain_box b=NoSuchClass
  SpHost#use_zz k=Integer zz=Integer
PLAN

OWNERS = %w[SpBox SpSub SpOther SpHash SpHost].freeze

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
# One whole function, from its signature to the fell-off-the-end guard every compiled body ends with.
fn_text = lambda do |code, prefix, name|
  code[/^#{prefix}mrb_value #{name}\(mrb_state\* M.*?fell off the end of its body"\);\n\}\n/m].to_s
end
spec_of = lambda do |code, owner, fn|
  fn_text.call(code, '\[\[maybe_unused\]\] static ', "#{owner}_#{fn}_spec_impl")
end
GUARD_LINE = /^  if \(.*\) return \w+_spec_impl\(.*\n/

generate = lambda do |source, dir, plan: nil, env: {}, **options|
  env = env.merge('BC2CPP_SPECIALIZE' => plan) if plan
  saved = (env.keys | ['BC2CPP_SPECIALIZE']).to_h { |k| [k, ENV.fetch(k, nil)] }
  ENV.delete('BC2CPP_SPECIALIZE')
  env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  begin
    runtime.generate(source, dir, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    plan = File.join(dir, 'plan.txt')
    File.write(plan, PLAN)
    off_dir = File.join(dir, 'off')
    on_dir = File.join(dir, 'on')
    Dir.mkdir(off_dir)
    Dir.mkdir(on_dir)
    off, = generate.call(SOURCE, off_dir)
    on, on_err = generate.call(SOURCE, on_dir, plan: plan)

    # -- gate off
    gates = { '0' => '0', 'empty' => '', 'an empty plan file' => File.join(dir, 'empty.txt') }
    File.write(gates.fetch('an empty plan file'), "# nothing\n")
    gates.each do |what, value|
      d = File.join(dir, "gate_#{what.gsub(/\W+/, '_')}")
      Dir.mkdir(d)
      code = begin
        generate.call(SOURCE, d, env: { 'BC2CPP_SPECIALIZE' => value }).first
      rescue RuntimeError => e
        e.message
      end
      check.call("gate off (#{what}): byte-identical to the unset build", code == off)
    end
    check.call('gate off: no specialized function, no entry check', !off.include?('_spec_impl') && !off.include?('ENTRY_SPECIALIZED'))

    # -- gate on, positive
    check.call('gate on: the build still generates and differs', on != off)
    shaped = {
      'use_box' => 'SpBox', 'use_val' => 'SpBox', 'use_hash' => 'Hash', 'use_int' => 'Integer', 'use_int_math' => 'Integer',
      'use_float' => 'Float', 'use_two' => 'Hash+Integer', 'use_str' => 'String',
      'use_ary' => 'Array', 'use_range' => 'Range'
    }
    shaped.each do |fn, klass|
      check.call("SpHost##{fn} (#{klass}): a specialized body and one entry check ahead of the generic body",
                 !spec_of.call(on, 'SpHost', fn).empty? && body_of.call(on, 'SpHost', fn).lines.count { |l| l.match?(GUARD_LINE) } == 1)
      generic = body_of.call(on, 'SpHost', fn).sub(GUARD_LINE, '')
      check.call("SpHost##{fn}: the generic body is byte-for-byte the gate-off body apart from the guard line",
                 generic == body_of.call(off, 'SpHost', fn))
    end
    check.call('plain_box (no usable plan line) and drive (unlisted) are untouched',
               body_of.call(on, 'SpHost', 'plain_box') == body_of.call(off, 'SpHost', 'plain_box') &&
                 body_of.call(on, 'SpHost', 'drive') == body_of.call(off, 'SpHost', 'drive'))

    box = spec_of.call(on, 'SpHost', 'use_box')
    check.call('a user class: the by-name send is a direct call, no class-tag chain, no nomethod fallback',
               box.include?('SpBox_tag_impl(M, r') && !box.include?('bc2cpp_owner_class_') && !box.include?('bc2cpp_nomethod') &&
                 body_of.call(on, 'SpHost', 'use_box').include?('bc2cpp_nomethod'))
    check.call('a user class: the guard compares the object\'s own class pointer (a subclass or a singleton misses)',
               body_of.call(on, 'SpHost', 'use_box')[GUARD_LINE].to_s.match?(/!mrb_immediate_p\(b\) && mrb_obj_ptr\(b\)->c == bc2cpp_owner_class_\d+\(M\)/) &&
                 !body_of.call(on, 'SpHost', 'use_box')[GUARD_LINE].to_s.include?('mrb_obj_class') &&
                 !body_of.call(on, 'SpHost', 'use_box')[GUARD_LINE].to_s.include?('kind_of'))
    check.call('Hash: the guard is the exact class, the specialized body calls the native bodies with no test',
               body_of.call(on, 'SpHost', 'use_hash')[GUARD_LINE].to_s.include?('if ((mrb_hash_p(h) && mrb_obj_ptr(h)->c == M->hash_class)) return') &&
                 spec_of.call(on, 'SpHost', 'use_hash').include?('mrb_hash_key_p') &&
                 !spec_of.call(on, 'SpHost', 'use_hash').include?('bc2cpp_send('))
    check.call('Integer: the guard is a fixnum test (a bigint, a Float and nil take the generic body)',
               body_of.call(on, 'SpHost', 'use_int')[GUARD_LINE].to_s.include?('if ((mrb_fixnum_p(n))) return') &&
                 !body_of.call(on, 'SpHost', 'use_int')[GUARD_LINE].to_s.include?('mrb_integer_p'))
    check.call('two parameters: both are tested, in one condition',
               body_of.call(on, 'SpHost', 'use_two')[GUARD_LINE].to_s.match?(/mrb_hash_p\(h\).*&&.*mrb_fixnum_p\(n\)/))
    check.call('the diagnostic lists every specialization on stderr',
               on_err.include?('bc2cpp: specialize: SpHost#use_box b=SpBox') && on_err.include?('SpHost#use_two h=Hash n=Integer'))

    # -- negatives: each keeps only the generic body
    { 'with_block' => 'block fallback regions', 'with_opt' => 'optional, rest or keyword parameters',
      'with_kw' => 'optional, rest or keyword parameters', 'with_rescue' => 'has a rescue/ensure range',
      'with_yield' => 'takes or yields to a block', 'with_amp' => 'optional, rest or keyword parameters',
      'with_rest' => 'optional, rest or keyword parameters', 'use_sym' => 'has no exact entry test',
      'plain_box' => 'has no exact entry test', 'use_nil' => 'has no exact entry test',
      'use_noop' => 'the assumption changes nothing' }.each do |fn, why|
      check.call("NEG SpHost##{fn}: stays generic (#{why})",
                 spec_of.call(on, 'SpHost', fn).empty? && !body_of.call(on, 'SpHost', fn).match?(GUARD_LINE) &&
                   on_err.match?(/bc2cpp: specialize: SpHost##{fn} stays generic: .*#{Regexp.escape(why)}/))
    end
    check.call('NEG: a parameter the method does not have refuses the whole line (k alone would have been fine)',
               on_err.include?('SpHost#use_zz stays generic: zz is not a required positional parameter') &&
                 spec_of.call(on, 'SpHost', 'use_zz').empty?)

    # -- identity clone: the clone path reproduces the generic body
    id_plan = File.join(dir, 'identity.txt')
    File.write(id_plan, "SpHost#use_box\nSpHost#use_hash\nSpHost#use_int\nSpHost#use_two\nSpHost#use_exact\nSpHost#drive\n")
    id_dir = File.join(dir, 'identity')
    Dir.mkdir(id_dir)
    id_code, id_err = generate.call(SOURCE, id_dir, plan: id_plan)
    %w[use_box use_hash use_int use_two use_exact drive].each do |fn|
      spec = spec_of.call(id_code, 'SpHost', fn).sub(/_spec_impl/, '_impl').sub('[[maybe_unused]] static ', '')
      check.call("identity clone SpHost##{fn}: the clone compiles to the generic body (every label-keyed table is carried)",
                 !spec.empty? && spec == fn_text.call(off, '', "SpHost_#{fn}_impl") &&
                   !body_of.call(id_code, 'SpHost', fn).match?(GUARD_LINE))
    end
    check.call('identity clones are listed as such', id_err.include?('SpHost#use_box (identity clone)'))
    check.call('the call-site facts the generic body has (use_exact: every site passes a SpBox) are in the clone too',
               spec_of.call(id_code, 'SpHost', 'use_exact').include?('CLOSED_WORLD_EXACT_CLASS :tag') &&
                 !spec_of.call(id_code, 'SpHost', 'use_exact').include?('bc2cpp_nomethod'))

    # -- worlds that must withdraw
    singleton = "class SpHost\n  def maker; a = [1]; def a.other(*); 1; end; a; end\nend\n"
    Dir.mktmpdir do |d|
      code, err = generate.call(SOURCE + singleton, d, plan: plan)
      check.call('NEG a singleton maker in the world: no specialization anywhere, the guard cannot trust the class',
                 !code.include?('_spec_impl') && err.include?('stays generic: no exact-class world'))
    end
    Dir.mktmpdir do |d|
      code, err = generate.call(SOURCE, d, plan: plan, closed: false)
      check.call('NEG the open world: no specialization', !code.include?('_spec_impl') && err.include?('stays generic: no exact-class world'))
    end
    Dir.mktmpdir do |d|
      code, = generate.call(SOURCE, d, plan: plan, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('NEG BC2CPP_CLASS_POOLS=0 (the kill switch of the pools the clone is compiled through): no specialization',
                 !code.include?('_spec_impl'))
    end
    Dir.mktmpdir do |d|
      missing = File.join(d, 'missing.txt')
      failed = begin
        generate.call(SOURCE, File.join(d, 'x').tap { |p| Dir.mkdir(p) }, plan: missing)
        false
      rescue RuntimeError => e
        e.message.include?('no such file')
      end
      check.call('a plan file that does not exist fails the build loudly (a typo must not silently build generic)', failed)
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

build = runtime.full || runtime.core || runtime.full_or_build
if ENV['MRBC'] && build && runtime.compiler? && !ENV['SP_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  body = <<~'CPP'
    #include <cstdlib>
    #include <cstring>
    #include <mruby/string.h>
    #include <mruby/range.h>
    static mrb_value sp_obj(mrb_state* M, const char* cls) { return mrb_obj_new(M, mrb_class_get(M, cls), 0, nullptr); }
    static void sp_call(mrb_state* M, const char* label, mrb_value host, const char* meth, int argc, const mrb_value* argv) {
      dispatches = 0;
      sp_spec_runs = 0;
      mrb_value r = (mrb_funcall_argv)(M, host, mrb_intern_cstr(M, meth), argc, argv);
      int made = dispatches;
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        std::printf("%s => raised %s\n", label, mrb_obj_classname(M, e));
      } else {
        show(M, label, r);
      }
      if (compiled) std::printf("  dispatches=%d\n  spec=%d\n", made, sp_spec_runs);
    }
    static int scenario(mrb_state* M) {
      mrb_value host = sp_obj(M, "SpHost");
      mrb_value box = sp_obj(M, "SpBox"), sub = sp_obj(M, "SpSub"), other = sp_obj(M, "SpOther");
      mrb_value nil = mrb_nil_value(), one = mrb_fixnum_value(1), three = mrb_fixnum_value(3);
      mrb_value hash = mrb_hash_new(M);
      mrb_hash_set(M, hash, one, mrb_fixnum_value(2));
      mrb_value subhash = sp_obj(M, "SpHash");
      mrb_hash_set(M, subhash, one, mrb_fixnum_value(2));
      mrb_value str = mrb_str_new_cstr(M, "a"), empty = mrb_str_new_cstr(M, "");
      mrb_value ary = mrb_ary_new(M), full = mrb_ary_new(M);
      mrb_ary_push(M, full, one);
      mrb_value range = mrb_range_new(M, one, three, FALSE);
      mrb_value flt = mrb_float_value(M, 1.5);
      mrb_value big = mrb_fixnum_value(1000000);
      mrb_value a2[2];

      // an object with the guarded class, a subclass, another class and nil, against use_box/use_val
      sp_call(M, "use_box hit", host, "use_box", 2, (a2[0] = box, a2[1] = one, a2));
      sp_call(M, "use_box subclass", host, "use_box", 2, (a2[0] = sub, a2[1] = one, a2));
      sp_call(M, "use_box other", host, "use_box", 2, (a2[0] = other, a2[1] = one, a2));
      sp_call(M, "use_box nil", host, "use_box", 2, (a2[0] = nil, a2[1] = one, a2));
      sp_call(M, "use_box int", host, "use_box", 2, (a2[0] = three, a2[1] = one, a2));
      sp_call(M, "use_val hit", host, "use_val", 1, &box);
      sp_call(M, "use_val subclass", host, "use_val", 1, &sub);
      sp_call(M, "use_val other", host, "use_val", 1, &other);
      sp_call(M, "use_val nil", host, "use_val", 1, &nil);
      // Hash, a Hash subclass that overrides key? and [], nil, an Array
      sp_call(M, "use_hash hit", host, "use_hash", 2, (a2[0] = hash, a2[1] = one, a2));
      sp_call(M, "use_hash miss key", host, "use_hash", 2, (a2[0] = hash, a2[1] = three, a2));
      sp_call(M, "use_hash subclass", host, "use_hash", 2, (a2[0] = subhash, a2[1] = one, a2));
      sp_call(M, "use_hash nil", host, "use_hash", 2, (a2[0] = nil, a2[1] = one, a2));
      sp_call(M, "use_hash array", host, "use_hash", 2, (a2[0] = full, a2[1] = one, a2));
      // Integer: a fixnum, a Float, nil, a String, a big fixnum
      sp_call(M, "use_int 3", host, "use_int", 1, &three);
      sp_call(M, "use_int 1", host, "use_int", 1, &one);
      sp_call(M, "use_int big", host, "use_int", 1, &big);
      sp_call(M, "use_int float", host, "use_int", 1, &flt);
      sp_call(M, "use_int nil", host, "use_int", 1, &nil);
      sp_call(M, "use_int str", host, "use_int", 1, &str);
      sp_call(M, "use_int_math 4", host, "use_int_math", 1, &three);
      sp_call(M, "use_int_math max", host, "use_int_math", 1, (a2[0] = mrb_fixnum_value(MRB_INT_MAX), a2));
      sp_call(M, "use_int_math float", host, "use_int_math", 1, &flt);
      sp_call(M, "use_int_math nil", host, "use_int_math", 1, &nil);
      // Float, nil, String, Array, Range
      sp_call(M, "use_float hit", host, "use_float", 1, &flt);
      sp_call(M, "use_float int", host, "use_float", 1, &three);
      sp_call(M, "use_float nil", host, "use_float", 1, &nil);
      sp_call(M, "use_nil hit", host, "use_nil", 1, &nil);
      sp_call(M, "use_nil box", host, "use_nil", 1, &box);
      sp_call(M, "use_nil other", host, "use_nil", 1, &other);
      sp_call(M, "use_nil int", host, "use_nil", 1, &three);
      sp_call(M, "use_two hit", host, "use_two", 2, (a2[0] = hash, a2[1] = one, a2));
      sp_call(M, "use_two first misses", host, "use_two", 2, (a2[0] = subhash, a2[1] = one, a2));
      sp_call(M, "use_two second misses", host, "use_two", 2, (a2[0] = hash, a2[1] = flt, a2));
      sp_call(M, "use_two both miss", host, "use_two", 2, (a2[0] = nil, a2[1] = nil, a2));
      sp_call(M, "use_str hit", host, "use_str", 1, &str);
      sp_call(M, "use_str empty", host, "use_str", 1, &empty);
      sp_call(M, "use_str ary", host, "use_str", 1, &ary);
      sp_call(M, "use_ary hit", host, "use_ary", 1, &full);
      sp_call(M, "use_ary empty", host, "use_ary", 1, &ary);
      sp_call(M, "use_ary str", host, "use_ary", 1, &str);
      sp_call(M, "use_range hit", host, "use_range", 1, &range);
      sp_call(M, "use_range nil", host, "use_range", 1, &nil);
      sp_call(M, "drive", host, "drive", 1, &nil);
      // arity errors and the not-eligible shapes go through the same entry
      sp_call(M, "use_box arity", host, "use_box", 1, &box);
      sp_call(M, "with_opt hit", host, "with_opt", 1, &box);
      sp_call(M, "with_rest hit", host, "with_rest", 1, &box);
      sp_call(M, "plain_box", host, "plain_box", 1, &other);
      return 0;
    }
  CPP
  Dir.mktmpdir do |dir|
    plan = File.join(dir, 'plan.txt')
    File.write(plan, PLAN)
    _code, err = generate.call(SOURCE, dir, plan: plan)
    # Count the entries into specialized bodies: the counter is declared ahead of the generated code and bumped by the
    # first statement of every `_spec_impl`, so a guard hit is observable apart from a guard miss.
    gen = File.join(dir, 'fixture_gen.cpp')
    text = File.read(gen).gsub(/^(\[\[maybe_unused\]\] static mrb_value \w+_spec_impl\(.*\) \{\n)/) { "#{Regexp.last_match(1)}  ++sp_spec_runs;\n" }
    File.write(gen, "static int sp_spec_runs = 0;\n#{text}")
    full = File.exist?("#{build}/lib/libmruby.a")
    built, output = runtime.run(dir, err, OWNERS, body, build: build, full: full, exact_arity: true)
    check.call('the fixture compiles and runs against real mruby', built)
    if built
      sections = runtime.sections(output)
      values = ->(lines) { lines.reject { |l| l.start_with?('  dispatches', '  spec=') } }
      interpreted = values.call(sections.fetch('interpreted', []))
      compiled_lines = sections.fetch('compiled', [])
      compiled = values.call(compiled_lines)
      puts output if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call("every call answers what the interpreter answers (#{interpreted.size} calls), guard hit or miss, values and exceptions alike",
                 !interpreted.empty? && interpreted == compiled)
      spec_runs = {}
      compiled_lines.each_cons(3) do |a, _b, c|
        spec_runs[a[/\A(.*?) =>/, 1]] = c[/spec=(\d+)/, 1].to_i if c.start_with?('  spec=')
      end
      hits = ['use_box hit', 'use_val hit', 'use_hash hit', 'use_hash miss key', 'use_int 3', 'use_int 1', 'use_int big',
              'use_int_math 4', 'use_int_math max', 'use_float hit', 'use_two hit', 'use_str hit', 'use_str empty',
              'use_ary hit', 'use_ary empty', 'use_range hit']
      misses = ['use_box subclass', 'use_box other', 'use_box nil', 'use_box int', 'use_val subclass', 'use_val other',
                'use_val nil', 'use_hash subclass', 'use_hash nil', 'use_hash array', 'use_int float', 'use_int nil', 'use_int str',
                'use_int_math float', 'use_int_math nil', 'use_float int', 'use_float nil', 'use_nil hit', 'use_nil box', 'use_nil other', 'use_nil int', 'use_two first misses', 'use_two second misses', 'use_two both miss', 'use_str ary', 'use_ary str',
                'use_range nil', 'plain_box', 'with_opt hit', 'with_rest hit']
      check.call("a guard hit runs the specialized body (#{hits.size} calls: every class of the plan, Integer a fixnum)",
                 hits.all? { |label| spec_runs[label] == 1 })
      check.call("a guard miss runs the generic body (#{misses.size} calls: subclass, other class, nil, Float, String, a Hash subclass, " \
                 'one of two parameters missing, the unspecialized shapes)',
                 misses.all? { |label| spec_runs[label] == 0 })
      check.call('the subclass and the other class answer their own tag (a guard that accepted them would answer :box)',
                 compiled.include?('use_box subclass => :sub') && compiled.include?('use_box other => :other'))
      check.call('the Hash subclass answers through its own key?/[] (a guard that accepted it would use the native body)',
                 compiled.include?('use_hash subclass => :sub_get'))
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp entry specialize check: PASS'
else
  warn "bc2cpp entry specialize check: #{failures.size} failure(s)"
  exit 1
end
