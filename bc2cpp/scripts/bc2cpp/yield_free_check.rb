#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check the yield-free proof (docs/adr/0283) end to end.
#
#   - generated code: a block proved yield-free is built with the env flag set, a BLOCK_CORE_DIRECT
#     arm for it drops the root-context test, the registered entry of a compiled core iterator
#     checks the block's flag instead of always falling back under a Fiber, and every method a
#     Fiber can reach and that may yield beneath it (also through an explicit-receiver call in
#     another class) is refused;
#   - behaviour: the fixture compiled together with the compiled core prints what the interpreter
#     prints for the same driver: compiled yield-free blocks iterated inside Fibers, blocks that
#     reach Fiber.yield through other classes, computed sends, generators, Enumerator#next over
#     compiled iterators, interpreted blocks that yield, nested Fibers, GC pressure.
#
# The behavioural half needs a full-core libmruby (BC2CPP_MRUBY_FULL, or one built with rake) and
# g++, and skips without them. Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/yield_free_check.rb

require 'etc'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
MRBC_PATH = Bc2cppFixtureRuntime.mrbc

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~'RUBY'
  class YfHelper
    def quiet(x); x + 1; end
    def step(x); Fiber.yield x; x; end
    def relay(x); step(x); end
  end

  # The emulator shape: a Fiber body calls into another object (explicit receiver), which loops and
  # calls a third object's method that yields.
  class YfPpu
    def emu_wait; Fiber.yield 1; end
  end
  class YfCpu
    def initialize(ppu); @ppu = ppu; end
    def emu_run; 3.times { @ppu.emu_wait }; :done; end
  end
  class YfSys
    def initialize; @cpu = YfCpu.new(YfPpu.new); @f = Fiber.new { @cpu.emu_run }; end
    def sync; @f.resume; end
    def sync_all(n); r = []; n.times { r << @f.resume if @f.alive? }; r; end
  end

  class YfRunner
    def initialize; @h = YfHelper.new; end

    # Blocks that cannot reach a Fiber.yield.
    def sum(a); s = 0; a.each { |x| s += x }; s; end
    def squares(a); a.map { |x| @h.quiet(x) * x }; end
    def evens(a); a.select { |x| x.even? }; end
    def pairs(h); r = []; h.each { |k, v| r << "#{k}=#{v}" }; r; end
    def acc(a); a.inject(0) { |m, x| m + @h.quiet(x) }; end
    def idx(a); r = []; a.each_with_index { |x, i| r << x * i }; r; end
    def times_sum(n); s = 0; n.times { |i| s += i }; s; end
    def sorted(a); a.sort_by { |x| -x }; end
    def churn(n); r = []; n.times { |i| r << [i.to_s, (i * 2).to_s].map { |z| z * 3 } }; r.size; end
    def nested(a); a.map { |x| [x, x + 1].map { |y| y * 2 } }; end
    def broke(a); a.each { |x| break x * 10 if x > 1 }; end

    # Blocks that reach Fiber.yield.
    def relay_each(a); a.each { |x| @h.step(x) }; :relayed; end
    def direct_each(a); a.each { |x| Fiber.yield x }; :direct; end
    def nested_relay(a); a.each { |x| [x].each { |y| @h.relay(y) } }; :nested; end
    def dyn_each(a); a.each { |x| send(:direct_step, x) }; :dyn; end
    def direct_step(x); Fiber.yield x; end

    # Generators and Enumerators over compiled iterators.
    def gen; Enumerator.new { |y| y << 1; y << 2; y << 3 }; end
    def enum_of(a); a.each_with_index; end

    # Resumers: the Fiber is resumed from a compiled frame, the path that cannot cross a compiled frame.
    def pump(f, n); r = []; n.times { r << f.resume if f.alive? }; r; end
    def pull(e, n); r = []; n.times { r << e.next }; r; end

    # Fibers built in the world.
    def fiber_sum(a); Fiber.new { r = sum(a); Fiber.yield r; squares(a) }; end
    def fiber_relay(a); Fiber.new { relay_each(a) }; end
    def fiber_direct(a); Fiber.new { direct_each(a) }; end
    def fiber_dyn(a); Fiber.new { dyn_each(a) }; end
    def fiber_nested_relay(a); Fiber.new { nested_relay(a) }; end
    def fiber_cross(x); Fiber.new { @h.relay(x); :crossed }; end
    def fiber_many(a); Fiber.new { r = [sum(a), evens(a), idx(a), times_sum(5), sorted(a), nested(a), acc(a), broke(a)]; Fiber.yield r; r.size }; end
    def fiber_nested(a)
      Fiber.new do
        inner = Fiber.new { Fiber.yield sum(a); churn(20) }
        r = inner.resume
        Fiber.yield r
        [inner.resume, sum(a) + acc(a)]
      end
    end
    def fiber_churn(n); Fiber.new { churn(n); Fiber.yield GC.start; churn(n) }; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = YfRunner.new
  data = [3, 1, 2, 5, 4]
  hash = { a: 1, b: 2 }
  def drain(f, limit = 20)
    out = []
    limit.times do
      break unless f.alive?
      begin
        out << f.resume
      rescue => e
        out << [e.class, e.message]
        break
      end
    end
    out
  end
  def guarded
    yield
  rescue => e
    [e.class, e.message]
  end
  # Root context.
  puts "root: #{[fx.sum(data), fx.squares(data), fx.evens(data), fx.pairs(hash), fx.acc(data), fx.idx(data),
                  fx.times_sum(6), fx.sorted(data), fx.churn(30), fx.nested([1, 2]), fx.broke(data)].inspect}"
  puts "root relay: #{fx.fiber_cross(4).resume.inspect}"
  # Inside Fibers.
  puts "fiber sum: #{drain(fx.fiber_sum(data)).inspect}"
  puts "fiber many: #{drain(fx.fiber_many(data)).inspect}"
  puts "fiber relay: #{drain(fx.fiber_relay(data)).inspect}"
  puts "fiber direct: #{drain(fx.fiber_direct(data)).inspect}"
  puts "fiber dyn: #{drain(fx.fiber_dyn(data)).inspect}"
  puts "fiber nested relay: #{drain(fx.fiber_nested_relay(data)).inspect}"
  puts "fiber cross: #{drain(fx.fiber_cross(7)).inspect}"
  puts "fiber nested: #{drain(fx.fiber_nested(data)).inspect}"
  puts "fiber churn: #{drain(fx.fiber_churn(200)).inspect}"
  # The emulator shape.
  sys = YfSys.new
  puts "emulator: #{guarded { [sys.sync, sys.sync, sys.sync, sys.sync] }.inspect}"
  puts "emulator all: #{guarded { YfSys.new.sync_all(6) }.inspect}"
  # Fibers resumed from compiled frames.
  puts "pump sum: #{guarded { fx.pump(fx.fiber_sum(data), 3) }.inspect}"
  puts "pump relay: #{guarded { fx.pump(fx.fiber_relay(data), 8) }.inspect}"
  puts "pump direct: #{guarded { fx.pump(fx.fiber_direct(data), 8) }.inspect}"
  puts "pump dyn: #{guarded { fx.pump(fx.fiber_dyn(data), 8) }.inspect}"
  puts "pump nested relay: #{guarded { fx.pump(fx.fiber_nested_relay(data), 8) }.inspect}"
  puts "pump cross: #{guarded { fx.pump(fx.fiber_cross(7), 4) }.inspect}"
  puts "pump nested: #{guarded { fx.pump(fx.fiber_nested(data), 4) }.inspect}"
  puts "pull gen: #{guarded { fx.pull(fx.gen, 3) }.inspect} #{guarded { fx.pull(fx.gen, 4) }.inspect}"
  puts "pull enum: #{guarded { fx.pull(fx.enum_of([4, 5]), 2) }.inspect}"
  # Interpreted blocks that yield, handed to compiled core iterators.
  f = Fiber.new do
    [1, 2].each { |x| Fiber.yield [:each, x] }
    [3, 4].map { |x| Fiber.yield [:map, x] }
    2.times { |i| Fiber.yield [:times, i] }
    { k: 1 }.each { |k, v| Fiber.yield [:hash, k, v] }
    [5, 6].each_with_index { |x, i| Fiber.yield [:ewi, x, i] }
    [7, 8].inject(0) { |m, x| Fiber.yield [:inject, x]; m + x }
    (1..2).each { |x| Fiber.yield [:range, x] }
    [9, 8].sort_by { |x| Fiber.yield [:sort_by, x]; x }
    [1, 2].select { |x| Fiber.yield [:select, x]; x > 1 }
  end
  puts "interpreted yields: #{drain(f, 40).inspect}"
  # Enumerators over compiled iterators, and generators.
  e = fx.enum_of([5, 6, 7])
  puts "enum next: #{[e.next, e.next, e.next].inspect} #{begin; e.next; rescue StopIteration; :stop; end}"
  g = fx.gen
  puts "gen next: #{[g.next, g.next, g.next].inspect} #{begin; g.next; rescue StopIteration; :stop; end}"
  puts "gen to_a: #{fx.gen.to_a.inspect} take: #{fx.gen.take(2).inspect} lazy: #{fx.gen.lazy.map { |x| x * 2 }.first(2).inspect}"
  puts "each next: #{e2 = [10, 20].each; [e2.next, e2.next].inspect}"
  puts "map enum: #{m = [1, 2].map; [m.next, m.next].inspect}"
  # Fibers inside Fibers, blocks compiled and interpreted.
  outer = Fiber.new do
    inner = Fiber.new { Fiber.yield fx.sum([1, 2]); fx.acc([1]) }
    Fiber.yield inner.resume
    Fiber.yield fx.sorted([2, 1])
    inner.resume
  end
  puts "nested fibers: #{drain(outer).inspect}"
  puts "end"
