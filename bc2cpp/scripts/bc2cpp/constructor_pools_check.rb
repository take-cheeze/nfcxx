#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CONSTRUCTOR_POOLS (docs/adr/0313): the arguments of an `initialize` are the join of what every `Klass.new`,
# `super(...)`, implicit-self `new` of a singleton method and `self.class.new` passes, so the ivars they are stored
# into carry exact classes and a receiver read from them loses its class test and its by-name dispatch.
#
# 1. Generated code (needs MRBC): each positive loses its guard (a pooled Array/Integer/user-class argument reaching a
#    method through an ivar, through an inherited initialize, through an explicit `super`, through an implicit-self
#    `new`, through `self.class.new`, through an optional parameter's leading position); each negative keeps it (two
#    classes at the sites, a splat, a bare `super`, a post-mandatory parameter, an Exception subclass, a class that aliases
#    its initialize, the optional position at its largest count, a subclass that overrides without `super`); each
#    withdrawal world (a Symbol :new, instance_method(:initialize), a Ruby `def self.new`, a module's initialize, an
#    explicit initialize call, a forwarded splat `new`, a `new` on a computed receiver, a constant bound to a class, a
#    native or foreign Ruby source spelling the class, a singleton maker, a dynamic subclass, a Class mixin, a wild
#    superclass, `allocate` + `send(:initialize)`, the kill switch, the open world) keeps the guards it must.
#    CP_GENERATED_ONLY=1 stops here (what the mutation check runs).
# 2. Behaviour on real mruby: the fixture runs interpreted and compiled and must answer alike, nil and Hash arguments
#    included, while the proven methods make no dynamic dispatch. Run it on a full-core and a core-only mruby, and on a
#    32-bit mrb_int build (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir BC2CPP_FULL_BUILD_DIR=dir BC2CPP_MRUBY_FULL32=dir
#         BC2CPP_MRBC32=mrbc32] ruby scripts/bc2cpp/constructor_pools_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

