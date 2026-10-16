#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0365: the by-name tail of the shared index helpers (bc2cpp_getidx, bc2cpp_getidx0, bc2cpp_setidx) is closed.
# In a closed world where only the native `[]` / `[]=` of Array, Hash, String, Struct, Proc, Table and the
# classes of the program answer, the helper's else is a class-tag switch over mruby's own bodies (exported by
# patches/mruby-expose-index-bodies.patch) and a proven NoMethodError.
#
# 1. With MRBC: the generated code. The three helpers hold no by-name call and name each arm; a singleton
#    `def self.[]`, a method_missing class, a module definer, an uncovered subclass, a build that links
#    mruby-method, an open world and BC2CPP_INDEX_HELPER_CLOSED=0 each keep the by-name helper (and the world
#    that stays closed is shown to stay closed).
# 2. The generator reads the mruby sources it is built from: a tree whose wrappers no longer call the exported
#    bodies refuses the closed form (a scratch copy of the sources, host only).
# 3. With a full-core libmruby: each helper is called directly against the real method (`recv[key]`,
#    `recv[idx] = val`, on a fresh equal receiver) over a matrix of receivers (every member class, subclasses,
#    frozen ones, class objects, procs, non-members) and keys, comparing the value, the class and message of an
#    error, and the receiver afterwards; the fixture's own methods answer alike compiled and interpreted, and
#    make no by-name call on a member receiver. The run repeats at mrb_int 32 (BC2CPP_MRUBY_FULL32,
#    BC2CPP_MRBC32) and without bigint (BC2CPP_MRUBY_NOBIGINT).
#    The libmruby must be built from the tree with patches/mruby-expose-index-bodies.patch applied.
#    Table is rgss's, which the libmruby does not link: the run defines a stand-in class with the same
#    entry points (rgss_table_p, rgss_table_aref_impl, rgss_table_aset_impl), so it checks what the helper
#    passes to them and what it returns.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32
#         BC2CPP_MRUBY_NOBIGINT=dir] ruby scripts/bc2cpp/index_closed_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Classes the world's own Ruby answers `[]` / `[]=` with, a subclass that inherits, one that overrides, subclasses of the
# native classes (one of which overrides), a Struct class and one below it, and a class nothing answers.
FIXTURE = <<~'RUBY'
  class IxVars
    def [](i) = i * 2
    def []=(i, v)
      @last = [i, v]
      v
    end
    def inspect = "vars"
  end
  class IxGrid
    def [](i) = i + 100
    def []=(i, v)
      @last = [i, v]
      :grid
    end
    def inspect = "grid"
  end
  class IxSub < IxVars
  end
  class IxOwn < IxVars
    def [](i) = :own
  end
  class IxArr < Array
  end
  class IxArrOver < Array
    def [](i) = :arr_over
    def []=(i, v)
      :arr_over_set
    end
  end
  class IxHsh < Hash
  end
  class IxStr < String
  end
  IxPoint = Struct.new(:x, :y)
  class IxPointSub < IxPoint
  end
  class IxConv
    def to_int = 1
    def inspect = "conv"
  end
  class IxBox
    def inspect = "box"
  end
  # Procs indexed by compiled methods that capture a block: the block is a cfunc-backed proc (ADR 0266), which OP_CALL cannot run
  # from a compiled frame, so the helper must yield to it.
  class IxCap
    def cap_idx(x, &blk) = blk[x]
    def stored(&b)
      @s = b
    end
    def stored_idx(x) = @s[x]
    def forms(&b) = [b[1], b.call(2), b.(3), b.yield(4)]
    def ret(&b) = b
    def run_idx = cap_idx(3) { |x| x * 2 }
    def run_stored
      stored { |x| x + 40 }
      stored_idx(2)
    end
    def run_forms = forms { |x| x + 1 }
    def run_ret = ret { |x| x + 1 }[3]
    def run_lambda = cap_idx(2, &lambda { |x| x * 5 })
    def run_lambda_arity = cap_idx(1, &lambda { |a, b| a })
    def run_break = cap_idx(1) { |x| break :b }
    def run_upvar
      n = 10
      cap_idx(1) { |x| x + n }
    end
    def run_nested = cap_idx(1) { |x| cap_idx(x + 1) { |y| y * 3 } }
  end
  class IxOpen
    def get(x, i) = x[i]
    def get0(x) = x[0]
    def set(x, i, v)
      x[i] = v
    end
    # By-name calls the call makes: a member receiver makes none.
    def dget(x, i)
      w = IxProbe.dispatches
      x[i]
      IxProbe.dispatches - w - 1 # the second probe call is itself one dispatch
    end
    def dget0(x)
      w = IxProbe.dispatches
      x[0]
      IxProbe.dispatches - w - 1
    end
    def dset(x, i, v)
      w = IxProbe.dispatches
      x[i] = v
      IxProbe.dispatches - w - 1
    end
  end
RUBY
OWNERS = %w[IxVars IxGrid IxSub IxOwn IxArr IxArrOver IxHsh IxStr IxPoint IxPointSub IxConv IxBox IxCap IxOpen].freeze

def helper_text(code, name)
  start = code.index(/^static mrb_value #{Regexp.escape(name)}\(/) or return nil
  code[start..code.index(/^\}\n/, start)]
end

