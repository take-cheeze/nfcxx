#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# INLINE_NIL_RECEIVER (tools/bc2cpp/codegen_loop_inline.rb inline_receiver_guard): an inlined block loop over an
# ivar the class hint names Array or Hash is entered with no class guard, but an ivar no path has assigned yet is nil.
# Its tripwire raised `TypeError: bc2cpp: expected Array receiver for inlined #each` where the interpreter raises
# `NoMethodError: undefined method 'each' for NilClass`; nil now takes the send's own NoMethodError first.
#
#   generated code (needs a host mrbc)
#     - `@h.each`, `@h.each_with_index`, `@h.map`, `@h.select`, `@h.inject(0)`, `@g.each`, `@g.each_value` and
#       `@g.each_key` test nil (bc2cpp_nil_receiver_id) ahead of the tripwire;
#     - NIL_RECEIVER_ID / COLD_RAISE (symbol_cache.rb): a nil arm passes no receiver and its helper is noreturn;
#       BC2CPP_NIL_RECEIVER_ID=0 and BC2CPP_COLD_NORETURN=0 bring back the receiver and the returning head;
#     - the nil arm of an inlined `inject(0)` passes its argument, as nil's NoMethodError#args has it;
#     - MONO_RECEIVER_PROOF (codegen_mono_receiver.rb): a MONO call (plain, keyword and keywordless) stays unguarded
#       only on a receiver proven to reach the owner (a fresh `.new`, self in the owner or a subclass); a nil-or-owner
#       ivar takes MONO_NILABLE's nil test, any other receiver MONO_GUARD's class guard with the by-name send (a module
#       owner, which no guard can name, MONO_UNPROVEN's plain send);
#       BC2CPP_MONO_RECEIVER_PROOF=0 brings back the unguarded MONO call; a keyword call to a method a `public :name`
#       in its own class body re-publicises after a private def stays direct (VISIBILITY_SAME_BODY);
#     - COLD_COMPACT_CALLS (cold_compact_calls.rb): with the CcHold methods on the cold list, each pair of identical
#       guarded sends (nil-receiver, class-guard, two-owner, keyword, block and element sites) calls one shared
#       helper; BC2CPP_COLD_COMPACT_CALLS=0 keeps the inline text;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same with the ivars assigned and with them left nil, the
#       NoMethodError's name and args included; a MONO name on nil, a String or an Integer raises as interpreted;
#       the cold-compacted world prints what the interpreter prints, wrong-class, nil, keyword and block cases included.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/inline_nil_receiver_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

SRC = <<~'RUBY'
  class InrBox
    def initialize(fill)
      @h = [] if fill
      @g = { 1 => 2 } if fill
    end
    def push(x); @h << x; end
    def each_sum; r = 0; @h.each { |v| r += v }; r; end
    def ewi; r = []; @h.each_with_index { |v, i| r << [v, i] }; r; end
    def map1; @h.map { |v| v + 1 }; end
    def sel; @h.select { |v| v > 1 }; end
    def fold; @h.inject(0) { |s, v| s + v }; end
    def heach; r = 0; @g.each { |_k, v| r += v }; r; end
    def hval; r = 0; @g.each_value { |v| r += v }; r; end
    def hkey; r = []; @g.each_key { |k| r << k }; r; end
  end
  class InrPt
    def initialize; @v = 1; end
    def x; @v; end
    def m(a, b); a + b + @v; end
  end
  class InrNo
    def nv; 1; end
    def na(a, b); a + b; end
  end
  class InrHold
    def initialize(fill)
      @p = fill ? InrPt.new : nil
      @q = fill ? InrNo.new : nil
      @w = fill ? InrNo.new : 'str'
      @fill = fill
    end
    def px; @p.x; end
    def pm; @p.m(1, 2); end
    def qv; @q.nv; end
    def qa; @q.na(1, 2); end
    def wv; @w.nv; end
    def ov(o); o.nv; end
    def onil; ov(@fill ? InrNo.new : nil); end
    def oint; ov(@fill ? InrNo.new : 5); end
    def fresh; InrNo.new.nv; end
  end
  class InrUse
    METHODS = %i[each_sum ewi map1 sel fold heach hval hkey px pm qv qa wv onil oint fresh].freeze
    HOLD = %i[px pm qv qa wv onil oint fresh].freeze
    def run(fill)
      b = InrBox.new(fill)
      b.push(2) if fill
      h = InrHold.new(fill)
      METHODS.map do |m|
        begin
          (HOLD.include?(m) ? h.send(m) : b.send(m)).inspect
        rescue NoMethodError => e
          "#{e.class}: #{e.message} name=#{e.name.inspect} args=#{e.args.inspect}"
        rescue StandardError => e
          "#{e.class}: #{e.message}"
        end
      end
    end
  end