HOLDER = <<~RUBY
  class CpHelper
    def compute(x); x + 1; end
  end

  class CpOther
    def compute(x); x + 2; end
  end

  # -- positives
  class CpHold
    def initialize(helper, items, w, h)
      @helper = helper
      @items = items
      @w = w
      @h = h
    end

    def run; @helper.compute(3); end
    def count; @items.size; end
    def first; @items[0]; end
    def area; @w * @h; end
  end

  # An inherited initialize (CpKid) and an explicit super (CpSup) both feed the same pool.
  class CpBase
    def initialize(items); @items = items; end
    def base_count; @items.size; end
  end
  class CpSup < CpBase; def initialize(items); super(items); end; end
  class CpKid < CpBase; end

  class CpMk
    def self.cp_build(items); new(items); end
    def initialize(items); @items = items; end
    def mk_count; @items.size; end
  end

  class CpCopy
    def initialize(items); @items = items; end
    def again; self.class.new(@items); end
    def cp_count; @items.size; end
  end

  class CpOpt
    def initialize(items, extra = 5); @items = items; @extra = extra; end
    def opt_count; @items.size; end
  end

  # An override that never calls super takes its own arguments: CpBase is untouched.
  class CpFork < CpBase
    def initialize(a, b); @cp_fa = a; @cp_fb = b; end
    def fork_prod; @cp_fa * @cp_fb; end
  end

  class CpNil
    def initialize(v); @v = v; end
    def nil_count; @v.size; end
  end

  # -- negatives
  class CpMix
    def initialize(v); @v = v; end
    def mix_count; @v.size; end
  end

  class CpSplat
    def initialize(v); @v = v; end
    def splat_count; @v.size; end
  end

  class CpBase2
    def initialize(items); @items = items; end
    def base2_count; @items.size; end
  end
  class CpBad < CpBase2
    def initialize(*rest); super(*rest); end
  end

  class CpBaseZ
    def initialize(items); @items = items; end
    def basez_count; @items.size; end
  end
  class CpZsup < CpBaseZ; def initialize(items); super; end; end

  # ADR 0382: a keyword parameter leaves positions 1..mand alone, so this constructor is pooled.
  class CpKw
    def initialize(items, flag: false); @items = items; end
    def kw_count; @items.size; end
  end

  # A post-mandatory parameter is still refused.
  class CpPost
    def initialize(items, *rest, last); @items = items; end
    def post_count; @items.size; end
  end

  class CpErr < StandardError
    def initialize(items); @items = items; super('e'); end
    def err_count; @items.size; end
  end

  class CpAliased
    def initialize(items); @items = items; end
    alias_method :old_init, :initialize
    def aliased_count; @items.size; end
  end

  class CpOpt2
    def initialize(items, extra = 5); @items = items; end
    def opt2_count; @items.size; end
  end

  class CpRoot
    def self.rebuild; new({ a: 1 }); end
    def initialize(items); @items = items; end
    def root_count; @items.size; end
  end

  class CpCopy2
    def initialize(items); @items = items; end
    def again; self.class.new({ a: 1 }); end
    def cp2_count; @items.size; end
  end

  class CpArity
    def initialize(items); @items = items; end
    def arity_count; @items.size; end
  end

  class CpBound
    def initialize(items); @items = items; end
    def bound_count; @items.size; end
  end

  class CpDrv
    def make; CpHold.new(CpHelper.new, [1, 2, 3], 3, 4); end
    def other; CpOther.new.compute(1); end
    def sup; CpSup.new([1, 2]); end
    def kid; CpKid.new([1]); end
    def mk; CpMk.cp_build([1, 2, 3, 4]); end
    def cp; CpCopy.new([1, 2, 3, 4, 5]).again; end
    def opt_small; CpOpt.new([1]); end
    def opt_big; CpOpt.new([1, 2], 7); end
    def fork; CpFork.new(1, 2); end
    def nil_ok; CpNil.new([1]); end
    def nil_none; CpNil.new(nil); end
    def mix_arr; CpMix.new([1]); end
    def mix_hash; CpMix.new({ a: 1 }); end
    def splat(args); CpSplat.new(*args); end
    def splat_plain; CpSplat.new([1]); end
    def bad; CpBad.new([1, 2]); end
    def base2; CpBase2.new([1]); end
    def zsup; CpZsup.new([1, 2, 3]); end
    def kw; CpKw.new([1]); end
    def post; CpPost.new([1], 2); end
    def err; CpErr.new([1]); end
    def aliased; CpAliased.new([1]); end
    def opt2_small; CpOpt2.new([1]); end
    def opt2_big; CpOpt2.new({ a: 1 }, 7); end
    def root_plain; CpRoot.new([1, 2]); end
    def root_hash; CpRoot.rebuild; end
    def cp2_plain; CpCopy2.new([1, 2, 3]); end
    def cp2_hash; CpCopy2.new([1]).again; end
    def arity_ok; CpArity.new([1]); end
    def arity_bound; CpBound.new([1]); end
  end
RUBY

OWNERS = HOLDER.scan(/^class (\w+)/).flatten.freeze

# [owner, method, marker the proven body carries] of the positives; the method reads an ivar the pool types.
POSITIVES = [
  ['CpHold', 'count', 'CLOSED_WORLD_NATIVE_EXACT :size'], ['CpHold', 'run', 'CLOSED_WORLD_EXACT_CLASS :compute'],
  ['CpHold', 'area', 'NUMERIC_OPERAND_PROOF :*'], ['CpHold', 'first', 'INDEX_EXACT'],
  ['CpBase', 'base_count', 'CLOSED_WORLD_NATIVE_EXACT :size'], ['CpMk', 'mk_count', 'CLOSED_WORLD_NATIVE_EXACT :size'],
  ['CpCopy', 'cp_count', 'CLOSED_WORLD_NATIVE_EXACT :size'], ['CpOpt', 'opt_count', 'CLOSED_WORLD_NATIVE_EXACT :size'],
  ['CpFork', 'fork_prod', 'NUMERIC_OPERAND_PROOF :*'], ['CpKw', 'kw_count', 'CLOSED_WORLD_NATIVE_EXACT :size']
].freeze
# The negatives of the base world: a class whose argument pool must not be exact.
NEGATIVES = [
  ['CpMix', 'mix_count'], ['CpSplat', 'splat_count'], ['CpBase2', 'base2_count'], ['CpBaseZ', 'basez_count'],
  ['CpPost', 'post_count'], ['CpErr', 'err_count'], ['CpAliased', 'aliased_count'], ['CpOpt2', 'opt2_count'],
  ['CpRoot', 'root_count'], ['CpCopy2', 'cp2_count']
].freeze