def generate(runtime, source, **opts)
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(source, dir, only_owners: OWNERS, **opts)
    [code, err]
  end
end

def with_env(overrides)
  saved = overrides.keys.to_h { |k| [k, ENV[k]] }
  overrides.each { |k, v| ENV[k] = v }
  yield
ensure
  saved.each { |k, v| ENV[k] = v }
end

CLOSED_ARMS = {
  'bc2cpp_getidx' => %w[mrb_ary_aget1_impl mrb_hash_get mrb_proc_aref_impl mrb_str_aref mrb_struct_aref_impl rgss_table_aref_impl
                        mrb_ary_s_create_impl mrb_hash_s_create_impl mrb_obj_new],
  'bc2cpp_getidx0' => %w[mrb_ary_aget1_impl mrb_hash_get mrb_proc_aref_impl mrb_str_aref mrb_struct_aref_impl rgss_table_aref_impl
                         mrb_ary_s_create_impl mrb_hash_s_create_impl mrb_obj_new],
  'bc2cpp_setidx' => %w[mrb_ary_aset2_impl mrb_hash_set mrb_str_aset mrb_struct_aset_impl rgss_table_aset_impl]
}.freeze

def closed?(code, helper)
  text = helper_text(code, helper)
  !text.nil? && text.include?('INDEX_CLOSED') && !text.include?('bc2cpp_send(') && !text.include?('mrb_funcall(') &&
    text.include?('bc2cpp_nomethod(')
end

