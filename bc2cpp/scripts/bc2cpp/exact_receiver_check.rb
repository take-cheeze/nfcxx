#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check EXACT_CORE_RECEIVER (docs/adr/0280): a receiver that is provably exactly an Array, Hash,
# Range or String (a literal, a `*rest` array) or a fresh RGSS `Klass.new` lets the core-body arms
# of ADR 0253, 0257 and 0270 drop their class test and, when the body is frame-independent,
# their dynamic send.
#
#   - generated code: which receivers are proven, and every reason a proof is withheld (a
#     parameter, a reassignment, a branch join, a captured local, a Ruby override, a world
#     that can give an object a singleton class);
#   - behaviour: a fixture compiled together with the compiled core, linked into a full-core
#     mruby, prints what the interpreted build prints for the same driver, including calls made
#     from inside a Fiber, break/next/return/raise out of the proven block arms and receivers
#     that are almost literals (subclass, singleton, user `join`).
#
# The behavioural half builds two full-core mruby hosts (minutes), so it skips without
# 3rd/mruby, rake or g++. Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/exact_receiver_check.rb

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
  class ExFx
    def lit_join; [1, nil, "a", [2, [3]]].join; end
    def lit_join_sep; [1, 2].join(","); end
    def lit_join_var(sep); [1, 2].join(sep); end
    def lit_join_nil; [1, 2].join(nil); end
    def moved_compact; a = [1, nil, 2]; b = a; b.compact; end
    def rest_compact(*xs); xs.compact; end
    def rest_shift(*xs); [xs.shift, xs]; end
    def str_bytes; "abc".bytes; end
    def str_interp(x); "a#{x}".bytes; end
    def splat_compact(x); [1, *x].compact; end
    def index_lit(x); [1, 2, 3].index(x); end
    def pushed(a); b = [1]; b << a; b.join; end
    def param_join(a); a.join; end
    def param_compact(a); a.compact; end
    def reassigned(a); b = [1]; b = a; b.join; end
    def branch(c, a); b = c ? [1] : a; b.compact; end
    def upvar_write(a); b = [1]; f = proc { b = a }; f.call; b.join; end
    def loop_reassign(a); b = [1]; i = 0; while i < 2; b.join; b = a; i += 1; end; b; end
    def cond_assign(c); b = nil; b = [1] if c; b.join; end
    def while_assign(n); b = nil; i = 0; while i < n; b = [i]; i += 1; end; b.join; end
    def rescue_join; begin; raise 'x'; b = [1]; rescue; end; b.join; end
    def ensure_join; b = nil; begin; b = [1]; ensure; b.join; end; end
    def case_join(x); case x when 1 then b = [1] when 2 then b = [2] end; b.join; end
    def or_assign(a); b = a || [1]; b.join; end
    def block_each(a); b = [1]; a.each { |x| b = x }; b.join; end
    def masgn(a); b, c = [1], a; b.join; end
    def range_map(n); (1..n).map { |i| i * 2 }; end
    def range_select(n); (1..n).select { |i| i.even? }; end
    def range_break; (1..5).map { |i| break i if i == 3; i }; end
    def range_next; (1..5).select { |i| next false if i == 2; true }; end
    def range_raise; (1..3).map { |i| raise ArgumentError, "x#{i}" if i == 2; i }; rescue ArgumentError => e; e.message; end
    def range_return; (1..3).select { |i| return :early if i == 2; true }; :late; end
    def hash_sel; { a: 1, b: 2 }.select { |_k, v| v > 1 }; end
    def ary_ewo; [1, 2].each_with_object([]) { |x, m| m << x }; end
    def ary_reject(a); a.reject { |x| x.odd? }; end
    def nested; (1..3).map { |i| (1..i).map { |j| j * i } }; end
    def gc_pressure; s = 0; 200.times { s += (1..50).map { |i| i.to_s }.size }; s; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = ExFx.new
  class ExArr < Array; end
  class ExStr < String; end
  sub_join = ExArr.new([1, 2])
  def sub_join.join(*); "singleton"; end
  user_join = ExArr.new([3, 4])
  class ExArr
    def compact; :user_compact; end
  end
  cases = {
    lit_join: [[]], lit_join_sep: [[]], lit_join_nil: [[]],
    lit_join_var: [[nil], [","], ["::"], [:sym], [5], [Object.new.tap { |o| def o.to_str; "-"; end }]],
    moved_compact: [[]], str_bytes: [[]], str_interp: [[1], ["é"], [nil]],
    splat_compact: [[[nil, 2]], [[]], [nil], [1..3]], index_lit: [[1], [3], [9], [nil], [1.0]],
    pushed: [[7], [nil], [[1]]],
    param_join: [[[1, 2]], [[]], [sub_join], [user_join], [ExArr.new([5])]],
    param_compact: [[[1, nil]], [sub_join], [user_join]],
    reassigned: [[[8, 9]], [sub_join]], branch: [[true, [1]], [false, [nil, 2]], [false, user_join]],
    upvar_write: [[[4, 5]], [sub_join]],
    loop_reassign: [[[4, 5]], [nil], [sub_join]], cond_assign: [[true], [false]], while_assign: [[0], [3]],
    rescue_join: [[]], ensure_join: [[]], case_join: [[1], [2], [3]], or_assign: [[nil], [[7]], [false]],
    block_each: [[[1, 2]], [[]]], masgn: [[[5]]],
    range_map: [[0], [1], [5]], range_select: [[0], [6]], range_break: [[]], range_next: [[]],
    range_raise: [[]], range_return: [[]], hash_sel: [[]], ary_ewo: [[]],
    ary_reject: [[[1, 2, 3]], [{ a: 1 }], [1..4]], nested: [[]], gc_pressure: [[]]
  }
  puts "rest: #{fx.rest_compact(1, nil, 2).inspect} #{fx.rest_compact.inspect} #{fx.rest_shift(1, 2).inspect} #{fx.rest_shift.inspect}"
  cases.each do |name, inputs|
    inputs.each_with_index do |args, i|
      out = begin
        fx.send(name, *args).inspect
      rescue => e
        [e.class, e.message].inspect
      end
      puts "#{name}/#{i}: #{out}"
    end
  end
  # A Fiber takes the entry guard's bytecode path for every block arm.
  f = Fiber.new do
    puts "fiber range_map: #{fx.range_map(3).inspect}"
    Fiber.yield 1
    puts "fiber hash_sel: #{fx.hash_sel.inspect} #{fx.range_break.inspect} #{fx.nested.inspect}"
    2
  end
  puts "fiber resume: #{f.resume.inspect} #{f.resume.inspect}"
  puts "end"
