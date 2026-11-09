#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# EMBED_FAMILY (tools/bc2cpp/codegen.rb fold_embed_families): a base class and subclasses that each have ivars share
# the base's RData struct.
#
#   generated code (needs a host mrbc)
#     - the family has one struct, the base's, and every member is an MRB_TT_DATA class; a subclass method reads its
#       own and the base's ivars as struct fields, with no mrb_iv_get;
#     - a family whose subclass works before `super` is not folded, and BC2CPP_EMBED_FAMILIES=0 keeps the refusal.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for the methods, reflection (instance_variables,
#       instance_variable_get/set), dup, GC.stress and a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/embed_family_check.rb

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
  class EfBase
    def initialize(a)
      @a = [a][0]
      @shared = :base
    end
    def a; @a; end
    def bump; @a += 1; self; end
    def describe; [@a, @shared]; end
  end
  class EfLeft < EfBase
    def initialize(a)
      super
      @left = a * 2
    end
    def left_sum; @a + @left; end
    def set_shared(v); @shared = v; end
  end
  class EfRight < EfBase
    def initialize(a, b)
      super(a)
      @right = b
      @shared = :right
    end
    def right_pair; [@a, @right, @shared]; end
  end
  class EfPlain < EfBase
    def doubled; @a * 2; end
  end
  class EfLateBase
    def initialize; @x = 1; end
    def x; @x; end
  end
  class EfLate < EfLateBase
    def initialize; @y = 2; super; end
    def y; @y; end
  end
RUBY

OWNERS = %w[EfBase EfLeft EfRight EfPlain EfLateBase EfLate].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(env = {}, directory: nil)
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  if directory
    Bc2cppFixtureRuntime.generate(SRC, directory, core: true, only_owners: OWNERS)
  else
    Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
  end
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-embed-family')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
tts = baseline_err[/== classes needing MRB_SET_INSTANCE_TT.*?(?=^==|\z)/m].to_s
check.call('the family has one struct, the base\'s',
           code.include?('struct EfBase_ivars {') && !code.include?('struct EfLeft_ivars') &&
             !code.include?('struct EfRight_ivars'))
check.call('the base struct holds every member\'s ivars',
           %w[ivar_a ivar_shared ivar_left ivar_right].all? { |f| code[/struct EfBase_ivars \{.*?\};/m].to_s.include?(f) })
check.call('every member is an MRB_TT_DATA class', %w[EfBase EfLeft EfRight EfPlain].all? { |k| tts.include?("  #{k}\n") })
check.call('a subclass method reads its own and the base\'s ivars as struct fields',
           code_of(code, 'EfLeft_left_sum').include?('(EfBase_ivars*)DATA_PTR(self))->ivar_left') &&
             !code_of(code, 'EfLeft_left_sum').include?('mrb_iv_get('))
check.call('a subclass that works before super keeps its family out of the struct storage',
           !code.include?('struct EfLateBase_ivars') && !code.include?('struct EfLate_ivars'))
check.call('no #error in the generated code', !code.include?('#error'))
full_probe, full_probe_err = generate_world({ 'BC2CPP_PROBE_TEXT_CLEANUP' => '0' }, directory: baseline_dir)
check.call('full probe root analysis and text cleanup preserve emitted C++ and embedding decisions',
           full_probe == code && full_probe_err == baseline_err)
off, = generate_world({ 'BC2CPP_EMBED_FAMILIES' => '0' })
check.call('BC2CPP_EMBED_FAMILIES=0: the family is refused', !off.include?('struct EfBase_ivars'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  l = EfLeft.new(3)
  r = EfRight.new(5, :r)
  p0 = EfPlain.new(7)
  late = EfLate.new
  show.call('left') { [l.a, l.left_sum, l.describe, l.bump.a, l.left_sum] }
  show.call('right') { [r.right_pair, r.describe, r.bump.right_pair] }
  show.call('plain') { [p0.doubled, p0.describe] }
  show.call('late') { [late.x, late.y] }
  show.call('ivars') { [l, r, p0, late].map { |o| o.instance_variables.sort } }
  show.call('ivar_get') { [l.instance_variable_get(:@left), r.instance_variable_get(:@right), l.instance_variable_get(:@right)] }
  show.call('ivar_set') { l.instance_variable_set(:@left, 100); l.set_shared(:changed); [l.left_sum, l.describe] }
  show.call('dup') { d = r.dup; d.bump; [d.right_pair, r.right_pair] }
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    out = (1..20).map { |i| (i.odd? ? EfLeft.new(i) : EfRight.new(i, i.to_s)).describe }
    GC.stress = false if GC.respond_to?(:stress=)
    out
  end
  f = Fiber.new do
    a = EfLeft.new(1)
    Fiber.yield a.left_sum
    EfRight.new(2, :f).right_pair
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
        const char* src = R"EMF(#{DRIVER})EMF";
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
  puts 'bc2cpp embed family check: PASS'
else
  warn "bc2cpp embed family check: #{failures.size} failure(s)"
  exit 1
end