def open?(code, helper)
  text = helper_text(code, helper)
  !text.nil? && !text.include?('INDEX_CLOSED') && text.match?(/bc2cpp_send\(|mrb_funcall\(/)
end

def generated_checks(check, runtime)
  puts '-- generated code (closed world: the program, Array, Hash, String, Struct, Proc, Table and class objects answer)'
  code, err = generate(runtime, FIXTURE)
  check.call('stderr reports the three helpers closed', err.include?('getidx closed, getidx0 closed, setidx closed'))
  open_call = code[/^\/\/ IxOpen#get \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
  check.call('IxOpen#get is one helper call with no by-name call of its own',
             open_call.include?('bc2cpp_getidx(M, ') && !open_call.include?('bc2cpp_send(') && !open_call.include?('mrb_funcall('))
  CLOSED_ARMS.each do |helper, arms|
    text = helper_text(code, helper)
    check.call("#{helper} holds no by-name call and ends in a proven NoMethodError", closed?(code, helper))
    check.call("#{helper} has an arm for #{arms.join(', ')}", text && arms.all? { |arm| text.include?("#{arm}(") })
    check.call("#{helper} keeps its inline fast paths ahead of the chain", text && text.index('M->array_class') < text.index('INDEX_CLOSED'))
  end
  getidx = helper_text(code, 'bc2cpp_getidx')
  check.call('the chain lists the program\'s definers first, the subclass that inherits next to its owner',
             getidx.include?('POLY_SMALL_N :[] -> IxVars, IxGrid, IxOwn, IxArrOver') && getidx.include?('INHERITED_GUARD :[] -- also IxSub < IxVars') &&
             getidx.index('IxArrOver_') < getidx.index('mrb_ary_aget1_impl('))
  check.call('the Struct class arm tests the class made by Struct.new, not Struct itself', getidx.include?('bc2cpp_struct_class_p(M, k)'))
  check.call('a gem\'s exported function is declared weak and tested before it runs',
             code.include?('extern "C" __attribute__((weak)) mrb_bool rgss_table_p(mrb_value);') &&
             getidx.include?('rgss_table_p != nullptr && rgss_table_p(recv)') && code.include?('extern "C" mrb_value mrb_ary_aget1_impl(') &&
             !code.include?('__attribute__((weak)) mrb_value mrb_ary_aget1_impl'))
  setidx = helper_text(code, 'bc2cpp_setidx')
  check.call('setidx returns the assigned value from the Hash and String arms and the body\'s result from the others',
             setidx.scan(/r0 = val;/).size == 2 && setidx.include?('r0 = mrb_ary_aset2_impl('))

  negatives = {
    'a singleton `def self.[]` (a class object answers for itself)' =>
      ["#{FIXTURE}class IxBox\n  def self.[](k) = :single\nend\n", %w[bc2cpp_getidx bc2cpp_getidx0], %w[bc2cpp_setidx]],
    'a method_missing class' =>
      ["#{FIXTURE}class IxMissing\n  def method_missing(n, *a) = :mm\nend\n", %w[bc2cpp_getidx bc2cpp_getidx0 bc2cpp_setidx], []],
    'a module definer of `[]`' =>
      ["#{FIXTURE}module IxMod\n  def [](k) = :mod\nend\nclass IxBox\n  include IxMod\nend\n", %w[bc2cpp_getidx bc2cpp_getidx0], %w[bc2cpp_setidx]],
    'a `[]` that takes two arguments (not a candidate of the chain)' =>
      ["#{FIXTURE}class IxTwo\n  def [](a, b) = a\nend\n", %w[bc2cpp_getidx bc2cpp_getidx0], %w[bc2cpp_setidx]],
    'more subclasses of IxVars than the chain can list' =>
      [FIXTURE + (1..20).map { |i| "class IxMany#{i} < IxVars\nend\n" }.join, %w[bc2cpp_getidx bc2cpp_getidx0 bc2cpp_setidx], []]
  }
  negatives.each do |what, (source, open_helpers, closed_helpers)|
    owners = OWNERS + %w[IxMissing IxMod IxTwo] + (1..20).map { |i| "IxMany#{i}" }
    code, = generate(runtime, source, only_owners: owners)
    check.call("NEG: #{what} keeps the by-name helpers #{open_helpers.join(', ')}", open_helpers.all? { |h| open?(code, h) })
    check.call("...and #{closed_helpers.empty? ? 'leaves none closed' : "#{closed_helpers.join(', ')} stays closed"}",
               closed_helpers.all? { |h| closed?(code, h) } && (open_helpers + closed_helpers).size >= 1)
  end
  reopened = generate(runtime, "#{FIXTURE}class Array\n  def [](i) = :array_over\nend\n", only_owners: OWNERS + %w[Array])
  check.call('POS: a Ruby `Array#[]` joins the chain as one more owner and the helper stays closed',
             closed?(reopened[0], 'bc2cpp_getidx') && helper_text(reopened[0], 'bc2cpp_getidx').include?('Array'))
  check.call('NEG: a build that links mruby-method (Method#[] has no exported body) keeps the by-name helpers',
             (code, = generate(runtime, FIXTURE, build_gems: { 'mruby-method' => File.join(Bc2cppFixtureRuntime::ROOT, '3rd/mruby/mrbgems/mruby-method') })) &&
             open?(code, 'bc2cpp_getidx') && open?(code, 'bc2cpp_getidx0'))
  off, = with_env('BC2CPP_INDEX_HELPER_CLOSED' => '0') { generate(runtime, FIXTURE) }
  check.call('BC2CPP_INDEX_HELPER_CLOSED=0 keeps the by-name helpers byte for byte',
             %w[bc2cpp_getidx bc2cpp_getidx0 bc2cpp_setidx].all? { |h| open?(off, h) } && !off.include?('INDEX_CLOSED') &&
             off.include?('r0 = bc2cpp_send(M, recv, ') && !off.include?('extern "C" __attribute__'))
  open_world, = generate(runtime, FIXTURE, closed: false)
  check.call('NEG: an open world keeps the by-name helpers', %w[bc2cpp_getidx bc2cpp_getidx0 bc2cpp_setidx].all? { |h| open?(open_world, h) })
end

# The sources the generator trusts: the wrappers must still call the exported bodies, the registrations must be the ones scanned.
def source_audit_checks(check, runtime)
  puts '-- the generator reads the mruby sources it is built from'
  root = Bc2cppFixtureRuntime::ROOT
  mruby = File.join(root, '3rd/mruby')
  unless File.exist?(File.join(mruby, 'src/array.c'))
    puts '  SKIP: no 3rd/mruby tree'
    return
  end
  edits = {
    'Array#[] stops calling mrb_ary_aget1_impl' => ['src/array.c', 'return mrb_ary_aget1_impl(mrb, self, mrb_get_arg1(mrb));', 'return mrb_nil_value();'],
    'Array#[]= stops calling mrb_ary_aset2_impl' => ['src/array.c', 'return mrb_ary_aset2_impl(mrb, self, vs[0], vs[1]);', 'return vs[1];'],
    'Hash#[] stops being mrb_hash_get' => ['src/hash.c', 'return mrb_hash_get(mrb, self, key);', 'return mrb_nil_value();'],
    'String#[]= stops being mrb_str_aset' => ['src/string.c', 'mrb_str_aset(mrb, str, idx, alen, replace);', 'mrb_str_aset(mrb, str, idx, alen, replace); alen = idx;'],
    'Struct#[] stops calling mrb_struct_aref_impl' => ['mrbgems/mruby-struct/src/struct.c', 'return mrb_struct_aref_impl(mrb, s, mrb_get_arg1(mrb));', 'return mrb_nil_value();'],
    'Proc#[] stops being call_proc' => ['src/proc.c', "MRB_METHOD_FROM_PROC(m, &call_proc);\n  mrb_define_method_raw(mrb, pc, MRB_SYM(call), m);",
                                        "MRB_METHOD_FROM_PROC(m, &call_proc);\n  (void)0;\n  mrb_define_method_raw(mrb, pc, MRB_SYM(call), m);"],
    'mrb_instance_new stops being mrb_obj_new plus a block' => ['src/class.c', 'mrb_funcall_with_block(mrb, obj, init, argc, argv, blk);', 'mrb_funcall_argv(mrb, obj, init, argc, argv);']
  }
  edits.each do |what, (file, from, to)|
    Dir.mktmpdir do |dir|
      scratch = File.join(dir, '3rd/mruby')
      FileUtils.mkdir_p(File.dirname(scratch))
      FileUtils.cp_r(mruby, scratch)
      path = File.join(scratch, file)
      text = File.read(path, encoding: 'UTF-8')
      unless text.include?(from)
        check.call("MUTANT #{what}: the edit applies to the tree", false)
        next
      end
      File.write(path, text.sub(from, to))
      natives = core_native_srcs(scratch) + Dir["#{root}/mruby-rgss/src/*.cxx"] + external_gem_native_srcs(root)
      code, err = Dir.mktmpdir do |gen_dir|
        source = File.join(gen_dir, 'fixture.rb')
        File.write(source, FIXTURE)
        env = { 'MRBC' => runtime.mrbc, 'OUT_SYMBOL' => 'fixture', 'OUT_DIR' => gen_dir, 'BC2CPP_SELF_REGISTERING' => '1', 'SKIP_UNSUPPORTED' => '1',
                'ONLY_OWNERS' => OWNERS.join(','), 'NATIVE_SRCS' => Shellwords.join(natives),
                'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)), 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(root).map { |n, d| "#{n}=#{d}" }),
                NomethodReviewed::ALLOW_ENV => 'allow' }
        out, e, status = Open3.capture3(env, RbConfig.ruby, Bc2cppFixtureRuntime::BC2CPP, '--annotated', source)
        raise "bc2cpp.rb failed:\n#{e[-2000..]}" unless status.success?

        [out, e]
      end
      mutated_open = %w[bc2cpp_getidx bc2cpp_getidx0 bc2cpp_setidx].any? { |h| open?(code, h) }
      check.call("MUTANT #{what}: a helper that stands on it goes back to by-name (#{err[/index helpers closed[^\n]*/]})", mutated_open)
    end
  end
end

# --- the run against real mruby -------------------------------------------------------------------------------------

WIDTHS = { 64 => { fmax: '4611686018427387903' }, 32 => { fmax: '1073741823' }, nobig: { fmax: '2147483647' } }.freeze

# The Ruby side: fresh receivers and keys per case (the two runs of a case need equal, separate objects).
def index_driver(width)
  <<~RUBY
  FM = #{WIDTHS.fetch(width)[:fmax]}
  IM = $bigint ? FM * 2 + 1 : FM
  class IxTable
  end
  module Ix
    KEYS = [
      -> { 0 }, -> { 1 }, -> { -1 }, -> { 2 }, -> { 3 }, -> { 5 }, -> { -5 }, -> { 100 }, -> { FM }, -> { -FM }, -> { -FM - 1 },
      -> { 1.5 }, -> { -0.5 }, -> { 2.0 }, -> { 1.0e30 }, -> { "a" }, -> { "ab" }, -> { "z" }, -> { :x }, -> { :y }, -> { nil },
      -> { true }, -> { 1..2 }, -> { 0..-1 }, -> { -3..-1 }, -> { 2..1 }, -> { 1...1 }, -> { 5..6 }, -> { 1.. }, -> { [1] },
      -> { { a: 1 } }, -> { IxConv.new }, -> { IxBox.new }, -> { IxBox }, -> { $bigint ? 2**70 : IM }, -> { $bigint ? -(2**70) : -IM }
    ]
    KEYS_SET = KEYS
    VALS = [-> { 1 }, -> { "s" }, -> { nil }, -> { :v }, -> { [1, 2] }, -> { 2.5 }, -> { "longer replacement" }, -> { IxBox.new }]
    PROCS = [
      -> { lambda { |x| x } }, -> { proc { |x| [x] } }, -> { lambda { |a, b| a } }, -> { lambda { 1 } }, -> { :upcase.to_proc },
      -> { proc { |x| break x } }, -> { lambda { |x| return x } }, -> { proc { |*a| a } }
    ]
    def self.recvs_get
      r = []
      r << ['array', -> { [10, 20, 30] }] << ['array-empty', -> { [] }] << ['array-frozen', -> { [1, 2, 3].freeze }]
      r << ['array-nested', -> { [[1], nil, "x", 2.5] }]
      r << ['IxArr', -> { a = IxArr.new; a.push(10, 20, 30); a }] << ['IxArrOver', -> { a = IxArrOver.new; a.push(1, 2); a }]
      r << ['hash', -> { { 1 => :a, "k" => 2, nil => 3, 1.5 => 4, [1] => 5 } }] << ['hash-default', -> { Hash.new(7) }]
      r << ['hash-proc', -> { Hash.new { |h, k| [:dflt, k] } }] << ['hash-frozen', -> { { 1 => 2 }.freeze }]
      r << ['IxHsh', -> { h = IxHsh.new; h[1] = :one; h["a"] = :str; h }]
      r << ['string', -> { +"hello" }] << ['string-mb', -> { +"h\\u00e9llo\\u3042" }] << ['string-empty', -> { +"" }]
      r << ['string-frozen', -> { "frozen".freeze }] << ['IxStr', -> { IxStr.new("sub") }]
      r << ['struct', -> { IxPoint.new(1, 2) }] << ['IxPointSub', -> { IxPointSub.new(3, 4) }] << ['struct-frozen', -> { IxPoint.new(5, 6).freeze }]
      r << ['IxVars', -> { IxVars.new }] << ['IxSub', -> { IxSub.new }] << ['IxOwn', -> { IxOwn.new }] << ['IxGrid', -> { IxGrid.new }]
      r << ['IxTable', -> { t = IxTable.new(5); 5.times { |i| t[i] = i * 3 }; t }]
      PROCS.each_with_index { |pr, i| r << ["proc\#{i}", pr] }
      r << ['Array.class', -> { Array }] << ['IxArr.class', -> { IxArr }] << ['Hash.class', -> { Hash }] << ['IxHsh.class', -> { IxHsh }]
      r << ['IxPoint.class', -> { IxPoint }] << ['IxPointSub.class', -> { IxPointSub }] << ['Struct.class', -> { Struct }]
      r << ['IxBox.class', -> { IxBox }] << ['IxVars.class', -> { IxVars }] << ['Object.class', -> { Object }] << ['Integer.class', -> { Integer }]
      r << ['Class', -> { Class }] << ['Comparable', -> { Comparable }] << ['Kernel', -> { Kernel }]
      r << ['Array.sclass', -> { Array.singleton_class }] << ['IxBox.sclass', -> { IxBox.singleton_class }]
      r << ['nil', -> { nil }] << ['true', -> { true }] << ['int', -> { 7 }] << ['float', -> { 1.5 }] << ['sym', -> { :sym }]
      r << ['range', -> { 1..3 }] << ['IxBox', -> { IxBox.new }] << ['IxConv', -> { IxConv.new }]
      r
    end
    def self.recvs_set
      r = []
      r << ['array', -> { [10, 20, 30] }] << ['array-empty', -> { [] }] << ['array-frozen', -> { [1, 2, 3].freeze }]
      r << ['IxArr', -> { a = IxArr.new; a.push(10, 20, 30); a }] << ['IxArrOver', -> { IxArrOver.new }]
      r << ['hash', -> { { 1 => :a, "k" => 2 } }] << ['hash-frozen', -> { { 1 => 2 }.freeze }] << ['hash-default', -> { Hash.new(7) }]
      r << ['IxHsh', -> { IxHsh.new }]
      r << ['string', -> { +"hello" }] << ['string-mb', -> { +"h\\u00e9llo\\u3042" }] << ['string-empty', -> { +"" }]
      r << ['string-frozen', -> { "frozen".freeze }] << ['IxStr', -> { IxStr.new("sub") }]
      r << ['struct', -> { IxPoint.new(1, 2) }] << ['IxPointSub', -> { IxPointSub.new(3, 4) }] << ['struct-frozen', -> { IxPoint.new(5, 6).freeze }]
      r << ['IxVars', -> { IxVars.new }] << ['IxSub', -> { IxSub.new }] << ['IxOwn', -> { IxOwn.new }] << ['IxGrid', -> { IxGrid.new }]
      r << ['IxTable', -> { t = IxTable.new(5); 5.times { |i| t[i] = i }; t }]
      r << ['Array.class', -> { Array }] << ['IxBox.class', -> { IxBox }] << ['IxPoint.class', -> { IxPoint }]
      r << ['proc', -> { proc { |x| x } }] << ['nil', -> { nil }] << ['int', -> { 7 }] << ['sym', -> { :sym }] << ['IxBox', -> { IxBox.new }]
      r
    end
    SETKEYS = (0...KEYS.size).to_a
    GET_CASES = []
    SET_CASES = []
    def self.build
      recvs_get.each { |rl, rf| KEYS.each_with_index { |kf, ki| GET_CASES << [rl, rf, ki] } }
      recvs_set.each do |rl, rf|
        SETKEYS.each { |ki| VALS.each_with_index { |_, vi| SET_CASES << [rl, rf, ki, vi] } }
      end
    end
    def self.get_pair(i)
      _, rf, ki = GET_CASES[i]
      [rf.call, KEYS[ki].call, rf.call, KEYS[ki].call]
    end
    def self.set_pair(i)
      _, rf, ki, vi = SET_CASES[i]
      [rf.call, KEYS[ki].call, VALS[vi].call, rf.call, KEYS[ki].call, VALS[vi].call]
    end
    def self.get_label(i) = GET_CASES[i][0] + " " + desc(KEYS[GET_CASES[i][2]].call)
    def self.set_label(i)
      c = SET_CASES[i]
      c[0] + " " + desc(KEYS[c[2]].call) + " = " + desc(VALS[c[3]].call)
    end
    def self.get_count = GET_CASES.size
    def self.set_count = SET_CASES.size
    def self.desc(v)
      case v
      when nil, true, false, Symbol then v.inspect
      when Integer then "\#{v} h=\#{v.hash}"
      when Float then v.nan? ? "NaN" : "\#{v.inspect} bits=\#{[v].pack('E').unpack('Q')[0] rescue v}"
      when String then "\#{v.inspect} \#{v.class}\#{v.frozen? ? ' frozen' : ''}"
      when Array then "[" + v.map { |e| desc(e) }.join(", ") + "] \#{v.class}\#{v.frozen? ? ' frozen' : ''}"
      when Hash then "{" + v.map { |k, e| desc(k) + "=>" + desc(e) }.join(", ") + "} \#{v.class}\#{v.frozen? ? ' frozen' : ''}"
      when Range then "range(\#{desc(v.begin)}, \#{desc(v.end)}, \#{v.exclude_end?})"
      when Proc then "proc"
      when Module then v.inspect.start_with?("\#<") ? "\#<anon>" : v.inspect
      when IxPoint then "point(\#{desc(v.x)}, \#{desc(v.y)}) \#{v.class}\#{v.frozen? ? ' frozen' : ''}"
      when IxTable then "table(\#{(0...5).map { |i| (v[i] rescue :err) }.inspect})"
      when IxVars, IxGrid then "\#{v.inspect} \#{v.class} last=\#{desc(v.instance_variable_get(:@last))}"
      else "\#{v.class}"
      end
    end
    def self.err(e) = "raised \#{e.class}: \#{e.message}"
    def self.arity_ok? = true
  end
  Ix.build
  o = IxOpen.new
  # The fixture's own methods, compiled and interpreted.
  Ix.get_count.times do |i|
    recv, key, = Ix.get_pair(i)
    puts "get \#{Ix.get_label(i)} => \#{(Ix.desc(o.get(recv, key)) rescue Ix.err($!))}"
    recv, = Ix.get_pair(i)
    puts "get0 \#{Ix.get_label(i).split(' ').first} => \#{(Ix.desc(o.get0(recv)) rescue Ix.err($!))}" if i % Ix::KEYS.size == 0
  end
  Ix.set_count.times do |i|
    recv, key, val, = Ix.set_pair(i)
    r = (Ix.desc(o.set(recv, key, val)) rescue Ix.err($!))
    puts "set \#{Ix.set_label(i)} => \#{r} then \#{Ix.desc(recv)}"
  end
  c = IxCap.new
  %i[run_idx run_stored run_forms run_ret run_lambda run_lambda_arity run_break run_upvar run_nested].each do |m|
    puts "cap \#{m} => \#{(Ix.desc(c.send(m)) rescue Ix.err($!))}"
  end
  puts 'end driver'
  RUBY
end

# The member receivers a compiled run must answer with no by-name call.
DISPATCH_DRIVER = <<~RUBY
  member = %w[array array-empty array-frozen array-nested IxArr IxArrOver hash hash-default hash-proc hash-frozen IxHsh string string-mb
              string-empty string-frozen IxStr struct IxPointSub struct-frozen IxVars IxSub IxOwn IxGrid IxTable proc0 proc1 proc2 proc3
              proc4 Array.class IxArr.class Hash.class IxHsh.class IxPoint.class IxPointSub.class]
  Ix::GET_CASES.each_index do |i|
    label = Ix::GET_CASES[i][0]
    next unless member.include?(label)
    recv, key, = Ix.get_pair(i)
    # The program's own `[]` does arithmetic on its key, which is its own business.
    next if %w[IxVars IxSub IxOwn IxGrid].include?(label) && !key.is_a?(Integer)
    puts "  D get \#{Ix.get_label(i)} \#{(o.dget(recv, key) rescue -1)}"
  end
  Ix::SET_CASES.each_index do |i|
    label = Ix::SET_CASES[i][0]
    next unless member.include?(label)
    recv, key, val, = Ix.set_pair(i)
    puts "  D set \#{Ix.set_label(i)} \#{(o.dset(recv, key, val) rescue -1)}"
  end
RUBY

SCENARIO = <<~CPP
  #include <string>
  #include <vector>
  // Stand-in for rgss's Table: the same three entry points the generated helper declares, over a plain vector.
  struct IxTab { mrb_int xs, ys, zs; std::vector<int16_t> d; };
  static void ix_tab_free(mrb_state*, void* p) { delete static_cast<IxTab*>(p); }
  static const mrb_data_type ix_tab_type = { "IxTable", ix_tab_free };
  static IxTab& ix_tab(mrb_state* M, mrb_value self) { return *static_cast<IxTab*>(mrb_data_get_ptr(M, self, &ix_tab_type)); }
  static long ix_tab_index(const IxTab& t, mrb_int x, mrb_int y, mrb_int z) {
    if (x < 0 || x >= t.xs || y < 0 || y >= t.ys || z < 0 || z >= t.zs) return -1;
    return x + y * (long)t.xs + z * (long)t.xs * t.ys;
  }
  static mrb_value ix_tab_init(mrb_state* M, mrb_value self) {
    mrb_int a, b = 1, c = 1;
    mrb_get_args(M, "i|ii", &a, &b, &c);
    mrb_int argc = mrb_get_argc(M);
    IxTab* t = new IxTab{ a, argc >= 2 ? b : 1, argc >= 3 ? c : 1, {} };
    t->d.assign((size_t)t->xs * t->ys * t->zs, 0);
    mrb_data_init(self, t, &ix_tab_type);
    return self;
  }
  static mrb_value ix_tab_get_impl(mrb_state* M, mrb_value self, mrb_int x, mrb_int y, mrb_int z) {
    IxTab& t = ix_tab(M, self);
    long i = ix_tab_index(t, x, y, z);
    return i < 0 ? mrb_nil_value() : mrb_fixnum_value(t.d[i]);
  }
  static mrb_value ix_tab_set_impl(mrb_state* M, mrb_value self, mrb_int argc, mrb_value a0, mrb_value a1, mrb_value a2, mrb_value a3) {
    mrb_int x = mrb_as_int(M, a0), y = 0, z = 0;
    mrb_value v;
    if (argc == 2) { v = a1; }
    else if (argc == 3) { y = mrb_as_int(M, a1); v = a2; }
    else { y = mrb_as_int(M, a1); z = mrb_as_int(M, a2); v = a3; }
    IxTab& t = ix_tab(M, self);
    long i = ix_tab_index(t, x, y, z);
    if (i < 0) return v;
    t.d[i] = (int16_t)mrb_as_int(M, v);
    return v;
  }
  static mrb_value ix_tab_get(mrb_state* M, mrb_value self) {
    mrb_int x, y = 0, z = 0;
    mrb_get_args(M, "i|ii", &x, &y, &z);
    return ix_tab_get_impl(M, self, x, y, z);
  }
  static mrb_value ix_tab_set(mrb_state* M, mrb_value self) {
    mrb_value a0, a1, a2 = mrb_nil_value(), a3 = mrb_nil_value();
    mrb_get_args(M, "oo|oo", &a0, &a1, &a2, &a3);
    return ix_tab_set_impl(M, self, mrb_get_argc(M), a0, a1, a2, a3);
  }
  extern "C" mrb_bool rgss_table_p(mrb_value v) { return mrb_data_p(v) && DATA_TYPE(v) == &ix_tab_type; }
  extern "C" mrb_value rgss_table_aref_impl(mrb_state* M, mrb_value self, mrb_int x, mrb_int y, mrb_int z) { return ix_tab_get_impl(M, self, x, y, z); }
  extern "C" mrb_value rgss_table_aset_impl(mrb_state* M, mrb_value self, mrb_int argc, mrb_value a0, mrb_value a1, mrb_value a2, mrb_value a3) {
    return ix_tab_set_impl(M, self, argc, a0, a1, a2, a3);
  }

  struct IxCall { int kind; mrb_value recv, key, val; bool method; };
  static mrb_value ix_body(mrb_state* M, void* ud) {
    IxCall* k = (IxCall*)ud;
    if (k->method) {
      switch (k->kind) {
        case 0: return (mrb_funcall)(M, k->recv, "[]", 1, k->key);
        case 1: return (mrb_funcall)(M, k->recv, "[]", 1, mrb_fixnum_value(0));
        default: return (mrb_funcall)(M, k->recv, "[]=", 2, k->key, k->val);
      }
    }
    switch (k->kind) {
      case 0: return bc2cpp_getidx(M, k->recv, k->key);
      case 1: return bc2cpp_getidx0(M, k->recv);
      default: return bc2cpp_setidx(M, k->recv, k->key, k->val);
    }
  }
  static std::string ix_str(mrb_state* M, mrb_value s) {
    return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
  }
  // The value, or the class and message of the error; for a write, the receiver afterwards.
  static std::string ix_describe(mrb_state* M, mrb_value ix, mrb_value v, bool raised, mrb_value recv, bool after) {
    std::string out = raised ? ix_str(M, (mrb_funcall)(M, ix, "err", 1, v)) : ix_str(M, (mrb_funcall)(M, ix, "desc", 1, v));
    if (after) {
      mrb_value st = (mrb_funcall)(M, ix, "desc", 1, recv);
      if (M->exc) { M->exc = nullptr; out += " then <desc failed>"; } else out += " then " + ix_str(M, st);
    }
    return out;
  }
  static int ix_run(mrb_state* M, mrb_value ix, int kind, mrb_int n) {
    int total = 0, bad = 0;
    for (mrb_int i = 0; i < n; ++i) {
      int ai = mrb_gc_arena_save(M);
      mrb_value pair = (mrb_funcall)(M, ix, kind == 2 ? "set_pair" : "get_pair", 1, mrb_fixnum_value(i));
      mrb_value label = (mrb_funcall)(M, ix, kind == 2 ? "set_label" : "get_label", 1, mrb_fixnum_value(i));
      mrb_value ha = RARRAY_PTR(pair)[0], ka = RARRAY_PTR(pair)[1], va = mrb_nil_value();
      mrb_value hb, kb, vb = mrb_nil_value();
      if (kind == 2) { va = RARRAY_PTR(pair)[2]; hb = RARRAY_PTR(pair)[3]; kb = RARRAY_PTR(pair)[4]; vb = RARRAY_PTR(pair)[5]; }
      else { hb = RARRAY_PTR(pair)[2]; kb = RARRAY_PTR(pair)[3]; }
      IxCall got_call = { kind, ha, ka, va, false }, want_call = { kind, hb, kb, vb, true };
      mrb_bool e1 = FALSE, e2 = FALSE;
      mrb_value got = mrb_protect_error(M, ix_body, &got_call, &e1);
      mrb_value want = mrb_protect_error(M, ix_body, &want_call, &e2);
      std::string g = ix_describe(M, ix, got, e1, ha, kind == 2), w = ix_describe(M, ix, want, e2, hb, kind == 2);
      ++total;
      if (g != w) {
        ++bad;
        if (bad <= 8) std::printf("  H MISMATCH %d %s helper=%.200s method=%.200s\\n", kind, ix_str(M, label).c_str(), g.c_str(), w.c_str());
      }
      mrb_gc_arena_restore(M, ai);
    }
    std::printf("  H summary %d %d cases, %d mismatches\\n", kind, total, bad);
    return bad;
  }
  static int scenario(mrb_state* M) {
    RClass* probe = mrb_define_module(M, "IxProbe");
    mrb_define_class_method(M, probe, "dispatches", [](mrb_state*, mrb_value) { return mrb_fixnum_value(dispatches); }, MRB_ARGS_NONE());
    RClass* tab = mrb_define_class(M, "IxTable", M->object_class);
    MRB_SET_INSTANCE_TT(tab, MRB_TT_CDATA);
    mrb_define_method(M, tab, "initialize", ix_tab_init, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2));
    mrb_define_method(M, tab, "[]", ix_tab_get, MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2));
    mrb_define_method(M, tab, "[]=", ix_tab_set, MRB_ARGS_REQ(2) | MRB_ARGS_OPT(2));
    std::fflush(stdout);
    const char* src = R"BCD(__SOURCE__)BCD";
    mrb_load_string(M, src);
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    mrb_value ix = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "Ix"));
    mrb_int gets = mrb_integer((mrb_funcall)(M, ix, "get_count", 0));
    mrb_int sets = mrb_integer((mrb_funcall)(M, ix, "set_count", 0));
    // Each helper called directly against the method it stands for; the interpreted VM runs the same helpers, which
    // the registered compiled methods do not change.
    ix_run(M, ix, 0, gets);
    ix_run(M, ix, 1, gets);
    ix_run(M, ix, 2, sets);
    return 0;
  }