# The method's own body plus the functions its blocks were outlined into, without comment lines.
live_of = lambda do |code, owner, fn|
  code.scan(/^(?:static )?mrb_value #{owner}_#{fn}(?:_\w*?)?_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m)
      .join.lines.reject { |l| l.lstrip.start_with?('//') }.join
end
DISPATCH = ['bc2cpp_send(', 'mrb_funcall(', 'bc2cpp_getidx(', 'bc2cpp_setidx(', 'bc2cpp_slow_', '->c == M->', 'bc2cpp_owner_class_', 'switch (mrb_type('].freeze
# The proof removed the class test and the by-name dispatch of the receiver.
proven = lambda do |code, owner, fn, marker|
  with_comments = code.scan(/^(?:static )?mrb_value #{owner}_#{fn}(?:_\w*?)?_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
  body = live_of.call(code, owner, fn)
  next false if body.empty? || !with_comments.include?(marker)

  # `first` keeps the index operand's own tag test, which the receiver's class does not decide.
  fn == 'first' ? !body.include?('bc2cpp_getidx(') : DISPATCH.none? { |d| body.include?(d) }
end
kept = lambda do |code, owner, fn|
  body = live_of.call(code, owner, fn)
  !body.empty? && DISPATCH.any? { |d| body.include?(d) }
end

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(HOLDER, dir)

    POSITIVES.each do |owner, fn, marker|
      check.call("#{owner}##{fn}: a pooled constructor argument takes no class test and no by-name dispatch",
                 proven.call(code, owner, fn, marker))
    end
    NEGATIVES.each do |owner, fn|
      check.call("NEG #{owner}##{fn}: keeps the class test or the dispatch", kept.call(code, owner, fn))
    end
    check.call('CpNil#nil_count: a nil-or-Array argument takes a nil arm, not a send',
               live_of.call(code, 'CpNil', 'nil_count').include?('bc2cpp_nil_receiver') &&
               !live_of.call(code, 'CpNil', 'nil_count').include?('bc2cpp_send('))
    pools = err[/== class pools.*?\n\n/m].to_s
    ctor = err[/== constructor pools.*?\n\n/m].to_s
    check.call('the diagnostic lists the pooled constructors and why the others are refused',
               ctor.include?('CTOR CpHold#initialize pooled') && ctor.include?('CTOR CpKw#initialize pooled') &&
               ctor.include?('CTOR CpPost#initialize refused: arity (req=1 opt=0 rest=1 post=1') &&
               ctor.include?('CTOR CpErr#initialize refused: hierarchy') &&
               ctor.include?('CTOR CpAliased#initialize refused: initialize aliased in CpAliased') &&
               ctor.include?('CTOR CpBaseZ#initialize refused: super with unmodelled arguments') &&
               ctor.include?('CTOR CpSplat#initialize refused: new with a splat or keyword'))
    check.call('the pooled arguments are class pools of the exact classes',
               pools.include?('CLASSARG CpHold#initialize arg1 (CpHelper)') && pools.include?('CLASSARG CpHold#initialize arg2 (ARR)') &&
               pools.include?('CLASSARG CpFork#initialize arg1 (INT)') && pools.include?('CLASSARG CpMix#initialize arg1 (ARR|HSH)'))

    # Variant worlds: [what, extra source, options, probes that must keep a guard, probes that must stay proven]
    base_probe = [['CpHold', 'count'], ['CpBase', 'base_count'], ['CpMk', 'mk_count'], ['CpCopy', 'cp_count']]
    gem_dir = lambda do |root, name, files|
      File.join(root, name).tap do |gem|
        files.each { |rel, text| FileUtils.mkdir_p(File.dirname(File.join(gem, rel))) && File.write(File.join(gem, rel), text) }
      end
    end
    variants = [
      ['a Symbol :new (send(:new))', "class CpNaming\n  def go(k); k.send(:new, 1); end\nend\n", {}, base_probe, []],
      ['instance_method(:initialize)', "class CpNaming\n  def go(k); k.instance_method(:initialize); end\nend\n", {}, base_probe, []],
      ['a Ruby-defined self.new', "class CpNewDef\n  def self.new(*a); super; end\nend\n", {}, base_probe, []],
      ['a module initialize', "module CpMod\n  def initialize(x); @x = x; end\nend\n", {}, base_probe, []],
      ['an explicit initialize call', "class CpReinit\n  def reinit; initialize([]); end\n  def initialize(x); end\nend\n", {}, base_probe, []],
      ['a method_missing proxy forwarding new(*args)',
       "class CpProxy\n  def method_missing(n, *a); @k.new(*a); end\nend\n", {}, base_probe, []],
      ['allocate and send(:initialize)', "class CpAlloc\n  def go; o = CpHold.allocate; o.send(:initialize, 1, 2, 3, 4); end\nend\n", {}, base_probe, []],
      ['a singleton maker', "class CpSing\n  def go(x); def x.foo; end; end\nend\n", {}, base_probe, []],
      ['a Class mixin', "class Class\n  include Comparable\nend\n", {}, base_probe, []],
      ['a wild superclass', "class CpWild < Kernel.const_get(:Object)\nend\n", {}, base_probe, []],
      ['"new" spelled as a String next to a computed-name send',
       "class CpStr\n  def go(o, n); o.send(n); 'new'; end\nend\n", {}, base_probe, []],
      # A computed receiver withdraws exactly the initializers it can get past ENTER for: one argument here.
      ['a `new` on a computed receiver with one argument',
       "class CpComputed\n  def go(k, v); k.new(v); end\nend\n", {},
       [['CpBase', 'base_count'], ['CpMk', 'mk_count'], ['CpCopy', 'cp_count']], [['CpHold', 'count'], ['CpFork', 'fork_prod']]],
      ['a constant bound to a class',
       "CpHandle = CpBound\nclass CpUse\n  def go; CpHandle.new({ a: 1 }); end\nend\n", {},
       [['CpBound', 'bound_count']], [['CpHold', 'count']]],
      ['a dynamic subclass (Class.new(CpBase))', "CpDyn = Class.new(CpBase)\n", {}, [['CpBase', 'base_count']], [['CpHold', 'count']]],
      ['a bare alias of initialize in another class',
       "class CpAlias2\n  def initialize(x); @x = x; end\n  alias old_init initialize\nend\n", {}, [], [['CpHold', 'count'], ['CpBase', 'base_count']]],
      ['a build gem whose native source spells the class', '', { gem: ['cp_native_gem', { 'src/cp.cxx' => "static void cp_touch(void) { mrb_class_get(0, \"CpHold\"); }\n" }] },
       [['CpHold', 'count']], [['CpBase', 'base_count'], ['CpMk', 'mk_count']]],
      ['a build gem whose Ruby source spells the class', '', { gem: ['cp_ruby_gem', { 'mrblib/cp.rb' => "CpHold\n" }] }, [['CpHold', 'count']],
       [['CpBase', 'base_count'], ['CpMk', 'mk_count']]]
    ]
    variants.each do |what, extra, options, guarded_probes, proven_probes|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      gems = options[:gem] ? [[options[:gem][0], gem_dir.call(d, *options[:gem])]] : []
      vcode, = generate.call(HOLDER + extra, d, build_gems: gems)
      guarded_probes.each do |owner, fn|
        check.call("NEG #{what}: #{owner}##{fn} keeps its guard", kept.call(vcode, owner, fn))
      end
      proven_probes.each do |owner, fn|
        marker = POSITIVES.find { |o, f, _| o == owner && f == fn }&.last
        check.call("#{what}: #{owner}##{fn} stays proven", marker && proven.call(vcode, owner, fn, marker))
      end
    end

    # An opt-in rule must withdraw the whole world on a name it cannot place, not one class.
    Dir.mktmpdir do |off_dir|
      off_code, off_err = generate.call(HOLDER, off_dir, env: { 'BC2CPP_CONSTRUCTOR_POOLS' => '0' })
      check.call('the kill switch (BC2CPP_CONSTRUCTOR_POOLS=0): the old guards on every positive',
                 POSITIVES.all? { |owner, fn, _| kept.call(off_code, owner, fn) })
      check.call('the kill switch lists no constructor pool', off_err[/== constructor pools.*?\n\n/m].to_s.include?('off: BC2CPP_CONSTRUCTOR_POOLS=0') &&
                                                              off_err.lines.grep(/CLASSARG CpHold#initialize/).empty?)
    end

    Dir.mktmpdir do |open_dir|
      open_code, = generate.call(HOLDER, open_dir, closed: false)
      check.call('the open world proves nothing about a constructor', POSITIVES.all? { |owner, fn, _| kept.call(open_code, owner, fn) })
    end

    Dir.mktmpdir do |pool_dir|
      pool_code, = generate.call(HOLDER, pool_dir, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('the class-pool kill switch withdraws the class proofs the constructor pools feed',
                 kept.call(pool_code, 'CpHold', 'count') && kept.call(pool_code, 'CpHold', 'run'))
    end

    # A gem that spells no class of the fixture leaves every proof in place.
    Dir.mktmpdir do |gd|
      gem = gem_dir.call(gd, 'cp_plain_gem', 'src/cp.c' => "void cp_init(void) {}\n", 'mrblib/cp.rb' => "module CpPlain\n  def self.x; 1; end\nend\n")
      pcode, = generate.call(HOLDER, gd, build_gems: [['cp_plain_gem', gem]])
      check.call('an unrelated build gem does not withdraw the pools', proven.call(pcode, 'CpHold', 'count', 'CLOSED_WORLD_NATIVE_EXACT :size'))
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

# [label, build dir, host mrbc, extra compiler flags, full-core?]
builds = []
if ENV['MRBC'] && runtime.compiler? && !ENV['CP_GENERATED_ONLY']
  flags = ENV.fetch('BC2CPP_CXXFLAGS', '')
  full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
  builds << ['mrb_int 64, full-core', full, ENV.fetch('MRBC'), flags, true] if full
  builds << ['mrb_int 64, core-only', runtime.core, ENV.fetch('MRBC'), flags, false] if runtime.core
  if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
    builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie', true]
  end
end
if builds.empty?
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
else
  puts '== fixture on real mruby, interpreted and compiled'
  scenario = <<~CPP
    #include <string>
    // Like call(), but an object result prints its class: an inspect would show an address.
    static mrb_value ask(mrb_state* M, const std::string& label, mrb_value obj, const char* meth, int argc = 0,
                         const mrb_value* argv = nullptr) {
      dispatches = 0;
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      int made = dispatches;
      if (M->exc) show_exc(M, label.c_str());
      else if (mrb_integer_p(r) || mrb_nil_p(r) || mrb_array_p(r) || mrb_hash_p(r)) show(M, label.c_str(), r);
      else std::printf("%s => <%s>\\n", label.c_str(), mrb_obj_classname(M, r));
      if (compiled) std::printf("  dispatches=%d\\n", made);
      return M->exc ? mrb_nil_value() : r;
    }
    // Builds an object with a driver method, then asks it +meth+.
    static void step(mrb_state* M, mrb_value drv, const char* label, const char* build, const char* meth) {
      mrb_value o = ask(M, std::string(label) + " obj", drv, build);
      if (!mrb_nil_p(o)) ask(M, label, o, meth);
    }
    static int scenario(mrb_state* M) {
      mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "CpDrv"), 0, nullptr);
      mrb_value hold = ask(M, "make", drv, "make");
      ask(M, "hold count", hold, "count");
      ask(M, "hold run", hold, "run");
      ask(M, "hold first", hold, "first");
      ask(M, "hold area", hold, "area");
      ask(M, "other", drv, "other");
      step(M, drv, "base kid", "kid", "base_count");
      step(M, drv, "base sup", "sup", "base_count");
      step(M, drv, "mk", "mk", "mk_count");
      step(M, drv, "cp", "cp", "cp_count");
      step(M, drv, "opt 0", "opt_small", "opt_count");
      step(M, drv, "opt 1", "opt_big", "opt_count");
      step(M, drv, "fork prod", "fork", "fork_prod");
      step(M, drv, "nil_ok count", "nil_ok", "nil_count");
      step(M, drv, "nil_none count", "nil_none", "nil_count");
      step(M, drv, "mix arr", "mix_arr", "mix_count");
      step(M, drv, "mix hash", "mix_hash", "mix_count");
      mrb_value one = mrb_ary_new_capa(M, 2);
      mrb_ary_push(M, one, mrb_fixnum_value(1));
      mrb_ary_push(M, one, mrb_fixnum_value(2));
      mrb_value args = mrb_ary_new_capa(M, 1);
      mrb_ary_push(M, args, one);
      mrb_value args_hash = mrb_ary_new_capa(M, 1);
      mrb_ary_push(M, args_hash, mrb_hash_new(M));
      ask(M, "splat arr", ask(M, "splat arr obj", drv, "splat", 1, &args), "splat_count");
      ask(M, "splat hash", ask(M, "splat hash obj", drv, "splat", 1, &args_hash), "splat_count");
      step(M, drv, "splat plain", "splat_plain", "splat_count");
      step(M, drv, "bad", "bad", "base2_count");
      step(M, drv, "base2", "base2", "base2_count");
      step(M, drv, "zsup", "zsup", "basez_count");
      step(M, drv, "kw", "kw", "kw_count");
      step(M, drv, "err", "err", "err_count");
      step(M, drv, "aliased", "aliased", "aliased_count");
      step(M, drv, "opt2 small", "opt2_small", "opt2_count");
      step(M, drv, "opt2 big", "opt2_big", "opt2_count");
      step(M, drv, "root plain", "root_plain", "root_count");
      step(M, drv, "root hash", "root_hash", "root_count");
      step(M, drv, "cp2 plain", "cp2_plain", "cp2_count");
      step(M, drv, "cp2 hash", "cp2_hash", "cp2_count");
      step(M, drv, "arity ok", "arity_ok", "arity_count");
      step(M, drv, "arity bound", "arity_bound", "bound_count");
      return 0;
    }
  CPP
  builds.each do |label, build, mrbc, flags, with_gems|
    puts "-- fixture on real mruby (#{label}), interpreted and compiled"
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = flags
    begin
      Dir.mktmpdir do |dir|
        _code, gen_err = runtime.generate(HOLDER, dir, closed: true, only_owners: OWNERS)
        built, output = runtime.run(dir, gen_err, OWNERS, scenario, build: build, full: with_gems)
        check.call("#{label}: the fixture compiles and runs against real mruby", built)
        puts output unless built
        next unless built

        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        check.call("#{label}: every method answers what the interpreter answers (#{values.call('interpreted').size} lines), values and exceptions alike",
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        interpreted = values.call('interpreted')
        compiled = values.call('compiled')
        # A core-only mruby (no mrblib) reports a different exception class on both sides, so there the check is the
        # interpreter's own answer, and that it raised; full-core pins NoMethodError.
        nil_line = ->(lines) { lines.find { |l| l.start_with?('nil_none count =>') }.to_s }
        expected_nil = with_gems ? 'nil_none count => raised NoMethodError' : nil_line.call(interpreted)
        nil_ok = nil_line.call(compiled) == expected_nil && expected_nil.include?('raised')
        puts "    expected #{expected_nil.inspect}, actual #{nil_line.call(compiled).inspect}" unless nil_ok
        check.call("#{label}: a nil argument reaches the nil arm and raises as the interpreter does", nil_ok)
        check.call("#{label}: a pooled Array argument answers its size", compiled.include?('hold count => 3') && compiled.include?('mk => 4'))
        check.call("#{label}: a Hash reaching a mixed pool answers its own size",
                   compiled.include?('mix hash => 1') && compiled.include?('root hash => 1') && compiled.include?('cp2 hash => 1'))
        check.call("#{label}: a splat site passes either class through", compiled.include?('splat arr => 2') && compiled.include?('splat hash => 0'))
        check.call("#{label}: the optional parameter's count is the Array's", compiled.include?('opt 0 => 1') && compiled.include?('opt 1 => 2'))
        check.call("#{label}: the widest optional call keeps its own class", compiled.include?('opt2 big => 1'))
        lines = sections.fetch('compiled', [])
        %w[hold\ count hold\ run hold\ first hold\ area base\ kid base\ sup mk cp opt\ 0 opt\ 1 fork\ prod].each do |m|
          at = lines.index { |l| l.start_with?("#{m} =>") }
          n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
          check.call("#{label}: #{m}: the compiled call makes no dynamic dispatch", n == 0)
        end
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
end

if failures.empty?
  puts 'bc2cpp constructor pools check: PASS'
else
  warn "bc2cpp constructor pools check: #{failures.size} failure(s)"
  exit 1
end
