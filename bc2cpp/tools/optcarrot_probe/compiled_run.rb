#!/usr/bin/env ruby
# frozen_string_literal: true

# Build an isolated mruby binary with bc2cpp's optcarrot methods installed,
# then run the normal headless checksum benchmark. See README.md for limits.

require 'fileutils'
require 'etc'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
MRUBY = File.join(ROOT, '3rd/mruby')
MRBC = ENV['MRBC'] || File.join(MRUBY, 'bin/mrbc')
FRAMES = Integer(ARGV.fetch(0, '180'))
ROM = ARGV.fetch(1, File.join(ROOT, '3rd/optcarrot/examples/Lan_Master.nes'))
FIBER_BOUNDARY_METHODS = {
  'Optcarrot::NES' => %w[run step dispose],
  'Optcarrot::CPU' => %w[run vsync],
  'Optcarrot::PPU' => %w[
    initialize update vsync sync run dispose main_loop wait_frame wait_zero_clocks wait_one_clock wait_two_clocks
  ]
}.freeze
PPU_METHODS_OUTSIDE_FIBER = %w[
  reset set_chr_mem nametables= setup_frame
  poke_2000 poke_2001 peek_2002 poke_2003 poke_2004 peek_2004
  poke_2005 poke_2006 poke_2007 peek_2007 poke_2xxx peek_2xxx
  peek_3000 poke_4014 peek_4014
].freeze

abort "#{MRBC} is missing -- build the optcarrot probe mrbc first" unless File.executable?(MRBC)
abort "#{ROM} is missing -- initialize the optcarrot submodule first" unless File.file?(ROM)

require File.join(ROOT, 'tools/bc2cpp/compiled_gems')

sources = %w[
  optcarrot.rb
  optcarrot/nes.rb
  optcarrot/rom.rb
  optcarrot/pad.rb
  optcarrot/opt.rb
  optcarrot/cpu.rb
  optcarrot/apu.rb
  optcarrot/ppu.rb
  optcarrot/palette.rb
  optcarrot/driver.rb
  optcarrot/config.rb
].map { |path| File.join(ROOT, '3rd/optcarrot/lib', path) }

native_sources = core_native_srcs(MRUBY) + Dir[File.join(ROOT, '3rd/mruby-onig-regexp/src/*.c')]
foreign_sources = Dir[File.join(MRUBY, 'mrblib/**/*.rb')] +
                  Dir[File.join(MRUBY, 'mrbgems/*/mrblib/**/*.rb')] +
                  Dir[File.join(ROOT, '3rd/mruby-onig-regexp/mrblib/**/*.rb')]

def section_lines(text, header)
  start = text.index("== #{header} ==")
  raise "missing bc2cpp diagnostic section: #{header}" unless start

  rest = text[start..]
  stop = rest.index("\n==", 1)
  body = stop ? rest[0...stop] : rest
  body.lines.drop(1).map(&:strip).reject(&:empty?)
end

def run_bc2cpp(sources, env)
  command = [RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), *sources]
  stdout, stderr, status = Open3.capture3(env, *command)
  raise "bc2cpp failed (#{status.exitstatus}):\n#{stderr[-4000..]}" unless status.success?

  [stdout, stderr]
end

def run_benchmark(label, command, chdir: nil)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  options = chdir ? { chdir: chdir } : {}
  output, status = Open3.capture2e(*command, **options)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  unless status.success?
    result = status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"
    raise "#{label} benchmark failed (#{result}, #{status.inspect}):\n#{output}"
  end

  checksum = output[/^checksum: (\d+)$/, 1]
  raise "#{label} benchmark did not print a checksum:\n#{output}" unless checksum

  fps = output[/^fps: ([\d.]+)$/, 1]
  puts "#{label}: #{format('%.2f s (%.2f frames/s)', elapsed, FRAMES / elapsed)}; " \
       "reported fps=#{fps || 'n/a'}, checksum=#{checksum}"
  { label: label, seconds: elapsed, checksum: checksum, reported_fps: fps }
end

