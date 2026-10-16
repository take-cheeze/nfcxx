#!/usr/bin/env ruby
# frozen_string_literal: true

# Check BLOCK_RETURNS (tools/bc2cpp/block_returns.rb, codegen_block_returns.rb, docs/adr/0475): RBS declarations of
# methods that return their block's value (`[T] (...) { (...) -> T } -> T`) or their receiver (`{ ... } -> self`).
#
#   host     the declaration shapes BlockReturns.classify accepts and the ones it reports; the native source scan on
#            profiler.cxx and on mutants of it (a return that is not the yield, a self-changing yield, an escaping
#            block, a wrong yield arity); a reviewed native entry is accepted only with the file's SHA-256; the Ruby
#            body check on hand-compiled bodies (when MRBC is set);
#   fixture  bc2cpp.rb on a small closed world (the wio world plus mruby-object-ext, for Kernel#tap/then): a
#            generic declaration proves a call's class (RETURN_CLASS_TABLE), natively (RGSS::Profiler.section/frame)
#            and in Ruby (a program method, tap, then, yield_self), through nested blocks; the block's self is the
#            caller's (BLOCK_SELF, through RBS_CHECKED_PARAMS); refused sites (a breaking block, an undeclared second
#            definition, an optional block) prove nothing; false declarations, Ruby and native, fail the build with
#            TC1010 (DECLARED_RETURN_CHECK).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/generic_block_return_check.rb   (without MRBC only the host half runs)

require 'digest'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'rbs'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/block_returns'
require_relative '../../tools/bc2cpp/rbs_signatures'
require_relative '../../tools/bc2cpp/wio_world_env'

ROOT = File.expand_path('../..', __dir__)
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# BlockReturns entries of one signature text (as RbsSignatures loads it).
entries_of = lambda do |text, dir_name: 'bc2cpp'|
  Dir.mktmpdir do |dir|
    sig = File.join(dir, 'sig', dir_name)
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'x.rbs'), text)
    BlockReturns.from_signatures(RbsSignatures.load([dir], display_root: dir))
  end
end

puts '== declaration shapes'
shapes = entries_of.call(<<~RBS).to_h { |e| [e.name, e] }
  class C
    def value: [T] (Integer a) { (Integer) -> T } -> T
    def me: () { (Integer) -> void } -> self
    def opt: [T] () ?{ () -> T } -> T
    def bound: [T < Integer] () { () -> T } -> T
    def leak: [T] (T a) { () -> T } -> T
    def selfed: [T] () { () [self: Integer] -> T } -> T
    def rest: [T] (*Integer) { () -> T } -> T
    def blockrest: [T] () { (*Integer) -> T } -> T
    def plain: () { () -> void } -> Integer
    def noblock: () -> self
  end
RBS
check.call('`[T] (A) { (B) -> T } -> T` is a :block_value declaration with one argument and block arity 1',
           shapes['value']&.kind == :block_value && shapes['value'].args == 1 && shapes['value'].arity == 1 && !shapes['value'].problem)
check.call('`{ (B) -> void } -> self` is a :self declaration', shapes['me']&.kind == :self && !shapes['me'].problem)
{ 'opt' => 'optional', 'bound' => 'bound', 'leak' => 'also types a parameter', 'selfed' => 'self type',
  'rest' => 'method takes', 'blockrest' => 'block takes' }.each do |name, why|
  check.call("#{name}: reported (#{why}), no fact", shapes[name]&.problem.to_s.include?(why))
end
check.call('a block with an unrelated return type, and `-> self` without a block, are not block returns',
           !shapes.key?('plain') && !shapes.key?('noblock'))
check.call('a declaration in sig/native is a native one', entries_of.call(<<~RBS, dir_name: 'native').first&.native)
  module M
    def self.s: [T] () { () -> T } -> T
  end
RBS