CPP

def runtime_checks(check, runtime, builds)
  builds.each do |label, build, mrbc, flags, width, bigint|
    puts "-- closed index helpers on real mruby (#{label})"
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = flags
    begin
      Dir.mktmpdir do |dir|
        _code, err = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS)
        source = "$bigint = #{bigint}\n#{index_driver(width)}\n#{DISPATCH_DRIVER}\nputs 'end dispatch'\n"
        scenario = SCENARIO.sub('__SOURCE__') { source }
        built, output = runtime.run(dir, err, OWNERS, scenario, build: build, full: true)
        check.call('the closed index fixture compiles and runs against real mruby', built)
        puts output.to_s.lines.last(25).join unless built
        next unless built

        sections = runtime.sections(output)
        interpreted = sections['interpreted'].to_a
        compiled = sections['compiled'].to_a
        strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
        check.call('both runs finish', strip.call(interpreted).include?('end driver') && strip.call(compiled).include?('end driver'))
        check.call("the fixture's methods answer as the interpreter does: value, error class and message, receiver afterwards " \
                   "(#{strip.call(interpreted).size} answers)",
                   strip.call(interpreted) == strip.call(compiled) && strip.call(interpreted).size > 5000)
        strip.call(interpreted).zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
          puts "    interpreted: #{a}\n    compiled:    #{b}"
        end
        classes = %w[NoMethodError TypeError ArgumentError IndexError RangeError FrozenError LocalJumpError]
        check.call("the matrix has #{classes.join(', ')} rows", classes.all? { |e| interpreted.count { |l| l.include?(e) } > 5 })
        check.call('the matrix reaches Array.[], Hash.[] (also below a class), a Struct class\'s [], a lambda\'s arity error and a proc\'s break',
                   %w[IxArr.class IxPoint.class IxPointSub.class proc2 proc5].all? { |label| interpreted.any? { |l| l.start_with?("get #{label} ") } } &&
                   interpreted.any? { |l| l.include?('wrong number of arguments') && l.start_with?('get proc2') })
        [interpreted, compiled].each_with_index do |lines, i|
          %w[0 1 2].each do |kind|
            summary = lines.grep(/\A  H summary #{kind} /).first.to_s
            lines.grep(/\A  H MISMATCH #{kind} /).first(5).each { |l| puts "    #{l.strip}" }
            check.call("#{i.zero? ? 'interpreted' : 'compiled'}: the #{%w[getidx getidx0 setidx][kind.to_i]} helper agrees with the method it stands for (#{summary.strip})",
                       summary.match?(/ 0 mismatches/) && summary[/ #{kind} (\d+) cases/, 1].to_i > 300)
          end
        end
        dispatched = compiled.grep(/\A  D /)
        bad = dispatched.reject { |l| %w[0 -1].include?(l.split.last) }
        check.call("a member receiver makes no by-name call (#{dispatched.size} calls)",
                   dispatched.size > 1000 && bad.empty? && dispatched.count { |l| l.end_with?(' 0') } > 1000)
        bad.first(5).each { |l| puts "    dispatched: #{l.strip}" }
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
end

# BC2CPP_INDEX_CLOSED_ONLY=run runs only the sections against real mruby.
ONLY_RUN = ENV['BC2CPP_INDEX_CLOSED_ONLY'] == 'run'
generated_checks(check, runtime) if ENV['MRBC'] && !ONLY_RUN
source_audit_checks(check, runtime) if ENV['MRBC'] && !ONLY_RUN

builds = []
full = runtime.full
builds << ['mrb_int 64', full, ENV['MRBC'], '-DMRB_USE_BIGINT', 64, true] if full && runtime.compiler?
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && runtime.compiler?
  builds << ['mrb_int 32 (MRB_INT32, 31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
             '-DMRB_32BIT -DMRB_INT32 -no-pie -DMRB_USE_BIGINT', 32, true]
end
if ENV['BC2CPP_MRUBY_NOBIGINT'] && runtime.compiler?
  builds << ['no mruby-bigint (32-bit mrb_int, no heap Integers)', ENV['BC2CPP_MRUBY_NOBIGINT'], ENV['MRBC'], '', :nobig, false]
end
puts '-- SKIP run: set BC2CPP_MRUBY_FULL (a full-core libmruby.a built from the patched tree) and have g++' if builds.empty?
runtime_checks(check, runtime, builds) if ENV['MRBC']

if failures.empty?
  puts 'bc2cpp index closed check: PASS'
else
  warn "bc2cpp index closed check: #{failures.size} failure(s)"
  exit 1
end