def owner_class_expr(owner)
  singleton = owner.end_with?('.singleton')
  parts = owner.sub(/\.singleton\z/, '').split('::')
  raise "unexpected optcarrot owner: #{owner}" unless parts.first == 'Optcarrot' && parts.length > 1

  parent = 'root'
  parts[1..].each do |part|
    parent = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(#{parent}), " \
             "mrb_intern_cstr(M, #{part.dump})))"
  end
  [parent, singleton]
end

def emit_register(diagnostics, out_dir)
  rows = section_lines(diagnostics, 'compiled entry points').filter_map do |line|
    match = line.match(/^\s*(\w+) \/ \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$/)
    next unless match

    entry, owner, name, extra = match.captures
    next if owner == 'Optcarrot::PPU' && !PPU_METHODS_OUTSIDE_FIBER.include?(name)
    next if FIBER_BOUNDARY_METHODS.fetch(owner, []).include?(name)

    raise "cannot register protected method #{owner}##{name}" if extra.include?('[protected')

    [entry, owner, name, extra.include?('[private')]
  end
  embeds = section_lines(diagnostics, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')

  File.open(File.join(out_dir, 'register.cxx'), 'w') do |file|
    file.puts '#include <mruby.h>'
    file.puts '#include "optcarrot_probe_decls.h"'
    file.puts '#include "optcarrot_probe_gen.cpp"'
    file.puts 'static mrb_value optcarrot_install(mrb_state* M, mrb_value) {'
    file.puts '  struct RClass* root = mrb_module_get(M, "Optcarrot");'
    embeds.each do |owner|
      klass, = owner_class_expr(owner)
      file.puts "  MRB_SET_INSTANCE_TT(#{klass}, MRB_TT_DATA);"
    end
    rows.each do |entry, owner, name, private_method|
      klass, singleton = owner_class_expr(owner)
      if singleton
        file.puts "  mrb_define_class_method(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
      elsif private_method
        file.puts "  mrb_define_private_method(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
      else
        file.puts "  mrb_define_method(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
      end
    end
    file.puts '  return mrb_nil_value();'
    file.puts '}'
    file.puts 'extern "C" void mrb_optcarrot_compiled_gem_init(mrb_state* M) {'
    file.puts '  struct RClass* mod = mrb_define_module(M, "OptcarrotProbe");'
    file.puts '  mrb_define_module_function(M, mod, "install!", optcarrot_install, MRB_ARGS_NONE());'
    file.puts '}'
    file.puts 'extern "C" void mrb_optcarrot_compiled_gem_final(mrb_state*) {}'
  end
  rows.size
end

Dir.mktmpdir('optcarrot-bc2cpp-') do |temp|
  scan_dir = File.join(temp, 'scan')
  output_dir = File.join(temp, 'gem', 'src')
  FileUtils.mkdir_p(scan_dir)
  FileUtils.mkdir_p(output_dir)
  base_env = {
    'MRBC' => MRBC,
    'OUT_SYMBOL' => 'optcarrot_probe',
    'NATIVE_SRCS' => Shellwords.join(native_sources),
    'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_sources)
  }
  _scan_cpp, scan_diagnostics = run_bc2cpp(sources, base_env.merge('OUT_DIR' => scan_dir))
  owners = section_lines(scan_diagnostics, 'compiled entry points').filter_map do |line|
    line[/\(([^#]+)#/, 1]
  end.uniq.reject { |owner| owner.start_with?('Optcarrot::PPU::') }
  compiled_cpp, diagnostics = run_bc2cpp(sources, base_env.merge(
    'OUT_DIR' => temp,
    'ONLY_OWNERS' => owners.join(',')
  ))
  File.write(File.join(output_dir, 'optcarrot_probe_gen.cpp'), compiled_cpp)
  FileUtils.cp(File.join(temp, 'optcarrot_probe_decls.h'), output_dir)
  count = emit_register(diagnostics, output_dir)

  gem_dir = File.join(temp, 'gem')
  File.write(File.join(gem_dir, 'mrbgem.rake'), <<~RUBY)
    MRuby::Gem::Specification.new('optcarrot-compiled') do |spec|
      spec.license = 'MIT'
      spec.authors = 'probe'
      spec.add_dependency 'mruby-onig-regexp'
    end
  RUBY
  profiling = ENV['GPROF'] == '1'
  interpreted_target = profiling ? 'optcarrotinterpretedprofile' : 'optcarrotinterpreted'
  compiled_target = profiling ? 'optcarrotcompiledprofile' : 'optcarrotcompiled'
  config = File.join(temp, 'mruby_build_config.rb')
  File.write(config, <<~RUBY)
    base = proc do
      toolchain
      gembox 'full-core'
      gem #{File.join(ROOT, '3rd/mruby-onig-regexp').dump}
      enable_debug
    end
    MRuby::Build.new(#{interpreted_target.dump}) do
      instance_eval(&base)
      if #{profiling}
        cc.flags << '-pg'
        linker.flags << '-pg'
      end
    end
    MRuby::Build.new(#{compiled_target.dump}) do
      instance_eval(&base)
      gem #{gem_dir.dump}
      if #{profiling}
        cc.flags << '-pg'
        cxx.flags << %w(-pg -fno-inline)
        linker.flags << '-pg'
      end
    end
  RUBY
  system(File.join(ROOT, 'scripts/apply_mruby_patch.bash'), MRUBY,
         File.join(ROOT, 'patches/mruby-module-function-scope.patch'), exception: true)
  # CI exports LD=ld for native project builds. mruby's host mrbc link must
  # go through the compiler driver so libc is added; raw ld omits it.
  rake_env = { 'MRUBY_CONFIG' => config, 'LD' => nil }
  output, status = Open3.capture2e(rake_env, 'rake', "-j#{Etc.nprocessors}", chdir: MRUBY)
  raise "mruby build failed (#{status.exitstatus}):\n#{output[-6000..]}" unless status.success?

  bundle = File.join(temp, 'optcarrot.rb')
  cruby_bundle = File.join(temp, 'optcarrot_cruby.rb')
  compiled_bundle = File.join(temp, 'optcarrot_compiled.rb')
  system(RbConfig.ruby, File.join(ROOT, 'tools/optcarrot_probe/build_bundle.rb'), bundle, exception: true)
  system({ 'OPTCARROT_NO_SHIMS' => '1' }, RbConfig.ruby,
         File.join(ROOT, 'tools/optcarrot_probe/build_bundle.rb'), cruby_bundle, exception: true)
  source = File.read(bundle)
  raise 'optcarrot runner insertion point not found' unless source.sub!(/^nes = Optcarrot::NES\.new\(/, "OptcarrotProbe.install!\nnes = Optcarrot::NES.new(")
  File.write(compiled_bundle, source)

  interpreted_binary = File.join(MRUBY, "build/#{interpreted_target}/bin/mruby")
  compiled_binary = File.join(MRUBY, "build/#{compiled_target}/bin/mruby")
  puts "bc2cpp installed #{count} methods (NES/CPU/PPU Fiber boundary methods remain interpreted)"
  benchmarks = []
  benchmarks << run_benchmark('CRuby', [RbConfig.ruby, cruby_bundle, ROM, FRAMES.to_s])
  profile_dir = File.join(temp, 'profile')
  interpreted_profile_dir = File.join(profile_dir, 'interpreted')
  compiled_profile_dir = File.join(profile_dir, 'compiled')
  FileUtils.mkdir_p([interpreted_profile_dir, compiled_profile_dir]) if profiling
  benchmarks << run_benchmark('mruby interpreter', [interpreted_binary, bundle, ROM, FRAMES.to_s],
                              chdir: (interpreted_profile_dir if profiling))
  benchmarks << run_benchmark('mruby + bc2cpp', [compiled_binary, compiled_bundle, ROM, FRAMES.to_s],
                              chdir: (compiled_profile_dir if profiling))
  checksums = benchmarks.map { |result| result[:checksum] }.uniq
  raise "benchmark checksums differ: #{benchmarks.map { |result| "#{result[:label]}=#{result[:checksum]}" }.join(', ')}" unless checksums.size == 1

  if (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?
    File.open(summary_path, 'a') do |summary|
      summary.puts "## Optcarrot benchmark (#{FRAMES} frames)", '',
                   '| Runtime | Wall time | Wall fps | Optcarrot fps | Checksum |',
                   '| --- | ---: | ---: | ---: | ---: |'
      benchmarks.each do |result|
        summary.puts format('| %s | %.2f s | %.2f | %s | %s |', result[:label], result[:seconds],
                            FRAMES / result[:seconds], result[:reported_fps] || 'n/a', result[:checksum])
      end
      summary.puts '', 'All three runtimes produced the same checksum.'
      summary.puts format('mruby is %.2fx slower than CRuby; bc2cpp is %.2fx slower than mruby.',
                          benchmarks[1][:seconds] / benchmarks[0][:seconds],
                          benchmarks[2][:seconds] / benchmarks[1][:seconds])
      summary.puts 'The generated optcarrot bundle calls CPU opcode handlers with fixed positional arguments to avoid per-opcode splat arrays. NES#run/#step/#dispose, CPU#run/#vsync, and the PPU Fiber loop and helpers remain interpreted to avoid generated C frames in the Fiber path; PPU setup and CPU-facing peek/poke methods are compiled.'
    end
  end

  if profiling
    [['mruby interpreter', interpreted_binary, interpreted_profile_dir],
     ['mruby + bc2cpp', compiled_binary, compiled_profile_dir]].each do |label, binary, directory|
      profile_data = File.join(directory, 'gmon.out')
      raise "gprof output not found at #{profile_data}" unless File.file?(profile_data)

      profile, status = Open3.capture2e('gprof', binary, profile_data)
      raise "gprof failed (#{status.exitstatus}):\n#{profile[-4000..]}" unless status.success?

      if (profile_path = ENV['GPROF_OUTPUT']) && !profile_path.empty?
        suffix = label == 'mruby interpreter' ? 'mruby-interpreter' : 'mruby-bc2cpp'
        File.write("#{profile_path}.#{suffix}.txt", profile)
      end
      puts "\ngprof profile for #{label} (instrumented build; top entries):"
      puts profile.lines.first(55).join
    end
  end
end
