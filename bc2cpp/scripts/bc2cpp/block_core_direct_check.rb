#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check BLOCK_CORE_DIRECT (docs/adr/0270): a literal-block send to a core block method
# (Array#each, Hash#select, Integer#times, Enumerable#collect, ...) gets exact-builtin-class
# arms that call the compiled core body directly, in front of the block-carrying dynamic send.
#
#   - generated code: the arms, and every reason they are withheld (open world, a Ruby
#     override or prepend on the class, a dynamic installer, no compiled core, arity);
#   - behaviour: a fixture compiled together with the compiled core, linked into a full-core
#     mruby, prints what the interpreted build prints for the same driver (results, break,
#     next, return, exceptions, Fibers, Enumerator#next, GC pressure, user receivers).
#
# The behavioural half builds two full-core mruby hosts (minutes), so it skips without
# 3rd/mruby, rake or g++. Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/block_core_direct_check.rb

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
  class BdFx
    def each_sum(a); s = 0; a.each { |x| s += x }; s; end
    def each_break(a); a.each { |x| break x * 10 if x > 2 }; end
    def each_next(a); r = []; a.each { |x| next if x.odd?; r << x }; r; end
    def each_return(a); a.each { |x| return x if x > 1 }; :none; end
    def hash_each(h); s = []; h.each { |k, v| s << "#{k}=#{v}" }; s; end
    def range_each(r); s = 0; r.each { |i| s += i }; s; end
    def map_sq(a); a.map { |x| x * x }; end
    def select_even(a); a.select { |x| x.even? }; end
    def reject_odd(a); a.reject { |x| x.odd? }; end
    def ewi(a); r = []; a.each_with_index { |x, i| r << [x, i] }; r; end
    def ewo(a); a.each_with_object([]) { |x, m| m << x + 1 }; end
    def times_sum(n); s = 0; n.times { |i| s += i }; s; end
    def downto_list(n); r = []; n.downto(1) { |i| r << i }; r; end
    def sort_by_neg(a); a.sort_by { |x| -x }; end
    def hash_select(h); h.select { |_k, v| v > 1 }; end
    def flat(a); a.flat_map { |x| [x, x] }; end
    def raising(a)
      a.each { |x| raise ArgumentError, "boom #{x}" if x == 2 }
      :done
    rescue ArgumentError => e
      e.message
    end
    def nested(a); r = 0; a.each { |x| [1, 2].each { |y| r += x * y } }; r; end
    def stringy(n); (1..n).to_a.map { |x| x.to_s }.select { |s| s.size > 1 }.size; end
    def any_all(a); [a.any? { |x| x > 2 }, a.all? { |x| x > 0 }]; end
    def ivar_block(a); @acc = []; a.each { |x| @acc << x }; @acc; end
    def user_each(o); r = []; o.each { |x| r << x }; r; end
    def mutate(a); r = []; a.each { |x| r << x; a << x + 10 if a.size < 5 }; r; end
    def each_count(a); n = 0; a.each { n += 1 }; n; end
    def each_rest(a); r = []; a.each { |*xs| r << xs }; r; end
    def pair_each(o); r = []; o.each { |a, b| r << [a, b] }; r; end
    def single_each(o); r = []; o.each { |a| r << a }; r; end
    def hash_pairs(h); r = []; h.each { |pair| r << pair }; r; end
    def find_sum(a); [a.find { |x| x > 1 }, a.sum { |x| x * 2 }, a.inject(0) { |m, x| m + x }]; end
    def rest_each(*xs); r = []; xs.each { |x| r << x * 2 }; r; end
    def strict_copy(a); l = lambda(&proc { |x| x }); a.map { |x| l.call(x) }; end
  end
RUBY

