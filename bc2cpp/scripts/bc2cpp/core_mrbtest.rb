#!/usr/bin/env ruby
# encoding: UTF-8
#
# mruby's own test suites against the compiled core mrblib (docs/adr/0264).
#
# Builds a full-core host mruby twice with `rake test` -- once as shipped (every core
# method is bytecode), once with a harness gem that compiles the same core Ruby with
# tools/bc2cpp (owners: BC2CPP_CORE_OWNERS, the world: core mrblib only) and registers
# every compiled method over the bytecode -- and requires the same mrbtest result:
# the same number of assertions, none failing or crashing. mrbtest runs test/t/*.rb and
# every core gem's own tests, so it reaches the compiled methods' edge cases (empty and
# endless ranges, nil/Float/Integer operands, argument errors) with mruby's own expectations.
#
# Slow (two full mruby builds, minutes), so it is its own CI shard. It builds outside the
# tree (BC2CPP_MRBTEST_DIR or a temp dir) and skips when 3rd/mruby, rake or a compiler is
# missing. The mruby checkout must carry the project's patches, as every build does.
#
# Usage: ruby scripts/bc2cpp/core_mrbtest.rb

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
MRUBY = File.join(ROOT, '3rd/mruby')

def tool?(name)
  system(name, '--version', out: File::NULL, err: File::NULL)
end

unless File.exist?(File.join(MRUBY, 'Rakefile')) && tool?('rake') && tool?('g++')
  puts 'bc2cpp core mrbtest: SKIP (needs 3rd/mruby, rake and g++)'
  exit 0
end

