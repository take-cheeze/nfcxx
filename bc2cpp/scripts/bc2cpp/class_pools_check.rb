#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CLASS_POOLS and NILABLE_RECEIVER (docs/adr/0296): the exact-class flow of ADR 0289 reads
# an ivar and an argument across methods through whole-program pools, and a receiver that is nil or
# exactly one class takes one nil test and then the exact path.
#
# 1. Generated code (needs MRBC): positive shapes lose their guard and their dispatch; every
#    withdrawal condition (a writer the scan cannot type, reflection, a foreign source, a singleton
#    maker, an unassigned constructor path, a second class, an argument site of another class, a
#    computed or aliased name, the kill switch) keeps the guard.
# 2. Behaviour on real mruby: compiled answers equal interpreted ones, nil receivers raise the
#    interpreter's NoMethodError, and a world with a writer behind the analysis' back is the
#    documented failure the kill switch removes.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/class_pools_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class PlBox
    def initialize; @n = 0; end
    def tag; :box; end
    def pl_nil_ok; :box; end
    def val; @n; end
    # An RGSS native also spells `count`, so only the guard-free TYPED call can take the site.
    def count; @n; end
  end

  # nil answers pl_nil_ok too, so the nil arm of a call to it must still dispatch.
  class NilClass
    def pl_nil_ok; :nil; end
  end

  class PlOther
    def tag; :other; end
    def pl_nil_ok; :other; end
    def count; 7; end
  end
RUBY

HOST = <<~RUBY
  class PlHost
    attr_writer :written

    def initialize
      @box = PlBox.new
      @maybe = nil
      @mixed = PlBox.new
      @param = PlBox.new
      @written = PlBox.new
      @refl = PlBox.new
      @ui = nil
    end

    # -- exact: assigned in the constructor, never written to another class
    def read_box; @box.tag; end
    def read_box_count; @box.count; end

    # -- nil or one class: assigned after construction
    def setup; @maybe = PlBox.new; end
    def read_maybe; @maybe.tag; end
    def read_maybe_count; @maybe.count; end
    def read_maybe_ok; @maybe.pl_nil_ok; end

    # -- a local that is nil on one path
    def read_local(f); b = f ? PlBox.new : nil; b.tag; end

    # -- two classes
    def swap; @mixed = PlOther.new; end
    def read_mixed; @mixed.tag; end

    # -- a value from outside the pools
    def put(o); @param = o; end
    def read_param; @param.tag; end

    # -- an attr_writer anyone can call
    def read_written; @written.tag; end

    # -- instance_variable_set with a literal name
    def poke; instance_variable_set(:@refl, PlOther.new); end
    def read_refl; @refl.tag; end

    # -- a Hash literal and nil
    def open_ui; @ui = {}; end
    def ui_get(k); @ui[k]; end
    def ui_set(k, v); @ui[k] = v; end
    def ui_to_s; @ui.to_s; end
    def ui_key(k); @ui.key?(k); end
  end

  class PlArgs
    def pl_use(b); b.tag; end
    def go; [pl_use(PlBox.new), pl_use(PlBox.new)]; end

    def pl_use_two(b); b.tag; end
    def go_two; [pl_use_two(PlBox.new), pl_use_two(PlOther.new)]; end

    def pl_use_send(b); b.tag; end
    def go_send; [pl_use_send(PlBox.new), send(:pl_use_send, PlOther.new)]; end

    def pl_use_alias(b); b.tag; end
    alias pl_use_aliased pl_use_alias
    def go_alias; [pl_use_alias(PlBox.new), pl_use_aliased(PlOther.new)]; end

    def pl_use_param(b); b.tag; end
    def go_param(o); [pl_use_param(PlBox.new), pl_use_param(o)]; end
  end

  class PlLazy
    # One path leaves @lz unassigned, so a read can see nil.
    def initialize(f); @lz = PlBox.new if f; end
    def read_lz; @lz.tag; end
  end

  class PlDrv
    def go(h, a)
      [h.read_box, h.read_box_count, h.read_mixed, h.read_param, h.read_written, h.read_refl, a.go, a.go_two]
    end
  end
RUBY