RUBY

# -- generated code -------------------------------------------------------------------------------

gems = NomethodReviewedProbe.wio_gems(ROOT)
native_srcs = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
core_srcs = core_compiled_mrblib_srcs(ROOT)

unless system(MRBC_PATH, '--version', out: File::NULL, err: File::NULL)
  puts "  SKIP: no host mrbc (set MRBC); generated-code and behavioural checks need it"
  exit 0
end

owners = BC2CPP_CORE_OWNERS + %w[YfHelper YfRunner YfPpu YfCpu YfSys]
env = lambda do |dir, name|
  { 'MRBC' => MRBC_PATH, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
    'NATIVE_SRCS' => Shellwords.join(native_srcs), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
    'ONLY_OWNERS' => owners.join(','), 'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
    'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }), NomethodReviewed::ALLOW_ENV => 'allow' }
end

work = ENV['BC2CPP_YIELD_FREE_DIR'] || Dir.mktmpdir('bc2cpp_yield_free')
FileUtils.mkdir_p(work)
fixture_path = File.join(work, 'fixture.rb')
File.write(fixture_path, FIXTURE)
File.write(File.join(work, 'driver.rb'), DRIVER)
out, err, status = Open3.capture3(env.call(work, 'yf'), RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), *core_srcs, fixture_path)
abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?
File.write(File.join(work, 'yf_gen.cpp'), out)
File.write(File.join(work, 'yf.err'), err)

