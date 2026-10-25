#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_ITERATOR_DIRECT: literal-block iterator sends call the compiled block-taking body directly.
#
#   generated code (needs a host mrbc; one closed-world generation per world variant, seconds)
#     - an implicit-self `loop { }` calls Kernel#loop's compiled body, behind the root-context test unless the block
#       is yield-free; a program definition of `loop`, a native registration of it or a BasicObject subclass withdraws it;
#     - `s.each_char { }` / `s.each_line { }` on an unproven receiver get an exact-String arm, the dynamic send its else;
#       a program String#each_char withdraws the arm;
#     - an Integer literal receiver (`2.times { }` nested in an inlined loop) keeps no dynamic else;
#     - a Range literal receiver of a name only core owners answer (`(1..n).map { }`, OUTSIDE_OWNER_CALL's bare
#       line) takes the proven-receiver arm and keeps no dynamic else;
#     - the Array/Hash/Range arms and the guarded loops are unchanged: an unproven receiver keeps
#       its class tests and the dynamic send as the else;
#     - BC2CPP_BLOCK_CORE_DIRECT=0 removes every arm of this change with the others.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - compiled and interpreted runs print the same for each with break/next/return, each over an array mutated
#       during iteration, map/select/reject/any?/all?/reduce, Integer#times (literal and nested), Hash#each/each_key,
#       String#each_char/each_line (and IO#each_line on a File), Kernel#loop (break, value break, return, next, StopIteration), user Enumerable and
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

# Exercise the original-register proof independently of compile_send's site proof.
class CodeGen; end
require_relative '../../tools/bc2cpp/codegen_block_core_direct'
literal_probe = Object.new.extend(BlockCoreDirectFallback)
probe_irep = Object.new
probe_irep.define_singleton_method(:index_of_addr) { |_addr| 1 }
literal_probe.instance_variable_set(:@call_block_region, { parent_irep: probe_irep, dest_reg: 2, sendb_addr: 4 })
probe_world = Struct.new(:safe) do
  def exact_instances_singleton_free?; safe; end
end.new(true)
literal_probe.define_singleton_method(:block_core_world) { probe_world }
%w[Integer String Array Hash Range].each do |klass|
  literal_probe.define_singleton_method(:exact_literal) { |_irep, _idx, _reg| Struct.new(:klass).new(klass.to_sym) }
  check.call("original-register literal proof: #{klass}", literal_probe.block_core_literal_class == klass)
  probe_world.safe = false
  check.call("singleton gate: #{klass}", literal_probe.block_core_literal_class == (klass == 'Integer' ? klass : nil))
  probe_world.safe = true
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
    def rej_bang(a); a.reject! { |x| x.even? }; end
    def any_all(a); [a.any? { |x| x > 2 }, a.all? { |x| x > 0 }]; end
    def red(a); a.reduce(0) { |m, x| m + x }; end
    def red_break(a); a.reduce(0) { |m, x| break [:stop, m] if x > 2; m + x }; end
    def red_sym(a); a.reduce(:+) { |m, x| m * x }; end
    def red_var(a, i); a.reduce(i) { |m, x| m * x }; end
    def red_lit_sym; [1, 2, 3].reduce(:+) { |m, x| m * x }; end
    def idx(a); a.index { |x| x > 2 }; end
    def idx_break(a); a.index { |x| break [:stop, x] if x == 5; x > 30 }; end
    def idx_grow(a); a.index { |x| a << x + 100 if a.size < 8; x > 100 }; end
    def idx_lit(k); [5, 6, 7].index { |x| x == k }; end
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
    def chars_nested(n); r = []; n.times { "ab".each_char { |c| r << c } }; r; end
    def chars_nested_break(n); r = []; n.times { r << "ab".each_char { |c| break c } }; r; end
    def rng_map(n); (1..n).map { |i| i * 2 }; end
    def rng_any(n); (1..n).any? { |i| i > 2 }; end
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