OWNERS = %w[PlBox PlOther PlHost PlLazy PlArgs PlDrv].freeze
EXACT_TAG = /(?:EXACT_TYPED|CLOSED_WORLD_EXACT_CLASS) :\w+[?!]? /

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
exact = ->(code, owner, fn) { body_of.call(code, owner, fn).match?(EXACT_TAG) && !body_of.call(code, owner, fn).include?('mrb_nil_p') }
nilable = lambda do |code, owner, fn|
  body = body_of.call(code, owner, fn)
  body.include?('NILABLE_RECEIVER') && body.match?(EXACT_TAG)
end
guarded = lambda do |code, owner, fn|
  body = body_of.call(code, owner, fn)
  !body.empty? && !body.match?(EXACT_TAG) && !body.include?('NILABLE_RECEIVER :tag')
end

generate = lambda do |source, dir, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(CLASSES + HOST, dir)

    %w[read_box read_box_count].each do |fn|
      check.call("PlHost##{fn}: an ivar every constructor assigns a fresh PlBox is a guard-free direct call",
                 exact.call(code, 'PlHost', fn) && !body_of.call(code, 'PlHost', fn).include?('mrb_obj_class(M, r'))
    end
    %w[read_maybe read_maybe_count].each do |fn|
      check.call("PlHost##{fn}: nil-or-PlBox takes one nil test, then the guard-free call",
                 nilable.call(code, 'PlHost', fn) && !body_of.call(code, 'PlHost', fn).include?('runtime-class-checked'))
    end
    check.call('NEG: a name a NilClass method in the world answers keeps the dispatch on the nil arm',
               body_of.call(code, 'PlHost', 'read_maybe_ok').include?('NILABLE_RECEIVER') &&
                 !body_of.call(code, 'PlHost', 'read_maybe_ok').include?('bc2cpp_nil_receiver(M,'))
    check.call('a local that is a PlBox or nil on two paths takes the same nil test and exact call',
               nilable.call(code, 'PlHost', 'read_local'))
    check.call('the nil arm of a name nil does not answer is the NIL_RECEIVER helper, not a send',
               body_of.call(code, 'PlHost', 'read_maybe').include?('bc2cpp_nil_receiver(M,') &&
                 !body_of.call(code, 'PlHost', 'read_maybe').include?('bc2cpp_send(') &&
                 code.include?('static mrb_value bc2cpp_nil_receiver(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...)'))
    check.call('the NIL_RECEIVER sites are listed on stderr, apart from the NOMETHOD sites',
               err.include?('  NIL_RECEIVER_SITE PlHost#read_maybe -> tag') && !err.include?('  NOMETHOD PlHost#read_maybe'))
    check.call('the diagnostic lists the pools',
               err.include?('CLASSIVAR PlHost#@box (PlBox)') && err.include?('CLASSIVAR PlHost#@maybe (NIL|PlBox)') &&
                 err.include?('CLASSARG PlArgs#pl_use arg1 (PlBox)'))
    check.call('Hash literal and nil: GETIDX/SETIDX test nil once and take the exact fast path',
               %w[ui_get ui_set].all? do |fn|
                 body = body_of.call(code, 'PlHost', fn)
                 body.include?('NILABLE_RECEIVER') && body.include?('INDEX_EXACT') && body.include?('bc2cpp_nil_receiver(M,') &&
                   !body.include?('mrb_hash_p(')
               end)
    check.call('a name nil answers (to_s) keeps the ordinary send on the nil arm',
               !body_of.call(code, 'PlHost', 'ui_to_s').include?('bc2cpp_nil_receiver(M,'))
    check.call('an exact argument pool drops the guard of PlArgs#pl_use', exact.call(code, 'PlArgs', 'pl_use'))

    # NEG: each of these keeps its guard (or its dispatch) in the same world.
    { 'read_mixed' => 'two classes (PlBox, PlOther)',
      'read_param' => 'a parameter is stored into it',
      'read_written' => 'an attr_writer reaches it',
      'read_refl' => 'instance_variable_set(:@refl)' }.each do |fn, why|
      check.call("NEG PlHost##{fn}: #{why} keeps the guard", guarded.call(code, 'PlHost', fn))
    end
    { 'pl_use_two' => 'a call site passes a PlOther', 'pl_use_send' => 'a send(:name) can reach it',
      'pl_use_alias' => 'an alias can reach it', 'pl_use_param' => 'a call site passes a parameter' }.each do |fn, why|
      check.call("NEG PlArgs##{fn}: #{why} keeps the guard", guarded.call(code, 'PlArgs', fn))
    end
    check.call('NEG: a constructor path that leaves @lz unassigned makes the read nilable, not exact',
               !exact.call(code, 'PlLazy', 'read_lz') && nilable.call(code, 'PlLazy', 'read_lz'))

    # Withdrawal conditions: each variant world proves nothing for the always-exact control.
    variants = {
      'a native source that spells @box' => { native: [['pl_native.cxx', "void pl_touch(mrb_state* M, mrb_value o) { mrb_iv_set(M, o, mrb_intern_lit(M, \"@box\"), mrb_nil_value()); }\n"]] },
      'a foreign Ruby source that spells @box' => { foreign: [['pl_foreign.rb', "class PlOutside\n  def x(o); o.instance_variable_get(:@box); end\nend\n"]] },
      'an instance_variable_set with a computed name' => { global: true, extra: "class PlHost\n  def wild(n, v); instance_variable_set(n, v); end\nend\n" },
      'an instance_eval without a literal block' => { global: true, extra: "class PlHost\n  def wild(b); instance_eval(&b); end\nend\n" },
      'a define_method block that writes @box under another self' => { extra: "class PlHost\n  define_method(:evil) { @box = PlOther.new }\nend\n" },
      'a singleton maker (a def on an object)' => { global: true, extra: "class PlHost\n  def maker; a = [1]; def a.other(*); 1; end; a; end\nend\n" },
      'an allocate' => { extra: "class PlHost\n  def raw; self.class.allocate; end\nend\n" },
      'a method_missing' => { extra: "class PlHost\n  def method_missing(n, *a); 1; end\nend\n" }
    }
    variants.each do |what, spec|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      vcode, = generate.call(CLASSES + HOST + spec.fetch(:extra, ''), d, **spec.slice(:native, :foreign))
      verdict = if what.include?('allocate')
                  # An allocate can build an unassigned instance: still a nil-or-PlBox read, never guard-free.
                  !exact.call(vcode, 'PlHost', 'read_box') && nilable.call(vcode, 'PlHost', 'read_box')
                elsif what.include?('method_missing')
                  # A method_missing class does not change what an ivar holds; nothing is withdrawn but
                  # no site becomes less guarded either.
                  exact.call(vcode, 'PlHost', 'read_box')
                elsif spec.key?(:global)
                  # Reflection, a rebinding or a singleton maker could write any ivar: no pool at all.
                  !exact.call(vcode, 'PlHost', 'read_box') && !nilable.call(vcode, 'PlHost', 'read_maybe')
                else
                  !exact.call(vcode, 'PlHost', 'read_box') && !nilable.call(vcode, 'PlHost', 'read_box')
                end
      check.call("#{what}: #{what.include?('allocate') ? 'read_box is nil-or-PlBox' : 'withdrawn as the model says'}", verdict)
    end

    Dir.mktmpdir do |off_dir|
      off_code, off_err = generate.call(CLASSES + HOST, off_dir, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('the kill switch (BC2CPP_CLASS_POOLS=0): no pool, no nil arm, no INDEX_EXACT, the old guards',
                 !off_code.include?('NILABLE_RECEIVER') && !off_code.include?('INDEX_EXACT') &&
                   !off_err.include?('CLASSIVAR') && guarded.call(off_code, 'PlHost', 'read_box') &&
                   !exact.call(off_code, 'PlArgs', 'pl_use'))
    end

    Dir.mktmpdir do |strict_dir|
      marshal = "class PlHost\n  def roundtrip(o); Marshal.load(Marshal.dump(o)); end\nend\n"
      default_code, = generate.call(CLASSES + HOST + marshal, strict_dir)
      Dir.mktmpdir do |d2|
        strict_code, = generate.call(CLASSES + HOST + marshal, d2, env: { 'BC2CPP_CLASS_POOLS' => 'strict' })
        check.call('a world that can reach Marshal: the default models hostile bytes as outside, =strict withdraws the pools',
                   exact.call(default_code, 'PlHost', 'read_box') && !exact.call(strict_code, 'PlHost', 'read_box'))
      end
    end

  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

build = runtime.full || runtime.core || runtime.full_or_build
has_meta = !runtime.full.nil? && build == runtime.full
if ENV['MRBC'] && build && runtime.compiler? && !ENV['PL_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  body = <<~'CPP'
    static void pl_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                        const mrb_value* argv = nullptr) {
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value msg = (mrb_funcall)(M, e, "message", 0);
        std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
      } else {
        show(M, label, r);
      }
    }
    // The state-changing calls print nothing: an inspected object carries its address.
    static void pl_quiet(mrb_state* M, mrb_value obj, const char* meth, int argc = 0, const mrb_value* argv = nullptr) {
      (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      M->exc = nullptr;
    }
    static int scenario(mrb_state* M) {
      const char* mode = std::getenv("PL_SCENARIO");
      bool outside = mode && !std::strcmp(mode, "outside");
      mrb_value host = mrb_obj_new(M, mrb_class_get(M, "PlHost"), 0, nullptr);
      mrb_value no = mrb_false_value();
      mrb_value lazy = mrb_obj_new(M, mrb_class_get(M, "PlLazy"), 1, &no);
      mrb_value args = mrb_obj_new(M, mrb_class_get(M, "PlArgs"), 0, nullptr);
      mrb_value other = mrb_obj_new(M, mrb_class_get(M, "PlOther"), 0, nullptr);
      mrb_value k = mrb_symbol_value(mrb_intern_lit(M, "k"));
      mrb_value v = mrb_fixnum_value(5);
      mrb_value kv[] = { k, v };
      if (outside) {
        // A writer behind the analysis' back, as no program in the closed world could be: the
        // documented failure the kill switch removes.
        mrb_iv_set(M, host, mrb_intern_lit(M, "@box"), other);
      }
      pl_call(M, "read_box", host, "read_box");
      pl_call(M, "read_box_count", host, "read_box_count");
      mrb_value yes = mrb_true_value();
      mrb_value nope = mrb_false_value();
      pl_call(M, "read_local true", host, "read_local", 1, &yes);
      pl_call(M, "read_local false", host, "read_local", 1, &nope);
      pl_call(M, "read_maybe before setup", host, "read_maybe");
      pl_call(M, "read_maybe_count before setup", host, "read_maybe_count");
      pl_call(M, "read_maybe_ok before setup", host, "read_maybe_ok");
      pl_quiet(M, host, "setup");
      pl_call(M, "read_maybe", host, "read_maybe");
      pl_call(M, "read_maybe_count", host, "read_maybe_count");
      pl_call(M, "read_mixed", host, "read_mixed");
      pl_quiet(M, host, "swap");
      pl_call(M, "read_mixed after swap", host, "read_mixed");
      pl_quiet(M, host, "put", 1, &other);
      pl_call(M, "read_param", host, "read_param");
      pl_quiet(M, host, "written=", 1, &other);
      pl_call(M, "read_written", host, "read_written");
      pl_quiet(M, host, "poke");
      pl_call(M, "read_refl", host, "read_refl");
      pl_call(M, "ui_get before open", host, "ui_get", 1, &k);
      pl_call(M, "ui_set before open", host, "ui_set", 2, kv);
      pl_call(M, "ui_to_s before open", host, "ui_to_s");
      pl_call(M, "ui_key before open", host, "ui_key", 1, &k);
      pl_quiet(M, host, "open_ui");
      pl_call(M, "ui_set", host, "ui_set", 2, kv);
      pl_call(M, "ui_get", host, "ui_get", 1, &k);
      pl_call(M, "ui_to_s", host, "ui_to_s");
      pl_call(M, "ui_key", host, "ui_key", 1, &k);
      pl_call(M, "lazy read_lz (never assigned)", lazy, "read_lz");
      pl_call(M, "args go", args, "go");
      pl_call(M, "args go_two", args, "go_two");
      pl_call(M, "args go_send", args, "go_send");
      pl_call(M, "args go_alias", args, "go_alias");
      pl_call(M, "args go_param box", args, "go_param", 1, &other);
      return 0;
    }
  CPP
  Dir.mktmpdir do |dir|
    _code, err = generate.call(CLASSES + HOST, dir)
    full = File.exist?("#{build}/lib/libmruby.a")
    run_with = lambda do |envs|
      runtime.run(dir, err, OWNERS, "#include <cstdlib>\n#include <cstring>\n#include <mruby/string.h>\n#{body}", build: build,
                                                                                                  full: full, envs: envs)
    end
    values = lambda do |output|
      sections = runtime.sections(output)
      [sections.fetch('interpreted', []).reject { |l| l.start_with?('  dispatches') },
       sections.fetch('compiled', []).reject { |l| l.start_with?('  dispatches') }]
    end

    built, results = run_with.call([{ 'PL_SCENARIO' => 'inside' }, { 'PL_SCENARIO' => 'outside' }])
    check.call('the fixture compiles and runs against real mruby', built)
    if built
      (in_out, in_ok), (out_out, out_ok) = results
      interpreted, compiled = values.call(in_out)
      puts in_out if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call("every method answers what the interpreter answers (#{interpreted.size} lines), values and exceptions alike",
                 in_ok && !interpreted.empty? && interpreted == compiled)
      check.call('a nil receiver raises the interpreter\'s NoMethodError, message included',
                 compiled.grep(/before setup => raised NoMethodError: undefined method 'tag' for NilClass/).size == 1 &&
                   compiled.any? { |l| l.start_with?('ui_get before open => raised NoMethodError') })
      check.call('a nil local raises where the interpreter does',
                 compiled.include?('read_local true => :box') &&
                   compiled.any? { |l| l.start_with?('read_local false => raised NoMethodError') })
      check.call('a name a world NilClass method answers (pl_nil_ok) still answers on the nil arm',
                 compiled.include?('read_maybe_ok before setup => :nil'))
      check.call('a name nil answers (to_s) still answers on the nil arm',
                 compiled.include?('ui_to_s before open => ""'))
      check.call('the two-class ivar reached both classes (a wrong exact proof would answer :box twice)',
                 compiled.include?('read_mixed => :box') && compiled.include?('read_mixed after swap => :other'))
      # A bare core has no instance_variable_set or send: interpreted == compiled above is the check there.
      check.call('the parameter, writer and reflection writes are seen',
                 compiled.include?('read_param => :other') && compiled.include?('read_written => :other') &&
                   (!has_meta || compiled.include?('read_refl => :other')))
      check.call('the object whose constructor skipped @lz raises like the interpreter',
                 compiled.any? { |l| l.start_with?('lazy read_lz (never assigned) => raised NoMethodError') })
      check.call('the argument pools: one exact, the others see their PlOther',
                 compiled.include?('args go => [:box, :box]') && compiled.include?('args go_two => [:box, :other]') &&
                   (!has_meta || compiled.include?('args go_send => [:box, :other]')) &&
                   compiled.include?('args go_alias => [:box, :other]'))

      # An @box written from outside the closed world: the pool did not see it. The compiled
      # exact read answers the pooled class's body for a PlOther; the kill switch restores it.
      puts out_out if ENV['BC2CPP_CHECK_VERBOSE']
      interpreted, compiled = values.call(out_out)
      # The exact read calls PlBox's bodies on a PlOther: a wrong answer, or a crash where the
      # body reads an embedded ivar (a crash loses the buffered output, so no section may exist).
      check.call('RESIDUAL: a writer outside the analysed world is not modelled -- the compiled exact read ' \
                 'misanswers or crashes where the interpreter answers (documented, ADR 0296)',
                 !out_ok || interpreted != compiled)
    end
    Dir.mktmpdir do |off_dir|
      _off_code, off_err = generate.call(CLASSES + HOST, off_dir, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      off_built, off_results = runtime.run(off_dir, off_err, OWNERS,
                                           "#include <cstdlib>\n#include <cstring>\n#include <mruby/string.h>\n#{body}",
                                           build: build, full: full, envs: [{ 'PL_SCENARIO' => 'outside' }])
      if off_built
        interpreted, compiled = values.call(off_results.first.first)
        check.call('BC2CPP_CLASS_POOLS=0: the writer outside the world answers what the interpreter answers',
                   !interpreted.empty? && interpreted == compiled)
      else
        check.call('BC2CPP_CLASS_POOLS=0 build', false)
      end
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp class pools check: PASS'
else
  warn "bc2cpp class pools check: #{failures.size} failure(s)"
  exit 1
end
