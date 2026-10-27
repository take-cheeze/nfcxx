#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# SLOT_ASSURED (tools/bc2cpp/ivar_slot_assured.rb): an embedded mrb_value ivar read skips its undef test when every
# #initialize of the family assigns the ivar and the read cannot run while an instance is being built.
#
#   generated code (needs a host mrbc)
#     - a method outside the construction reach reads an assigned ivar as the bare field;
#     - an ivar assigned outside #initialize, a read in the construction reach (#initialize, a method it calls, a
#       method `send(:name)` or a block made there reaches) and every read of a family that hands `self` out keep
#       the test;
#     - a literal argument of a construction-time self-call (`reset(mapping: false)`, `prepare(false)`) leaves the
#       arm it switches off out of the reach;
#     - an assignment made by a self-called helper or by `super` counts; one made on a single branch does not;
#     - BC2CPP_SLOT_ASSURED=0 keeps every test.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for the methods, reflection (instance_variables,
#       instance_variable_get on an unset ivar), dup, a block kept from a construction that raised, GC.stress and
#       a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/slot_assured_check.rb

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
  class SaPlain
    def initialize(a, hook = nil)
      @alpha = a
      reset(mapping: false)
      $sa_hooks << lambda { peek } if hook
      @delta = send(:pick)
    end
    def reset(opt = {})
      $sa_seen = send(:probe) if opt.fetch(:mapping, true)
      @beta = [@alpha, :b]
      @flag = false
    end
    def set_c(v); @gamma = v; self; end
    def sum; [@alpha, @beta, @flag, @gamma, @delta]; end
    def peek; [@alpha, @beta]; end
    def pick; [@alpha, @beta]; end
    def probe; [@alpha, @beta, @delta]; end
  end
  class SaFlag
    def initialize; prepare(false); end
    def prepare(expose)
      $sa_out = self if expose
      @val = 7
    end
    def val; @val; end
  end
  class SaBranch
    def initialize(a)
      @xpos = a if a > 0
      @ypos = a
    end
    def pair; [@xpos, @ypos]; end
  end
  class SaEscape
    def initialize(a)
      $sa_last = self
      @vee = a
    end
    def v; @vee; end
  end
  class SaRaise
    def initialize(a)
      $sa_kept = lambda { peek }
      raise ArgumentError, 'no' if a < 0
      @rho = a
    end
    def peek; @rho; end
    def r; @rho; end
  end
  class SaBase
    def initialize(a)
      @base = a
      @shared = :base
    end
    def base_pair; [@base, @shared]; end
  end
  class SaLeft < SaBase
    def initialize(a)
      super
      @left = a * 2
    end
    def left_triple; [@base, @left, @shared]; end
  end
RUBY

OWNERS = %w[SaPlain SaFlag SaBranch SaEscape SaRaise SaBase SaLeft].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def checked?(code, owner, ivar)
  code.include?("mrb_undef_p(((#{owner}_ivars*)DATA_PTR(self))->ivar_#{ivar})")
end

def bare?(code, owner, ivar)
  code.include?("((#{owner}_ivars*)DATA_PTR(self))->ivar_#{ivar};") && !checked?(code, owner, ivar)
end