RUBY

RG_FIXTURE = <<~'RUBY'
  module RGSS
    class Tilemap
    end
    class Sprite
    end
    class ExRg
      def tile(m); t = Tilemap.new; t.map_data = m; t; end
      def sprite_src(r); s = Sprite.new; s.src_rect = r; s.z = 3; s.z = r; s; end
      def sprite_param(s, r); s.src_rect = r; end
      def sprite_reassigned(o, r); s = Sprite.new; s = o; s.src_rect = r; end
    end
  end
RUBY

# -- generated code -----------------------------------------------------------------------

gems = NomethodReviewedProbe.wio_gems(ROOT)
native_srcs = Dir[File.join(ROOT, 'mruby-rgss/src/*.cxx')] + core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
core_srcs = core_compiled_mrblib_srcs(ROOT)

generate = lambda do |source, name, closed: true, core: true, owners: ['ExFx'], extra_env: {}|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => MRBC, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs),
            'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
            'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + owners).join(',') }.merge(extra_env)
    if closed
      env.merge!('BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                 'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                 NomethodReviewed::ALLOW_ENV => 'allow')
    end
    srcs = (core ? core_srcs : []) + [path]
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', *srcs)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end

body_of = lambda do |code, fn, owner = 'ExFx'|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

unless tool?(MRBC)
  puts '  SKIP: no host mrbc (set MRBC); generated-code and behavioural checks need it'
  exit 0
