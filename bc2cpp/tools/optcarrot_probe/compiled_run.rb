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
  end.uniq.reject { |owner| owner == 'Optcarrot::PPU' || owner.start_with?('Optcarrot::PPU::') }
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
  config = File.join(temp, 'mruby_build_config.rb')
  File.write(config, <<~RUBY)
    MRuby::Build.new('optcarrotcompiled') do |conf|
      conf.toolchain
      conf.gembox 'full-core'
      conf.gem #{File.join(ROOT, '3rd/mruby-onig-regexp').dump}
      conf.gem #{gem_dir.dump}
      conf.enable_debug
    end
  RUBY
  rake_env = { 'MRUBY_CONFIG' => config }
  output, status = Open3.capture2e(rake_env, 'rake', "-j#{Etc.nprocessors}", chdir: MRUBY)
  raise "mruby build failed (#{status.exitstatus}):\n#{output[-6000..]}" unless status.success?

  bundle = File.join(temp, 'optcarrot_compiled.rb')
  system(RbConfig.ruby, File.join(ROOT, 'tools/optcarrot_probe/build_bundle.rb'), bundle, exception: true)
  source = File.read(bundle)
  raise 'optcarrot runner insertion point not found' unless source.sub!(/^nes = Optcarrot::NES\.new\(/, "OptcarrotProbe.install!\nnes = Optcarrot::NES.new(")

  File.write(bundle, source)
  binary = File.join(MRUBY, 'build/optcarrotcompiled/bin/mruby')
  puts "bc2cpp installed #{count} methods (PPU remains interpreted)"
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  output, status = Open3.capture2e(binary, bundle, ROM, FRAMES.to_s)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  print output
  raise "compiled optcarrot failed (#{status.exitstatus})" unless status.success?

  puts format('wall time: %.2f s (%.2f frames/s)', elapsed, FRAMES / elapsed)
end