def generate_world(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-slot-assured')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
ENV['BC2CPP_SLOT_ASSURED_REPORT'] = '1'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
ENV.delete('BC2CPP_SLOT_ASSURED_REPORT')
puts baseline_err.lines.grep(/slot-assured/).map { |line| "    #{line}" }.join
sum = code_of(code, 'SaPlain_sum')
check.call('ivars #initialize and its self-called helper assign are read bare',
           bare?(sum, 'SaPlain', 'alpha') && bare?(sum, 'SaPlain', 'beta') && bare?(sum, 'SaPlain', 'flag'))
check.call('an ivar only a later method assigns keeps the test', checked?(sum, 'SaPlain', 'gamma'))
check.call('methods a construction-time block or send(:pick) reach keep the test',
           checked?(code_of(code, 'SaPlain_peek'), 'SaPlain', 'alpha') && checked?(code_of(code, 'SaPlain_pick'), 'SaPlain', 'alpha'))
check.call('a literal argument leaves out the arm it switches off: reset(mapping: false), prepare(false)',
           bare?(code_of(code, 'SaPlain_probe'), 'SaPlain', 'alpha') && bare?(code_of(code, 'SaFlag_val'), 'SaFlag', 'val'))
check.call('reads inside #initialize\'s callees keep the test', checked?(code_of(code, 'SaPlain_reset'), 'SaPlain', 'alpha'))
pair = code_of(code, 'SaBranch_pair')
check.call('an ivar assigned on one branch keeps the test, one assigned on both is bare',
           checked?(pair, 'SaBranch', 'xpos') && bare?(pair, 'SaBranch', 'ypos'))
check.call('a family that hands self out before assigning keeps every test', checked?(code_of(code, 'SaEscape_v'), 'SaEscape', 'vee'))
check.call('a raise before the assignment leaves no exit unassigned: @rho is bare outside the reach',
           bare?(code_of(code, 'SaRaise_r'), 'SaRaise', 'rho') && checked?(code_of(code, 'SaRaise_peek'), 'SaRaise', 'rho'))
left = code_of(code, 'SaLeft_left_triple')
check.call('an assignment made by super counts for the subclass',
           bare?(left, 'SaBase', 'base') && bare?(left, 'SaBase', 'left') && bare?(left, 'SaBase', 'shared'))
check.call('no #error in the generated code', !code.include?('#error'))
off, = generate_world('BC2CPP_SLOT_ASSURED' => '0')
check.call('BC2CPP_SLOT_ASSURED=0 keeps every test', checked?(code_of(off, 'SaPlain_sum'), 'SaPlain', 'alpha') &&
                                                     checked?(code_of(off, 'SaLeft_left_triple'), 'SaBase', 'left'))

DRIVER = <<~'RUBY'
  $sa_hooks = []
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  plain = SaPlain.new(3, true)
  show.call('plain') { [plain.sum, plain.peek, plain.set_c(:c).sum] }
  show.call('hooks') { [$sa_hooks.map(&:call), plain.reset, plain.sum, $sa_seen, plain.probe] }
  show.call('flag') { f = SaFlag.new; [f.val, $sa_out, f.prepare(true), $sa_out.val] }
  show.call('branch') { [SaBranch.new(1).pair, SaBranch.new(-1).pair] }
  show.call('escape') { [SaEscape.new(5).v, $sa_last.v] }
  show.call('raise') { SaRaise.new(-1) }
  show.call('kept method') { $sa_kept.call }
  show.call('raise ok') { s = SaRaise.new(2); [s.r, s.peek, $sa_kept.call] }
  show.call('left') { l = SaLeft.new(4); [l.left_triple, l.base_pair] }
  show.call('ivars') { [SaPlain.new(1), SaBranch.new(-1), SaLeft.new(2)].map { |o| o.instance_variables.sort } }
  show.call('ivar_get unset') { [SaPlain.new(1).instance_variable_get(:@gamma), SaBranch.new(-1).instance_variable_get(:@xpos)] }
  show.call('ivar_set nil') { p0 = SaPlain.new(1); p0.instance_variable_set(:@alpha, nil); p0.sum }
  show.call('dup') { d = plain.dup; d.set_c(:d); [d.sum, plain.sum] }
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    out = (1..20).map { |i| (i.odd? ? SaLeft.new(i).left_triple : SaPlain.new(i).sum) }
    GC.stress = false if GC.respond_to?(:stress=)
    out
  end
  f = Fiber.new do
    a = SaPlain.new(7)
    Fiber.yield a.sum
    SaLeft.new(8).left_triple
  end
  show.call('fiber') { [f.resume, f.resume] }
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
        const char* src = R"SAF(#{DRIVER})SAF";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp slot assured check: PASS'
else
  warn "bc2cpp slot assured check: #{failures.size} failure(s)"
  exit 1
end