puts '== native source scan'
profiler = File.binread(File.join(ROOT, 'mruby-rgss/src/profiler.cxx'))
section = BlockReturns::Entry.new(owner: 'RGSS::Profiler.singleton', name: 'section', kind: :block_value, args: 1, arity: 0)
frame = BlockReturns::Entry.new(owner: 'RGSS::Profiler.singleton', name: 'frame', kind: :block_value, args: 0, arity: 0)
check.call('profiler.cxx registers section with prof_section and prof_stub_yield',
           BlockReturns.registrations(profiler, 'section').map(&:last).sort == %w[prof_section prof_stub_yield])
%w[prof_section prof_frame prof_stub_yield].each do |function|
  check.call("#{function} returns its block's value", BlockReturns.native_function_why(profiler, function, 0).nil?)
end
check.call('a function that does not take a block is refused',
           BlockReturns.native_function_why(profiler, 'prof_stats', 0).to_s.include?('mrb_get_args'))
check.call('a declared block arity the yields do not pass is refused',
           BlockReturns.native_function_why(profiler, 'prof_section', 1).to_s.include?('yields 0'))
mutants = {
  'a return of something else' => ['return ret;', 'return mrb_nil_value();'],
  'the yield result written again' => ['profiler_section_end(mrb_string_value_cstr(M, &name), start);',
                                       'profiler_section_end(mrb_string_value_cstr(M, &name), start); ret = name;'],
  'a yield that changes self' => ['return mrb_yield_argv(M, blk, 0, nullptr);',
                                  'return mrb_yield_with_class(M, blk, 0, nullptr, name, nullptr);'],
  'the block stored away' => ['const uint64_t start = profiler_section_begin();',
                              'mrb_gv_set(M, 0, blk); const uint64_t start = profiler_section_begin();']
}
Dir.mktmpdir do |dir|
  mutants.each do |what, (from, to)|
    body_start = profiler.index('mrb_value prof_section(')
    at = profiler.index(from, body_start)
    mutant = profiler.dup
    mutant[at, from.size] = to
    path = File.join(dir, 'mruby-rgss', 'src', 'profiler.cxx')
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, mutant)
    why, = BlockReturns.native_entry_why(section, [path])
    check.call("mutant (#{what}): refused", why.to_s.include?('prof_section'))
    reviewed = { section.key => { 'mruby-rgss/src/profiler.cxx' => Digest::SHA256.hexdigest(mutant) } }
    check.call("mutant (#{what}): accepted once reviewed with its SHA-256",
               BlockReturns.native_entry_why(section, [path], reviewed: reviewed).first.nil?)
    stale = { section.key => { 'mruby-rgss/src/profiler.cxx' => Digest::SHA256.hexdigest(profiler) } }
    check.call("mutant (#{what}): a review of another version does not count",
               !BlockReturns.native_entry_why(section, [path], reviewed: stale).first.nil?)
  end
  path = File.join(dir, 'p.cxx')
  File.binwrite(path, profiler)
  check.call('the real profiler.cxx verifies both declarations, with no review',
             BlockReturns.native_entry_why(section, [path], reviewed: {}) == [nil, 2] &&
               BlockReturns.native_entry_why(frame, [path], reviewed: {}) == [nil, 2])
  instance = BlockReturns::Entry.new(owner: 'RGSS::Profiler', name: 'section', kind: :block_value, args: 1, arity: 0)
  check.call('mrb_define_module_function registers the instance method too: an instance declaration verifies',
             BlockReturns.native_entry_why(instance, [path], reviewed: {}).first.nil?)
end
check.call('the reviewed table is a frozen Hash of declaration => {path => SHA-256}',
           BlockReturns::REVIEWED.frozen? &&
             BlockReturns::REVIEWED.all? { |k, v| k.include?('#') && v.all? { |p, d| p.is_a?(String) && Array(d).all? { |x| x.match?(/\A\h{64}\z/) } } })

mrbc = ENV['MRBC']
unless mrbc && File.executable?(mrbc)
  puts 'SKIP the Ruby body and fixture sections: MRBC is not set to a host mrbc'
  abort "generic_block_return_check: #{failures.size} failure(s)" unless failures.empty?
  puts "generic_block_return_check: #{checks} host checks passed"
  exit 0
end

require_relative '../../tools/bc2cpp/bc2cpp'

