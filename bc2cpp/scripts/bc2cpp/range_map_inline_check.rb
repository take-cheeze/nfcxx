#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RANGE_MAP_INLINE (tools/bc2cpp/codegen_loop_regions.rb, codegen_loop_inline.rb): `(a..b).map { |i| BODY }` over two
# Integer literals as an inlined counted loop, in a method body and in a BLOCK_FALLBACK body.
#
#   generated code (needs a host mrbc)
#     - literal inclusive, exclusive, empty and negative ranges, `next`, `break`, a captured local written by the block,
#       a raise, GC in the block and a `return` from the method are inlined loops, no `map` call;
#     - the innermost map of three nested blocks (PPU::TILE_LUT's shape) is inlined into its BLOCK_FALLBACK host, which
#       reads and writes the outer frames through its own captured upvars;
#     - a computed or Float end, a two-parameter block, and BC2CPP_RANGE_MAP_INLINE=0 keep the call.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for each fixture, under GC stress, and inside a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/range_map_inline_check.rb

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
  class RmFx
    def inc(n); (0..3).map { |i| i * n }; end
    def exc; (0...4).map { |i| i + 1 }; end
    def empty; (5..2).map { |i| i }; end
    def neg; (-3..-1).map { |i| i.abs }; end
    def nxt; (0..5).map { |i| next :odd if i.odd?; i }; end
    def brk; (0..9).map { |i| break [:stop, i] if i == 3; i }; end
    def acc; s = 0; r = (1..4).map { |i| s += i }; [r, s]; end
    def boom; (0..3).map { |i| raise ArgumentError, "at #{i}" if i == 2; i }; rescue ArgumentError => e; e.message; end
    def strs; (0..2).map { |i| GC.start; "#{i}-" * 2 }; end
    def ret; (0..3).map { |i| return [:early, i] if i == 2; i }; end
    def deep; [1, 2].map { |a| (0..1).map { |j| (0...3).map { |i| a * 100 + j * 10 + i } } }; end
    def deep_set; t = 0; [1, 2].map { |a| (0..1).map { |j| (0..2).map { |i| t += a + j + i } } }; t; end
    def computed(n); (0..n).map { |i| i * 2 }; end
    def floaty; (0..2.5).map { |i| i }; end
    def two; (0..2).map { |i, j| [i, j] }; end
  end
RUBY

# The method's body, its `rescue` try bodies and its BLOCK_FALLBACK bodies.
def code_of(code, name)
  code.scan(/^(?:static )?mrb_value RmFx_#{name}_(?:impl|\w+_impl)\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: %w[RmFx]) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

INLINED = 'Range receiver for inlined #map'

baseline_dir = Dir.mktmpdir('bc2cpp-range-map')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: %w[RmFx])
%w[inc exc empty neg nxt brk acc boom strs ret].each do |name|
  check.call("#{name}: (a..b).map { } is an inlined loop", code_of(code, name).include?(INLINED))
end
deep = code_of(code, 'deep')
check.call('deep: the innermost map runs inline in its BLOCK_FALLBACK host',
           deep.scan(/^static mrb_value RmFx_deep_\w*block_fallback\w*_impl\(.*?(?=^(?:static )?mrb_value |\z)/m)
               .any? { |body| body.include?(INLINED) })
check.call('deep_set: a write to an outer local from the inlined loop goes through the captured upvar',
           code_of(code, 'deep_set').include?(INLINED) && code_of(code, 'deep_set').include?('bc2cpp_upvar_root'))
%w[computed floaty two].each do |name|
  check.call("#{name}: keeps the map call", !code_of(code, name).include?(INLINED))
end
check.call('no #error in the generated code', !code.include?('#error'))
off, = generate_world('BC2CPP_RANGE_MAP_INLINE' => '0')
check.call('BC2CPP_RANGE_MAP_INLINE=0: no site is inlined', !off.include?(INLINED))

DRIVER = <<~'RUBY'
  fx = RmFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  show.call('inc') { fx.inc(3) }
  %i[exc empty neg nxt brk acc boom strs ret deep deep_set floaty two].each { |m| show.call(m.to_s) { fx.send(m) } }
  [0, 3, -1].each { |n| show.call("computed/#{n}") { fx.computed(n) } }
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [fx.inc(2), fx.acc, fx.deep, fx.strs]
    GC.stress = false if GC.respond_to?(:stress=)
    r
  end
  f = Fiber.new do
    out = [fx.exc, fx.nxt, fx.deep_set]
    Fiber.yield out
    fx.brk
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
        const char* src = R"RMI(#{DRIVER})RMI";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, %w[RmFx], body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('break gives the call its value', interpreted.include?('brk: [:stop, 3]'))
      check.call('the innermost value reads every outer frame', interpreted.include?(
        'deep: [[[100, 101, 102], [110, 111, 112]], [[200, 201, 202], [210, 211, 212]]]'
      ))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp Range#map inline check: PASS'
else
  warn "bc2cpp Range#map inline check: #{failures.size} failure(s)"
  exit 1
end