DRIVER = <<~'RUBY'
  fx = BdFx.new
  class BdArr < Array; end
  user = Object.new
  def user.each; yield 1; yield 2; end
  singleton = [7, 8]
  def singleton.each; yield :single; end
  frozen = [1, 2, 3].freeze
  pairs = Object.new
  def pairs.each; yield [1, 2]; yield 3; yield [4, 5, 6]; yield; end
  spread = Object.new
  def spread.each; yield 1, 2; yield 3, 4, 5; yield 6; end
  big = (1..3000).to_a
  hash = { a: 1, b: 2, c: 3 }
  cases = {
    each_sum: [[1, 2, 3, 4], [], [5], frozen, big, BdArr.new([1, 2])],
    each_break: [[1, 2, 3, 4], [1, 2], []],
    each_next: [[1, 2, 3, 4, 5, 6]],
    each_return: [[1, 2, 3], [0, 1]],
    hash_each: [hash, {}],
    range_each: [1..5, 3..2, (1...4)],
    map_sq: [[1, 2, 3], [], big.first(50), hash, 1..4],
    select_even: [[1, 2, 3, 4], hash, 1..8],
    reject_odd: [[1, 2, 3, 4], 1..8],
    ewi: [%w[a b c], [], hash],
    ewo: [[1, 2], 1..3],
    times_sum: [0, 1, 10, 100],
    downto_list: [0, 3],
    sort_by_neg: [[3, 1, 2], big.first(20)],
    hash_select: [hash, {}],
    flat: [[1, 2], 1..2],
    raising: [[1, 2, 3], [1]],
    nested: [[1, 2, 3]],
    stringy: [10, 300, 3000],
    any_all: [[1, 2, 3], [0, 1], []],
    ivar_block: [[1, 2, 3]],
    user_each: [user, [1, 2], singleton, BdArr.new([3, 4])],
    mutate: [[1, 2]],
    each_count: [[1, 2, 3], []],
    each_rest: [[1, 2], []],
    pair_each: [pairs, spread, { a: 1 }],
    single_each: [pairs, spread, [1, 2]],
    hash_pairs: [hash],
    find_sum: [[1, 2, 3], [], 1..4],
    strict_copy: [[1, 2, 3]]
  }
  puts "rest_each: #{fx.rest_each(1, 2, 3).inspect} #{fx.rest_each.inspect}"
  cases.each do |name, inputs|
    inputs.each_with_index do |input, i|
      out = begin
        r = fx.send(name, input)
        r.is_a?(Array) && r.size > 30 ? [:array, r.size, r.first, r.last] : r
      rescue => e
        [e.class, e.message]
      end
      puts "#{name}/#{i}: #{out.inspect}"
    end
  end
  # A Fiber runs the same calls through the entry guard's bytecode path.
  f = Fiber.new do
    puts "fiber each_sum: #{fx.each_sum([1, 2, 3]).inspect}"
    Fiber.yield 1
    puts "fiber map_sq: #{fx.map_sq([4, 5]).inspect}"
    2
  end
  puts "fiber resume: #{f.resume.inspect} #{f.resume.inspect}"
  e = [10, 20, 30].each
  puts "enumerator: #{e.next} #{e.next} #{e.next}"
  puts "end"
RUBY

# -- generated code -----------------------------------------------------------------------

gems = NomethodReviewedProbe.wio_gems(ROOT)
native_srcs = core_native_srcs(MRUBY) + external_gem_native_srcs(ROOT)
core_srcs = core_compiled_mrblib_srcs(ROOT)

generate = lambda do |source, name, closed: true, core: true, hot: nil|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => MRBC, 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'NATIVE_SRCS' => Shellwords.join(native_srcs),
            'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
            'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + ['BdFx']).join(',') }
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

