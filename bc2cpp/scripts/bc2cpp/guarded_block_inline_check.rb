#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check GUARDED_BLOCK_INLINE (docs/adr/0420): a literal-block send whose receiver class is NOT proven runs the
# block body as an inline loop behind an exact-class test (Array, Hash), with the ordinary BLOCK_CORE_DIRECT arms and
# dynamic send as its else.
#
#   - generated code: the guarded loop, the label after the send, the else path kept, and every reason the loop is
#     withheld (open world, a Ruby override or prepend, a dynamic installer, the kill switch, a proven receiver);
#   - behaviour: the fixture compiled with the compiled core, linked into a full-core mruby, prints what the
#     interpreted build prints (break/next with a value, return from the method, exceptions, mutation during
#     iteration, destructuring, captured locals, nested blocks, subclasses, singletons, user receivers, Fibers).
#
# GB_GENERATED_ONLY=1 skips the behavioural half. Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/guarded_block_inline_check.rb

require 'etc'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

ROOT = File.expand_path('../..', __dir__)
MRUBY = File.join(ROOT, '3rd/mruby')
MRBC = ENV['MRBC'] || 'mrbc'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def tool?(name)
  system(name, '--version', out: File::NULL, err: File::NULL)
end

FIXTURE = <<~'RUBY'
  class GbFx
    def each_sum(a); s = 0; a.each { |x| s += x }; s; end
    def each_value_of(a); a.each { |x| x }; end
    def each_break(a); a.each { |x| break x * 10 if x > 2 }; end
    def each_next(a); r = []; a.each { |x| next if x.odd?; r << x }; r; end
    def each_return(a); a.each { |x| return x if x > 1 }; :none; end
    def each_raise(a)
      a.each { |x| raise ArgumentError, "boom #{x}" if x == 2 }
      :done
    rescue ArgumentError => e
      e.message
    end
    def each_ensure(a, log); a.each { |x| log << x }; :ok; ensure log << :ens; end
    def each_push(a); r = []; a.each { |x| r << x; a << x + 10 if a.size < 5 }; r; end
    def each_delete(a); r = []; a.each { |x| r << x; a.delete(x) }; r; end
    def each_clear(a); r = []; a.each { |x| r << x; a.clear }; r; end
    def each_shift(a); r = []; a.each { |x| r << x; a.shift }; r; end
    def each_destructure(a); r = []; a.each { |x, (y, z)| r << [x, y, z] }; r; end
    def each_pair2(a); r = []; a.each { |k, v| r << [k, v] }; r; end
    def each_one(a); r = []; a.each { |k| r << k }; r; end
    def each_nested(a); r = 0; a.each { |x| a.each { |y| r += x * y } }; r; end
    def each_nested_mixed(a, n); a.map { |x| [1, 2].map { |y| x * y + n } }; end
    def each_escape(a); a.map { |x| -> { x } }.map(&:call); end
    def each_ivar(a); @acc = []; a.each { |x| @acc << x }; @acc; end
    def each_self(a); a.each { |x| helper(x) }; @seen; end
    def helper(x); (@seen ||= []) << x; end
    def each_index_sum(a); s = 0; a.each_index { |i| s += i }; s; end
    def each_index_push(a); r = []; a.each_index { |i| r << i; a << 0 if a.size < 4 }; r; end
    def ewi(a); r = []; a.each_with_index { |x, i| r << [x, i] }; r; end
    def ewi_break(a); a.each_with_index { |x, i| break [x, i] if i == 1 }; end
    def map_sq(a); a.map { |x| x * x }; end
    def map_next(a); a.map { |x| next 0 if x.odd?; x * 2 }; end
    def map_break(a); a.map { |x| break :stop if x > 2; x }; end
    def map_return(a); a.map { |x| return :early if x > 2; x }; :late; end
    def map_mut(a); a.map { |x| a << 9 if a.size < 4; x }; end
    def select_even(a); a.select { |x| x.even? }; end
    def reject_odd(a); a.reject { |x| x.odd? }; end
    def find_big(a); a.find { |x| x > 1 }; end
    def flat(a); a.flat_map { |x| [x, x] }; end
    def fmap(a); a.filter_map { |x| x * 2 if x.odd? }; end
    def any_all(a); [a.any? { |x| x > 2 }, a.all? { |x| x > 0 }, a.none? { |x| x > 5 }]; end
    def count_odd(a); a.count { |x| x.odd? }; end
    def inject_sum(a); a.inject(0) { |m, x| m + x }; end
    def sym_map(a); a.map(&:to_s); end
    def sym_select(a); a.select(&:odd?); end
    def hash_each(h); r = []; h.each { |k, v| r << "#{k}=#{v}" if v }; r; end
    def literal_hash_each; r = []; { a: 1, b: 2 }.each { |k, v| r << k if v }; r; end
    def hash_each_break(h); h.each { |k, v| break k if v > 1 }; end
    def hash_each_value(h); s = 0; h.each_value { |v| s += v }; s; end
    def hash_each_key(h); r = []; h.each_key { |k| r << k }; r; end
    def hash_each_add(h); r = []; h.each { |k, v| r << k; h[:z] = 1 }; r; end
    def user_each(o); r = []; o.each { |x| r << x }; r; end
    def rest_each(*xs); r = []; xs.each { |x| r << x * 2 }; r; end
    def literal_each; r = []; [1, 2, 3].each { |x| r << x }; r; end
    def user_map(o); o.map { |x| x }; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = GbFx.new
  class GbArr < Array
    def each; yield :sub; self; end
  end
  class GbArr2 < Array; end
  user = Object.new
  def user.each; yield 1; yield 2; end
  def user.map; yield 3; :user_map; end
  singleton = [7, 8]
  def singleton.each; yield :single; end
  def singleton.map; [:single_map]; end
  frozen = [1, 2, 3].freeze
  pairs = [[1, 2], [3, [4, 5]], 6, [7]]
  big = (1..3000).to_a
  hash = { a: 1, b: 2, c: 3 }
  cases = {
    each_sum: [[1, 2, 3, 4], [], [5], frozen, big, GbArr2.new([1, 2]), 1..4, nil],
    each_value_of: [[1, 2], hash, []],
    each_break: [[1, 2, 3, 4], [1, 2], []],
    each_next: [[1, 2, 3, 4, 5, 6], []],
    each_return: [[1, 2, 3], [0, 1]],
    each_raise: [[1, 2, 3], [1]],
    each_push: [[1, 2], [1, 2, 3, 4, 5, 6]],
    each_delete: [[1, 2, 3, 4], [5, 5, 5]],
    each_clear: [[1, 2, 3], []],
    each_shift: [[1, 2, 3, 4]],
    each_destructure: [pairs, [[1, [2, 3]]], []],
    each_pair2: [pairs, hash, [[1, 2, 3]], []],
    each_one: [pairs, hash],
    each_nested: [[1, 2, 3], []],
    each_escape: [[1, 2, 3]],
    each_ivar: [[1, 2, 3]],
    each_self: [[4, 5]],
    each_index_sum: [[5, 5, 5], []],
    each_index_push: [[1, 2]],
    ewi: [%w[a b c], [], hash],
    ewi_break: [%w[a b c], %w[a]],
    map_sq: [[1, 2, 3], [], big.first(50), hash, 1..4, user, singleton],
    map_next: [[1, 2, 3, 4]],
    map_break: [[1, 2, 3, 4], [1]],
    map_return: [[1, 2, 3, 4], [1]],
    map_mut: [[1, 2]],
    select_even: [[1, 2, 3, 4], hash, 1..8],
    reject_odd: [[1, 2, 3, 4], 1..8],
    find_big: [[1, 2, 3], [], 1..4],
    flat: [[1, 2], 1..2],
    fmap: [[1, 2, 3], []],
    any_all: [[1, 2, 3], [0, 1], [], 1..3],
    count_odd: [[1, 2, 3], []],
    inject_sum: [[1, 2, 3], [], 1..4],
    sym_map: [[1, 2], [], nil],
    sym_select: [[1, 2, 3], []],
    hash_each: [hash, {}, [[1, 2]]],
    hash_each_break: [hash, {}],
    hash_each_value: [hash, {}],
    hash_each_key: [hash, {}],
    user_each: [user, [1, 2], singleton, GbArr.new([3, 4]), GbArr2.new([5, 6]), nil, 1],
    user_map: [user, [1, 2], singleton, GbArr2.new([8])]
  }
  puts "rest_each: #{fx.rest_each(1, 2, 3).inspect} #{fx.rest_each.inspect} #{fx.literal_each.inspect} #{fx.literal_hash_each.inspect}"
  cases.each do |name, inputs|
    inputs.each_with_index do |input, i|
      input = input.dup if input.is_a?(Array) && !input.frozen? && !input.equal?(big)
      out = begin
        r = fx.send(name, input)
        r.is_a?(Array) && r.size > 30 ? [:array, r.size, r.first, r.last] : r
      rescue => e
        [e.class, e.message]
      end
      puts "#{name}/#{i}: #{out.inspect}"
    end
  end
  hash_mut = { a: 1, b: 2 }
  puts "hash_each_add: #{(fx.hash_each_add(hash_mut) rescue [$!.class, $!.message]).inspect}"
  log = []
  puts "each_ensure: #{fx.each_ensure([1, 2], log).inspect} #{log.inspect}"
  log = []
  puts "each_ensure raise: #{(fx.each_ensure(nil, log) rescue $!.class).inspect} #{log.inspect}"
  puts "each_ensure sub: #{fx.each_ensure(GbArr.new([1]), log = []).inspect} #{log.inspect}"
  puts "each_nested_mixed: #{fx.each_nested_mixed([1, 2], 10).inspect}"
  f = Fiber.new do
    puts "fiber each_sum: #{fx.each_sum([1, 2, 3]).inspect}"
    Fiber.yield 1
    puts "fiber map_sq: #{fx.map_sq([4, 5]).inspect}"
    2
  end
  puts "fiber resume: #{f.resume.inspect} #{f.resume.inspect}"
  puts "end"
