#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# FRESH_BUILTIN_FREEZE (tools/bc2cpp/closed_world.rb fresh_builtin_result?): `(0..n).map { }.freeze` freezes a new
# builtin Array, so it does not stop ClosedWorld#user_objects_unfrozen? from proving that no user object is ever
# frozen, and an embedded ivar store then needs no frozen check.
#
#   generated code (needs a host mrbc)
#     - a world whose only freeze is of a core iterator's result on a Range literal stores embedded ivars with no
#       frozen check;
#     - a freeze of a user object, or of `map` once user Ruby defines its own `map`, keeps the check, and so
#       does BC2CPP_FRESH_FREEZE=0.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, the frozen Array included.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fresh_freeze_check.rb

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
  class FfTable
    def initialize(n)
      @rows = (0...n).map { |i| i * 3 }.select(&:even?).freeze
      @count = 0
    end
    def bump(v); @count = v; self; end
    def rows; @rows; end
    def count; @count; end
  end
RUBY

FROZEN_USER = SRC + <<~'RUBY'
  class FfSealer
    def seal(obj); obj.freeze; end
  end
RUBY

OWN_MAP = SRC + <<~'RUBY'
  class Range
    def map; [self]; end
  end
RUBY

OWNERS = %w[FfTable].freeze
FROZEN_TEST = 'mrb_frozen_p(mrb_obj_ptr(self))'

def generate(src)
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS) }
end

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

baseline_dir = Dir.mktmpdir('bc2cpp-fresh-freeze')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
bump = code_of(code, 'FfTable_bump')
check.call('the store compiles to the embedded field', bump.include?('(FfTable_ivars*)DATA_PTR(self))->ivar_count'))
check.call('a freeze of a core iterator result on a literal leaves no frozen check', !code.include?(FROZEN_TEST))
check.call('no #error in the generated code', !code.include?('#error'))
sealed, = generate(FROZEN_USER)
check.call('a freeze of a user object keeps the frozen check', code_of(sealed, 'FfTable_bump').include?(FROZEN_TEST))
own, = generate(OWN_MAP)
check.call('a user-defined map keeps the frozen check', code_of(own, 'FfTable_bump').include?(FROZEN_TEST))
ENV['BC2CPP_FRESH_FREEZE'] = '0'
off, = generate(SRC)
ENV.delete('BC2CPP_FRESH_FREEZE')
check.call('BC2CPP_FRESH_FREEZE=0 keeps the frozen check', code_of(off, 'FfTable_bump').include?(FROZEN_TEST))

DRIVER = <<~'RUBY'
  t = FfTable.new(6)
  p [t.rows, t.rows.frozen?, t.bump(4).count, t.frozen?]
  begin
    t.rows << 1
  rescue => e
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
        const char* src = R"FFZ(#{DRIVER})FFZ";
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
  puts 'bc2cpp fresh freeze check: PASS'
else
  warn "bc2cpp fresh freeze check: #{failures.size} failure(s)"
  exit 1
end
