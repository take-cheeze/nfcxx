#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check BLOCK_ARM_REACH (docs/adr/0310): the BLOCK_CORE_DIRECT arms of ADR 0270 reach three more
# kinds of literal-block send, and a proven arm keeps no dynamic else.
#
#   1. a block nested in an inlined loop body (`2.times { rows.each { } }`) takes the arms, with the
#      registers shifted by the outer body's offset;
#   2. a send whose arm chain the compiler built twice (one build dropped) is accepted when every
#      live `_impl` call is covered by name by a direct_call_args call, not only when the totals match;
#   3. an arm whose receiver class is proven and whose block is yield-free is the call alone.
#
# Modes (BR_MODE): all (default), generated (no mruby build), run (behaviour only).
# BR_TOOL_DIR names a copy of tools/bc2cpp (the mutants below); BC2CPP_BLOCK_ARM_REACH=0 is the kill
# switch under test. The behavioural half builds a full-core, a core-only and a 32-bit mrb_int mruby
# twice each (interpreted, and with the fixture compiled over the compiled core): minutes.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/block_arm_reach_check.rb

require 'etc'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
TOOL_DIR = ENV['BR_TOOL_DIR'] || File.join(ROOT, 'tools/bc2cpp')
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative 'mutant_pool'

MRUBY = File.join(ROOT, '3rd/mruby')
MRBC_PATH = ENV['MRBC'] || 'mrbc'
MODE = ENV['BR_MODE'] || 'all'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def tool?(name)
  system(name, '--version', out: File::NULL, err: File::NULL)
end

