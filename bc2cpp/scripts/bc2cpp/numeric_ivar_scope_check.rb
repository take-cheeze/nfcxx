#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# NUMERIC_IVAR_PROOF scope (tools/bc2cpp/codegen_numeric_ivars.rb): two sends no longer turn the whole-program ivar
# proof off.
#   - UNDEFINED_REBINDER: `eval` in a world that defines no `eval` (no mruby-eval) can only raise NoMethodError.
#   - SELF_SCOPED_IVAR_WRITE: `instance_variable_set(:"@#{k}", v)` on the implicit self writes only that self's
#     class family, so it fails that family's ivar groups and leaves the others proven.
#
#   generated code (needs a host mrbc)
#     - with both sends present and no mruby-eval, another class's Array ivar gets its class pool and its index
#       read loses the class test, while the self-written class's ivar gets no pool;
#     - the same world with mruby-eval's sources, and a computed instance_variable_set on another object, keep the
#       proof off.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/numeric_ivar_scope_check.rb

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
  class NsBox
    def initialize(n)
      @items = []
      @count = 0
      n.times { |i| @items << i * 3 }
    end
    def at(i); @items[i]; end
    def add(v); @count += v; @items << v; self; end
    def count; @count; end
    def run(src); src ? eval(src) : @items.size; end
  end
  class NsConf
    def initialize(opts)
      opts.each { |k, v| instance_variable_set(:"@#{k}", v) }
    end
    def speed; @speed; end
  end
RUBY

# The same, but the computed write targets another object, which may be of any family.
OTHER_TARGET = SRC.sub('instance_variable_set(:"@#{k}", v)', 'opts.instance_variable_set(:"@#{k}", v)')

OWNERS = %w[NsBox NsConf].freeze
NO_EVAL = { drop_native: ['/mruby-eval/'], drop_gems: ['mruby-eval'] }.freeze
POOL = 'CLASSIVAR NsBox#@items (ARR)'
OFF = 'off: numeric ivar proof unavailable'

def generate(src, **opts)
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS, **opts) }
end

def at_body(code)
  code[/^mrb_value NsBox_at_impl\(mrb_state\* M.*?^}/m].to_s
end

baseline_dir = Dir.mktmpdir('bc2cpp-numeric-ivar-scope')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS, **NO_EVAL)
check.call('the proof stays on with an undefined eval and a self-scoped computed write', !baseline_err.include?(OFF))
check.call('the other class keeps its Array ivar pool', baseline_err.include?(POOL))
check.call('the self-written class gets no ivar pool', !baseline_err.include?('CLASSIVAR NsConf#'))
check.call('the index read on the pooled ivar drops its class test',
           at_body(code).include?('INDEX_EXACT') && !at_body(code).include?('bc2cpp_getidx('))
check.call('no #error in the generated code', !code.include?('#error'))
_, with_eval = generate(SRC)
check.call('a world that defines eval keeps the proof off', with_eval.include?(OFF) && !with_eval.include?(POOL))
_, other = generate(OTHER_TARGET, **NO_EVAL)
check.call('a computed instance_variable_set on another object keeps the proof off',
           other.include?(OFF) && !other.include?(POOL))

# `run` never reaches eval here: the behaviour library may still define it.
DRIVER = <<~'RUBY'
  b = NsBox.new(4)
  p [b.at(2), b.add(5).at(4), b.count, b.run(nil)]
  c = NsConf.new(speed: 3, name: 'x')
  p [c.speed, c.instance_variables.sort]
  begin
    NsBox.new(1).at('x')
  rescue TypeError => e
    p e.class
  end
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
        const char* src = R"NIS(#{DRIVER})NIS";
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
  puts 'bc2cpp numeric ivar scope check: PASS'
else
  warn "bc2cpp numeric ivar scope check: #{failures.size} failure(s)"
  exit 1
end
