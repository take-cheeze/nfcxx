#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_ITERATOR_DIRECT (docs/adr/0472): literal-block iterator sends call the compiled block-taking body directly.
#
#   generated code (needs a host mrbc; one closed-world generation per world variant, seconds)
#     - an implicit-self `loop { }` calls Kernel#loop's compiled body, behind the root-context test unless the block
#       is yield-free; a program definition of `loop`, a native registration of it or a BasicObject subclass withdraws it;
#     - `s.each_char { }` / `s.each_line { }` on an unproven receiver get an exact-String arm, the dynamic send its else;
#       a program String#each_char withdraws the arm;
#     - an Integer literal receiver (`2.times { }` nested in an inlined loop) keeps no dynamic else;
#     - the Array/Hash/Range arms (ADR 0270) and the guarded loops (ADR 0420) are unchanged: an unproven receiver keeps
#       its class tests and the dynamic send as the else;
#     - BC2CPP_BLOCK_CORE_DIRECT=0 removes every arm of this ADR with the others.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - compiled and interpreted runs print the same for each with break/next/return, each over an array mutated
#       during iteration, map/select/reject/any?/all?/reduce, Integer#times (literal and nested), Hash#each/each_key,
#       String#each_char/each_line, Kernel#loop (break, value break, return, next, StopIteration), user Enumerable and
#       nil receivers, and the same calls inside a Fiber (the root-context test's else).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_iterator_direct_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is checked against the shipped signature files of no program: they name engine classes it lacks.
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
  class BiFx
    def each_sum(a); s = 0; a.each { |x| s += x }; s; end
    def each_break(a); a.each { |x| break x * 10 if x > 2 }; end
    def each_next(a); r = []; a.each { |x| next if x.odd?; r << x }; r; end
    def each_return(a); a.each { |x| return [:ret, x] if x > 1 }; :none; end
    def grow(a); r = []; a.each { |x| r << x; a << x + 10 if a.size < 6 }; [r, a]; end
    def shrink(a); r = []; a.each { |x| r << x; a.pop }; [r, a]; end
    def map_sq(a); a.map { |x| x * x }; end
    def sel(a); a.select { |x| x.even? }; end
    def rej(a); a.reject { |x| x.even? }; end
    def any_all(a); [a.any? { |x| x > 2 }, a.all? { |x| x > 0 }]; end
    def red(a); a.reduce(0) { |m, x| m + x }; end
    def red_break(a); a.reduce(0) { |m, x| break [:stop, m] if x > 2; m + x }; end
    def ewi(a); r = []; a.each_with_index { |x, i| r << [x, i] }; r; end
    def eidx(a); r = []; a.each_index { |i| r << i }; r; end
    def tm(n); r = 0; n.times { |i| r += i }; r; end
    def tm_literal(k); r = []; 3.times { |i| r << i * k }; r; end
    def tm_first(n); n.times { |i| break [:first, i] }; end
    def tm_count(n); c = 0; n.times { c += 1 }; [c, n.times { }]; end
    def tm_nested(n); r = []; n.times { |i| 2.times { |j| r << i * 10 + j } }; r; end
    def tm_nested_break(n); r = []; n.times { |i| r << 2.times { |j| break [:inner, i, j] if j == 1 } }; r; end
    def h_each(h); r = []; h.each { |k, v| r << "#{k}=#{v}" }; r; end
    def h_keys(h); r = []; h.each_key { |k| r << k }; r; end
    def h_break(h); h.each { |k, v| break k if v > 1 }; end
    def chars(s); r = []; s.each_char { |c| r << c.upcase }; r; end
    def char_break(s); s.each_char { |c| break [:at, c] if c == 'b' }; end
    def str_lines(s); r = []; s.each_line { |l| r << l.chomp }; r; end
    def lp(n); i = 0; loop { i += 1; break if i > n }; i; end
    def lp_value(n); i = 0; loop { i += 1; break i * 2 if i >= n }; end
    def lp_return(n); i = 0; loop { i += 1; return [:ret, i] if i == n }; end
    def lp_next(n); i = 0; r = []; loop { i += 1; next if i.odd?; r << i; break if i > n }; r; end
    def lp_stop(n); i = 0; v = loop { i += 1; raise StopIteration if i == n }; [v, i]; end
    def lp_drain(a); r = []; loop { raise StopIteration if a.empty?; r << a.shift }; r; end
    def lp_raise(n); i = 0; loop { i += 1; raise ArgumentError, "at #{i}" if i == n }; rescue ArgumentError => e; e.message; end
    def user_each(o); r = []; o.each { |x| r << x }; r; end
    def nil_each(o); o.each { |x| x }; rescue NoMethodError => e; e.class; end
  end

  class BiTimes
    def times; yield 7; :mine; end
  end

  class BiColl
    include Enumerable
    def initialize(*a); @a = a; end
    def each; @a.each { |x| yield x }; self; end
  end
