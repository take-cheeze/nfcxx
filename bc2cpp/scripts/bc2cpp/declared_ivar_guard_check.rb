#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_IVAR_GUARD / DECLARED_IVAR_PROOF: an RBS `@x: T` declaration of Integer, Float, Symbol or a program class
# (or `T?`) is a fact only because the compiled stores check it. End to end, on small fixtures:
#   1. every compiled store to a declared slot tests the declared kind (and raises BC2cppDeclarationViolation through
#      bc2cpp_declared_ivar_violation); a store the flow already proves carries no test; `bool` and a class with
#      subclasses stay unchecked;
#   2. once no store can bypass the checks, the declared kind is the slot's class pool: a `@peer.name` send is a proven
#      one (BC2CPP_DECLARED_IVAR_PROOF=0 keeps the checks and drops the proof); a slot an attr_accessor writes is trusted
#      when its synthesized writer carries the check too; one a store in an uncompiled owner could reach is not;
#   3. interpreted and compiled runs agree on a right declaration; a wrong store raises the violation, naming the ivar;
#   4. DECLARED_UNION: a union of program classes (`A | B`, `nil | A | B`) and a class with subclasses (its closed
#      subtree) are checked as the exact classes they stand for, seed the pool with them, and a send on such a slot is
#      one exact-class arm per class with no by-name fallback (USER_RECEIVER_CASES, NILABLE_RECEIVER for nil);
#   5. DECLARED_NATIVE: a declaration may name a native class too (its own section below).
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/declared_ivar_guard_check.rb
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('declared_ivar_guard_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Peer
    def name; 'peer'; end
  end
  class Other
    def name; 'other'; end
  end
  class Gauge
    def initialize
      @level = 0
      @ratio = 0.5
      @mark = :lo
      @peer = Peer.new
      @flag = true
      @opt = nil
      nil
    end

    def set(v); @level = v; nil; end
    def zero; @level = 0; nil; end
    def bump; @level += 1; nil; end
    def set_ratio(r); @ratio = r; nil; end
    def set_mark(m); @mark = m; nil; end
    def set_peer(p); @peer = p; nil; end
    def set_flag(f); @flag = f; nil; end
    def set_opt(o); @opt = o; nil; end
    def peek; @peer.name; end
    def level; @level; end
    def ratio; @ratio; end
    def mark; @mark; end
    def opt; @opt; end
  end
  class Base; end
  class Kid < Base; end
  class Holder
    def initialize; @b = Base.new; nil; end
    def set_b(x); @b = x; nil; end
  end
  class Acc
    attr_accessor :v
    def initialize; @v = 0; nil; end
    def reset(x); @v = x; nil; end
    def read; @v + 1; end
  end
  class Wide
    def initialize; @w = 0; nil; end
    def put(x); @w = x; nil; end
    def read; @w; end
  end
  class Left
    def name; 'left'; end
  end
  class Right
    def name; 'right'; end
  end
  class Pair
    def initialize; @side = Left.new; @maybe = nil; nil; end
    def set_side(x); @side = x; nil; end
    def set_maybe(x); @maybe = x; nil; end
    def side_name; @side.name; end
    def maybe_name; @maybe.name; end
  end
  class Open; end
  OpenKid = Class.new(Open)
  class Loose
    def initialize; @l = Open.new; nil; end
    def put(x); @l = x; nil; end
  end
RUBY

SIGS = <<~RBS
  class Gauge
    @level: Integer
    @ratio: Float
    @mark: Symbol
    @peer: Peer
    @flag: bool
    @opt: Integer?
  end
  class Holder
    @b: Base
  end
  class Acc
    @v: Integer
  end
  class Wide
    @w: Integer
  end
  class Pair
    @side: Left | Right
    @maybe: (nil | Left | Right)
  end
  class Loose
    @l: Open | Peer
  end
RBS

OWNERS = %w[Peer Other Gauge Base Kid Holder Acc Wide Left Right Pair Open Loose].freeze

# [code, stderr] of one generation with the given switches (nil code: generation refused, stderr is the message).
generate = lambda do |source, env = {}, owners: OWNERS|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('declared_ivar') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'ivars.rbs'), SIGS)
    ENV['BC2CPP_SIG_DIRS'] = sig
    Bc2cppFixtureRuntime.generate(source, dir, only_owners: owners)
  rescue RuntimeError => e
    [nil, e.message]
  end
