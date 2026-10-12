#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ARRAY_NEW_BLOCK (docs/adr/0391): `Array.new(n) { |i| ... }` is an inlined counted loop when the closed world proves
# the receiver is the stable top-level constant Array and that Class#new / Array#initialize are mruby's own.
#
#   generated code (needs a host mrbc; one closed-world build per world variant)
#     - the admitted shapes (a one-parameter block, a parameterless block, `break`/`next`/`return`, inside a rescue
#       range) become a loop: no RProc, no by-name `new` with a block, no BLOCK_FALLBACK :new;
#     - every refusal keeps the call and is counted under its reason in the "Array.new block inlining" report:
#       a second argument, a two-parameter block, a receiver that is not the constant, a nested class named Array,
#       a reopened Array#initialize, a prepend on Array, a runtime installer of `initialize`, a `new`/`allocate`
#       override on Object's or Array's singleton;
#     - BC2CPP_ARRAY_NEW_INLINE=0 restores the call everywhere;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - compiled and interpreted runs print the same for sizes 0, 3, -1, 2.5, nil, "x", a block that raises half way,
#       break, next, return from the method, a captured counter, a nested Array.new, and under GC stress.
#
# scripts/bc2cpp_array_new_block_mutation_check.rb weakens each proof clause in turn.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/array_new_block_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

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
    def grid(n); Array.new(n) { |i| i * 2 }; end
    def fill; Array.new(3) { 7 }; end
    def with_break(n); Array.new(n) { |i| break :stopped if i == 2; i }; end
    def with_next(n); Array.new(n) { |i| next :even if i.even?; i }; end
    def with_return(n); Array.new(n) { |i| return [:early, i] if i == 2; i }; end
    def counted(n); c = 0; a = Array.new(n) { |i| c += 1; c * i }; [a, c]; end
    def nested(n); Array.new(n) { |i| Array.new(i) { |j| i * 10 + j } }; end
    def raising(n); Array.new(n) { |i| raise ArgumentError, "at #{i}" if i == 2; i }; rescue ArgumentError => e; e.message; end
    def strings(n); Array.new(n) { |i| "s#{i}" * 3 }; end
    def in_rescue(n)
      begin
        Array.new(n) { |i| raise "boom" if i == 3; i }
      rescue RuntimeError
        :rescued
      end
    end

    # Refused: each keeps the call.
    def with_fill(n); Array.new(n, 0) { |i| i }; end
    def two_params(n); Array.new(n) { |i, j| [i, j] }; end
    def via_variable(k, n); k.new(n) { |i| i }; end
    def no_block(n); Array.new(n); end
    def reads_frame_block(n); Array.new(n) { |i| block_given? ? i : -i }; end
  end

  module AnOuter
    class Array
      def initialize(n); @n = n; yield 1; end
    end

    def self.nested_array(n); Array.new(n) { |i| i }; end
  end
RUBY