FIXTURE = <<~'RUBY'
  class BrFx
    def initialize; @cells = table; @acc = 0; @seen = []; end
    def table; [[1, 2, 3, 4, 5], [6, 7, 8, 9, 10]]; end

    # -- a block nested in an inlined loop body (the outer 2.times / 3.times / (1..n).each is inlined)
    def nested_each(rows); out = []; 2.times { |j| rows.each { |row| out << row[j] } }; out; end
    def nested_sel(rows); r = []; 3.times { |i| r << rows.select { |x| x > i } }; r; end
    def nested_map(n); r = []; (1..n).each { |i| r << [i, i + 1].map { |x| x * 2 } }; r; end
    def nested_ewi(rows); r = []; 2.times { |i| rows.each_with_index { |x, k| r << [i, k, x] } }; r; end
    def nested_hash(h); r = []; 2.times { |i| h.each { |k, v| r << [i, k, v] } }; r; end
    def nested_break(rows); out = []; 2.times { |j| rows.each { |row| break if row.nil?; out << row[j] } }; out; end
    def nested_raise(rows); 2.times { |j| rows.each { |row| raise ArgumentError, "bad #{j}" if row == :bad } }; :ok; end
    def nested_next(rows); out = []; 2.times { |j| rows.each { |row| next if row == :skip; out << [j, row] } }; out; end
    def nested_ivar(rows); @seen = []; 2.times { |j| rows.each { |row| @seen << [j, row] } }; @seen; end
    def nested_gc(rows); out = []; 3.times { |j| rows.each { |row| out << (row.to_s * 40); GC.start if j == 1 } }; out.size; end
    def nested_three(rows); r = 0; 2.times { |i| rows.each { |a| a.each { |b| r += b * (i + 1) } } }; r; end
    def nested_user(o); out = []; 2.times { |j| o.each { |x| out << [j, x] } }; out; end
    def nested_mutate(a); r = []; 2.times { |j| a.each { |x| r << x; a << x + 10 if a.size < 4 } }; r; end

    # -- a proven class that was a dynamic-only send because the arm chain was built twice
    # Nine parameters are past EACH_SPREAD_MAX (ADR 0376), so this stays a call; five would be an inlined loop.
    def patch; @acc = 0; @cells.each { |a, b, c, d, e, _f, _g, _h, _i| @acc += a * b + c + d + e }; @acc; end
    def patch_spread; @acc = 0; @cells.each { |a, b, c, d, e| @acc += a * b + c + d + e }; @acc; end
    def tmp_ewo; @cells.each_with_object({}) { |c, h| h[c[0]] = c.size }; end

    # -- the proven arm and its else
    def range_map(n); (1..n).map { |i| i * 2 }; end
    def range_break; (1..5).map { |i| break i * 10 if i == 3; i }; end
    def lit_each; s = 0; [1, 2, 3].each { |x| s += x }; s; end
    def unknown_each(a); s = 0; a.each { |x| s += x }; s; end
    def fiber_map; (1..3).map { |i| Fiber.yield i; i }; end
    def down(n); r = []; n.downto(1) { |i| r << i }; r; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = BrFx.new
  class BrArr < Array; end
  user = Object.new
  def user.each; yield 1; yield 2; end
  single = [7, 8]
  def single.each; yield :single; end
  single_rows = [[1, 2], [3, 4]]
  def single_rows.each; yield [9, 9]; end
  frozen = [[1, 2], [3, 4]].freeze
  big = (1..600).map { |i| [i, i + 1] }
  downer = Object.new
  def downer.downto(n); yield :user_downto; end
  hash = { a: 1, b: 2 }
  rows = [[1, 2], [3, 4], [5, 6]]
  cases = {
    nested_each: [rows, [], frozen, big, BrArr.new([[1, 2]]), single_rows, [[1], [2]]],
    nested_sel: [[1, 2, 3, 4], [], single, 1..5, hash],
    nested_map: [0, 1, 4],
    nested_ewi: [[:a, :b], [], single, hash, 1..3],
    nested_hash: [hash, {}, single, [[1, 2]]],
    nested_break: [rows, [[1, 2], nil, [3, 4]], []],
    nested_raise: [[1, 2], [1, :bad], []],
    nested_next: [[1, :skip, 2], []],
    nested_ivar: [rows, []],
    nested_gc: [rows, big.first(40)],
    nested_three: [rows, [[1, 2], [3]], [[]]],
    nested_user: [user, [5, 6], single, BrArr.new([8])],
    nested_mutate: [[1, 2], [1]],
    patch: [nil],
    tmp_ewo: [nil],
    range_map: [0, 1, 5],
    range_break: [nil],
    lit_each: [nil],
    unknown_each: [[1, 2, 3], [], 1..4, [1, 2, 3, 4], user, single, BrArr.new([4, 5])],
    down: [3, 0, downer, 2.5]
  }
  run = lambda do |label|
    cases.each do |name, inputs|
      inputs.each_with_index do |input, i|
        out = begin
          r = name == :patch || name == :tmp_ewo || name == :range_break || name == :lit_each ? fx.send(name) : fx.send(name, input)
          r.is_a?(Array) && r.size > 30 ? [:array, r.size, r.first, r.last] : r
        rescue => e
          [e.class, e.message]
        end
        puts "#{label} #{name}/#{i}: #{out.inspect}"
      end
    end
  end
  run.call('plain')
  if Object.const_defined?(:Fiber)
    f = Fiber.new do
      puts "fiber nested_each: #{fx.nested_each([[1, 2], [3, 4]]).inspect}"
      puts "fiber range_map: #{fx.range_map(3).inspect}"
      puts "fiber patch: #{fx.patch.inspect}"
      puts "fiber nested_user: #{fx.nested_user(user).inspect}"
      Fiber.yield :mid
      puts "fiber fiber_map: #{fx.fiber_map.inspect}"
      :done
    end
    puts "fiber resume: #{f.resume.inspect} #{f.resume.inspect} #{f.resume.inspect} #{f.resume.inspect} #{f.resume.inspect}" rescue puts "fiber: #{$!.class}"
    gen = Object.new
    def gen.each; Fiber.yield :from_each; yield 1; end
    f2 = Fiber.new { fx.nested_user(gen) }
    puts "fiber user each: #{f2.resume.inspect} #{f2.resume.inspect}" rescue puts "fiber user each: #{$!.class}"
    puts "fiber_map outside a fiber: #{(fx.fiber_map rescue $!.class).inspect}"
  end
  if GC.respond_to?(:interval_ratio=)
    GC.interval_ratio = 100
    GC.step_ratio = 200
    GC.generational_mode = false
  end
  run.call('stress')
  puts "end"