body_of = lambda do |code, fn|
  code[/^mrb_value BdFx_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

unless tool?(MRBC)
  puts "  SKIP: no host mrbc (set MRBC); generated-code and behavioural checks need it"
  exit 0
end

closed = generate.call(FIXTURE, 'bd_closed')
arm = ->(fn) { body_of.call(closed, fn) }
# A block that breaks keeps the cfunc wrapper (no direct entry, so no yield-free proof): its arms keep the
# root-context test of the entry guard (ADR 0269). A block that provably cannot yield (ADR 0283) drops it.
check.call('each on an unknown receiver gets Array, Hash and Range arms with the dynamic send as their else',
           arm.call('each_break').match?(/BLOCK_CORE_DIRECT :each .*exact Array\/Hash\/Range.*\n\s+if \(M->c == M->root_c && mrb_array_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->array_class\) \{\n\s+r\d+ = Array_each_impl\(M, r\d+, mrb_obj_value\(bc2cpp_blk_proc_\d+\)\);\n\s+\} else if \(M->c == M->root_c && mrb_hash_p.*Hash_each_impl.*\} else if \(M->c == M->root_c && mrb_range_p.*Range_each_impl.*\} else \{\n\s+r\d+ = mrb_funcall_with_block\(/m))
# The BLOCK_CORE_DIRECT arms only: ADR 0420's guarded inline loop sits before them and keeps the root-context test in its own
# guard by design, so the whole body is not the arms.
core_arms = ->(fn) { arm.call(fn)[%r{// BLOCK_CORE_DIRECT :each .*?\} else \{}m].to_s }
check.call('every arm of a block that may not be yield-free repeats the entry guard of ADR 0269', core_arms.call('each_break').scan('M->c == M->root_c').size == 3)
check.call('the arms of a yield-free block drop the root-context test',
           arm.call('each_sum').match?(/BLOCK_CORE_DIRECT :each .*\n\s+if \(mrb_array_p\(r\d+\) && mrb_obj_ptr\(r\d+\)->c == M->array_class\) \{\n\s+r\d+ = Array_each_impl/m) &&
           !core_arms.call('each_sum').include?('M->root_c'))
check.call('downto is an Integer arm', arm.call('downto_list').match?(/mrb_integer_p\(r\d+\)\) \{\n\s+r\d+ = \w*downto_impl\(M, /))
check.call('times stays with the inlined loop of ADR 0147, not an arm', !arm.call('times_sum').include?('BLOCK_CORE_DIRECT'))
check.call('map reaches Enumerable#collect through the alias', arm.call('map_sq').include?('Enumerable_collect_impl(M,'))
check.call('select on a Hash is Hash#select, on an Array or Range Enumerable#find_all (its alias)',
           arm.call('select_even').include?('Hash_select_impl(M,') && arm.call('select_even').include?('Enumerable_find_all_impl(M,'))
check.call('a send to a user receiver keeps only dynamic dispatch in its else', arm.call('user_each').include?('BLOCK_CORE_DIRECT'))
check.call('break, next and return keep their catch around the arms',
           arm.call('each_break').include?('catch (bc2cpp_block_break&') && arm.call('each_return').include?('BLOCK_CORE_DIRECT'))

check.call('a rest parameter is an Array, so its each is the inlined loop, not an arm',
           !arm.call('rest_each').include?('BLOCK_CORE_DIRECT') && !arm.call('rest_each').include?('mrb_funcall_with_block'))
check.call('an optional-block core method (find) gets arms',
           arm.call('find_sum').include?('BLOCK_CORE_DIRECT :find'))

open_code = generate.call(FIXTURE, 'bd_open', closed: false)
check.call('without the closed world no arm is emitted', !open_code.include?('BLOCK_CORE_DIRECT'))
nocore = generate.call(FIXTURE, 'bd_nocore', core: false)
check.call('without the compiled core no arm is emitted', !nocore.include?('BLOCK_CORE_DIRECT'))

override = generate.call("#{FIXTURE}\nclass Array\n  def each(&b); 1; end\nend\n", 'bd_override')
check.call('a Ruby Array#each withdraws the Array arm and leaves Hash and Range',
           !body_of.call(override, 'each_sum').include?('Array_each_impl') && body_of.call(override, 'each_sum').include?('Hash_each_impl'))
prepend = generate.call("#{FIXTURE}\nmodule BdShadow; def each; end; end\nclass Array\n  prepend BdShadow\nend\n", 'bd_prepend')
check.call('a prepend on Array withdraws every Array arm',
           !body_of.call(prepend, 'each_sum').include?('Array_each_impl') && !body_of.call(prepend, 'map_sq').include?('mrb_array_p'))
installer = generate.call("#{FIXTURE}\nclass BdFx\n  def install(n); Array.send(:define_method, n) { 1 }; end\nend\n", 'bd_installer')
check.call('a dynamic installer withdraws every arm', !installer.include?('BLOCK_CORE_DIRECT'))

# -- behaviour -------------------------------------------------------------------------------

unless tool?('rake') && tool?('g++') && File.exist?(File.join(MRUBY, 'Rakefile'))
  puts '  SKIP behavioural comparison: needs 3rd/mruby, rake and g++'
  abort "bc2cpp block core direct check: #{failures.size} failure(s)" unless failures.empty?
  puts 'bc2cpp block core direct check: PASS (generated code only)'
  exit 0
end

GEM_RAKE = <<~'RAKE'
  require 'shellwords'
  ROOT = ENV.fetch('BC2CPP_ROOT')
  require "#{ROOT}/tools/bc2cpp/compiled_gems"
  require "#{ROOT}/tools/bc2cpp/nomethod_reviewed"
  require "#{ROOT}/tools/bc2cpp/nomethod_reviewed_probe"

  MRuby::Gem::Specification.new('bc2cpp-block-test') do |spec|
    spec.license = 'MIT'
    spec.author = 'rpg-maker-clone'
    spec.summary = 'harness: a closed-world fixture compiled with the compiled core'

    (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
      add_dependency gem_name if spec.build.gems.any? { |g| g.name == gem_name }
    end

    if ENV['BC2CPP_BLOCK_COMPILED'] == '1'
      generated = "#{build_dir}/bd_gen.cpp"
      prerequisites = [*Dir["#{ROOT}/tools/bc2cpp/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
      file generated => prerequisites do
        FileUtils.mkdir_p build_dir
        gems = NomethodReviewedProbe.wio_gems(ROOT)
        srcs = core_compiled_mrblib_srcs(ROOT, spec.build.gems.map(&:name)) + [ENV.fetch('BC2CPP_BLOCK_FIXTURE')]
        native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
        env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'bd', 'OUT_DIR' => build_dir,
                'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + ['BdFx']).join(','), 'NATIVE_SRCS' => Shellwords.join(native),
                'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)), 'SKIP_UNSUPPORTED' => '1',
                'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
                'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |n, d| "#{n}=#{d}" }),
                NomethodReviewed::ALLOW_ENV => 'allow' }
        cmd = "#{RbConfig.ruby.shellescape} #{ROOT}/tools/bc2cpp/bc2cpp.rb --annotated #{srcs.map(&:shellescape).join(' ')} " \
              "> #{generated.shellescape} 2> #{build_dir}/bd.diag"
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
    #{compiled ? '#include "bd_gen.cpp"' : ''}

    static const char* const kFixture = R"BDFX(#{FIXTURE})BDFX";

    extern "C" void mrb_bc2cpp_block_test_gem_init(mrb_state* M) {
      mrb_load_string(M, kFixture);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; }
    #{compiled ? '  bc2cpp_set_instance_tts(M);' : ''}
    #{compiled ? '  bc2cpp_register_owner_methods(M);' : ''}
    }

    extern "C" void mrb_bc2cpp_block_test_gem_final(mrb_state*) {}
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

work = ENV['BC2CPP_BLOCK_DIRECT_DIR'] || Dir.mktmpdir('bc2cpp_block_direct')
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
          'BC2CPP_HARNESS_GEM' => gem_dir, 'BC2CPP_BLOCK_COMPILED' => compiled ? '1' : '0',
          'BC2CPP_BLOCK_FIXTURE' => File.join(work, 'fixture.rb') }.merge(Bc2cppCxx.rake_env)
  out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: MRUBY)
  File.write(File.join(work, "#{name}.log"), out)
  bin = File.join(build, 'host/bin/mruby')
  return [nil, out] unless status.success? && File.exist?(bin)

  [Open3.capture2e(bin, File.join(work, 'driver.rb')).first, out]
end

puts 'block direct: interpreted baseline'
base_out, base_log = build_and_run.call('interpreted', false)
check.call('the interpreted build runs the driver', base_out && base_out.lines.last == "end\n")
puts 'block direct: compiled fixture over the compiled core'
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
  diag = File.join(work, 'compiled/host/mrbgems/bc2cpp-block-test/bd.diag')
  arms = File.exist?(diag.sub('bd.diag', 'bd_gen.cpp')) ? File.read(diag.sub('bd.diag', 'bd_gen.cpp')).scan('BLOCK_CORE_DIRECT').size : 0
  check.call("the harness compiled the fixture with block arms (#{arms})", arms.positive?)
end

FileUtils.rm_rf(work) unless ENV['BC2CPP_BLOCK_DIRECT_DIR']
if failures.empty?
  puts 'bc2cpp block core direct check: PASS'
else
  warn "bc2cpp block core direct check: #{failures.size} failure(s)"
  exit 1
end