# A site inside a rescue range lives in the extracted try function.
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
# The dynamic else an unproven receiver keeps: mrb_funcall_with_block, or the owner call carrying the block
# (BLOCK_OWNER_CALL). BY_NAME is the unchecked by-name send alone, which a fully proven site must not keep.
DYNAMIC = /mrb_funcall_with_block\(|bc2cpp_owner_call\(M, [^;]*BC2CPP_OWNERS\([^)]*\), (?!mrb_nil_value\(\))/
BY_NAME = 'mrb_funcall_with_block('

# Keep the baseline bytecode and C++ for runtime; BC2CPP_CXXFLAGS only affects its C++ compilation.
baseline_dir = Dir.mktmpdir('bc2cpp-iterator')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: %w[BiFx])
%w[lp lp_value lp_return lp_next lp_stop lp_drain lp_raise].each do |name|
  check.call("#{name}: loop { } calls the compiled Kernel#loop", code_of(code, name).include?(KERNEL_LOOP))
end
# The else is the site's send: by name, or the owner call when the closed world names every owner.
ELSE_SEND = '(?:mrb_funcall_with_block|bc2cpp_owner_call)\\('
check.call('lp: a block with a break keeps the root-context test, the send its else',
           code_of(code, 'lp').match?(/if \(M->c == M->root_c\) \{\n\s+r\d+ = Kernel_loop_impl\(M, self, .*\} else \{\n\s+r\d+ = #{ELSE_SEND}M, self, /m))
check.call('lp_drain: a yield-free block leaves no dynamic send',
           code_of(code, 'lp_drain').include?('no dynamic send') && !code_of(code, 'lp_drain').include?(BY_NAME))
chars = code_of(code, 'chars')
check.call('chars: an unproven each_char receiver gets an exact-String arm with the send as its else',
           chars.match?(/if \(mrb_string_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->string_class\) \{\n\s+r\d+ = String_each_char_impl\(M, .*\} else \{\n\s+r\d+ = #{ELSE_SEND}/m))
check.call('str_lines: each_line gets the String arm', code_of(code, 'str_lines').include?('String_each_line_impl(M, '))
# A `!`/`?` name is spelled with `$` in C++ (`Array_reject$21_impl`); the arm check must still count those calls.
check.call('rej_bang: reject! calls the compiled Array body, no by-name send left',
           code_of(code, 'rej_bang').include?('Array_reject$21_impl(M, ') && !code_of(code, 'rej_bang').include?(BY_NAME))
# IO#each_line is an alias in mruby-io's Ruby, never a registry definition: the owner call must still name IO.
lines_owner = code_of(code, 'str_lines')[/BC2CPP_OWNERS\(([^)]*)\)[^;]*; \/\* CLOSED_WORLD owner-call: each_line/, 1]
check.call('str_lines: an owner-call else lists IO, whose each_line is a core alias',
           lines_owner.nil? || lines_owner.include?('"IO"'))
nested = code_with_blocks(code, 'tm_nested')
# The only dynamic send left is the outer `n.times`'s own else (its receiver is unproven); the inner `2.times` keeps
# none, in the inlined loop and in the block function the outer else passes.
check.call('tm_nested: the Integer literal receiver of the inner times keeps no dynamic else',
           nested.include?('literal Integer receiver') && nested.include?('Integer_times_impl(M, ') &&
           nested.scan(DYNAMIC).size == 1 && code_of(code, 'tm_nested').scan(DYNAMIC).size == 1)
nested_chars = code_with_blocks(code, 'chars_nested')
check.call('chars_nested: a String literal in a nested block keeps no class test or dynamic else',
           nested_chars.match?(/-- (?:literal|proven) String receiver, yield-free block/) && nested_chars.scan(DYNAMIC).size == 1)
check.call('chars_nested_break: a nonlocal break keeps the root-context guard',
           code_with_blocks(code, 'chars_nested_break').match?(/(?:literal|proven) String receiver at the root context/))
tm = code_of(code, 'tm')
check.call('tm: an unproven receiver runs the inlined loop behind a Fixnum test, the send with its Integer arm as the else',
           tm.match?(/GUARDED_BLOCK_INLINE :times .*\n\s+if \(M->c == M->root_c && mrb_integer_p\(r\d+\)\) \{\n/) &&
           tm.include?('Integer_times_impl(M, ') && tm.match?(DYNAMIC))
check.call('tm_literal: an Integer literal receiver is the plain loop of ADR 0147',
           code_of(code, 'tm_literal').include?('bc2cpp_times_i_') && !code_of(code, 'tm_literal').include?('GUARDED_BLOCK_INLINE') &&
           !code_of(code, 'tm_literal').include?(BY_NAME))
red = code_of(code, 'red')
check.call('red: an unproven receiver runs the inlined fold behind an Array test, the send as the else',
           red.match?(/GUARDED_BLOCK_INLINE :reduce .*\n\s+if \(M->c == M->root_c && mrb_array_p\(r\d+\)/) &&
             red.match?(DYNAMIC))
check.call('red_sym, red_var: a Symbol or unproven initial value (Enumerable#inject takes a Symbol as the operator) ' \
           'keeps the send', %w[red_sym red_var red_lit_sym].none? { |m| code_of(code, m).include?('bc2cpp_accum_') })
ix = code_of(code, 'idx')
check.call('idx: an unproven receiver runs the inlined index loop behind an Array test, the send as the else ' \
           '(Array#index is array.c\'s own native)',
           ix.match?(/GUARDED_BLOCK_INLINE :index .*\n\s+if \(M->c == M->root_c && mrb_array_p\(r\d+\)/) &&
             ix.match?(DYNAMIC))
check.call('idx_lit: a literal Array receiver is the plain index loop, no send',
           code_of(code, 'idx_lit').include?('bc2cpp_accum_') && !code_of(code, 'idx_lit').include?(BY_NAME))
# OUTSIDE_OWNER_CALL's bare line (a name only core owners answer) reads the site's receiver proof too.
%w[rng_map rng_any].each do |name|
  check.call("#{name}: a Range literal receiver of an outside-owner name takes the proven arm, no dynamic send",
             code_of(code, name).include?('-- proven Range receiver, yield-free block') && !code_of(code, name).match?(DYNAMIC))
end
user = code_of(code, 'user_each')
check.call('user_each: an unproven receiver keeps the exact-class arms and the dynamic send as the else',
           user.include?('Array_each_impl(M, ') && user.match?(DYNAMIC))
check.call('no arm of this ADR is an unchecked fallback: every #error-free body compiles', !code.include?('#error'))

puts '-- world proofs withdraw the arms'
c, = generate_world(SRC + "class BiOther\n  def loop; :mine; end\nend\n")
check.call('a program definition of loop anywhere withdraws the Kernel arm', !code_of(c, 'lp').include?(KERNEL_LOOP))
c, = generate_world(SRC + "class BiBare < BasicObject\nend\n")
check.call('a BasicObject subclass withdraws the Kernel arm', !code_of(c, 'lp').include?(KERNEL_LOOP))
c, = generate_world(SRC + "class BiMeta\n  def install(n); Object.send(:define_method, n) { 1 }; end\nend\n")
check.call('a dynamic installer withdraws the Kernel and String arms',
           !code_of(c, 'lp').include?(KERNEL_LOOP) && !code_of(c, 'chars').include?('String_each_char_impl'))
c, = generate_world(SRC + "class BiSingleton\n  def touch(o); o.singleton_class; end\nend\n")
check.call('singleton makers withdraw the heap literal proof',
           !code_with_blocks(c, 'chars_nested').match?(/-- (?:literal|proven) String receiver/))
c, = generate_world(SRC + "class String\n  def each_char; yield 'z'; end\nend\n")
# The core arm (an exact-String test in front of the core body) goes. A STATIC_OWNER_ARMS arm may stay: it calls the
# program's own String#each_char, which is what an exact String receiver's lookup finds.
check.call('a program String#each_char withdraws the core String arm',
           !code_of(c, 'chars').match?(/M->string_class\) \{\n\s+r\d+ = String_each_char_impl/))
c, = generate_world(SRC + "class Array\n  def index(*a); :mine; end\nend\n")
check.call('a program Array#index withdraws the index loops, proven and guarded',
           %w[idx idx_lit].none? { |m| code_of(c, m).include?('bc2cpp_accum_') })
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
    %i[each_sum each_break each_next each_return map_sq sel rej rej_bang any_all red red_break idx idx_break idx_grow ewi
       eidx].each do |m|
      show.call("#{m}/#{i}") { fx.send(m, a.frozen? ? a : a.dup) }
    end
    [:+, 1, 2.5].each { |init| show.call("red_var/#{i}/#{init.inspect}") { fx.red_var(a.dup, init) } }
    show.call("red_sym/#{i}") { fx.red_sym(a.dup) }
  end
  [[1, 2], [1, 2, 3], []].each_with_index do |a, i|
    show.call("grow/#{i}") { fx.grow(a.dup) }
    show.call("shrink/#{i}") { fx.shrink(a.dup) }
  end
  show.call('frozen grow') { fx.grow([1].freeze) }
  [0, 1, 4].each do |n|
    show.call("chars_nested/#{n}") { fx.chars_nested(n) }
    show.call("chars_nested_break/#{n}") { fx.chars_nested_break(n) }
    show.call("tm/#{n}") { fx.tm(n) }
    show.call("tm_nested/#{n}") { fx.tm_nested(n) }
    show.call("tm_nested_break/#{n}") { fx.tm_nested_break(n) }
  end
  show.call('tm_literal') { fx.tm_literal(5) }
  show.call('red_lit_sym') { fx.red_lit_sym }
  [6, 9].each { |k| show.call("idx_lit/#{k}") { fx.idx_lit(k) } }
  [0, 1, 4].each do |n|
    show.call("rng_map/#{n}") { fx.rng_map(n) }
    show.call("rng_any/#{n}") { fx.rng_any(n) }
  end
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
    %i[map_sq sel rej rej_bang any_all red idx user_each ewi].each { |m| show.call("#{m}/u#{i}") { fx.send(m, o) } }
  end
  # A File's each_line is IO's core-Ruby alias; an Enumerator's each_with_index is its own core-Ruby method.
  File.open('bc2cpp_bi_lines.txt', 'w') { |f| f.write("p\nqq\n") }
  show.call('str_lines/io') { File.open('bc2cpp_bi_lines.txt', 'r') { |f| fx.str_lines(f) } }
  File.unlink('bc2cpp_bi_lines.txt')
  show.call('ewi/enum') { fx.ewi([4, 5].each) }
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
      built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, %w[BiFx], body, build: build, full: true)
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
        check.call('each_line on a File reads its lines', interpreted.include?('str_lines/io: ["p", "qq"]'))
        check.call('each_with_index on an Enumerator pairs its values', interpreted.include?('ewi/enum: [[4, 0], [5, 1]]'))
        check.call('return leaves the method from a loop block', interpreted.include?('lp_return/3: [:ret, 3]'))
        check.call('StopIteration ends loop with its result', interpreted.include?('lp_stop/3: [nil, 3]'))
        check.call('each re-reads the length of an array grown during the iteration',
                   interpreted.include?('grow/0: [[1, 2, 11, 12, 21, 22], [1, 2, 11, 12, 21, 22]]'))
      end
      puts output.lines.last(30).join unless built && interpreted && compiled
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