puts '== Ruby bodies'
ruby_why = lambda do |source, name, kind:, args: 0, arity: 0|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'b.rb')
    File.write(path, source)
    ireps, root = compile_ireps([path], 'gb_body', dir, mrbc: mrbc)
    registry, = build_registry(ireps, root)
    d = registry[name].first
    BlockReturns.ruby_body_why(ireps[d.irep], ireps, BlockReturns::Entry.new(name: name, kind: kind, args: args, arity: arity))
  end
end
check.call('`yield` is the block value', ruby_why.call("def m; yield; end\n", 'm', kind: :block_value).nil?)
check.call('`block.call(x)` after `return to_enum unless block` is the block value',
           ruby_why.call("def m(&b); return to_enum(:m) unless b; b.call(1); end\n", 'm', kind: :block_value, arity: 1).nil?)
check.call('`yield self; self` is self', ruby_why.call("def m; yield self; self; end\n", 'm', kind: :self, arity: 1).nil?)
check.call('a loop of yields, then self (Array#each\'s shape), is self',
           ruby_why.call("def m(&b); return to_enum unless b; i = 0; while i < 3; yield i; i += 1; end; self; end\n",
                         'm', kind: :self, arity: 1).nil?)
check.call('a yield of the method\'s argument is the block value',
           ruby_why.call("def m(a); yield a; end\n", 'm', kind: :block_value, args: 1, arity: 1).nil?)
{
  'a path returning nil' => ["def m; yield; nil; end\n", :block_value, 0, 'RETNIL'],
  'a yield of two arguments' => ["def m; yield 1, 2; end\n", :block_value, 1, 'yields 2'],
  'a rescue path' => ["def m; yield; rescue StandardError; 0; end\n", :block_value, 0, 'RESCUE'],
  'an escaping block' => ["def m(&b); @b = b; b.call; end\n", :block_value, 0, 'escape'],
  'the yield value declared as self' => ["def m; yield; end\n", :self, 0, 'not self'],
  'a return from a nested block' => ["def m; [1].each { |x| return x }; yield; end\n", :block_value, 0, 'RETURN'],
  'a nested yield of the wrong arity' => ["def m; [1].each { |x| yield x, x }; yield 1; end\n", :block_value, 1, 'yields 2'],
  'an optional parameter' => ["def m(a = 1); yield; end\n", :block_value, 0, 'required']
}.each do |what, (source, kind, arity, why)|
  got = ruby_why.call(source, 'm', kind: kind, arity: arity)
  check.call("refused: #{what} (#{got})", got.to_s.include?(why))
end

puts '== bc2cpp.rb on a fixture closed world'
WORLD = <<~'RUBY'
  module RGSS
  end
  class GbPoint
    def initialize(x); @x = x; end
    def gb_x; @x; end
  end
  class GbWrap
    def gb_around; yield; end
    def gb_pass(a); r = yield(a); r; end
    def gb_each_self; yield 1; self; end
    def gb_shared; yield; end
    def gb_opt; yield; end
  end
  class GbOther
    def gb_shared; 0; end
  end
  class GbUser
    def gb_flag; true; end
    def gb_section; RGSS::Profiler.section('a') { GbPoint.new(1) }; end
    def gb_frame; RGSS::Profiler.frame { GbPoint.new(2) }; end
    def gb_nested; RGSS::Profiler.section('o') { RGSS::Profiler.frame { GbPoint.new(3).tap { |p| p.gb_x } } }; end
    def gb_nested_call; RGSS::Profiler.section('o') { 1.then { |n| gb_section } }; end
    def gb_tapped; GbPoint.new(4).tap { |p| p.gb_x }; end
    def gb_thened; 5.then { |n| GbPoint.new(n) }; end
    def gb_yield_selfed; 6.yield_self { |n| GbPoint.new(n) }; end
    def gb_wrapped; GbWrap.new.gb_around { GbPoint.new(7) }; end
    def gb_passed; GbWrap.new.gb_pass(8) { |n| GbPoint.new(n) }; end
    def gb_selfed; GbWrap.new.gb_each_self { |n| n }; end
    def gb_breaks; RGSS::Profiler.section('b') { break 1 if gb_flag; GbPoint.new(9) }; end
    def gb_shared_call; GbWrap.new.gb_shared { GbPoint.new(10) }; end
    def gb_opt_call; GbWrap.new.gb_opt { GbPoint.new(11) }; end
    def gb_mixed; RGSS::Profiler.section('m') { gb_flag ? GbPoint.new(12) : 0 }; end
    def gb_take_user(u); u; end
    def gb_self_in_section; RGSS::Profiler.section('s') { gb_take_user(self) }; end
    def gb_take_point(p); p; end
    def gb_value_params
      gb_take_point(RGSS::Profiler.section('v') { GbPoint.new(13) })
      gb_take_point(GbPoint.new(14).tap { |q| q.gb_x })
      gb_take_point(GbWrap.new.gb_around { GbPoint.new(15) })
    end
  end