GEM_RAKE = <<~'RAKE'
  require 'shellwords'
  ROOT = ENV.fetch('BC2CPP_ROOT')
  require "#{ROOT}/tools/bc2cpp/compiled_gems"

  # The core-only world: mruby core mrblib and the gems this build has, no engine Ruby.
  MRuby::Gem::Specification.new('bc2cpp-core-test') do |spec|
    spec.license = 'MIT'
    spec.author = 'rpg-maker-clone'
    spec.summary = 'harness: compiled core mrblib registered over the bytecode'

    (BC2CPP_CORE_MRBLIB_GEMS + BC2CPP_EXTERNAL_MRBLIB_GEMS).each do |gem_name|
      add_dependency gem_name if spec.build.gems.any? { |g| g.name == gem_name }
    end

    generated = "#{build_dir}/core_test_gen.cpp"
    prerequisites = [*Dir["#{ROOT}/tools/bc2cpp/*.rb"], File.join(ROOT, 'tools/bc2cpp/core_refused.txt'), spec.build.mrbcfile]
    file generated => prerequisites do
      FileUtils.mkdir_p build_dir
      srcs = core_compiled_mrblib_srcs(ROOT, spec.build.gems.map(&:name))
      native = core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)
      env = { 'MRBC' => spec.build.mrbcfile.to_s, 'OUT_SYMBOL' => 'core_test', 'OUT_DIR' => build_dir,
              'ONLY_OWNERS' => BC2CPP_CORE_OWNERS.join(','), 'NATIVE_SRCS' => Shellwords.join(native),
              'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)), 'SKIP_UNSUPPORTED' => '1' }
      cmd = "#{RbConfig.ruby.shellescape} #{ROOT}/tools/bc2cpp/bc2cpp.rb #{srcs.map(&:shellescape).join(' ')} " \
            "> #{generated.shellescape} 2> #{build_dir}/core_test.diag"
      sh env, cmd
    end
    file "#{dir}/src/register.cxx" => generated
    cxx.include_paths << build_dir
    cxx.include_paths << "#{ROOT}/include"
  end
RAKE

REGISTER_CXX = <<~'CPP'
  #include <mruby.h>
  #include <mruby/class.h>

  #include "core_test_gen.cpp"

  extern "C" void mrb_bc2cpp_core_test_gem_init(mrb_state* M) {
    bc2cpp_set_instance_tts(M);
    bc2cpp_register_owner_methods(M);
  }

  extern "C" void mrb_bc2cpp_core_test_gem_final(mrb_state*) {}
CPP

CONFIG_RB = <<~'RUBY'
  MRuby::Build.new('host') do |conf|
    toolchain :gcc
    conf.gembox 'full-core'
    conf.gem "#{ENV.fetch('BC2CPP_ROOT')}/3rd/mruby-stringio"
    conf.gem ENV['BC2CPP_HARNESS_GEM'] if ENV['BC2CPP_HARNESS_GEM']
    conf.cxx.flags << '-std=gnu++17'
    enable_cxx_exception
    enable_debug
    enable_test
    [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
  end
RUBY

work = ENV['BC2CPP_MRBTEST_DIR'] || Dir.mktmpdir('bc2cpp_core_mrbtest')
FileUtils.mkdir_p(File.join(work, 'gem/src'))
File.write(File.join(work, 'gem/mrbgem.rake'), GEM_RAKE)
File.write(File.join(work, 'gem/src/register.cxx'), REGISTER_CXX)
File.write(File.join(work, 'config.rb'), CONFIG_RB)

def build_and_test(work, name, harness)
  build = File.join(work, name)
  FileUtils.mkdir_p(File.join(build, 'repos/host'))
  FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(build, 'repos/host/mgem-list'))
  env = { 'BC2CPP_ROOT' => ROOT, 'MRUBY_CONFIG' => File.join(work, 'config.rb'), 'MRUBY_BUILD_DIR' => build,
          'BC2CPP_HARNESS_GEM' => (File.join(work, 'gem') if harness) }.compact.merge(Bc2cppCxx.rake_env)
  out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'test', chdir: MRUBY)
  File.write(File.join(work, "#{name}.log"), out)
  totals = %w[Total OK KO Crash].to_h { |k| [k, out[/^\s*#{k}:\s*(\d+)/, 1]&.to_i] }
  [status.success?, totals, build, out]
end

require 'etc'
puts 'core mrbtest: interpreted baseline'
ok_base, base, base_dir, base_out = build_and_test(work, 'interpreted', false)
puts "  #{base.inspect}"
puts 'core mrbtest: compiled core registered over the bytecode'
ok_comp, comp, comp_dir, comp_out = build_and_test(work, 'compiled', true)
puts "  #{comp.inspect}"

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
check.call('the interpreted baseline builds and passes', ok_base && base['Total'] && base['KO'].zero? && base['Crash'].zero?)
check.call('the build with the compiled core builds and passes', ok_comp && comp['Total'] && comp['KO'].zero? && comp['Crash'].zero?)
check.call('both runs execute the same number of assertions', base['Total'] == comp['Total'] && base['OK'] == comp['OK'])

diag = File.join(comp_dir, 'host/mrbgems/bc2cpp-core-test/core_test.diag')
entries = File.exist?(diag) ? File.read(diag)[/== core-source compiled entry points \((\d+)\)/, 1].to_i : 0
check.call("the harness compiled core methods (#{entries})", entries.positive?)

# A registered method is a C function, so it has no Ruby source location. The block-taking
# ones (Array#each, Integer#times, Enumerable#sort_by, Hash#each) are registered behind the
# Fiber guard of ADR 0269.
probe = 'p [Numeric.instance_method(:positive?).source_location.nil?, Comparable.instance_method(:between?).source_location.nil?, ' \
        'Array.instance_method(:each).source_location.nil?, Integer.instance_method(:times).source_location.nil?, ' \
        'Enumerable.instance_method(:sort_by).source_location.nil?, Hash.instance_method(:each).source_location.nil?]'
comp_probe = IO.popen([File.join(comp_dir, 'host/bin/mruby'), '-e', probe], &:read).strip
base_probe = IO.popen([File.join(base_dir, 'host/bin/mruby'), '-e', probe], &:read).strip
check.call("compiled build runs the compiled bodies (#{comp_probe}) and the baseline the bytecode (#{base_probe})",
           comp_probe == "[#{(['true'] * 6).join(', ')}]" && base_probe == "[#{(['false'] * 6).join(', ')}]")

# Fibers, Enumerator#next, break/return/raise through the compiled block methods: the same output,
# compiled and interpreted (the compiled entry hands the call to the bytecode while a Fiber runs).
blocks_probe = File.join(ROOT, 'scripts/bc2cpp/core_blocks_probe.rb')
blocks_out = [base_dir, comp_dir].map do |dir|
  IO.popen([File.join(dir, 'host/bin/mruby'), blocks_probe], err: %i[child out], &:read)
end
check.call("block/Fiber probe: #{blocks_out[0].lines.size} lines, interpreted and compiled identical",
           blocks_out[0].lines.last == "END\n" && blocks_out[0] == blocks_out[1])
unless blocks_out[0] == blocks_out[1]
  blocks_out[0].lines.zip(blocks_out[1].lines).reject { |a, b| a == b }.first(10).each do |a, b|
    puts "    interpreted: #{a}    compiled:    #{b}"
  end
end

if failures.empty?
  puts 'bc2cpp core mrbtest: PASS'
else
  warn "bc2cpp core mrbtest: #{failures.size} failure(s); logs in #{work}"
  puts (comp_out || '').lines.last(30).join
  exit 1
end
FileUtils.rm_rf(work) unless ENV['BC2CPP_MRBTEST_DIR']