body_of = lambda do |owner, fn|
  out[/^mrb_value #{owner}_#{Regexp.escape(fn)}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
compiled_entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
compiled = ->(owner, name) { compiled_entries.match?(/\(#{Regexp.escape(owner)}##{Regexp.escape(name)}, arity/) }
report = err[/== yield-free proof \(YIELD_REACH\) ==.*?(?=\n\n)/m].to_s

check.call('the closed world proof is in force', report.include?('closed, proof in force') && !report.include?('not sealed'))

# A yield-free block is built with the flag set, and its arms drop the root-context test.
sum = body_of.call('YfRunner', 'sum')
check.call('the block of a yield-free sum is built with the yield-free flag',
           sum.match?(/bc2cpp_blk_env_\d+\[\] = \{[^}]*mrb_int_value\(M, 1\) \}/))
check.call('its Array arm calls the compiled body without the root-context test',
           sum.match?(/BLOCK_CORE_DIRECT :each .*\n\s+if \(mrb_array_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->array_class\) \{\n\s+r\d+ = Array_each_impl/m) &&
           !sum.include?('M->root_c'))
check.call('a yield-free map / select / each_with_index / inject block drops it too',
           %w[squares evens idx acc].all? { |fn| !body_of.call('YfRunner', fn).include?('M->root_c') })
check.call('a block that breaks keeps the wrapper and the guard (no direct entry)',
           body_of.call('YfRunner', 'broke').include?('M->root_c'))

check.call('the registered entry of Array#each checks the block instead of always leaving a Fiber',
           out.include?('(M->c != M->root_c && !bc2cpp_block_yield_free(bc2cpp_entry_block(M)))'))
check.call('entries keep their Enumerable each_is_builtin test',
           out.match?(/\(M->c != M->root_c && !bc2cpp_block_yield_free\(bc2cpp_entry_block\(M\)\)\) \|\| !bc2cpp_core_each_is_builtin/))

# A Fiber can reach these and they may yield beneath it: refused.
%w[relay_each direct_each nested_relay dyn_each direct_step].each do |name|
  check.call("YfRunner##{name} is not compiled (a Fiber reaches it and it may yield)", !compiled.call('YfRunner', name))
end
check.call('YfHelper#step (Fiber.yield) and #relay (through an explicit-receiver call from a Fiber) are not compiled',
           !compiled.call('YfHelper', 'step') && !compiled.call('YfHelper', 'relay'))
check.call('the emulator shape is refused end to end: the loop a Fiber body calls on another object, and its yielding callee',
           !compiled.call('YfCpu', 'emu_run') && !compiled.call('YfPpu', 'emu_wait'))
check.call('the generator builder is not compiled: its block would sit below a yielder call',
           !compiled.call('YfRunner', 'gen'))
check.call('methods that cannot yield stay compiled',
           %w[sum squares evens pairs acc idx times_sum sorted churn nested broke].all? { |m| compiled.call('YfRunner', m) } &&
           compiled.call('YfHelper', 'quiet'))
check.call('the report counts the arms whose root-context test was dropped', report.match?(/arms: \d+, [1-9]\d* with the root-context test dropped/))

# -- behaviour ----------------------------------------------------------------------------------

# The interpreter the fixture runs on: mruby with the gems of the wio world (full-core and
# mruby-stringio), built once. BC2CPP_YIELD_FREE_MRUBY names a finished build dir
# (lib/libmruby.a and include/).
MRUBY_CONFIG_RB = <<~'RUBY'
  MRuby::Build.new('host') do |conf|
    toolchain :gcc
    conf.gembox 'full-core'
    conf.gem "#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio"
    conf.cxx.flags << '-std=gnu++17'
    enable_cxx_exception
    enable_debug
    [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
  end
RUBY

build_mruby = lambda do
  ready = ENV['BC2CPP_YIELD_FREE_MRUBY']
  return ready if ready && File.exist?(File.join(ready, 'lib/libmruby.a')) && File.directory?(File.join(ready, 'include'))
  return nil unless system('rake', '--version', out: File::NULL, err: File::NULL) && Bc2cppFixtureRuntime.compiler? &&
                    File.exist?(File.join(ROOT, '3rd/mruby/Rakefile'))

  dir = ENV['BC2CPP_YIELD_FREE_MRUBY_BUILD'] || File.join(work, 'mruby')
  host = File.join(dir, 'host')
  return host if File.exist?(File.join(host, 'lib/libmruby.a'))

  FileUtils.mkdir_p(File.join(dir, 'repos/host'))
  FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(dir, 'repos/host/mgem-list'))
  File.write(File.join(dir, 'config.rb'), MRUBY_CONFIG_RB)
  built_env = { 'MRUBY_CONFIG' => File.join(dir, 'config.rb'), 'MRUBY_BUILD_DIR' => dir, 'BC2CPP_ROOT' => ROOT }.merge(Bc2cppCxx.rake_env)
  log, st = Open3.capture2e(built_env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: File.join(ROOT, '3rd/mruby'))
  File.write(File.join(dir, 'build.log'), log)
  st.success? ? host : nil
end
full = ENV['BC2CPP_YIELD_FREE_GEN_ONLY'] == '1' ? nil : build_mruby.call
unless full
  puts '  SKIP behavioural comparison: needs a full-core mruby (BC2CPP_YIELD_FREE_MRUBY), rake and g++'
  puts report unless failures.empty?
  FileUtils.rm_rf(work) unless ENV['BC2CPP_YIELD_FREE_DIR']
  abort "bc2cpp yield free check: #{failures.size} failure(s)" unless failures.empty?
  puts 'bc2cpp yield free check: PASS (generated code only)'
  exit 0
end

File.write(File.join(work, 'main.cpp'), <<~CPP)
  #include <mruby.h>
  #include <mruby/compile.h>
  #include "yf_gen.cpp"
  #include <cstdio>
  #include <cstdlib>
  #include <fstream>
  #include <iterator>
  #include <string>
  static std::string slurp(const char* path) {
    std::ifstream in(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  }
  int main(int, char** argv) {
    bool compiled = argv[1][0] == 'c';
    mrb_state* M = mrb_open();
    std::string fixture = slurp(argv[2]);
    mrb_load_string(M, fixture.c_str());
    if (M->exc) { mrb_print_error(M); return 2; }
    if (compiled) {
      bc2cpp_set_instance_tts(M);
      bc2cpp_register_owner_methods(M);
    }
    if (getenv("BC2CPP_GC_STRESS")) mrb_load_string(M, "GC.interval_ratio = 100; GC.step_ratio = 200; GC.generational_mode = false");
    std::string driver = slurp(argv[3]);
    mrb_load_string(M, driver.c_str());
    if (M->exc) { mrb_print_error(M); return 3; }
    mrb_close(M);
    return 0;
  }
CPP
binary = File.join(work, 'yf_main')
flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -w -O1]
built = Bc2cppCxx.system(*flags, "-I#{work}", "-I#{full}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/mruby-rgss/src",
               File.join(work, 'main.cpp'), "#{full}/lib/libmruby.a", '-lm', '-o', binary)
check.call('the fixture compiled together with the compiled core links against a full-core mruby', built)
if built
  run = lambda do |mode, stress|
    e = stress ? { 'BC2CPP_GC_STRESS' => '1' } : {}
    IO.popen(e, [binary, mode, fixture_path, File.join(work, 'driver.rb')], err: %i[child out], &:read)
  end
  base = run.call('interpreted', false)
  check.call('the interpreted run reaches the end of the driver', base.lines.last == "end\n")
  [[false, 'default GC'], [true, 'incremental GC stress']].each do |stress, label|
    got = run.call('compiled', stress)
    check.call("compiled run (#{label}) reaches the end of the driver", got.lines.last == "end\n")
    same = got == base
    check.call("compiled run (#{label}) prints what the interpreter prints (#{base.lines.size} lines)", same)
    next if same

    base.lines.zip(got.lines).reject { |a, b| a == b }.first(8).each do |a, b|
      puts "    interpreted: #{a}    compiled:    #{b}"
    end
  end
  puts base.lines.first(25).map { |l| "    | #{l}" }.join if ENV['BC2CPP_YIELD_FREE_SHOW']
end

FileUtils.rm_rf(work) unless ENV['BC2CPP_YIELD_FREE_DIR']
if failures.empty?
  puts 'bc2cpp yield free check: PASS'
else
  warn "bc2cpp yield free check: #{failures.size} failure(s)"
  exit 1
end