RUBY

OWNERS = %w[InrBox InrPt InrNo InrHold InrUse].freeze
CASES = { 'InrBox_each_sum' => 'each', 'InrBox_ewi' => 'each_with_index', 'InrBox_map1' => 'map',
          'InrBox_sel' => 'select', 'InrBox_fold' => 'inject', 'InrBox_heach' => 'each', 'InrBox_hval' => 'each_value',
          'InrBox_hkey' => 'each_key' }.freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

dir = Dir.mktmpdir('bc2cpp-inline-nil')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
CASES.each do |fn, name|
  tripwires = method_code(code, fn).lines.grep(/receiver for inlined/)
  nil_arm = %r{if \(mrb_nil_p\((\w+)\)\) bc2cpp_nil_receiver_id\(M, \d+(?:, 1, r\d+)?\); /\* CLOSED_WORLD nil-receiver: #{name} \*/ mrb_raise}
  check.call("#{fn}: each inline loop tests nil ahead of its tripwire",
             !tripwires.empty? && tripwires.all? { |line| line.match?(nil_arm) })
end
cold = '[[noreturn, gnu::cold, gnu::noinline, maybe_unused]] static mrb_value bc2cpp_nil_receiver_id(mrb_state* M, int i, mrb_int argc, ...)'
check.call('InrBox_fold: the nil arm of an inlined inject(0) passes its argument',
           method_code(code, 'InrBox_fold').match?(/bc2cpp_nil_receiver_id\(M, \d+, 1, r\d+\)/))
check.call('COLD_RAISE: the nil-receiver and nomethod helpers are noreturn',
           code.include?(cold) && !code.include?('BC2CPP_NOIPA static mrb_value bc2cpp_nil_receiver'))
off_code, = Dir.mktmpdir('bc2cpp-inline-nil-off') do |off_dir|
  saved = ENV.to_h.slice('BC2CPP_NIL_RECEIVER_ID', 'BC2CPP_COLD_NORETURN')
  ENV['BC2CPP_NIL_RECEIVER_ID'] = '0'
  ENV['BC2CPP_COLD_NORETURN'] = '0'
  begin
    Bc2cppFixtureRuntime.generate(SRC, off_dir, core: true, only_owners: OWNERS)
  ensure
    %w[BC2CPP_NIL_RECEIVER_ID BC2CPP_COLD_NORETURN].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
  end
end
check.call('BC2CPP_NIL_RECEIVER_ID=0 BC2CPP_COLD_NORETURN=0: the receiver and the returning head come back',
           method_code(off_code.to_s, 'InrBox_each_sum').match?(/if \(mrb_nil_p\((\w+)\)\) bc2cpp_nil_receiver\(M, \1, \d+\);/) &&
             !off_code.to_s.include?('bc2cpp_nil_receiver_id(M, ') &&
             off_code.to_s.include?('BC2CPP_NOIPA static mrb_value bc2cpp_nil_receiver(mrb_state* M, mrb_value recv, int i)'))

MONO_SRC = <<~'RUBY'
  class Numeric
    def mnr_neg?; self < 0; end
  end
  module Enumerable
    def mnr_first; each { |x| return x }; nil; end
  end
  class MnrNo
    def nv; 1; end
    def kv(a, k: 1); a + k; end
    def self_kv; kv(1, k: 5); end
  end
  class MnrPriv
    private

    def pk(a, k: 1); a + k; end
    public :pk
  end
  class MnrSub < MnrNo
    def sub_kv; kv(2, k: 3); end
  end
  class MnrHold
    def initialize(fill)
      @q = fill ? MnrNo.new : nil
      @w = fill ? MnrNo.new : 'str'
      @fill = fill
    end
    def fresh; MnrNo.new.nv; end
    def qv; @q.nv; end
    def qk; @q.kv(1, k: 2); end
    def ql; @q.kv(1); end
    def wv; @w.nv; end
    def wk; @w.kv(1, k: 2); end
    def ov(o); o.nv; end
    def ok(o); o.kv(1, k: 2); end
    def onil; ov(@fill ? MnrNo.new : nil); end
    def oint; ov(@fill ? MnrNo.new : 5); end
    def oknil; ok(@fill ? MnrNo.new : nil); end
    def oksub; ok(@fill ? MnrSub.new : 5); end
    def selfk; MnrNo.new.self_kv; end
    def subk; MnrSub.new.sub_kv; end
    def on(o); o.mnr_neg?; end
    def onum; on(@fill ? -3 : 'x'); end
    def ef(o); o.mnr_first; end
    def efa; ef(@fill ? [4, 5] : 3); end
    def pv; MnrPriv.new.pk(1, k: 2); end
    def pvo(o); o.pk(1, k: 2); end
    def pvn; pvo(@fill ? MnrPriv.new : nil); end
  end
RUBY
MONO_OWNERS = %w[Numeric Enumerable MnrNo MnrPriv MnrSub MnrHold].freeze
MONO_TAGS = { 'MnrHold_fresh' => 'MONO :nv', 'MnrNo_self_kv' => 'MONO :kv', 'MnrSub_sub_kv' => 'MONO :kv',
              'MnrHold_qv' => 'MONO_NILABLE :nv', 'MnrHold_qk' => 'MONO_NILABLE :kv', 'MnrHold_ql' => 'MONO_NILABLE :kv',
              'MnrHold_wv' => 'MONO_GUARD :nv', 'MnrHold_wk' => 'MONO_GUARD :kv', 'MnrHold_ov' => 'MONO_GUARD :nv',
              'MnrHold_ok' => 'MONO_GUARD :kv', 'MnrHold_on' => 'MONO_GUARD :mnr_neg?',
              'MnrHold_ef' => 'MONO_UNPROVEN :mnr_first', 'MnrHold_pv' => 'MONO :pk', 'MnrHold_pvo' => 'MONO_NILABLE :pk' }.freeze
mono_dir = Dir.mktmpdir('bc2cpp-mono-nil')
at_exit { FileUtils.remove_entry(mono_dir) }
mono_code, mono_err = Bc2cppFixtureRuntime.generate(MONO_SRC, mono_dir, only_owners: MONO_OWNERS)
check.call('MONO fixture: no #error in the generated code', !mono_code.include?('#error'))
MONO_TAGS.each do |fn, tag|
  check.call("#{fn}: #{tag}", method_code(mono_code, fn).include?("// #{tag} "))
end
check.call('MnrHold_ok, MnrHold_on: an owner with a subclass (MnrSub, Integer) is tested with kind_of',
           %w[MnrHold_ok MnrHold_on].all? { |fn| method_code(mono_code, fn).include?('bc2cpp_kind_of_owner(M, ') })
check.call('MnrHold_wk: the guard\'s else arm is the keyword send OP_SEND makes',
           method_code(mono_code, 'MnrHold_wk').include?('bc2cpp_send_kw(M, '))
off_mono, = Dir.mktmpdir('bc2cpp-mono-nil-off') do |off_dir|
  ENV['BC2CPP_MONO_RECEIVER_PROOF'] = '0'
  Bc2cppFixtureRuntime.generate(MONO_SRC, off_dir, only_owners: MONO_OWNERS)
ensure
  ENV.delete('BC2CPP_MONO_RECEIVER_PROOF')
end
check.call('BC2CPP_MONO_RECEIVER_PROOF=0: every MONO call is unguarded again',
           %w[MnrHold_qv MnrHold_qk MnrHold_wv MnrHold_ov MnrHold_ok].all? { |fn| method_code(off_mono.to_s, fn).match?(%r{// MONO :\w+ -> }) } &&
             !off_mono.to_s.match?(/MONO_(?:NILABLE|GUARD|UNPROVEN) :/))

# VISIBILITY_SAME_BODY (closed_world.rb): a `public :pk` after a private def, in the same class body, leaves the
# keyword call's visibility proven, so the MONO call stays direct; with every visibility send counted it is the
# by-name keyword send.
vis_off, = Dir.mktmpdir('bc2cpp-mono-vis-off') do |off_dir|
  ENV['BC2CPP_VISIBILITY_SAME_BODY'] = '0'
  Bc2cppFixtureRuntime.generate(MONO_SRC, off_dir, only_owners: MONO_OWNERS)
ensure
  ENV.delete('BC2CPP_VISIBILITY_SAME_BODY')
end
check.call('BC2CPP_VISIBILITY_SAME_BODY=0: the re-publicised keyword call is the by-name keyword send',
           !method_code(vis_off.to_s, 'MnrHold_pv').include?('MnrPriv_pk_impl(M') &&
             method_code(vis_off.to_s, 'MnrHold_pv').include?('bc2cpp_send_kw(M, '))

# COLD_COMPACT_CALLS: every method a pair with the same send, so each guarded site has a twin to share a helper with.
COLD_SRC = <<~'RUBY'
  class CcA
    def initialize; @n = 1; end
    def nv; @n + 1; end
    def kv(a, k: 1); a + k + @n; end
    def each_v; yield @n; yield 4; end
    private

    def secret; @n; end
  end
  class CcB
    def initialize; @n = 2; end
    def nv; @n * 2; end
    def kv(a, k: 1); a * k + @n; end
    def each_v; yield @n; end
  end
  class CcHold
    def initialize(fill)
      @q = fill ? CcA.new : nil
      @w = fill ? CcA.new : 'str'
      @p = fill ? CcB.new : (@q || CcA.new)
      @a = fill ? [7, 8] : nil
      @h = fill ? { k: 9 } : nil
    end
    def qv1; @q.nv; end
    def qv2; @q.nv; end
    def wv1; @w.nv; end
    def wv2; @w.nv; end
    def pv1; @p.nv; end
    def pv2; @p.nv; end
    def qk1; @q.kv(1, k: 2); end
    def qk2; @q.kv(1, k: 2); end
    def wk1; @w.kv(3, k: 4); end
    def wk2; @w.kv(3, k: 4); end
    def pk1; @p.kv(2, k: 5); end
    def pk2; @p.kv(2, k: 5); end
    def qb1; r = 0; @q.each_v { |x| r += x }; r; end
    def qb2; r = 0; @q.each_v { |x| r += x }; r; end
    def pb1; r = []; @p.each_v { |x| r << x }; r; end
    def pb2; r = []; @p.each_v { |x| r << x }; r; end
    def ae1; @a[1]; end
    def ae2; @a[1]; end
    def he1; @h[:k]; end
    def he2; @h[:k]; end
    def as1; @a[0] = 6; end
    def as2; @a[0] = 6; end
    def qs1; @q.secret; end
    def qs2; @q.secret; end
  end
RUBY
COLD_OWNERS = %w[CcA CcB CcHold].freeze
COLD_NAMES = COLD_SRC[/class CcHold.*/m].scan(/def (\w+)/).flatten - ['initialize']
# The pairs whose send is a guarded statement; the rest (a stack block's send, a single by-name or index call) are one
# call already and only take part in the behavioural comparison.
COLD_PAIRS = %w[qv wv pv qk wk pk he].map { |n| ["#{n}1", "#{n}2"] }
cold_list = File.join(Dir.mktmpdir('bc2cpp-cold-calls-list'), 'cold_methods.txt')
File.write(cold_list, "# fixture\n#{COLD_NAMES.map { |n| "CcHold##{n}" }.join("\n")}\n")
cold_gen = lambda do |env|
  cdir = Dir.mktmpdir('bc2cpp-cold-calls')
  saved = ENV.to_h.slice('BC2CPP_COLD_LIST', *env.keys)
  ENV['BC2CPP_COLD_LIST'] = cold_list
  env.each { |k, v| ENV[k] = v }
  begin
    [cdir, *Bc2cppFixtureRuntime.generate(COLD_SRC, cdir, only_owners: COLD_OWNERS)]
  ensure
    ['BC2CPP_COLD_LIST', *env.keys].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
  end
end
cold_dir, cold_code, cold_err = cold_gen.call({})
off_cold_dir, off_cold_code, off_cold_err = cold_gen.call('BC2CPP_COLD_COMPACT_CALLS' => '0')
at_exit { [cold_dir, off_cold_dir].each { |d| FileUtils.remove_entry(d) } }
File.write(ENV['COLD_CALLS_DUMP'], cold_code) if ENV['COLD_CALLS_DUMP']
check.call('COLD_COMPACT_CALLS fixture: no #error in the generated code',
           !cold_code.include?('#error') && !off_cold_code.include?('#error'))
ccalls = ->(fn) { method_code(cold_code, fn).scan(/\bbc2cpp_ccall_\h{16}\b/) }
COLD_PAIRS.each do |a, b|
  check.call("COLD_COMPACT_CALLS #{a}/#{b}: the guarded send is one call of the same helper",
             !ccalls.call("CcHold_#{a}").empty? && ccalls.call("CcHold_#{a}") == ccalls.call("CcHold_#{b}"))
end
check.call('COLD_COMPACT_CALLS: a helper keeps its non-destination parameters const',
           cold_code.scan(
             /^static __attribute__\(\(noinline, cold\)\) \w+ bc2cpp_ccall_\h{16}\(mrb_state\* M(?:, (?:const )?mrb_value a\d+)*\)/
           ).size ==
             cold_code.scan(/^static [^\n]*\bbc2cpp_ccall_\h{16}\(/).size)
check.call('BC2CPP_COLD_COMPACT_CALLS=0: no helper, the inline guards stay',
           !off_cold_code.include?('bc2cpp_ccall_') && method_code(off_cold_code, 'CcHold_qv1').include?('mrb_nil_p('))
COLD_DRIVER = <<~RUBY
  [true, false].each do |fill|
    h = CcHold.new(fill)
    %i[#{COLD_NAMES.join(' ')}].each do |m|
      line = begin
        h.__send__(m).inspect
      rescue NoMethodError => e
        "\#{e.class}: \#{e.message} name=\#{e.name.inspect} args=\#{e.args.inspect}"
      rescue StandardError => e
        "\#{e.class}: \#{e.message}"
      end
      puts "\#{fill} \#{m}: \#{line}"
    end
  end
  puts 'end'
RUBY

MONO_DRIVER = <<~'RUBY'
  [true, false].each do |fill|
    h = MnrHold.new(fill)
    %i[fresh qv qk ql wv wk onil oint oknil oksub selfk subk onum efa pv pvn].each do |m|
      line = begin
        (case m
         when :fresh then h.fresh when :qv then h.qv when :qk then h.qk when :ql then h.ql
         when :wv then h.wv when :wk then h.wk when :onil then h.onil when :oint then h.oint
         when :oknil then h.oknil when :oksub then h.oksub when :selfk then h.selfk when :subk then h.subk
         when :onum then h.onum when :efa then h.efa when :pv then h.pv else h.pvn
         end).inspect
      rescue NoMethodError => e
        "#{e.class}: #{e.message} name=#{e.name.inspect} args=#{e.args.inspect}"
      end
      puts "#{fill} #{m}: #{line}"
    end
  end
  puts 'end'
RUBY

DRIVER = <<~'RUBY'
  u = InrUse.new
  [true, false].each { |fill| u.run(fill).each_with_index { |line, i| puts "#{fill} #{InrUse::METHODS[i]}: #{line}" } }
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"INR(#{DRIVER})INR";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('a nil ivar raises the NoMethodError the interpreter raises',
               interpreted.to_a.any? { |l| l.include?("NoMethodError: undefined method 'each' for NilClass") })
    check.call('a nil receiver with arguments raises with the same name and args',
               interpreted.to_a.include?("false pm: NoMethodError: undefined method 'm' for NilClass name=:m args=[1, 2]"))
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled

    puts '-- MONO fixture on real mruby, interpreted and compiled'
    mono_body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"MNR(#{MONO_DRIVER})MNR";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(mono_dir, mono_err, MONO_OWNERS, mono_body, build: build, full: true)
    check.call('the MONO fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('a MONO name on nil, a String and an Integer raises NoMethodError',
               %w[qv qk ql wv wk onil oint oknil oksub onum efa pvn].all? do |m|
                 interpreted.to_a.any? { |l| l.start_with?("false #{m}: NoMethodError:") }
               end)
    check.call('MONO: interpreted and compiled runs print the same', interpreted && interpreted.last == 'end' &&
               interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled

    { 'cold' => [cold_dir, cold_err], 'cold off' => [off_cold_dir, off_cold_err] }.each do |world, (wdir, werr)|
      puts "-- COLD_COMPACT_CALLS fixture (#{world}) on real mruby, interpreted and compiled"
      cold_body = <<~CPP
        static int scenario(mrb_state* M) {
          std::fflush(stdout);
          const char* src = R"CCC(#{COLD_DRIVER})CCC";
          mrb_load_string(M, src);
          std::fflush(stdout);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
          return 0;
        }
      CPP
      built, output = Bc2cppFixtureRuntime.run(wdir, werr, COLD_OWNERS, cold_body, build: build, full: true)
      check.call("COLD_COMPACT_CALLS (#{world}): the fixtures build and run", built)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      compiled = sections['compiled']
      check.call("COLD_COMPACT_CALLS (#{world}): nil, wrong-class and private receivers raise NoMethodError",
                 %w[qv1 wv1 qk1 wk1 qb1 ae1 he1 as1].all? do |m|
                   interpreted.to_a.any? { |l| l.start_with?("false #{m}: NoMethodError:") }
                 end &&
                   interpreted.to_a.any? { |l| l.start_with?('true qs1: NoMethodError:') })
      check.call("COLD_COMPACT_CALLS (#{world}): interpreted and compiled runs print the same",
                 interpreted && interpreted.last == 'end' && interpreted == compiled)
      if interpreted && compiled
        interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each do |a, b|
          puts "    interpreted: #{a}\n    compiled:    #{b}"
        end
      end
      puts output.lines.last(30).join unless built && interpreted && compiled
    end
  end
end

if failures.empty?
  puts 'bc2cpp inline nil receiver check: PASS'
else
  warn "bc2cpp inline nil receiver check: #{failures.size} failure(s)"
  exit 1
end
