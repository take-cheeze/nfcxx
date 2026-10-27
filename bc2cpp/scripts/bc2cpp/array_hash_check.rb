#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ARRAY_HASH_FIXNUM (tools/bc2cpp/codegen_array_hash.rb): the compiled Enumerable#hash hashes an exact Array of
# Fixnums natively instead of sending `__method_recursive?`, `hash` and `__update_hash`.
#
#   generated code (needs a host mrbc)
#     - the compiled Enumerable#hash opens with the native loop, and the helper is emitted;
#     - a program Integer#hash, a program `__update_hash` and BC2CPP_ARRAY_HASH=0 each keep the plain body;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same `hash` values (empty, negative, wide and 2**40 Fixnums, mixed,
#       nested, Float, bignum, subclass and recursive Arrays, a recursion reached through an element's `hash`), the
#       same Hash lookups and the same iteration order for Array keys.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/array_hash_check.rb

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
  class AhList < Array
  end
  # Its `hash` refills the outer Array with Fixnums and hashes it again: the inner call is a recursion.
  class AhRefill
    def initialize(a); @a = a; end
    def hash; @a[0] = 5; @a.hash; end
    def eql?(other); equal?(other); end
  end
  class AhTable
    def build(n)
      entries = {}
      (0...n).map do |i|
        key = [i & 3, i >> 2 & 1]
        entries[key] ||= [i]
        entries[key] << i
        entries[key]
      end
      entries
    end
    def keyed(k); h = { [1, 2] => :a, [2, 1] => :b, [1, 2, 3] => :c }; h[k]; end
  end
RUBY

OWNERS = %w[AhList AhRefill AhTable].freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

def generate_world(src, env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-array-hash')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
body = method_code(code, 'Enumerable_hash')
check.call('the compiled Enumerable#hash opens with the native loop',
           body.include?('ARRAY_HASH_FIXNUM') && body.index('bc2cpp_ary_fixnum_hash(') < body.index('Array_each_impl'))
check.call('the helper is emitted once', code.scan('static bool bc2cpp_ary_fixnum_hash(').size == 1)

refusals = {
  'a program Integer#hash' => [SRC + "class Integer\n  def hash; 7; end\nend\n", {}],
  'a program __update_hash' => [SRC + "module Enumerable\n  def __update_hash(h, i, v); h + v; end\nend\n", {}],
  'BC2CPP_ARRAY_HASH=0' => [SRC, { 'BC2CPP_ARRAY_HASH' => '0' }]
}
refusals.each do |label, (src, env)|
  world, = generate_world(src, env)
  check.call("#{label}: no native loop", !world.include?('bc2cpp_ary_fixnum_hash') && !world.include?('#error'))
end

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  big = 2**70
  show.call('fixnums') do
    [[], [0], [1, 2], [2, 1], [-1, -2**40], [2**40, 0x3fff_ffff, -0x4000_0000], (0...20).to_a].map(&:hash)
  end
  show.call('mixed') { [[1, :a], [1, 'a'], [1, 1.5], [1, nil], [[1, 2], 3], [1, big]].map(&:hash) }
  show.call('subclass') { l = AhList.new; l << 1 << 2; [l.hash, l.hash == [1, 2].hash] }
  show.call('self recursive') { a = [1, 2]; a << a; a.hash }
  show.call('recursion through an element') { a = [nil, 1]; a[0] = AhRefill.new(a); [a.hash, a] }
  show.call('equal arrays hash alike') { [[3, 4].hash == [3, 4].hash, [3, 4].hash == [4, 3].hash] }
  t = AhTable.new
  show.call('table') { t.build(16).to_a }
  show.call('keyed') { [t.keyed([1, 2]), t.keyed([2, 1]), t.keyed([1, 2, 3]), t.keyed([1]), t.keyed([1, 2.0])] }
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
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"AHF(#{DRIVER})AHF";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    # Enumerable is registered too, so a driver-level `hash` reaches the compiled body.
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS + %w[Enumerable], scenario,
                                             build: build, full: true)
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
  puts 'bc2cpp array hash check: PASS'
else
  warn "bc2cpp array hash check: #{failures.size} failure(s)"
  exit 1
end
