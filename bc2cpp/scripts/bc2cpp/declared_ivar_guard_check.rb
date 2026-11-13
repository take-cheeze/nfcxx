#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_IVAR_GUARD / DECLARED_IVAR_PROOF: an RBS `@x: T` declaration of Integer, Float, Symbol or a program class
# (or `T?`) is a fact only because the compiled stores check it. End to end, on small fixtures:
#   1. every compiled store to a declared slot tests the declared kind (and raises BC2cppDeclarationViolation through
#      bc2cpp_declared_ivar_violation); a store the flow already proves carries no test; `bool` and a class with
#      subclasses stay unchecked;
#   2. once no store can bypass the checks, the declared kind is the slot's class pool: a `@peer.name` send is a proven
#      one (BC2CPP_DECLARED_IVAR_PROOF=0 keeps the checks and drops the proof); a slot an attr_accessor can write, or one
#      a store in an uncompiled owner could reach, is not trusted;
#   3. interpreted and compiled runs agree on a right declaration; a wrong store raises the violation, naming the ivar.
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
RBS

OWNERS = %w[Peer Other Gauge Base Kid Holder Acc Wide].freeze

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
check.call('a class with a subclass is not checked (a subclass instance is a legal value)',
           guard.call('Holder#@b').zero? && !body_of.call(code, 'Holder#set_b').include?('declared_ivar_violation'))
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
check.call('bool and a class with subclasses are not seeded', pool.call(err, 'Gauge#@flag').nil? && pool.call(err, 'Holder#@b').nil?)
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
check.call('a slot an attr_accessor writes keeps its checks but is not trusted',
           code.include?('DECLARED_IVAR_GUARD Acc#@v') && pool.call(err, 'Acc#@v').nil?)

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
      unless interpreted.first(5) == compiled.first(5)
        puts '    interpreted | compiled'
        [interpreted.size, compiled.size].max.times { |i| puts "    #{interpreted[i].to_s.ljust(24)}| #{compiled[i]}" }
      end
    end
  ensure
    ENV.delete('BC2CPP_SIG_DIRS')
  end
end

suite.finish!