def code_of(code, name)
  code[/^mrb_value AnFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

def report_of(err)
  err[/== Array.new block inlining \(ARRAY_NEW_BLOCK\) ==\n(.*?)\n\n/m, 1].to_s.lines.to_h { |l| k, v = l.strip.split(': '); [k, v.to_i] }
end

# `gems` is an outside gem the build links: { name => { relative path => text } }. Its src/ and mrblib/ then count as
# outside native and Ruby sources of the closed world (the only way to add one).
def generate_world(src = SRC, env = {}, gems: {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir do |dir|
    build_gems = gems.map { |name, _| [name, File.join(dir, name)] }
    foreign = []
    gems.each do |name, files|
      files.each do |rel, text|
        path = File.join(dir, name, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
        foreign << ["#{name}/#{rel}", text] if rel.end_with?('.rb')
      end
    end
    return Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: %w[AnFx AnOuter::Array AnOuter.singleton],
                                                   build_gems: build_gems, foreign: foreign)
  end
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

INLINED = %w[grid fill with_break with_next with_return counted nested raising strings in_rescue].freeze
REFUSED = %w[with_fill two_params via_variable no_block reads_frame_block].freeze

# A generated function ends with its fell-off-the-end raise (ADR 0262); a bare `}` at column 0 also closes an
# arithmetic fast path inside the body, so the closing brace alone cannot delimit it.
FELL_OFF = /fell off the end of its body"\);\n\}/

# `outer` sites are the ones whose own call is gone; a block nested in an inlined loop keeps its own calls (the nested
# pass inlines BLOCK_FALLBACK regions only), so `nested` is allowed one remaining `new` call.
def inlined?(code, name, remaining_calls = 0)
  body = code_of(code, name)
  # A site inside a rescue range lives in the extracted try function.
  tries = code.scan(/^static mrb_value AnFx_#{name}_impl_rescue_try\w*\(.*?#{FELL_OFF.source}/m).join
  text = body + tries
  text.include?('ARRAY_NEW_BLOCK') && text.include?('mrb_ary_push(M, bc2cpp_anew_acc_') &&
    text.scan('BLOCK_FALLBACK :new').size == remaining_calls && !text.include?('#error')
end

puts '-- the admitted shapes are loops'
code, err = generate_world
INLINED.each { |name| check.call("#{name}: Array.new { } is an inlined loop", inlined?(code, name, name == 'nested' ? 1 : 0)) }
grid = code_of(code, 'grid')
check.call('grid: the size is converted by mrb_as_int, as mrb_ary_init does', grid.include?('mrb_as_int(M, r'))
check.call('grid: a size <= 0 allocates nothing and runs nothing', grid.include?('> 0 ? bc2cpp_anew_n_') && grid.include?('i_') )
check.call('grid: no RProc is built and no block is passed to a by-name call',
           !grid.include?('mrb_proc_new_cfunc') && !grid.include?('mrb_funcall_with_block'))
check.call('fill: the parameterless block binds no index', !code_of(code, 'fill').include?('mrb_fixnum_value(bc2cpp_anew_i_'))
check.call('grid: the index is bound to the block parameter', grid.include?('= mrb_fixnum_value(bc2cpp_anew_i_'))
check.call('with_break: the array is assigned only when no break ran', code_of(code, 'with_break').include?('if (!bc2cpp_anew_broke_'))
check.call('with_break: break sets the result and skips the array assignment',
           code_of(code, 'with_break').include?('bc2cpp_anew_broke_') && code_of(code, 'with_break').include?('goto Lbc2cpp_anew_end_'))

puts '-- refusals keep the call'
REFUSED.each do |name|
  body = code_of(code, name)
  check.call("#{name}: the call is kept", !body.include?('ARRAY_NEW_BLOCK') && !body.include?('#error'))
end
check.call('with_fill: Array.new(n, obj) { } is a call with a block', code_of(code, 'with_fill').include?('BLOCK_FALLBACK :new'))
check.call('two_params: a two-parameter block is a call with a block', code_of(code, 'two_params').include?('BLOCK_FALLBACK :new'))
nested = code[/^mrb_value AnOuter_singleton_nested_array_impl.*?^\}/m].to_s
check.call('nested_array: an Array defined inside AnOuter is not the top-level Array', !nested.include?('ARRAY_NEW_BLOCK'))
rep = report_of(err)
check.call("report: #{INLINED.size} inlined sites (the nested inner call is not a site of this pass)", rep['inlined'] == INLINED.size)
check.call('report: the block arity refusal is counted', rep['block_arity'] == 1)
check.call('report: the lexically nested Array is counted', rep['receiver_not_toplevel_array'] == 1)

puts '-- the world proofs'
worlds = {
  'initialize_defined_on_array' => ["class Array\n  def initialize(*a); super; end\nend\n", {}],
  'initialize_array_mixin' => ["module AnMix; end\nclass Array\n  prepend AnMix\nend\n", {}],
  'initialize_installed' => ["class AnMeta\n  define_method(:initialize) { |*a| }\nend\n", {}],
  'construction_replaceable' => ["class Object\n  def self.new(*a); super; end\nend\n", {}],
  'array_constant_unstable' => ["Array = Class.new(Object)\n", {}],
  # An outside Ruby source (a gem's mrblib) reopening Array, and an outside native registering over it.
  'initialize_outside_definer' => ['', { gems: { 'an-ruby' => { 'mrblib/outside.rb' => "class Array\n  def initialize(*a); super; end\nend\n" } } }],
  'initialize_native_spelled' => ['', { gems: { 'an-native' => { 'src/an_extra.c' =>
    'void an_replace(mrb_state *mrb) { mrb_define_method(mrb, mrb->array_class, "initialize", an_init, MRB_ARGS_ANY()); }' } } }]
}
worlds.each do |reason, (extra, outside)|
  c, e = generate_world(SRC + extra, **outside)
  rep = report_of(e)
  check.call("#{reason}: no site is inlined", !c.include?('ARRAY_NEW_BLOCK') && !c.include?('#error'))
  check.call("#{reason}: the refusal is counted under its reason", rep[reason].to_i >= INLINED.size)
end
c, = generate_world(SRC + "class AnMeta\n  alias_method :orig_initialize, :initialize\nend\n")
check.call('an alias_method that only copies initialize does not stop the inlining', INLINED.all? { |n| inlined?(c, n, n == 'nested' ? 1 : 0) })

puts '-- the switch'
c, e = generate_world(SRC, { 'BC2CPP_ARRAY_NEW_INLINE' => '0' })
check.call('BC2CPP_ARRAY_NEW_INLINE=0: no loop, the calls are kept',
           !c.include?('ARRAY_NEW_BLOCK') && !c.include?('#error'))

# ---------------------------------------------------------------------------------------------------------
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
  [0, 1, 3, -1, 2.5, nil, "x", :sym, 2**40].each do |n|
    show.call("grid(#{n.inspect})") { fx.grid(n) }
  end
  show.call('fill') { fx.fill }
  [0, 1, 2, 3, 5].each do |n|
    show.call("with_break(#{n})") { fx.with_break(n) }
    show.call("with_next(#{n})") { fx.with_next(n) }
    show.call("with_return(#{n})") { fx.with_return(n) }
    show.call("counted(#{n})") { fx.counted(n) }
    show.call("nested(#{n})") { fx.nested(n) }
    show.call("raising(#{n})") { fx.raising(n) }
    show.call("in_rescue(#{n})") { fx.in_rescue(n) }
  end
  show.call('result class') { [fx.grid(2).class, fx.grid(2).frozen?, fx.grid(2).equal?(fx.grid(2))] }
  GC.start
  big = nil
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    big = fx.strings(60)
    GC.stress = false if GC.respond_to?(:stress=)
    [big.size, big.first, big.last, big.map(&:size).uniq]
  end
  show.call('plain') { [fx.with_fill(3), fx.two_params(2), fx.via_variable(Array, 2), fx.no_block(2)] }
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
    saved_flags = ENV.fetch('BC2CPP_CXXFLAGS', nil)
    ENV['BC2CPP_CXXFLAGS'] = '-DMRB_USE_BIGINT'
    begin
      Dir.mktmpdir do |dir|
        code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: %w[AnFx])
        check.call('the closed-world build inlines the sites', INLINED.all? { |n| inlined?(code, n, n == 'nested' ? 1 : 0) })
        body = <<~CPP
          static int scenario(mrb_state* M) {
            std::fflush(stdout);
            const char* src = R"BCD(#{DRIVER})BCD";
            mrb_load_string(M, src);
            if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
            return 0;
          }
        CPP
        built, output = Bc2cppFixtureRuntime.run(dir, err, %w[AnFx], body, build: build, full: true)
        check.call('the fixtures build and run', built)
        sections = Bc2cppFixtureRuntime.sections(output)
        interpreted = sections['interpreted']
        compiled = sections['compiled']
        check.call("the driver prints #{interpreted&.size} lines in both runs", interpreted && interpreted.last == 'end' && compiled&.last == 'end')
        check.call('interpreted and compiled runs print the same', interpreted == compiled)
        if interpreted && compiled
          interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
          check.call('Array.new(3) { |i| i * 2 } is [0, 2, 4]', interpreted.include?('grid(3): [0, 2, 4]'))
          check.call('a negative size is an empty array', interpreted.include?('grid(-1): []'))
          check.call('a Float size truncates', interpreted.include?('grid(2.5): [0, 2]'))
          check.call('break returns its value from the call', interpreted.include?('with_break(5): :stopped'))
          check.call('return leaves the method', interpreted.include?('with_return(5): [:early, 2]'))
        end
        puts output.lines.last(20).join unless built
      end
    ensure
      saved_flags.nil? ? ENV.delete('BC2CPP_CXXFLAGS') : ENV['BC2CPP_CXXFLAGS'] = saved_flags
    end
  end
end

if failures.empty?
  puts 'bc2cpp Array.new block check: PASS'
else
  warn "bc2cpp Array.new block check: #{failures.size} failure(s)"
  exit 1
end