RUBY
SIGS = <<~RBS
  class GbWrap
    def gb_around: [T] () { () -> T } -> T
    def gb_pass: [T] (Integer a) { (Integer) -> T } -> T
    def gb_each_self: () { (Integer) -> void } -> self
    def gb_shared: [T] () { () -> T } -> T
    def gb_opt: [T] () ?{ () -> T } -> T
  end
  class GbUser
    def gb_take_user: (GbUser u) -> untyped
    def gb_take_point: (GbPoint p) -> untyped
  end
RBS
BAD_WORLD = <<~'RUBY'
  class GbBad
    def gb_bad_nil; yield; nil; end
    def gb_bad_arity; yield 1, 2; end
    def gb_bad_self; yield; end
    def gb_bad_rescue; yield; rescue StandardError; 0; end
    def gb_bad_ok; yield; end
  end
  class GbBadUser
    def gb_use; GbBad.new.gb_bad_ok { 1 }; end
  end
RUBY
BAD_SIGS = <<~RBS
  class GbBad
    def gb_bad_nil: [T] () { () -> T } -> T
    def gb_bad_arity: [T] () { (Integer) -> T } -> T
    def gb_bad_self: () { () -> void } -> self
    def gb_bad_rescue: [T] () { () -> T } -> T
    def gb_bad_ok: [T] () { () -> T } -> T
  end
RBS
BAD_NATIVE_SIGS = <<~RBS
  module GbNative
    def self.gb_native_wrap: [T] () { () -> T } -> T
  end
RBS
BAD_NATIVE = <<~C
  #include <mruby.h>
  static mrb_value gb_native_wrap(mrb_state* M, mrb_value self) {
    mrb_value blk;
    mrb_get_args(M, "&", &blk);
    mrb_yield_argv(M, blk, 0, NULL);
    return self;
  }
  void gb_native_init(mrb_state* M) {
    struct RClass* m = mrb_define_module(M, "GbNative");
    mrb_define_module_function(M, m, "gb_native_wrap", gb_native_wrap, MRB_ARGS_BLOCK());
  }
C