end

closed = generate.call(FIXTURE, 'ex_closed')
fn = ->(name) { body_of.call(closed, name) }
exact = ->(name) { fn.call(name).match?(/NATIVE_CORE_EXACT|NATIVE_CORE_DIRECT_REST/) }
dynamic = ->(name) { fn.call(name).include?('NATIVE_CORE_DIRECT') }

check.call('a literal Array#join has no class test and no send',
           fn.call('lit_join').match?(/NATIVE_CORE_EXACT :join .*\n\s+r\d+ = mrb_ary_join\(M, r\d+, mrb_nil_value\(\)\);/) &&
             !fn.call('lit_join').include?('bc2cpp_send('))
check.call('a String literal separator proves the argument guard', exact.call('lit_join_sep') &&
                                                                    !fn.call('lit_join_sep').include?('bc2cpp_send('))
check.call('a nil separator does too', exact.call('lit_join_nil'))
check.call('an unproven separator keeps its guard and the send, but not the class test',
           fn.call('lit_join_var').match?(/if \(\(mrb_nil_p\(r\d+\) \|\| mrb_string_p\(r\d+\)\)\) \{\n\s+r\d+ = mrb_ary_join\(.*\} else \{\n\s+r\d+ = bc2cpp_send\(/m) &&
             !fn.call('lit_join_var').include?('->c == M->array_class'))
check.call('a MOVE alias of a literal is exact', exact.call('moved_compact'))
check.call('a rest parameter is an exact Array', exact.call('rest_compact') && exact.call('rest_shift'))
check.call('a String literal is exact, also with an interpolated tail', exact.call('str_bytes') && exact.call('str_interp'))
check.call('a literal with a splat appended is exact', exact.call('splat_compact'))
check.call('a proven Array takes index with any argument', exact.call('index_lit'))
check.call('a push onto the literal leaves the alias exact', exact.call('pushed'))
check.call('the helpers an exact call needs are still emitted once',
           %w[bc2cpp_ary_compact bc2cpp_ary_index bc2cpp_str_bytes].all? { |h| closed.scan(/^static inline mrb_value #{h}\(/).size == 1 })

check.call('a parameter keeps the guarded arm with its send',
           dynamic.call('param_join') && !exact.call('param_join') && fn.call('param_join').include?('bc2cpp_send('))
check.call('a reassignment of the register withdraws the proof', dynamic.call('reassigned') && !exact.call('reassigned'))
check.call('a branch join withdraws the proof', dynamic.call('branch') && !exact.call('branch'))
check.call('a write from a captured block withdraws the proof', !exact.call('upvar_write'))
# A register that is nil on one path (ADR 0296) takes one nil test, then the exact call: never an
# unconditional one.
nil_tested = ->(name) { fn.call(name).include?('NILABLE_RECEIVER') }
check.call('a loop-carried, conditional, rescued, ensured or or-assigned register is not proven',
           %w[loop_reassign cond_assign while_assign rescue_join ensure_join case_join or_assign block_each].none? do |name|
             exact.call(name) && !nil_tested.call(name)
           end)
check.call('a register that is the literal or nil on two paths takes a nil test and then the exact call',
           %w[cond_assign while_assign].all? { |name| exact.call(name) && nil_tested.call(name) })
check.call('a multiple assignment that stores the literal directly is proven', exact.call('masgn'))

check.call('a literal Range with a block that may break gets one arm with no class test, and the else stays for Fibers',
           fn.call('range_break').match?(/BLOCK_CORE_DIRECT :map -- proven Range .*\n\s+if \(M->c == M->root_c\) \{\n\s+r\d+ = Enumerable_collect_impl\(.*\} else \{\n\s+r\d+ = mrb_funcall_with_block\(/m))
check.call('a literal Range with a yield-free block is the direct call alone: nothing for the else to answer (ADR 0310)',
           fn.call('range_map').match?(/BLOCK_CORE_DIRECT :map -- proven Range receiver, yield-free block.*\n\s+r\d+ = Enumerable_collect_impl\(/m) &&
             !fn.call('range_map').include?('mrb_funcall_with_block'))
check.call('a literal Hash and an Array literal get their own arm only',
           fn.call('hash_sel').match?(/proven Hash .*Hash_select_impl\(/m) && !fn.call('hash_sel').include?('Enumerable_find_all_impl') &&
             fn.call('ary_ewo').match?(/proven Array .*Enumerable_each_with_object_impl\(|proven Array .*Array_each_with_object_impl\(/m))
check.call('an unknown receiver keeps the three arms and their class tests',
           fn.call('ary_reject').include?('exact Array/Hash/Range') && fn.call('ary_reject').include?('mrb_range_p('))
check.call('break, next and return still catch around a proven arm',
           fn.call('range_break').include?('catch (bc2cpp_block_break&') && fn.call('range_return').include?('BLOCK_CORE_DIRECT'))

# ADR 0359: the literal and `*rest` proofs also hold inside a compiled core body, as CHECKED proofs: the
# arm sits behind the class test and its else is bc2cpp_guard_violation (scripts/bc2cpp/core_body_exact_check.rb
# runs it). Array#dig's `args.size` reads its own rest Array; Enumerable#uniq's `hash.values` reads a Hash literal.
core_exact = lambda do |code|
  body = body_of.call(code, 'dig', 'Array')
  body.include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array') && body.include?('CORE_BODY_EXACT_CHECKED :size -> Array') &&
    body.include?('(CORE_BODY_EXACT)')
end
check.call('a compiled core body proves its *rest Array and its literals, checked', core_exact.call(closed) &&
             body_of.call(closed, 'uniq', 'Enumerable').match?(/CORE_BODY_EXACT_CHECKED :values -> Hash.*CLOSED_WORLD_NATIVE_EXACT :values -> Hash/m))
check.call('no compiled core body keeps an unchecked proof',
           closed.scan(%r{^// (\S+#\S+) \(compiled from[^\n]*\n(.*?)(?=^// \S+#\S+ \(compiled from|\z)}m)
                 .none? { |name, text| !name.start_with?('ExFx#') && text.include?('unguarded proof') && !text.include?('CORE_BODY_EXACT_CHECKED') })
off = generate.call(FIXTURE, 'ex_core_off', extra_env: { 'BC2CPP_CORE_BODY_EXACT' => '0' })
check.call('BC2CPP_CORE_BODY_EXACT=0 leaves the core body with its tag chain', !core_exact.call(off) && !off.include?('CORE_BODY_EXACT'))

# A world where an object can gain a singleton class proves nothing. The first five only lose the
# unguarded proofs (the guarded arms stay); define_singleton_method is a global refusal already.
[['instance_eval', "def maker(o); o.instance_eval { 1 }; end", true],
 ['singleton_class', "def maker(o); o.singleton_class; end", true],
 ['define_singleton_method', "def maker(o); o.define_singleton_method(:x) { 1 }; end", false],
 ['a def on an object', "def maker; a = [1]; def a.other(*); 'x'; end; a; end", true],
 ['class << object', "def maker(o); class << o; def x; end; end; end", true],
 ['a Symbol naming one', "def maker(o); o.send(:singleton_class); end", true]].each do |what, body, guarded|
  code = generate.call("#{FIXTURE.sub(/^end\n\z/, '')}  #{body}\nend\n", 'ex_maker')
  proven = body_of.call(code, 'lit_join').include?('NATIVE_CORE_EXACT') || body_of.call(code, 'range_map').include?('proven')
  check.call("#{what} withdraws every proof of the world", !proven)
  check.call("#{what} withdraws the core body proofs too", !core_exact.call(code))
  check.call("#{what} withdraws the *rest Array arm too", !body_of.call(code, 'rest_compact').include?('NATIVE_CORE_DIRECT_REST'))
  check.call("#{what} leaves the guarded arms", body_of.call(code, 'lit_join').include?('NATIVE_CORE_DIRECT')) if guarded
end
allowed = generate.call("#{FIXTURE.sub(/^end\n\z/, '')}  def maker; o = Object.new; def o.x; 1; end; o; end\nend\nclass ExFxOpen\n  class << self\n    def z; end\n  end\n  def self.y; end\nend\n", 'ex_allowed')
check.call('a def on a fresh Object.new and the singleton of a class body do not', body_of.call(allowed, 'lit_join').include?('NATIVE_CORE_EXACT'))

override = generate.call("#{FIXTURE}\nclass Array\n  def join(sep = nil); 'x'; end\n  def compact; 1; end\nend\n", 'ex_override')
check.call('a Ruby Array#join or #compact withdraws the exact call as well',
           !body_of.call(override, 'lit_join').include?('NATIVE_CORE_EXACT') && !body_of.call(override, 'moved_compact').include?('NATIVE_CORE_EXACT') &&
             body_of.call(override, 'str_bytes').include?('NATIVE_CORE_EXACT'))
range_override = generate.call("#{FIXTURE}\nclass Enumerable\nend\nmodule Enumerable\n  def map(&b); 1; end\nend\n", 'ex_range_override')
check.call('a Ruby Enumerable#map withdraws the Range arm', !body_of.call(range_override, 'range_map').include?('Enumerable_collect_impl'))
open_code = generate.call(FIXTURE, 'ex_open', closed: false)
check.call('without the closed world nothing is proven, core bodies included', !core_exact.call(open_code) && !open_code.include?('NATIVE_CORE_EXACT') && !open_code.match?(/proven (?:Array|Hash|Range|String) receiver/))

rg = generate.call(RG_FIXTURE, 'ex_rgss', core: false, owners: ['RGSS::ExRg'])
rgfn = ->(name) { body_of.call(rg, name, 'RGSS__ExRg') }
check.call('a fresh RGSS::Tilemap.new calls the entry point with no class test',
           rgfn.call('tile').match?(/NATIVE_DIRECT_EXACT :map_data= .*\n\s+r\d+ = rgss::tilemap_set_map_data_direct\(M, r\d+, r\d+\);/) &&
             !rgfn.call('tile').include?('bc2cpp_native_class'))
sprite = rgfn.call('sprite_src')
check.call('an integer argument is converted as mrb_get_args does, with no guard and no send (ADR 0372)',
           sprite.match?(/NATIVE_DIRECT_EXACT :z= .*\n\s+\{\n\s+mrb_int bc2cpp_pu\d+_0 = mrb_as_int\(M, r\d+\);\n\s+r\d+ = rgss::object_z_set_direct\(/m) &&
             !sprite.include?('mrb_integer_p('))
check.call('a parameter or a reassigned register keeps the class-identity arm',
           rgfn.call('sprite_param').include?('bc2cpp_native_class == rgss::native_sprite_class()') &&
             rgfn.call('sprite_reassigned').include?('bc2cpp_native_class == rgss::native_sprite_class()') &&
             !rgfn.call('sprite_param').include?('NATIVE_DIRECT_EXACT'))
rg_maker = generate.call(RG_FIXTURE.sub("  class ExRg\n", "  class ExRg\n      def maker(o); o.instance_eval { 1 }; end\n"), 'ex_rgss_maker', core: false, owners: ['RGSS::ExRg'])
check.call('a singleton-making world keeps the class-identity arm', !rg_maker.include?('NATIVE_DIRECT_EXACT'))

# -- behaviour -------------------------------------------------------------------------------

unless tool?('rake') && tool?('g++') && File.exist?(File.join(MRUBY, 'Rakefile'))
  puts '  SKIP behavioural comparison: needs 3rd/mruby, rake and g++'
  abort "bc2cpp exact receiver check: #{failures.size} failure(s)" unless failures.empty?
  puts 'bc2cpp exact receiver check: PASS (generated code only)'
  exit 0
end

GEM_RAKE = <<~'RAKE'
  require 'shellwords'
  ROOT = ENV.fetch('BC2CPP_ROOT')
  require "#{ROOT}/tools/bc2cpp/compiled_gems"
  require "#{ROOT}/tools/bc2cpp/nomethod_reviewed"
  require "#{ROOT}/tools/bc2cpp/nomethod_reviewed_probe"

  MRuby::Gem::Specification.new('bc2cpp-exact-test') do |spec|
    spec.license = 'MIT'
    spec.author = 'rpg-maker-clone'
    spec.summary = 'harness: a closed-world fixture compiled with the compiled core'

    (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
      add_dependency gem_name if spec.build.gems.any? { |g| g.name == gem_name }
    end

    if ENV['BC2CPP_EXACT_COMPILED'] == '1'
      generated = "#{build_dir}/ex_gen.cpp"
      prerequisites = [*Dir["#{ROOT}/tools/bc2cpp/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
      file generated => prerequisites do
        FileUtils.mkdir_p build_dir
        gems = NomethodReviewedProbe.wio_gems(ROOT)
        srcs = core_compiled_mrblib_srcs(ROOT, spec.build.gems.map(&:name)) + [ENV.fetch('BC2CPP_EXACT_FIXTURE')]
        native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
        env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'ex', 'OUT_DIR' => build_dir,
                'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + ['ExFx']).join(','), 'NATIVE_SRCS' => Shellwords.join(native),
                'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)), 'SKIP_UNSUPPORTED' => '1',
                'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                NomethodReviewed::ALLOW_ENV => 'allow' }
        cmd = "#{RbConfig.ruby.shellescape} #{ROOT}/tools/bc2cpp/bc2cpp.rb --annotated #{srcs.map(&:shellescape).join(' ')} " \
              "> #{generated.shellescape} 2> #{build_dir}/ex.diag"
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
    #{compiled ? '#include "ex_gen.cpp"' : ''}

    static const char* const kFixture = R"EXFX(#{FIXTURE})EXFX";

    extern "C" void mrb_bc2cpp_exact_test_gem_init(mrb_state* M) {
      mrb_load_string(M, kFixture);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
    #{compiled ? '  bc2cpp_set_instance_tts(M);' : ''}
    #{compiled ? '  bc2cpp_register_owner_methods(M);' : ''}
    }

    extern "C" void mrb_bc2cpp_exact_test_gem_final(mrb_state*) {}
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

work = ENV['BC2CPP_EXACT_RECEIVER_DIR'] || Dir.mktmpdir('bc2cpp_exact_receiver')
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
          'BC2CPP_HARNESS_GEM' => gem_dir, 'BC2CPP_EXACT_COMPILED' => compiled ? '1' : '0',
          'BC2CPP_EXACT_FIXTURE' => File.join(work, 'fixture.rb') }.merge(Bc2cppCxx.rake_env)
  out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: MRUBY)
  File.write(File.join(work, "#{name}.log"), out)
  bin = File.join(build, 'host/bin/mruby')
  return [nil, out] unless status.success? && File.exist?(bin)

  [Open3.capture2e(bin, File.join(work, 'driver.rb')).first, out]
end

puts 'exact receiver: interpreted baseline'
base_out, base_log = build_and_run.call('interpreted', false)
check.call('the interpreted build runs the driver', base_out && base_out.lines.last == "end\n")
puts 'exact receiver: compiled fixture over the compiled core'
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
  generated = File.join(work, 'compiled/host/mrbgems/bc2cpp-exact-test/ex_gen.cpp')
  text = File.exist?(generated) ? File.read(generated) : ''
  check.call("the harness compiled the fixture with exact calls (#{text.scan('NATIVE_CORE_EXACT').size}) " \
             "and proven block arms (#{text.scan(/BLOCK_CORE_DIRECT :\S+ -- proven/).size})",
             text.include?('NATIVE_CORE_EXACT') && text.match?(/BLOCK_CORE_DIRECT :\S+ -- proven/))
end

FileUtils.rm_rf(work) unless ENV['BC2CPP_EXACT_RECEIVER_DIR']
if failures.empty?
  puts 'bc2cpp exact receiver check: PASS'
else
  warn "bc2cpp exact receiver check: #{failures.size} failure(s)"
  exit 1
end