RUBY

# -- generated code -----------------------------------------------------------------------

gems = NomethodReviewedProbe.wio_gems(ROOT)
native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
core_srcs = core_compiled_mrblib_srcs(ROOT)

generate = lambda do |source, name, closed: true, core: true, hot: nil, extra: {}|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => MRBC, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs),
            'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
            'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + ['GbFx']).join(',') }
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    env.merge!(extra)
    srcs = (core ? core_srcs : []) + [path]
    out, err, status = Open3.capture3(env, RbConfig.ruby, ENV.fetch('BC2CPP_TOOL') { File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb') }, '--annotated', *srcs)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end

body_of = lambda do |code, fn|
  code[/^mrb_value GbFx_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

unless tool?(MRBC)
  puts "  SKIP: no host mrbc (set MRBC); generated-code and behavioural checks need it"
  exit 0
end

closed = generate.call(FIXTURE, 'gb_closed')
body = ->(code, fn) { body_of.call(code, fn) }
guarded = ->(code, fn) { body.call(code, fn).scan('// GUARDED_BLOCK_INLINE').size }
GUARD_ARRAY = 'M->c == M->root_c && mrb_array_p(r%d) && mrb_obj_ptr(r%d)->c == M->array_class'

each_break = body.call(closed, 'each_break')
check.call('each on an unknown receiver runs an inline loop behind the exact-Array test',
           each_break.match?(/GUARDED_BLOCK_INLINE :each .*\n\s+if \(M->c == M->root_c && mrb_array_p\(r(\d+)\) && mrb_obj_ptr\(r\1\)->c == M->array_class\) \{\n.*bc2cpp_each_i_\d+ < RARRAY_LEN\(r\1\)/m))
check.call('the guarded loop jumps over the send: its label comes after the send of the else path',
           (m = each_break.match(/goto (Lbc2cpp_guarded_end_\d+);/)) &&
           each_break[each_break.index("goto #{m[1]}")...each_break.index("#{m[1]}:;")].match?(/mrb_funcall_with_block|_impl\(M, /))
check.call('the ordinary send stays as the else: BLOCK_FALLBACK (or the core arms) and the dynamic call are still emitted',
           each_break.include?('mrb_funcall_with_block') && each_break.include?('BLOCK_FALLBACK'))
check.call('a break in the guarded loop writes the destination register and leaves the loop (no throw)',
           each_break.index('GUARDED_BLOCK_INLINE') < each_break.index('Lbc2cpp_each_end_') &&
           !each_break[/GUARDED_BLOCK_INLINE.*?goto Lbc2cpp_guarded_end/m].include?('bc2cpp_block_break'))
%w[each_sum each_next each_return each_push each_destructure each_pair2 each_nested ewi map_sq map_next select_even
   reject_odd find_big flat fmap any_all count_odd sym_map sym_select hash_each_value hash_each_key each_index_sum].each do |fn|
  check.call("#{fn}: guarded inline loop", guarded.call(closed, fn).positive?)
end
check.call('each with a |k, v| block gets an Array (spread) loop and a Hash loop, each behind its own class test',
           guarded.call(closed, 'hash_each') == 2 && body.call(closed, 'hash_each').include?('mrb_hash_p(') &&
           body.call(closed, 'hash_each').scan(/goto Lbc2cpp_guarded_end_\d+;/).size == 2)
check.call('a rest parameter is a proven Array: the plain inlined loop, no guard and no send',
           guarded.call(closed, 'rest_each').zero? && !body.call(closed, 'rest_each').include?('mrb_funcall_with_block') &&
           !body.call(closed, 'rest_each').include?('BLOCK_CORE_DIRECT'))
check.call('a Hash literal is proven Hash: no Array guard in front of its Hash loop',
           guarded.call(closed, 'literal_hash_each').zero? && !body.call(closed, 'literal_hash_each').include?('mrb_funcall_with_block'))
hash_each = body.call(closed, 'hash_each')
check.call('the Array and the Hash loop over one block keep their own labels and nested functions',
           hash_each.include?('_A_') && hash_each.include?('_H_') && hash_each.scan(/^\s*(LBLK\d+_[AH]_\d+):;/).flatten.then { |l| l.uniq == l && l.size >= 2 })
check.call('a break in an each_with_index block declares the flag it sets',
           body.call(closed, 'ewi_break').match?(/mrb_bool bc2cpp_collect_broke_(\d+) = FALSE;.*bc2cpp_collect_broke_\1 = TRUE;/m))
check.call('an Array literal is proven too', guarded.call(closed, 'literal_each').zero? && !body.call(closed, 'literal_each').include?('mrb_funcall_with_block'))
check.call('the Hash loop is behind the exact-Hash test', hash_each.include?('mrb_hash_p(r') && hash_each.match?(/mrb_obj_ptr\(r\d+\)->c == M->hash_class\) \{\n.*heach/m))
check.call('user receivers are unproven and get the guard like any other', guarded.call(closed, 'user_each').positive?)
functions = closed.split(/^(?=(?:static )?mrb_value \w+\(mrb_state\* M)/)
check.call('every guarded loop is paired with exactly one label in its own function',
           functions.all? { |f| f.scan(/goto (Lbc2cpp_guarded_end_\d+);/).flatten.uniq.all? { |l| f.scan("#{l}:;").size == 1 } } &&
           functions.any? { |f| f.include?('goto Lbc2cpp_guarded_end_') })
check.call('the root-context test is in every guard', closed.scan(/\/\/ GUARDED_BLOCK_INLINE[^\n]*\n\s+if \((.*?)\) \{/).all? { |(t)| t.start_with?('M->c == M->root_c && ') })

no_core_direct = generate.call(FIXTURE, 'gb_no_core_direct', extra: { 'BC2CPP_BLOCK_CORE_DIRECT' => '0' })
check.call('BC2CPP_BLOCK_CORE_DIRECT=0 (no arms to fall back on) removes the guarded loops too', !no_core_direct.include?('GUARDED_BLOCK_INLINE'))
off = generate.call(FIXTURE, 'gb_off', closed: true, extra: { 'BC2CPP_GUARDED_BLOCK_INLINE' => '0' })
check.call('BC2CPP_GUARDED_BLOCK_INLINE=0 removes every guarded loop and changes nothing else', !off.include?('GUARDED_BLOCK_INLINE') && off.include?('BLOCK_CORE_DIRECT'))
open_code = generate.call(FIXTURE, 'gb_open', closed: false)
check.call('without the closed world no guarded loop is emitted', !open_code.include?('GUARDED_BLOCK_INLINE'))
nocore = generate.call(FIXTURE, 'gb_nocore', core: false)
check.call('without the compiled core no guarded loop is emitted', !nocore.include?('GUARDED_BLOCK_INLINE'))

override = generate.call("#{FIXTURE}\nclass Array\n  def each(&b); 1; end\nend\n", 'gb_override')
check.call('a Ruby Array#each withdraws the Array each loop but not the Array map loop',
           guarded.call(override, 'each_sum').zero? && guarded.call(override, 'map_sq').positive?)
prepend = generate.call("#{FIXTURE}\nmodule GbShadow; def each; end; def map; end; end\nclass Array\n  prepend GbShadow\nend\n", 'gb_prepend')
check.call('a prepend on Array withdraws every Array loop', guarded.call(prepend, 'each_sum').zero? && guarded.call(prepend, 'map_sq').zero?)
hash_override = generate.call("#{FIXTURE}\nclass Hash\n  def each_key(&b); 1; end\nend\n", 'gb_hash_override')
check.call('a Ruby Hash#each_key withdraws the Hash loop of each_key only',
           guarded.call(hash_override, 'hash_each_key').zero? && guarded.call(hash_override, 'hash_each_value').positive?)
installer = generate.call("#{FIXTURE}\nclass GbFx\n  def install(n); Array.send(:define_method, n) { 1 }; end\nend\n", 'gb_installer')
check.call('a dynamic installer withdraws every loop', !installer.include?('GUARDED_BLOCK_INLINE'))
subclass = generate.call("#{FIXTURE}\nclass GbSub < Array\n  def each; yield :s; end\nend\n", 'gb_sub')
check.call('an Array subclass keeps the loops: the exact-class test sends its instances to the else',
           guarded.call(subclass, 'each_sum').positive?)

# -- behaviour -------------------------------------------------------------------------------

unless ENV['GB_GENERATED_ONLY'] != '1' && tool?('rake') && tool?('g++') && File.exist?(File.join(MRUBY, 'Rakefile'))
  puts '  SKIP behavioural comparison: GB_GENERATED_ONLY=1, or no 3rd/mruby, rake or g++'
  abort "bc2cpp guarded block inline check: #{failures.size} failure(s)" unless failures.empty?
  puts 'bc2cpp guarded block inline check: PASS (generated code only)'
  exit 0
end

GEM_RAKE = <<~'RAKE'
  require 'shellwords'
  ROOT = ENV.fetch('BC2CPP_ROOT')
  require "#{ROOT}/tools/bc2cpp/compiled_gems"
  require "#{ROOT}/tools/bc2cpp/nomethod_reviewed"
  require "#{ROOT}/tools/bc2cpp/nomethod_reviewed_probe"

  MRuby::Gem::Specification.new('bc2cpp-guarded-test') do |spec|
    spec.license = 'MIT'
    spec.author = 'rpg-maker-clone'
    spec.summary = 'harness: a closed-world fixture compiled with the compiled core'

    (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
      add_dependency gem_name if spec.build.gems.any? { |g| g.name == gem_name }
    end

    if ENV['BC2CPP_GB_COMPILED'] == '1'
      generated = "#{build_dir}/gb_gen.cpp"
      prerequisites = [*Dir["#{ROOT}/tools/bc2cpp/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
      file generated => prerequisites do
        FileUtils.mkdir_p build_dir
        gems = NomethodReviewedProbe.wio_gems(ROOT)
        srcs = core_compiled_mrblib_srcs(ROOT, spec.build.gems.map(&:name)) + [ENV.fetch('BC2CPP_GB_FIXTURE')]
        native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
        env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'gb', 'OUT_DIR' => build_dir,
                'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + ['GbFx']).join(','), 'NATIVE_SRCS' => Shellwords.join(native),
                'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)), 'SKIP_UNSUPPORTED' => '1',
                'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                NomethodReviewed::ALLOW_ENV => 'allow' }
        cmd = "#{RbConfig.ruby.shellescape} #{ROOT}/tools/bc2cpp/bc2cpp.rb --annotated #{srcs.map(&:shellescape).join(' ')} " \
              "> #{generated.shellescape} 2> #{build_dir}/gb.diag"
        sh env, cmd
        # The generated register function covers the compiled core only; the fixture's own entry points are
        # registered from the diagnostics, as the other fixture checks do (fixture_runtime.rb registrations).
        entries = File.read("#{build_dir}/gb.diag").split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                      .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity (\d+)\)(.*)$})
        regs = entries.filter_map do |entry, owner, name, _arity, _extra|
          next unless owner == 'GbFx'

          "  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"GbFx\"))), #{name.dump}, #{entry}, MRB_ARGS_ANY());"
        end
        raise 'no GbFx entry points registered' if regs.empty?

        File.write("#{build_dir}/gb_reg.inc", "#{regs.join("\n")}\n")
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
    #{compiled ? '#include "gb_gen.cpp"' : ''}

    static const char* const kFixture = R"GBFX(#{FIXTURE})GBFX";

    extern "C" void mrb_bc2cpp_guarded_test_gem_init(mrb_state* M) {
      mrb_load_string(M, kFixture);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
    #{compiled ? '  bc2cpp_set_instance_tts(M);' : ''}
    #{compiled ? '  bc2cpp_register_owner_methods(M);' : ''}
    #{compiled ? '#include "gb_reg.inc"' : ''}
    }

    extern "C" void mrb_bc2cpp_guarded_test_gem_final(mrb_state*) {}
  CPP
end

CONFIG_RB = <<~'RUBY'
  MRuby::Build.new('host') do |conf|
    toolchain :gcc
    conf.gembox 'full-core'
    conf.gem "#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio"
    conf.gem ENV['BC2CPP_HARNESS_GEM']
    conf.cxx.flags << '-std=gnu++17'
    enable_cxx_exception
    enable_debug
    [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
  end
RUBY

work = ENV['BC2CPP_GUARDED_INLINE_DIR'] || Dir.mktmpdir('bc2cpp_guarded_inline')
FileUtils.mkdir_p(work)
File.write(File.join(work, 'config.rb'), CONFIG_RB)
File.write(File.join(work, 'fixture.rb'), FIXTURE)
File.write(File.join(work, 'driver.rb'), DRIVER)

build_and_run = lambda do |name, compiled|
  gem_dir = File.join(work, "gem_#{name}")
  FileUtils.mkdir_p(File.join(gem_dir, 'src'))
  File.write(File.join(gem_dir, 'mrbgem.rake'), GEM_RAKE)
  File.write(File.join(gem_dir, 'src/register.cxx'), register_cxx.call(compiled))
  build = File.join(work, name)
  FileUtils.mkdir_p(File.join(build, 'repos/host'))
  FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(build, 'repos/host/mgem-list'))
  env = { 'BC2CPP_ROOT' => ROOT, 'MRUBY_CONFIG' => File.join(work, 'config.rb'), 'MRUBY_BUILD_DIR' => build,
          'BC2CPP_HARNESS_GEM' => gem_dir, 'BC2CPP_GB_COMPILED' => compiled ? '1' : '0',
          'BC2CPP_GB_FIXTURE' => File.join(work, 'fixture.rb') }.merge(Bc2cppCxx.rake_env)
  out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: MRUBY)
  File.write(File.join(work, "#{name}.log"), out)
  bin = File.join(build, 'host/bin/mruby')
  return [nil, out] unless status.success? && File.exist?(bin)

  [Open3.capture2e(bin, File.join(work, 'driver.rb')).first, out]
end

puts 'guarded inline: interpreted baseline'
base_out, base_log = build_and_run.call('interpreted', false)
check.call('the interpreted build runs the driver', base_out && base_out.lines.last == "end\n")
puts 'guarded inline: compiled fixture over the compiled core'
comp_out, comp_log = build_and_run.call('compiled', true)
check.call('the compiled build runs the driver', comp_out && comp_out.lines.last == "end\n")
puts base_log.lines.last(15).join unless base_out
puts comp_log.lines.last(25).join unless comp_out

if base_out && comp_out
  check.call("driver output: #{base_out.lines.size} lines, interpreted and compiled identical", base_out == comp_out)
  unless base_out == comp_out
    base_out.lines.zip(comp_out.lines).reject { |a, b| a == b }.first(10).each do |a, b|
      puts "    interpreted: #{a}    compiled:    #{b}"
    end
  end
  diag = File.join(work, 'compiled/host/mrbgems/bc2cpp-guarded-test/gb.diag')
  arms = File.exist?(diag.sub('gb.diag', 'gb_gen.cpp')) ? File.read(diag.sub('gb.diag', 'gb_gen.cpp')).scan('GUARDED_BLOCK_INLINE').size : 0
  check.call("the harness compiled the fixture with guarded loops (#{arms})", arms.positive?)
end

FileUtils.rm_rf(work) unless ENV['BC2CPP_GUARDED_INLINE_DIR']
if failures.empty?
  puts 'bc2cpp guarded block inline check: PASS'
else
  warn "bc2cpp guarded block inline check: #{failures.size} failure(s)"
  exit 1
end
