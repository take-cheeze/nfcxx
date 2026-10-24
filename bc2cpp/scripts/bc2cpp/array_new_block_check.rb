#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ARRAY_NEW_BLOCK (tools/bc2cpp/codegen_array_new_inline.rb): `Array.new(n) { |i| BODY }` as an inlined counted loop.
#
#   generated code (needs a host mrbc)
#     - in the closed world, with every native source scanned, the site is inlined: the only native registration of
#       `initialize` on Array is mruby's own src/array.c (NATIVE_OWNER_MAP);
#     - `Array.new(n, obj) { }`, a block that forwards the method's block, and BC2CPP_ARRAY_NEW_INLINE=0 keep the call.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for a 0- and a 1-parameter block, a captured local written by the
#       block, `next` and `break` values, sizes 0, negative, Float and a non-number (TypeError), an exception raised
#       in the block, a nested Array.new, allocation and GC.start in the block, and the same calls inside a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/array_new_block_check.rb

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
  class AnFx
    def idx(n); Array.new(n) { |i| i * 2 }; end
    def zero(n); Array.new(n) { :z }; end
    def acc(n); s = 0; r = Array.new(n) { |i| s += i; s }; [r, s]; end
    def nxt(n); Array.new(n) { |i| next :odd if i.odd?; i }; end
    def brk(n); Array.new(n) { |i| break [:stop, i] if i == 2; i }; end
    def boom(n); Array.new(n) { |i| raise ArgumentError, "at #{i}" if i == 1; i }; rescue ArgumentError => e; e.message; end
    def grid(n); Array.new(n) { |i| Array.new(i) { |j| i * 10 + j } }; end
    def strs(n); Array.new(n) { |i| GC.start; "#{i}-" * 3 }; end
    def filled(n); Array.new(n, :x) { |i| i }; end
    def fwd(n); Array.new(n) { |i| yield i }; end
  end
RUBY

# The method's body and its helpers (a `rescue` body is its own `_impl_rescue_try` function).
def code_of(code, name)
  code.scan(/^(?:static )?mrb_value AnFx_#{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: %w[AnFx]) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

INLINED = '// ARRAY_NEW_BLOCK :new'

baseline_dir = Dir.mktmpdir('bc2cpp-array-new')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: %w[AnFx])
%w[idx zero acc nxt brk boom grid strs].each do |name|
  check.call("#{name}: Array.new(n) { } is an inlined loop, no `new` call", code_of(code, name).include?(INLINED))
end
check.call('the closed world reports every site inlined', !baseline_err.include?('initialize_native_spelled'))
check.call('filled: Array.new(n, obj) { } keeps the call', !code_of(code, 'filled').include?(INLINED))
check.call('fwd: a block that yields to the method block keeps the call', !code_of(code, 'fwd').include?(INLINED))
off, = generate_world('BC2CPP_ARRAY_NEW_INLINE' => '0')
check.call('BC2CPP_ARRAY_NEW_INLINE=0: no site is inlined', !off.include?(INLINED))

DRIVER = <<~'RUBY'
  fx = AnFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  [0, 1, 4, -3, 2.9, nil, 'x'].each do |n|
    %i[idx zero acc nxt brk boom grid strs filled].each { |m| show.call("#{m}/#{n.inspect}") { fx.send(m, n) } }
    show.call("fwd/#{n.inspect}") { fx.fwd(n) { |i| -i } }
  end
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [fx.idx(3), fx.acc(4), fx.grid(3), fx.strs(2)]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  f = Fiber.new do
    out = [fx.idx(2), fx.nxt(3)]
    Fiber.yield out
    fx.brk(5)
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
        const char* src = R"ANB(#{DRIVER})ANB";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, %w[AnFx], body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('a size that is not a number raises TypeError', interpreted.any? { |l| l.start_with?('idx/"x": TypeError') })
      check.call('break gives the call its value', interpreted.include?('brk/4: [:stop, 2]'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp Array.new block check: PASS'
else
  warn "bc2cpp Array.new block check: #{failures.size} failure(s)"
  exit 1
end