RUBY

# A site inside a rescue range lives in the extracted try function (ADR 0262's fell-off-the-end raise ends it).
def code_of(code, name)
  code[/^mrb_value BiFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s +
    code.scan(/^static mrb_value BiFx_#{name}_impl_rescue_try\w*\(.*?fell off the end of its body"\);\n\}/m).join
end

# Every block body of `name` too: a block nested in an inlined loop lives in the method's own function, but a
# block of a block that kept its call is compiled into a `_block_fallback_` function of its own.
def code_with_blocks(code, name)
  code_of(code, name) + code.scan(/^static mrb_value BiFx_#{name}_(?:inline_\d+_)*block_fallback\w*\(mrb_state\* M.*?^\}/m).join
end

def generate_world(src = SRC, env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: %w[BiFx]) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

KERNEL_LOOP = 'Kernel_loop_impl(M, self, '
DYNAMIC = 'mrb_funcall_with_block('

puts '-- generated code'
code, = generate_world
%w[lp lp_value lp_return lp_next lp_stop lp_drain lp_raise].each do |name|
  check.call("#{name}: loop { } calls the compiled Kernel#loop", code_of(code, name).include?(KERNEL_LOOP))
end
check.call('lp: a block with a break keeps the root-context test, the dynamic send its else',
           code_of(code, 'lp').match?(/if \(M->c == M->root_c\) \{\n\s+r\d+ = Kernel_loop_impl\(M, self, .*\} else \{\n\s+r\d+ = mrb_funcall_with_block\(M, self, /m))
check.call('lp_drain: a yield-free block leaves no dynamic send',
           code_of(code, 'lp_drain').include?('no dynamic send') && !code_of(code, 'lp_drain').include?(DYNAMIC))
chars = code_of(code, 'chars')
check.call('chars: an unproven each_char receiver gets an exact-String arm with the dynamic send as its else',
           chars.match?(/if \(mrb_string_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->string_class\) \{\n\s+r\d+ = String_each_char_impl\(M, .*\} else \{\n\s+r\d+ = mrb_funcall_with_block\(/m))
check.call('str_lines: each_line gets the String arm', code_of(code, 'str_lines').include?('String_each_line_impl(M, '))
nested = code_with_blocks(code, 'tm_nested')
# The only dynamic send left is the outer `n.times`'s own else (its receiver is unproven); the inner `2.times` keeps
# none, in the inlined loop and in the block function the outer else passes.
check.call('tm_nested: the Integer literal receiver of the inner times keeps no dynamic else',
           nested.include?('literal Integer receiver') && nested.include?('Integer_times_impl(M, ') &&
           nested.scan(DYNAMIC).size == 1 && code_of(code, 'tm_nested').scan(DYNAMIC).size == 1)
tm = code_of(code, 'tm')
check.call('tm: an unproven receiver runs the inlined loop behind a Fixnum test, the send with its Integer arm as the else',
           tm.match?(/GUARDED_BLOCK_INLINE :times .*\n\s+if \(M->c == M->root_c && mrb_integer_p\(r\d+\)\) \{\n/) &&
           tm.include?('Integer_times_impl(M, ') && tm.include?(DYNAMIC))
check.call('tm_literal: an Integer literal receiver is the plain loop of ADR 0147',
           code_of(code, 'tm_literal').include?('bc2cpp_times_i_') && !code_of(code, 'tm_literal').include?('GUARDED_BLOCK_INLINE') &&
           !code_of(code, 'tm_literal').include?(DYNAMIC))
user = code_of(code, 'user_each')
check.call('user_each: an unproven receiver keeps the exact-class arms and the dynamic send as the else',
           user.include?('Array_each_impl(M, ') && user.include?(DYNAMIC))
check.call('no arm of this ADR is an unchecked fallback: every #error-free body compiles', !code.include?('#error'))

puts '-- world proofs withdraw the arms'
c, = generate_world(SRC + "class BiOther\n  def loop; :mine; end\nend\n")
check.call('a program definition of loop anywhere withdraws the Kernel arm', !code_of(c, 'lp').include?(KERNEL_LOOP))
c, = generate_world(SRC + "class BiBare < BasicObject\nend\n")
check.call('a BasicObject subclass withdraws the Kernel arm', !code_of(c, 'lp').include?(KERNEL_LOOP))
c, = generate_world(SRC + "class BiMeta\n  def install(n); Object.send(:define_method, n) { 1 }; end\nend\n")
check.call('a dynamic installer withdraws the Kernel and String arms',
           !code_of(c, 'lp').include?(KERNEL_LOOP) && !code_of(c, 'chars').include?('String_each_char_impl'))
c, = generate_world(SRC + "class String\n  def each_char; yield 'z'; end\nend\n")
check.call('a program String#each_char withdraws the String arm', !code_of(c, 'chars').include?('String_each_char_impl'))
c, = generate_world(SRC, { 'BC2CPP_BLOCK_CORE_DIRECT' => '0' })
check.call('BC2CPP_BLOCK_CORE_DIRECT=0: no Kernel, String or literal arm',
           !code_of(c, 'lp').include?(KERNEL_LOOP) && !code_of(c, 'chars').include?('String_each_char_impl(M,') &&
           !c.include?('literal Integer receiver'))

DRIVER = <<~'RUBY'
  fx = BiFx.new
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  coll = BiColl.new(1, 2, 3)
  arrays = [[1, 2, 3, 4], [], [5], [0, 1], (1..40).to_a, [1, 2, 3].freeze]
  arrays.each_with_index do |a, i|
    %i[each_sum each_break each_next each_return map_sq sel rej any_all red red_break ewi eidx].each do |m|
      show.call("#{m}/#{i}") { fx.send(m, a.frozen? ? a : a.dup) }
    end
  end
  [[1, 2], [1, 2, 3], []].each_with_index do |a, i|
    show.call("grow/#{i}") { fx.grow(a.dup) }
    show.call("shrink/#{i}") { fx.shrink(a.dup) }
  end
  show.call('frozen grow') { fx.grow([1].freeze) }
  [0, 1, 4].each do |n|
    show.call("tm/#{n}") { fx.tm(n) }
    show.call("tm_nested/#{n}") { fx.tm_nested(n) }
    show.call("tm_nested_break/#{n}") { fx.tm_nested_break(n) }
  end
  show.call('tm_literal') { fx.tm_literal(5) }
  # Not a Fixnum: a bignum runs Integer#times, anything without `times` raises NoMethodError, a user `times` runs.
  # A positive bignum would count for ever, so it only runs to the first iteration's break.
  show.call('tm_first/big') { fx.tm_first(2**70) }
  [-(2**70), 2.5, nil, 'x', :s, BiTimes.new].each_with_index do |n, i|
    show.call("tm_first/x#{i}") { fx.tm_first(n) }
    show.call("tm_count/x#{i}") { fx.tm_count(n) }
    show.call("tm/x#{i}") { fx.tm(n) }
  end
  [0, 3, -1].each { |n| show.call("tm_count/#{n}") { fx.tm_count(n) } }
  [{ a: 1, b: 2, c: 3 }, {}, { 'x' => 0 }].each_with_index do |h, i|
    show.call("h_each/#{i}") { fx.h_each(h) }
    show.call("h_keys/#{i}") { fx.h_keys(h) }
    show.call("h_break/#{i}") { fx.h_break(h) }
  end
  ['abc', '', "x\nyy\nzzz", 'bbb'].each_with_index do |s, i|
    show.call("chars/#{i}") { fx.chars(s) }
    show.call("char_break/#{i}") { fx.char_break(s) }
    show.call("str_lines/#{i}") { fx.str_lines(s) }
  end
  [1, 3, 6].each do |n|
    %i[lp lp_value lp_return lp_next lp_stop lp_raise].each { |m| show.call("#{m}/#{n}") { fx.send(m, n) } }
  end
  show.call('lp_drain') { fx.lp_drain([1, 2, 3]) }
  show.call('lp_drain empty') { fx.lp_drain([]) }
  # Unproven receivers: a user Enumerable, a Range, a Hash where an Array was meant, nil, a String.
  [coll, 1..4, { k: 1 }, [9, 8]].each_with_index do |o, i|
    %i[map_sq sel rej any_all red user_each ewi].each { |m| show.call("#{m}/u#{i}") { fx.send(m, o) } }
  end
  show.call('nil_each') { fx.nil_each(nil) }
  show.call('each_char on nil') { fx.chars(nil) }
  # Inside a Fiber the root-context test fails, so the arms' else (the dynamic send) runs.
  f = Fiber.new do
    out = [fx.lp(3), fx.lp_value(2), fx.lp_return(2), fx.lp_drain([7, 8]), fx.chars('ab'), fx.tm_nested(2),
           fx.each_break([1, 5]), fx.user_each(coll), fx.lp_stop(2)]
    Fiber.yield out
    :done
  end
  show.call('fiber') { [f.resume, f.resume] }
  GC.start
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    r = [fx.lp_next(9), fx.chars('hello'), fx.tm_nested(3), fx.str_lines("a\nb")]
    GC.stress = false if GC.respond_to?(:stress=)
    r
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
    saved_flags = ENV.fetch('BC2CPP_CXXFLAGS', nil)
    ENV['BC2CPP_CXXFLAGS'] = '-DMRB_USE_BIGINT'
    begin
      Dir.mktmpdir do |dir|
        _code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: %w[BiFx])
        body = <<~CPP
          static int scenario(mrb_state* M) {
            std::fflush(stdout);
            const char* src = R"BID(#{DRIVER})BID";
            mrb_load_string(M, src);
            std::fflush(stdout);
            if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
            return 0;
          }
        CPP
        built, output = Bc2cppFixtureRuntime.run(dir, err, %w[BiFx], body, build: build, full: true)
        check.call('the fixtures build and run', built)
        sections = Bc2cppFixtureRuntime.sections(output)
        interpreted = sections['interpreted']
        compiled = sections['compiled']
        check.call("the driver prints #{interpreted&.size} lines in both runs",
                   interpreted && interpreted.last == 'end' && compiled&.last == 'end')
        check.call('interpreted and compiled runs print the same', interpreted == compiled)
        if interpreted && compiled
          interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
          check.call('break returns its value from loop', interpreted.include?('lp_value/3: 6'))
          check.call('return leaves the method from a loop block', interpreted.include?('lp_return/3: [:ret, 3]'))
          check.call('StopIteration ends loop with its result', interpreted.include?('lp_stop/3: [nil, 3]'))
          check.call('each re-reads the length of an array grown during the iteration',
                     interpreted.include?('grow/0: [[1, 2, 11, 12, 21, 22], [1, 2, 11, 12, 21, 22]]'))
        end
        puts output.lines.last(30).join unless built && interpreted && compiled
      end
    ensure
      saved_flags.nil? ? ENV.delete('BC2CPP_CXXFLAGS') : ENV['BC2CPP_CXXFLAGS'] = saved_flags
    end
  end
end

if failures.empty?
  puts 'bc2cpp block iterator direct check: PASS'
else
  warn "bc2cpp block iterator direct check: #{failures.size} failure(s)"
  exit 1
end