RUBY

OWNERS = BC2CPP_CORE_OWNERS + ['BrFx']

# -- generation ------------------------------------------------------------------------------

gems = NomethodReviewedProbe.wio_gems(ROOT)
native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
core_srcs = core_compiled_mrblib_srcs(ROOT)

generate = lambda do |source, name, closed: true, core: true, extra_env: {}|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => MRBC_PATH, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs),
            'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
            'ONLY_OWNERS' => OWNERS.join(',') }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    srcs = (core ? core_srcs : []) + [path]
    out, err, status = Open3.capture3(env.merge(extra_env), RbConfig.ruby, File.join(TOOL_DIR, 'bc2cpp.rb'), *srcs)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end

# The method's own body and the block cfuncs of it (file-scope functions named after it).
FN_RE = '^(?:static )?mrb_value \w+\(mrb_state\* M'
body_of = lambda do |code, fn|
  code[/^mrb_value BrFx_#{fn}_impl\(mrb_state\* M.*?(?=#{FN_RE}|\z)/m].to_s
end

# Every BLOCK_CORE_DIRECT chain of `text` names one receiver register in its class tests, its arm
# calls and its dynamic else.
chain_registers = lambda do |text|
  lines = text.lines
  lines.each_index.filter_map do |i|
    next unless lines[i].include?('// BLOCK_CORE_DIRECT :')

    window = []
    lines[(i + 1)..].each do |line|
      window << line
      break if line.include?('mrb_funcall_with_block(') || (line.include?('_impl(M, ') && lines[i].include?('no dynamic send'))
      break if window.size > 20
    end
    window.join.scan(/(?:mrb_(?:array|hash|range)_p\(|_impl\(M, |mrb_funcall_with_block\(M, )(r\d+|self)/).flatten.uniq
  end
end

run_generated = MODE != 'run' && tool?(MRBC_PATH)
puts '-- SKIP generated code: needs a host mrbc (set MRBC)' if MODE != 'run' && !run_generated

if run_generated
  puts 'generated code'
  new_code = generate.call(FIXTURE, 'br_new')
  old_code = generate.call(FIXTURE, 'br_old', extra_env: { 'BC2CPP_BLOCK_ARM_REACH' => '0' })
  nb = ->(fn) { body_of.call(new_code, fn) }
  ob = ->(fn) { body_of.call(old_code, fn) }
  direct_arm = /BLOCK_CORE_DIRECT :\w+\??[^\n]*\n\s+(?:if \([^\n]*\) \{|r\d+ = \w+_impl)/

  puts ' 1. blocks nested in an inlined loop body'
  %w[nested_each nested_sel nested_ewi nested_hash nested_ivar nested_next nested_raise nested_user nested_gc nested_mutate].each do |fn|
    check.call("#{fn}: the nested send has the exact-class arms and keeps the dynamic send as its else",
               nb.call(fn).match?(direct_arm) && nb.call(fn).include?('mrb_funcall_with_block('))
    check.call("#{fn}: the kill switch gives the dynamic send alone", !ob.call(fn).include?('BLOCK_CORE_DIRECT'))
  end
  check.call('the nested arm sits in the inlined body of the outer loop', nb.call('nested_each').include?('bc2cpp_times_i_'))
  check.call('a literal receiver nested in the loop is proven and leaves no dynamic send',
             nb.call('nested_map').match?(/BLOCK_CORE_DIRECT :map -- proven Array receiver, yield-free block/) &&
             !nb.call('nested_map').include?('mrb_funcall_with_block('))
  check.call('a block that breaks is not inlined into the loop; the outer loop keeps its own fallback',
             nb.call('nested_break').include?('BLOCK_FALLBACK :times') || nb.call('nested_break').include?('BLOCK_FALLBACK :each'))
  all_chains = chain_registers.call(new_code)
  check.call("every arm chain names one receiver register in tests, calls and else (#{all_chains.size} chains)",
             all_chains.size > 50 && all_chains.all? { |regs| regs.size == 1 })
  %w[nested_each nested_sel nested_ewi nested_hash nested_user].each do |fn|
    chains = chain_registers.call(nb.call(fn))
    check.call("#{fn}: the shifted receiver register is the same in the tests, the calls and the else",
               !chains.empty? && chains.all? { |regs| regs.size == 1 })
  end

  puts ' 2. a chain the compiler built twice'
  %w[patch tmp_ewo].each do |fn|
    check.call("#{fn}: a proven class is a direct arm (it was a dynamic-only send)",
               nb.call(fn).include?('BLOCK_CORE_DIRECT') && !ob.call(fn).include?('BLOCK_CORE_DIRECT'))
  end

  check.call('patch_spread: the same chain with five parameters is an inlined loop, not an arm (ADR 0376)',
             nb.call('patch_spread').include?('bc2cpp_row_') && !nb.call('patch_spread').include?('BLOCK_CORE_DIRECT'))

  puts ' 3. a proven arm and its else'
  check.call('a proven class and a yield-free block is the direct call alone',
             nb.call('range_map').match?(/BLOCK_CORE_DIRECT :map -- proven Range receiver, yield-free block[^\n]*\n\s+r\d+ = Enumerable_collect_impl\(M, r\d+, mrb_obj_value\(bc2cpp_blk_proc_\d+\)\);/) &&
             !nb.call('range_map').include?('mrb_funcall_with_block('))
  check.call('a literal Array each is the inlined loop, not an arm', !nb.call('lit_each').include?('BLOCK_CORE_DIRECT'))
  check.call('a block that may break keeps the root-context test and the dynamic else',
             nb.call('range_break').match?(/-- proven Range receiver at the root context.*\n\s+if \(M->c == M->root_c\) \{\n\s+r\d+ = Enumerable_collect_impl.*\} else \{\n\s+r\d+ = mrb_funcall_with_block\(/m))
  check.call('an unproven receiver keeps its class tests and the else even for a yield-free block',
             nb.call('unknown_each').match?(/if \(mrb_array_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->array_class\) \{.*else \{\n\s+r\d+ = mrb_funcall_with_block\(/m))
  check.call('a single arm whose receiver is not proven keeps its class test and the else, yield-free block or not',
             nb.call('down').match?(/if \(mrb_integer_p\(r\d+\)\) \{\n\s+r\d+ = \w*downto_impl\(M, .*\} else \{\n[^\n]*mrb_funcall_with_block\(/m))
  check.call('the kill switch keeps the dynamic else after a proven yield-free arm',
             ob.call('range_map').match?(/proven Range.*\n\s+if \(true\) \{\n\s+r\d+ = Enumerable_collect_impl.*\} else \{\n\s+r\d+ = mrb_funcall_with_block\(/m))

  puts ' 4. worlds that withdraw the arms'
  open_code = generate.call(FIXTURE, 'br_open', closed: false)
  check.call('without the closed world no arm is emitted', !open_code.include?('BLOCK_CORE_DIRECT'))
  nocore = generate.call(FIXTURE, 'br_nocore', core: false)
  check.call('without the compiled core no arm is emitted', !nocore.include?('BLOCK_CORE_DIRECT'))
  override = generate.call("#{FIXTURE}\nclass Array\n  def each(&b); 1; end\nend\n", 'br_override')
  check.call('a Ruby Array#each withdraws the Array arm of a nested send and leaves Hash and Range',
             !body_of.call(override, 'nested_each').include?('Array_each_impl') &&
             body_of.call(override, 'nested_each').include?('Hash_each_impl'))
  check.call('a Ruby Array#each leaves no BLOCK_CORE_DIRECT arm behind (it is a direct call, not a core arm)',
             !body_of.call(override, 'patch').include?('BLOCK_CORE_DIRECT'))
  # FIBER_BODY_GUARD (ADR 0333) lets a block-forwarding body compile, so a direct
  # Array#each call now appears where the receiver IS proven Array. The guard
  # widens what COMPILES, not what is PROVEN, and it must not re-enable the
  # core-direct arm for a Ruby body -- which the line above pins.
  off_guard = generate.call("#{FIXTURE}\nclass Array\n  def each(&b); 1; end\nend\n", 'br_noguard',
                            extra_env: { 'BC2CPP_FIBER_BODY_GUARD' => '0' })
  check.call('without the guard the same site keeps its by-name tail',
             !body_of.call(off_guard, 'patch').include?('Array_each_impl'))
  prepend = generate.call("#{FIXTURE}\nmodule BrShadow; def each; end; end\nclass Array\n  prepend BrShadow\nend\n", 'br_prepend')
  check.call('a prepend on Array withdraws every Array arm, nested ones too',
             !body_of.call(prepend, 'nested_each').include?('Array_each_impl') && !body_of.call(prepend, 'nested_sel').include?('mrb_array_p'))
  installer = generate.call("#{FIXTURE}\nclass BrFx\n  def install(n); Array.send(:define_method, n) { 1 }; end\nend\n", 'br_installer')
  check.call('a dynamic installer withdraws every arm', !installer.include?('BLOCK_CORE_DIRECT'))
  hash_override = generate.call("#{FIXTURE}\nclass Range\n  def map(&b); :mine; end\nend\n", 'br_range_override')
  check.call('a Ruby Range#map is called, not bypassed: no proven Range arm, the Range receiver reaches the user definition',
             !body_of.call(hash_override, 'range_map').include?('proven Range') &&
             !body_of.call(hash_override, 'range_map').include?('mrb_range_p(') &&
             body_of.call(hash_override, 'range_map').include?('Range_map_impl(M,'))
  subclass = generate.call("#{FIXTURE}\nclass BrArr2 < Array\n  def each; :sub; end\nend\n", 'br_subclass')
  check.call('a subclass override leaves the exact-class arm: its instances fail the class test and take the else',
             body_of.call(subclass, 'nested_each').include?('mrb_obj_ptr(') && body_of.call(subclass, 'nested_each').include?('c == M->array_class'))

  puts ' 5. direct_block_code? by name'
  require File.join(TOOL_DIR, 'bc2cpp')
  gen = CodeGen.allocate
  live = lambda do |*names|
    "  r1 = #{names.map { |n| "#{n}(M, r1)" }.join(' + ')};\n"
  end
  ENV.delete('BC2CPP_BLOCK_ARM_REACH')
  check.call('equal totals are accepted', gen.direct_block_code?(live.call('A_impl', 'B_impl'), 2, Hash.new(0).merge('A_impl' => 1, 'B_impl' => 1)))
  check.call('a dropped attempt (more counted than live) is accepted when every live call is covered by name',
             gen.direct_block_code?(live.call('A_impl', 'A_impl', 'A_impl'), 4, Hash.new(0).merge('A_impl' => 3, 'B_impl' => 1)))
  check.call('a live call of a name no direct_call_args call recorded is refused',
             !gen.direct_block_code?(live.call('A_impl', 'C_impl', 'A_impl'), 4, Hash.new(0).merge('A_impl' => 3, 'B_impl' => 1)))
  check.call('a name live more often than it was recorded is refused',
             !gen.direct_block_code?(live.call('A_impl', 'A_impl', 'A_impl'), 4, Hash.new(0).merge('A_impl' => 2, 'B_impl' => 2)))
  check.call('no recorded direct call is refused', !gen.direct_block_code?(live.call('A_impl'), 0, Hash.new(0)))
  check.call('a by-name funcall in the code is refused',
             !gen.direct_block_code?("  r1 = A_impl(M, r1);\n  mrb_funcall(M, r1, id, 0);\n", 2, Hash.new(0).merge('A_impl' => 2)))
  check.call('an #error marker is refused', !gen.direct_block_code?("  r1 = A_impl(M, r1);\n#error x\n", 2, Hash.new(0).merge('A_impl' => 2)))
  check.call('a commented call is not live, so its count does not matter', gen.direct_block_code?("  // B_impl(M, r1)\n  r1 = A_impl(M, r1);\n", 2, Hash.new(0).merge('A_impl' => 1, 'B_impl' => 1)))
  ENV['BC2CPP_BLOCK_ARM_REACH'] = '0'
  check.call('the kill switch returns to the exact count',
             !gen.direct_block_code?(live.call('A_impl', 'A_impl', 'A_impl'), 4, Hash.new(0).merge('A_impl' => 3, 'B_impl' => 1)))
  ENV.delete('BC2CPP_BLOCK_ARM_REACH')
end

# -- behaviour -------------------------------------------------------------------------------

ran_behaviour = false
if MODE != 'generated'
  unless tool?(MRBC_PATH) && tool?('rake') && tool?('g++') && File.exist?(File.join(MRUBY, 'Rakefile'))
    puts '-- SKIP behavioural comparison: needs a host mrbc, 3rd/mruby, rake and g++'
  else
    ran_behaviour = true
    GEM_RAKE = <<~'RAKE'
      require 'shellwords'
      ROOT = ENV.fetch('BC2CPP_ROOT')
      require "#{ROOT}/tools/bc2cpp/compiled_gems"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed"
      require "#{ROOT}/tools/bc2cpp/nomethod_reviewed_probe"

      MRuby::Gem::Specification.new('bc2cpp-reach-test') do |spec|
        spec.license = 'MIT'
        spec.author = 'rpg-maker-clone'
        spec.summary = 'harness: a closed-world fixture compiled with the compiled core'

        (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
          add_dependency gem_name if spec.build.gems.any? { |g| g.name == gem_name }
        end

        if ENV['BC2CPP_REACH_COMPILED'] == '1'
          generated = "#{build_dir}/br_gen.cpp"
          prerequisites = [*Dir["#{ROOT}/tools/bc2cpp/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
          file generated => prerequisites do
            FileUtils.mkdir_p build_dir
            gems = NomethodReviewedProbe.wio_gems(ROOT)
            srcs = core_compiled_mrblib_srcs(ROOT, spec.build.gems.map(&:name)) + [ENV.fetch('BC2CPP_REACH_FIXTURE')]
            native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
            env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'br', 'OUT_DIR' => build_dir,
                    'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + ['BrFx']).join(','), 'NATIVE_SRCS' => Shellwords.join(native),
                    'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)), 'SKIP_UNSUPPORTED' => '1',
                    'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                    'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                    NomethodReviewed::ALLOW_ENV => 'allow' }
            cmd = "#{RbConfig.ruby.shellescape} #{ROOT}/tools/bc2cpp/bc2cpp.rb #{srcs.map(&:shellescape).join(' ')} " \
                  "> #{generated.shellescape} 2> #{build_dir}/br.diag"
            sh env, cmd
          end
          file "#{dir}/src/register.cxx" => generated
        end
        cxx.include_paths << build_dir
        cxx.include_paths << "#{ROOT}/include"
      end
    RAKE

    register_cxx = lambda do |compiled|
      <<~CPP
        #include <mruby.h>
        #include <mruby/class.h>
        #include <mruby/compile.h>
        #{compiled ? '#include "br_gen.cpp"' : ''}

        static const char* const kFixture = R"BRFX(#{FIXTURE})BRFX";

        extern "C" void mrb_bc2cpp_reach_test_gem_init(mrb_state* M) {
          mrb_load_string(M, kFixture);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
        #{compiled ? '  bc2cpp_set_instance_tts(M);' : ''}
        #{compiled ? '  bc2cpp_register_owner_methods(M);' : ''}
        }

        extern "C" void mrb_bc2cpp_reach_test_gem_final(mrb_state*) {}
      CPP
    end

    # name => [gems, extra defines]. The core-only build is mruby's own mrblib with only mruby-io (for puts) on top: Fiber,
    # each_with_object and the other *-ext methods are absent, so the driver tolerates a NoMethodError in both builds.
    VARIANTS = {
      'full-core' => ["conf.gembox 'full-core'\n  conf.gem \"\#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio\"", ''],
      'core-only' => ["conf.gem core: 'mruby-bin-mruby'\n  conf.gem core: 'mruby-bin-mrbc'\n  conf.gem core: 'mruby-io'", ''],
      'int32' => ["conf.gembox 'full-core'\n  conf.gem \"\#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio\"",
                  "[conf.cc, conf.cxx].each { |t| t.defines << 'MRB_32BIT' << 'MRB_INT32' }"]
    }.freeze

    config_for = lambda do |variant|
      gems, defines = VARIANTS.fetch(variant)
      <<~RUBY
        MRuby::Build.new('host') do |conf|
          toolchain :gcc
          #{gems}
          conf.gem ENV['BC2CPP_HARNESS_GEM']
          #{defines}
          conf.cxx.flags << '-std=gnu++17'
          enable_cxx_exception
          enable_debug
          [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
        end
      RUBY
    end

    work = ENV['BC2CPP_REACH_DIR'] || Dir.mktmpdir('bc2cpp_block_reach')
    FileUtils.mkdir_p(work)
    File.write(File.join(work, 'fixture.rb'), FIXTURE)
    File.write(File.join(work, 'driver.rb'), DRIVER)

    build_and_run = lambda do |variant, compiled|
      name = "#{variant}_#{compiled ? 'compiled' : 'interpreted'}"
      File.write(File.join(work, "config_#{variant}.rb"), config_for.call(variant))
      gem_dir = File.join(work, "gem_#{name}")
      FileUtils.mkdir_p(File.join(gem_dir, 'src'))
      File.write(File.join(gem_dir, 'mrbgem.rake'), GEM_RAKE)
      File.write(File.join(gem_dir, 'src/register.cxx'), register_cxx.call(compiled))
      build = File.join(work, name)
      FileUtils.mkdir_p(File.join(build, 'repos/host'))
      FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(build, 'repos/host/mgem-list'))
      env = { 'BC2CPP_ROOT' => ROOT, 'MRUBY_CONFIG' => File.join(work, "config_#{variant}.rb"), 'MRUBY_BUILD_DIR' => build,
              'BC2CPP_HARNESS_GEM' => gem_dir, 'BC2CPP_REACH_COMPILED' => compiled ? '1' : '0',
              'BC2CPP_REACH_FIXTURE' => File.join(work, 'fixture.rb') }
      # ADR 0271 keeps a block's entry as an address in a 32-bit mrb_int slot; this 64-bit host truncates it.
      env['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if variant == 'int32'
      out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: MRUBY)
      File.write(File.join(work, "#{name}.log"), out)
      bin = File.join(build, 'host/bin/mruby')
      result = status.success? && File.exist?(bin) ? Open3.capture2e(bin, File.join(work, 'driver.rb')).first : nil
      gen = File.join(build, 'host/mrbgems/bc2cpp-reach-test/br_gen.cpp')
      arms = File.exist?(gen) ? File.read(gen) : ''
      FileUtils.rm_rf(build) unless ENV['BC2CPP_REACH_DIR']
      [result, out, arms]
    end

    (ENV['BR_VARIANTS'] || VARIANTS.keys.join(',')).split(',').each do |variant|
      puts "block arm reach (#{variant}): interpreted baseline"
      base_out, base_log, = build_and_run.call(variant, false)
      check.call("#{variant}: the interpreted build runs the driver", base_out && base_out.lines.last == "end\n")
      puts base_log.lines.last(15).join unless base_out
      puts "block arm reach (#{variant}): compiled fixture over the compiled core"
      comp_out, comp_log, gen_code = build_and_run.call(variant, true)
      check.call("#{variant}: the compiled build runs the driver", comp_out && comp_out.lines.last == "end\n")
      puts comp_log.lines.last(25).join unless comp_out
      next unless base_out && comp_out

      check.call("#{variant}: driver output, #{base_out.lines.size} lines, interpreted and compiled identical", base_out == comp_out)
      unless base_out == comp_out
        base_out.lines.zip(comp_out.lines).reject { |a, b| a == b }.first(10).each do |a, b|
          puts "    interpreted: #{a}    compiled:    #{b}"
        end
      end
      check.call("#{variant}: the harness compiled nested block arms (#{gen_code.scan('BLOCK_CORE_DIRECT').size} arms)",
                 gen_code.scan('BLOCK_CORE_DIRECT').size >= 10 && gen_code.include?('bc2cpp_times_i_'))
      if variant == 'full-core'
        check.call('full-core: the Fiber section ran and agreed', comp_out.include?('fiber resume:') && comp_out.include?('fiber user each:'))
      end
    end
    FileUtils.rm_rf(work) unless ENV['BC2CPP_REACH_DIR']
  end
end

# -- mutants ---------------------------------------------------------------------------------
#
# Each mutant is a copy of tools/bc2cpp with one soundness condition of ADR 0310 removed; the generated-code
# half of this script must fail against it.

MUTANTS = {
  'drop the else of a guarded proven arm' =>
    ['codegen_block_core_direct.rb', "sole_call = call if tests.empty? && exact_class && arms.size == 1 && block_arm_reach?",
     "sole_call = call if exact_class && arms.size == 1 && block_arm_reach?"],
  'drop the else of an unproven arm' =>
    ['codegen_block_core_direct.rb', "sole_call = call if tests.empty? && exact_class && arms.size == 1 && block_arm_reach?",
     "sole_call = call if unguarded && arms.size == 1 && block_arm_reach?"],
  'nested send keeps the unshifted destination register' =>
    ['codegen_arg_shapes.rb', "R\#{region[:dest_reg].to_i + offset} :", "R\#{region[:dest_reg].to_i} :"],
  'nested send passes the unshifted index and no trace' =>
    ['codegen_arg_shapes.rb', "sites = offset.zero? ? { idx: idx } : { idx: nil, trace_idx: idx, trace_reg_offset: offset }",
     "sites = { idx: idx }"],
  'by-name tally accepts any live name' =>
    ['codegen_arg_shapes.rb', "live_by_name.all? { |name, count| count <= direct_impls[name] }", "true"],
  'by-name tally ignores how often a name is live' =>
    ['codegen_arg_shapes.rb', "count <= direct_impls[name]", "direct_impls[name].positive?"],
  'the tally ignores the kill switch' =>
    ['codegen_arg_shapes.rb', "ENV['BC2CPP_BLOCK_ARM_REACH'] != '0'", "true"],
  'the nested glue is built without the owning definition' =>
    ['codegen_loop_inline.rb', "inline_offset: offset, owner_def: d)", "inline_offset: offset)"]
}.freeze

if ENV['BR_MUTANTS'] == '1' && MODE != 'run' && tool?(MRBC_PATH)
  puts 'mutants'
  # Each mutant is a copy of the generator with one soundness condition broken, run as its own
  # subprocess, so the pool runs several at a time (BC2CPP_JOBS; docs/ci.md, "Mutant pool").
  # This was one of the two slowest single commands in the bc2cpp check matrix as a serial loop,
  # and each mutant costs a full generated-code run of this check.
  mutate = lambda do |(name, (file, from, to))|
    Dir.mktmpdir('bc2cpp_reach_mutant') do |dir|
      FileUtils.cp_r(File.join(ROOT, 'tools/bc2cpp'), dir)
      path = File.join(dir, 'bc2cpp', file)
      text = File.read(path)
      next [:site_gone, file] unless text.include?(from)

      File.write(path, text.sub(from) { to })
      Bc2cppMutantPool.run({ 'BR_TOOL_DIR' => File.join(dir, 'bc2cpp'), 'BR_MODE' => 'generated',
                             'BR_MUTANTS' => '0', 'MRBC' => MRBC_PATH },
                          [RbConfig.ruby, __FILE__])
    end
  end

  # MUTANTS is a Hash; the pool indexes its items, so hand it the pairs in the order the
  # literal declares them.
  Bc2cppMutantPool.each_ordered(MUTANTS.to_a, work: mutate) do |(name, _spec), run|
    if run.is_a?(Array) && run.first == :site_gone
      check.call("mutant #{name}: the mutated text is still in #{run.last}", false)
      next
    end
    caught = !run.success && run.out.include?('FAIL')
    check.call("mutant killed: #{name}", caught)
    puts run.out.lines.grep(/FAIL|rror/).first(4).join unless caught
  end
end

if failures.empty?
  puts "bc2cpp block arm reach check: PASS#{ran_behaviour ? '' : ' (generated code only)'}"
else
  warn "bc2cpp block arm reach check: #{failures.size} failure(s)"
  exit 1
end