gems = NomethodReviewedProbe.wio_gems(ROOT).to_a + [['mruby-object-ext', File.join(ROOT, '3rd/mruby/mrbgems/mruby-object-ext')]]
generate = lambda do |world, sigs, native_sigs: nil, native: nil|
  Dir.mktmpdir('bc2cpp-gb') do |dir|
    path = File.join(dir, 'gb_fixture.rb')
    File.write(path, world)
    FileUtils.mkdir_p(File.join(dir, 'sig', 'bc2cpp'))
    File.write(File.join(dir, 'sig', 'bc2cpp', 'gb.rbs'), sigs)
    if native_sigs
      FileUtils.mkdir_p(File.join(dir, 'sig', 'native'))
      File.write(File.join(dir, 'sig', 'native', 'gb.rbs'), native_sigs)
    end
    # The fixture's own signatures and the repository's native declarations (RGSS::Profiler, Kernel, Array); the
    # repository's sig/bc2cpp describes engine classes this program does not have.
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'gb_fixture', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'BC2CPP_SIG_DIRS' => [File.join(dir, 'sig'), File.join(ROOT, 'sig', 'native')].join(File::PATH_SEPARATOR),
            'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }) }
    world_env = bc2cpp_wio_world_env(env, ROOT)
    if native
      native_path = File.join(dir, 'gb_native.c')
      File.write(native_path, native)
      world_env['NATIVE_SRCS'] = Shellwords.join(Shellwords.split(world_env['NATIVE_SRCS']) + [native_path])
    end
    Open3.capture3(world_env, RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
  end
end

_out, err, status = generate.call(WORLD, SIGS)
check.call('the fixture generates', status.success?)
unless status.success?
  puts err.lines.last(15).map { |l| "    #{l}" }.join
end
retclass = err.scan(/^  RETCLASS (\S+) \((\S+)\)$/).to_h
block_ret = err.scan(/^  BLOCK_RET (\S+) .*: (.*)$/).to_h
{ 'RGSS::Profiler.singleton#section' => 'checked, block_value', 'RGSS::Profiler.singleton#frame' => 'checked, block_value',
  'Kernel#tap' => 'checked, self', 'Kernel#then' => 'checked, block_value', 'Kernel#yield_self' => 'checked, block_value',
  'Array#each' => 'checked, self', 'GbWrap#gb_around' => 'checked, block_value', 'GbWrap#gb_pass' => 'checked, block_value',
  'GbWrap#gb_each_self' => 'checked, self', 'GbWrap#gb_shared' => 'checked, block_value' }.each do |key, status_text|
  check.call("#{key}: #{status_text}", block_ret[key] == status_text)
end
check.call('GbWrap#gb_opt (an optional block) is listed as not checked', block_ret['GbWrap#gb_opt'].to_s.start_with?('not checked'))
{ 'gb_section' => 'native section', 'gb_frame' => 'native frame', 'gb_nested' => 'nested section/frame/tap',
  'gb_nested_call' => 'a call inside nested blocks', 'gb_tapped' => 'Kernel#tap', 'gb_thened' => 'Kernel#then',
  'gb_yield_selfed' => 'Kernel#yield_self', 'gb_wrapped' => 'a program [T] method', 'gb_passed' => 'a [T] method with an argument' }.each do |name, what|
  check.call("#{what}: #{name} returns GbPoint", retclass[name] == 'GbPoint')
end
check.call('`-> self`: gb_selfed returns its receiver\'s class GbWrap', retclass['gb_selfed'] == 'GbWrap')
{ 'gb_breaks' => 'a breaking block', 'gb_shared_call' => 'an undeclared second definition of the name',
  'gb_opt_call' => 'an optional-block declaration', 'gb_mixed' => 'a block returning two classes' }.each do |name, what|
  check.call("refused, #{what}: #{name} has no class", !retclass.key?(name))
end
check.call('BLOCK_SELF and RBS_CHECKED_PARAMS: self in a section block, and section/tap/[T] values, prove the parameters',
           status.success? && !err.include?('TC1013'))

_out, err, status = generate.call(BAD_WORLD, BAD_SIGS, native_sigs: BAD_NATIVE_SIGS, native: BAD_NATIVE)
check.call('false declarations fail the build (DECLARED_RETURN_CHECK)',
           !status.success? && err.include?('[bc2cpp] DECLARED_RETURN_CHECK'))
{ 'GbBad#gb_bad_nil' => 'RETNIL', 'GbBad#gb_bad_arity' => 'yields 2', 'GbBad#gb_bad_self' => 'not self',
  'GbBad#gb_bad_rescue' => 'RESCUE', 'GbNative.singleton#gb_native_wrap' => 'return self' }.each do |key, why|
  line = err.lines.find { |l| l.include?("error: #{key}:") && l.include?('[TC1010]') }
  check.call("#{key}: a TC1010 error (#{why})", line.to_s.include?(why))
end
check.call('a true declaration next to them is still checked', err.include?('BLOCK_RET GbBad#gb_bad_ok { () -> T } -> T: checked, block_value'))

if failures.empty?
  puts "generic_block_return_check: #{checks} checks passed"
else
  abort "generic_block_return_check: #{failures.size} failure(s)"
end