ensure
  env.each_key { |k| ENV.delete(k) }
  ENV.delete('BC2CPP_SIG_DIRS')
end

body_of = ->(code, name) { code.to_s[%r{^// #{Regexp.escape(name)} \(compiled.*?(?=^// \w+#|\z)}m].to_s }

puts '-- the stores check the declared kind'
code, err = generate.call(SOURCE)
check.call('generated', !code.nil?)
suite.finish! if code.nil?

guard = ->(key) { code.scan("/* DECLARED_IVAR_GUARD #{key} */").size }
proven = ->(key) { code.scan("/* DECLARED_IVAR_PROVEN #{key} */").size }
set_body = body_of.call(code, 'Gauge#set')
check.call('Integer: an unknown value is tested as any Integer, bignum included and raises the helper',
           set_body.include?('(mrb_integer_p(r1) || mrb_bigint_p(r1))') && set_body.include?('bc2cpp_declared_ivar_violation(M, r1, "Gauge#@level", "Integer");'))
check.call('the test comes before the store',
           set_body.index('bc2cpp_declared_ivar_violation') < set_body.index('ivar_level'))
check.call('Integer: a literal 0 and `@level += 1` are proven by the flow, so carry no test',
           body_of.call(code, 'Gauge#zero').include?('DECLARED_IVAR_PROVEN Gauge#@level') &&
             !body_of.call(code, 'Gauge#zero').include?('declared_ivar_violation') &&
             !body_of.call(code, 'Gauge#bump').include?('declared_ivar_violation'))
check.call('Float: tested with mrb_float_p',
           body_of.call(code, 'Gauge#set_ratio').include?('!(mrb_float_p(r1))'))
check.call('Symbol: tested with mrb_symbol_p', body_of.call(code, 'Gauge#set_mark').include?('!(mrb_symbol_p(r1))'))
check.call('a program class: tested as exactly the class',
           body_of.call(code, 'Gauge#set_peer').match?(/!\(bc2cpp_class_is\(M, r1, bc2cpp_owner_class_\d+\(M\)\)\)/))
check.call('T?: nil or the kind', body_of.call(code, 'Gauge#set_opt').include?('!(mrb_nil_p(r1) || ((mrb_integer_p(r1) || mrb_bigint_p(r1))))'))
check.call('bool stays unchecked by design', guard.call('Gauge#@flag').zero? && proven.call('Gauge#@flag').zero? &&
                                              !body_of.call(code, 'Gauge#set_flag').include?('declared_ivar_violation'))
class_test = /bc2cpp_class_is\(M, r1, bc2cpp_owner_class_\d+\(M\)\)/
check.call('a class with a subclass is checked as its closed subtree (one exact test per class)',
           guard.call('Holder#@b') == 1 && body_of.call(code, 'Holder#set_b').scan(class_test).size == 2)
check.call('a union is checked as its classes, `nil | A | B` admitting nil first',
           body_of.call(code, 'Pair#set_side').scan(class_test).size == 2 &&
             body_of.call(code, 'Pair#set_side').include?('"Pair#@side", "Left | Right"') &&
             body_of.call(code, 'Pair#set_maybe').include?('!(mrb_nil_p(r1) || (bc2cpp_class_is('))
check.call('the report lists the slots and counts the stores',
           err.include?('DECLARED_IVAR Gauge#@level: Integer, guarded stores, pool seeded') &&
             err.match?(/declared instance variables \(DECLARED_IVAR_GUARD\): \d+, [1-9]\d* checked stores, [1-9]\d* proven stores/))
off, = generate.call(SOURCE, { 'BC2CPP_DECLARATION_GUARD' => '0' })
check.call('BC2CPP_DECLARATION_GUARD=0 drops the checks', off && !off.include?('bc2cpp_declared_ivar_violation(M,') && !off.include?('DECLARED_IVAR_'))

puts '-- the declared kind is the slot pool'
pool = ->(err_text, slot) { err_text[/CLASSIVAR #{Regexp.escape(slot)} \(([^)]*)\)/, 1] }
check.call('pools: Integer, Float, Symbol, the class, and Integer? with nil',
           pool.call(err, 'Gauge#@level') == 'INT' && pool.call(err, 'Gauge#@ratio') == 'FLT' &&
             pool.call(err, 'Gauge#@mark') == 'Symbol' && pool.call(err, 'Gauge#@peer') == 'Peer' &&
             pool.call(err, 'Gauge#@opt') == 'INT|NIL')
check.call('bool is not seeded', pool.call(err, 'Gauge#@flag').nil?)
check.call('a union seeds its classes (and nil for `nil | A | B`)',
           pool.call(err, 'Pair#@side')&.split('|')&.sort == %w[Left Right] &&
             pool.call(err, 'Pair#@maybe')&.split('|')&.sort == %w[Left NIL Right])
side = body_of.call(code, 'Pair#side_name')
check.call('a send on a union slot: one exact arm per class, no by-name fallback',
           side.include?('USER_RECEIVER_CASES :name') && side.include?('Left_name_impl') && side.include?('Right_name_impl') &&
             !side.match?(/bc2cpp_owner_call|mrb_funcall|bc2cpp_send\(/))
maybe = body_of.call(code, 'Pair#maybe_name')
check.call('on a nil-or-union slot: the nil test, then the same arms',
           maybe.include?('NILABLE_RECEIVER :name') && maybe.include?('USER_RECEIVER_CASES :name') &&
             !maybe.match?(/bc2cpp_owner_call|mrb_funcall|bc2cpp_send\(/))
check.call('a union naming a class the closed world cannot bound (Class.new(Open)) is not checked',
           guard.call('Loose#@l').zero? && pool.call(err, 'Loose#@l').nil?)
nounion, nounion_err = generate.call(SOURCE, { 'BC2CPP_DECLARED_UNION' => '0' })
check.call('BC2CPP_DECLARED_UNION=0 leaves unions and subclassed classes unchecked',
           nounion && !nounion.include?('DECLARED_IVAR_GUARD Pair#@side') && !nounion.include?('DECLARED_IVAR_GUARD Holder#@b') &&
             pool.call(nounion_err, 'Pair#@side').nil?)
unproven_code, unproven_err = generate.call(SOURCE, { 'BC2CPP_DECLARED_IVAR_PROOF' => '0' })
check.call('BC2CPP_DECLARED_IVAR_PROOF=0 drops the seed and keeps the checks',
           unproven_code && pool.call(unproven_err, 'Gauge#@peer') != 'Peer' &&
             unproven_code.include?('DECLARED_IVAR_GUARD Gauge#@peer'))
peek = body_of.call(code, 'Gauge#peek')
check.call('@peer.name is a proven send: one direct call, no class test, no fallback',
           peek.include?('Peer_name_impl(M, r2)') && !peek.include?('bc2cpp_class_is') && !peek.include?('bc2cpp_hint_violation'))
check.call('without the seed it is a class-tested call with a by-name fallback (the declared class hint)',
           body_of.call(unproven_code, 'Gauge#peek').include?('TYPED :name') &&
             body_of.call(unproven_code, 'Gauge#peek').include?('bc2cpp_hint_violation'))
check.call('a slot an attr_accessor writes is trusted once its synthesized writer is checked too',
           code.include?('DECLARED_IVAR_GUARD Acc#@v') && pool.call(err, 'Acc#@v') == 'INT')

puts '-- a store in a method that is not compiled voids the proof'
# Wide#put is a store the run would leave interpreted and unchecked: the owner is not compiled by this run.
partial = generate.call(SOURCE, owners: OWNERS - %w[Wide])
check.call('a stored-to slot whose writer is not compiled aborts the run, naming the proof switch',
           partial.first.nil? && partial.last.include?('DECLARED_IVAR_PROOF') && partial.last.include?('Wide#put'))
kept = generate.call(SOURCE, { 'BC2CPP_DECLARED_IVAR_PROOF' => '0' }, owners: OWNERS - %w[Wide])
check.call('with the proof off the same run is fine', !kept.first.nil?)

puts '-- interpreted and compiled runs'
DRIVER = <<~'RUBY'
  g = Gauge.new
  g.set(5)
  g.set(2**70)
  g.zero
  g.bump
  g.set_ratio(1.5)
  g.set_mark(:hi)
  g.set_opt(nil)
  g.set_opt(3)
  g.set_flag(false)
  g.set_flag(nil)
  puts g.level, g.ratio, g.mark, g.opt, g.peek
  [[:set, 'x'], [:set, nil], [:set_ratio, 1], [:set_mark, 'hi'], [:set_peer, nil], [:set_opt, 'x'], [:set_peer, Other.new]].each do |m, v|
    begin
      g.send(m, v)
      puts "#{m}: stored"
    rescue BC2cppDeclarationViolation => e
      puts "violation: #{e.message}"
    end
  end
  pr = Pair.new
  pr.set_side(Right.new)
  pr.set_maybe(Left.new)
  puts pr.side_name, pr.maybe_name
  begin
    pr.set_side(Other.new)
    puts 'set_side: kept'
  rescue BC2cppDeclarationViolation => e
    puts "union violation: #{e.message}"
  end
  h = Holder.new
  h.set_b(Kid.new)
  a = Acc.new
  a.v = 4
  a.reset(5)
  puts a.read
  puts 'end'
RUBY

build = Bc2cppFixtureRuntime.full_or_build
check.call('a full-core libmruby builds for the parity runs', !build.nil?)
if build
  Dir.mktmpdir('declared_ivar_run') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'ivars.rbs'), SIGS)
    ENV['BC2CPP_SIG_DIRS'] = sig
    _code, stderr = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: OWNERS)
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"APD(#{DRIVER})APD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, stderr, OWNERS, scenario, build: build, full: true)
    sections = built ? Bc2cppFixtureRuntime.sections(output) : {}
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    puts output.lines.last(30) unless built && interpreted&.last == 'end' && compiled&.last == 'end'
    check.call('the fixtures build and run', built && interpreted&.last == 'end' && compiled&.last == 'end')
    if interpreted && compiled
      violations = compiled.select { |l| l.start_with?('violation: ') }
      check.call('right stores (bignum, nil for T?, bool, an attr_accessor store): the first lines match',
                 interpreted.first(5) == compiled.first(5))
      check.call('each wrong store raises the violation, naming the ivar and the declared type',
                 violations.size == 7 &&
                   violations[0].include?('Gauge#@level was assigned String, declared Integer') &&
                   violations[1].include?('Gauge#@level was assigned NilClass, declared Integer') &&
                   violations[2].include?('Gauge#@ratio was assigned Integer, declared Float') &&
                   violations[3].include?('Gauge#@mark was assigned String, declared Symbol') &&
                   violations[4].include?('Gauge#@peer was assigned NilClass, declared Peer') &&
                   violations[5].include?('Gauge#@opt was assigned String, declared Integer?') &&
                   violations[6].include?('Gauge#@peer was assigned Other, declared Peer'))
      check.call('the interpreter stores every one of them', interpreted.count { |l| l.end_with?(': stored') } == 7)
      check.call('the tail (the attr_accessor slot) agrees', interpreted.last(2) == compiled.last(2))
      check.call('a union slot reads the same; a store outside the union raises, a subclass store does not',
                 compiled.include?('right') && compiled.include?('left') && interpreted.include?('set_side: kept') &&
                   compiled.any? { |l| l.include?('union violation: ') && l.include?('Pair#@side was assigned Other, declared Left | Right') })
      unless interpreted.first(5) == compiled.first(5)
        puts '    interpreted | compiled'
        [interpreted.size, compiled.size].max.times { |i| puts "    #{interpreted[i].to_s.ljust(24)}| #{compiled[i]}" }
      end
    end
  ensure
    ENV.delete('BC2CPP_SIG_DIRS')
  end
end

# COMPACT_LABELS (label_table.rb): the label of a declared return, parameter, keyword and ivar check is a table row in a
# real gem build. Run both ways, the compiled run raises and logs the same bytes: a presym name (fetch, take, store,
# with the fixture's own presym table) and a name without one (@level) alike.
LABEL_SOURCE = <<~RUBY
  class Peer
    def name; 'peer'; end
  end
  class Box
    def initialize; @level = 0; nil; end
    def set(v); @level = v; nil; end
    def fetch(x); x; end
    def take(peer); peer.name; end
    def store(k:); k + 1; end
  end
RUBY
LABEL_SIGS = <<~RBS
  class Box
    @level: Integer
    def fetch: (untyped x) -> Peer
    def take: (Peer peer) -> String
    def store: (k: Integer) -> Integer
  end
RBS
LABEL_OWNERS = %w[Peer Box].freeze
LABEL_DRIVER = <<~'RUBY'
  class LabelLog
    def puts(line); print("log: #{line}\n"); nil; end
  end
  $stderr = LabelLog.new
  b = Box.new
  puts b.fetch(Peer.new).name, b.take(Peer.new), b.store(k: 1)
  [[:set, 'x'], [:fetch, 'str'], [:take, 1], [:store, 'k']].each do |m, v|
    begin
      m == :store ? b.store(k: v) : b.send(m, v)
      puts "#{m}: no violation"
    rescue StandardError => e
      puts e.class.to_s == 'BC2cppDeclarationViolation' ? "violation: #{e.message}" : "#{m}: #{e.class}: #{e.message}"
    end
  end
  puts 'end'
RUBY

puts '-- COMPACT_LABELS: a label row prints the same bytes as its string'
if build
  header = File.join(build, 'include/mruby/presym/id.h')
  label_runs = %w[1 0].to_h do |flag|
    Dir.mktmpdir('declared_labels') do |dir|
      sig = File.join(dir, 'sig')
      FileUtils.mkdir_p(sig)
      File.write(File.join(sig, 'labels.rbs'), LABEL_SIGS)
      ENV['BC2CPP_SIG_DIRS'] = sig
      ENV['BC2CPP_COMPACT_LABELS'] = flag
      ENV['BC2CPP_PRESYM_HEADER'] = header
      code, stderr = Bc2cppFixtureRuntime.generate(LABEL_SOURCE, dir, only_owners: LABEL_OWNERS)
      scenario = <<~CPP
        static int scenario(mrb_state* M) {
          std::fflush(stdout);
          const char* src = R"APD(#{LABEL_DRIVER})APD";
          mrb_load_string(M, src);
          std::fflush(stdout);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
          return 0;
        }
      CPP
      built, output = Bc2cppFixtureRuntime.run(dir, stderr, LABEL_OWNERS, scenario, build: build, full: true)
      puts output.lines.last(30) unless built
      [flag, [code, built ? Bc2cppFixtureRuntime.sections(output)['compiled'] : nil]]
    ensure
      %w[BC2CPP_SIG_DIRS BC2CPP_COMPACT_LABELS BC2CPP_PRESYM_HEADER].each { |k| ENV.delete(k) }
    end
  end
  on_code, on_lines = label_runs['1']
  off_code, off_lines = label_runs['0']
  sites = %w[return param keyword ivar]
  check.call('with the rows every declared site names its row, and no label string is left',
             sites.all? { |kind| on_code.include?("bc2cpp_declared_#{kind}_violation_at(M, ") } &&
               !on_code.match?(/"Box#(?:fetch|take|store|@level)"/) && on_code.match?(/\{\d+, MRB_SYM\(fetch\), 0\}/) &&
               on_code.include?('"@level",'))
  check.call('BC2CPP_COMPACT_LABELS=0 keeps the strings and no table',
             sites.all? { |kind| off_code.include?("bc2cpp_declared_#{kind}_violation(M, ") } &&
               off_code.include?('"Box#fetch", "Peer")') && !off_code.include?('bc2cpp_label_rows'))
  expected = ['declaration violation: Box#@level was assigned String, declared Integer',
              'declaration violation: Box#fetch returned String, declared -> Peer',
              'declaration violation: Box#take argument 1 is Integer, declared Peer',
              'declaration violation: Box#store keyword is String, declared k: Integer']
  same = on_lines && on_lines == off_lines && on_lines.last == 'end' &&
         expected.all? { |m| on_lines.include?("violation: #{m}") && on_lines.include?("log: [RPG2k] #{m}") }
  check.call('the compiled runs print the same bytes both ways, the log lines included', same)
  puts on_lines.to_a.zip(off_lines.to_a).map { |a, b| "    #{a.to_s.ljust(70)}| #{b}" } unless same
end


# DECLARED_NATIVE: an RBS ivar declaration may name a class a native defines (ClosedWorld#native_class?), not only a
# program class. End to end, on fixtures over the natives StringIO and Time:
#   1. a native class with no subclass (`@io: StringIO`) is checked by its exact class at every store and seeds the
#      slot's pool, so a send on it needs no nil test and no by-name fallback;
#   2. a native class with a program subclass (`@at: Time`, `class Stamp < Time`) is checked as its closed family, one
#      exact test per class, and a Stamp store is accepted as Ruby accepts it;
#   3. `@ios: Array[StringIO]` tests each element it reads and pushes;
#   4. a family the closed world cannot bound (`Class.new(StringIO)`) and BC2CPP_DECLARED_NATIVE=0 leave the slots
#      unchecked and unseeded; a BC2CPP_CLASS_REACH_VERIFY=1 build checks each read of a seeded slot too;
#   5. interpreted and compiled runs agree on right stores, and a wrong store raises the violation, naming the ivar.

NATIVE_SOURCE = <<~RUBY
  class Stamp < Time
    def tag; :stamp; end
  end
  class Cup
    def initialize
      @at = Time.at(0)
      @io = StringIO.new('ab')
      @ios = [StringIO.new('c')]
      nil
    end

    def set_at(t); @at = t; nil; end
    def set_io(x); @io = x; nil; end
    def push(x); @ios << x; nil; end
    def at_i; @at.to_i; end
    def io_s; @io.string; end
    def first_s; @ios[0].string; end
    def last_s; @ios[-1].string; end
  end
RUBY

NATIVE_SIGS = <<~RBS
  class Cup
    @at: Time
    @io: StringIO
    @ios: Array[StringIO]
  end
RBS

NATIVE_OWNERS = %w[Stamp Cup].freeze

native_generate = lambda do |source, env = {}|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('declared_native') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'natives.rbs'), NATIVE_SIGS)
    ENV['BC2CPP_SIG_DIRS'] = sig
    Bc2cppFixtureRuntime.generate(source, dir, only_owners: NATIVE_OWNERS)
  rescue RuntimeError => e
    [nil, e.message]
  end
ensure
  env.each_key { |k| ENV.delete(k) }
  ENV.delete('BC2CPP_SIG_DIRS')
end

native_body_of = ->(code, name) { code.to_s[%r{^// #{Regexp.escape(name)} \(compiled.*?(?=^// \w+#|\z)}m].to_s }
native_pool = ->(err, slot) { err.to_s[/CLASSIVAR #{Regexp.escape(slot)} \(([^)]*)\)/, 1] }
native_class_test = /bc2cpp_class_is\(M, r1, bc2cpp_owner_class_\d+\(M\)\)/

puts '-- DECLARED_NATIVE: the stores check the declared native class'
ncode, nerr = native_generate.call(NATIVE_SOURCE)
check.call('native fixture generated', !ncode.nil?)

set_io = native_body_of.call(ncode, 'Cup#set_io')
check.call('a native class with no subclass: one exact class test before the store, raising the helper',
           set_io.include?('DECLARED_IVAR_GUARD Cup#@io') && set_io.scan(native_class_test).size == 1 &&
             set_io.include?('bc2cpp_declared_ivar_violation(M, r1, "Cup#@io", "StringIO");'))
set_at = native_body_of.call(ncode, 'Cup#set_at')
check.call('a native class with a program subclass: one exact test per class of its family',
           set_at.include?('DECLARED_IVAR_GUARD Cup#@at') && set_at.scan(native_class_test).size == 2)
check.call('the report lists both slots as seeded',
           nerr.include?('DECLARED_IVAR Cup#@io: StringIO, guarded stores, pool seeded') &&
             nerr.include?('DECLARED_IVAR Cup#@at: Time, guarded stores, pool seeded'))
check.call('the pools: the native class, and the family for the subclassed one',
           native_pool.call(nerr, 'Cup#@io') == 'StringIO' &&
             native_pool.call(nerr, 'Cup#@at')&.split('|')&.sort == %w[Stamp Time])
io_s = native_body_of.call(ncode, 'Cup#io_s')
check.call('a send on the seeded slot: no nil test and no by-name fallback',
           !io_s.empty? && !io_s.include?('bc2cpp_nil_receiver') && !io_s.include?('NILABLE_RECEIVER') &&
             !io_s.match?(/mrb_funcall|bc2cpp_send\(/))
check.call('Array[StringIO]: an element read and a push test the element against the exact class',
           native_body_of.call(ncode, 'Cup#first_s').include?('"Cup#@ios[]", "Array[StringIO]"') &&
             native_body_of.call(ncode, 'Cup#push').include?('DECLARED_ELEMENT_GUARD Cup#ios assigned'))

puts '-- DECLARED_NATIVE: an unbounded family, the kill switch, the verify reads'
loose, loose_err = native_generate.call("#{NATIVE_SOURCE}LooseIO = Class.new(StringIO)\n")
check.call('Class.new(StringIO): the StringIO slot and its elements are left unchecked and unseeded',
           loose && !loose.include?('DECLARED_IVAR_GUARD Cup#@io') && native_pool.call(loose_err, 'Cup#@io') != 'StringIO' &&
             !loose.include?('DECLARED_ELEMENT_GUARD Cup#ios') && loose.include?('DECLARED_IVAR_GUARD Cup#@at'))
off, off_err = native_generate.call(NATIVE_SOURCE, { 'BC2CPP_DECLARED_NATIVE' => '0' })
check.call('BC2CPP_DECLARED_NATIVE=0: no native slot or element is checked or seeded',
           off && !off.match?(/DECLARED_IVAR_GUARD Cup#@(?:at|io)\b/) && !off.include?('DECLARED_ELEMENT_GUARD Cup#') &&
             native_pool.call(off_err, 'Cup#@io') != 'StringIO' && !off_err.match?(/DECLARED_IVAR Cup#@(?:at|io):/))

verify, = native_generate.call(NATIVE_SOURCE, { 'BC2CPP_CLASS_REACH_VERIFY' => '1' })
check.call('BC2CPP_CLASS_REACH_VERIFY=1: a read of a seeded slot checks what it read (DECLARED_IVAR_VERIFY)',
           native_body_of.call(verify, 'Cup#io_s').include?('DECLARED_IVAR_VERIFY Cup#@io') &&
             !ncode.include?('DECLARED_IVAR_VERIFY'))

puts '-- DECLARED_NATIVE: interpreted and compiled runs'
NATIVE_DRIVER = <<~'RUBY'
  c = Cup.new
  c.set_io(StringIO.new('xy'))
  c.set_at(Stamp.at(5))
  c.push(StringIO.new('z'))
  puts c.at_i, c.io_s, c.first_s, c.last_s
  [[:set_io, 'xy'], [:set_io, nil], [:set_at, Object.new], [:set_at, 3], [:push, 9]].each do |m, v|
    begin
      c.send(m, v)
      puts "#{m}: stored"
    rescue BC2cppDeclarationViolation => e
      puts "violation: #{e.message}"
    end
  end
  puts 'end'
RUBY

if build
  Dir.mktmpdir('declared_native_run') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'natives.rbs'), NATIVE_SIGS)
    ENV['BC2CPP_SIG_DIRS'] = sig
    # The read checks (DECLARED_IVAR_VERIFY) are compiled in too: they must hold on every right store.
    ENV['BC2CPP_CLASS_REACH_VERIFY'] = '1'
    _code, stderr = Bc2cppFixtureRuntime.generate(NATIVE_SOURCE, dir, only_owners: NATIVE_OWNERS)
    ENV.delete('BC2CPP_CLASS_REACH_VERIFY')
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"APD(#{NATIVE_DRIVER})APD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, stderr, NATIVE_OWNERS, scenario, build: build, full: true)
    sections = built ? Bc2cppFixtureRuntime.sections(output) : {}
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    puts output.lines.last(30) unless built && interpreted&.last == 'end' && compiled&.last == 'end'
    check.call('the fixtures build and run', built && interpreted&.last == 'end' && compiled&.last == 'end')
    if interpreted && compiled
      check.call('right stores, a program subclass of the native class included: the reads match',
                 interpreted.first(4) == %w[5 xy c z] && compiled.first(4) == interpreted.first(4))
      violations = compiled.select { |l| l.start_with?('violation: ') }
      check.call('each wrong store raises the violation, naming the ivar and the declared type',
                 violations.size == 5 &&
                   violations[0].include?('Cup#@io was assigned String, declared StringIO') &&
                   violations[1].include?('Cup#@io was assigned NilClass, declared StringIO') &&
                   violations[2].include?('Cup#@at was assigned Object, declared Time') &&
                   violations[3].include?('Cup#@at was assigned Integer, declared Time') &&
                   violations[4].include?('Cup#@ios[] was assigned Integer, declared Array[StringIO]'))
      check.call('the interpreter stores every one of them', interpreted.count { |l| l.end_with?(': stored') } == 5)
    end
  ensure
    ENV.delete('BC2CPP_SIG_DIRS')
    ENV.delete('BC2CPP_CLASS_REACH_VERIFY')
  end
end

suite.finish!
