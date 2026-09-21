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
# Optcarrot::CPU/PPU/NES were once excluded here because compiled methods
# reached from the PPU Fiber could crash. CPU and NES are confirmed safe (see
# tools/optcarrot_probe/README.md's "Compiled runtime check" section) and stay
# compiled. Optcarrot::PPU itself is deliberately NOT in this list right now
# -- re-checking it (as part of the gc_gray_rescan investigation this file's
# own history references) found a real, 100%-reproducible failure, not the
# old SIGSEGV: `PPU#run`'s `@fiber ||= Fiber.new { ... }` compiles through the
# same BLOCK_FALLBACK path every other block literal uses (`bc2cpp.rb`'s
# `emit_block_fallback_glue`), which wraps the block body as a cfunc-backed
# RProc via `mrb_proc_new_cfunc_with_env` -- correct for `each`/`map`/`sub`/...
# (none of which care whether the RProc they're handed is cfunc- or
# bytecode-backed), but `Fiber.new` is not one of those: mruby's own
# `init_fiber` (3rd/mruby/mrbgems/mruby-fiber/src/fiber.c) checks
# `MRB_PROC_CFUNC_P(p)` and unconditionally raises `FiberError: tried to
# create Fiber from C defined method` rather than dereference a `body.irep`
# that a cfunc-backed proc doesn't have. This is deterministic C logic, not a
# timing- or memory-layout-dependent crash: every run of the 180-frame
# benchmark with PPU compiled hits it the instant `PPU#run` is first called
# -- confirmed both under GPROF=1 and with a plain, non-gprof
# `compiled_run.rb` run, and by reading the generated C++ directly (the
# `// BLOCK_FALLBACK :new` comment bc2cpp itself emits right above the
# `mrb_proc_new_cfunc_with_env` call that becomes `Fiber.new`'s block
# argument). Fixing it needs bc2cpp to emit a real, bytecode-backed Proc
# specifically for a block passed to `Fiber.new` (or to recognize that call
# shape and keep the containing method interpreted instead of devirtualizing
# into it) -- a bc2cpp.rb code-generation change, out of this file's own
# scope. Re-enabling `Optcarrot::PPU` here
# needs that fix landed and the same re-verification `Optcarrot::CPU`/`NES`
# got, not just re-adding the name.
FIBER_SAFE_OWNERS = %w[Optcarrot::Config Optcarrot::Opt Optcarrot::CPU Optcarrot::NES].freeze
# ROM loading and initialization run while NES is assembled, before emulator
# Fibers start; these methods exercise the generated loader fast paths.
FIBER_SAFE_SETUP_METHODS = {
  'Optcarrot::ROM' => %w[initialize],
  'Optcarrot::ROM.singleton' => %w[load]
}.freeze
# These methods run synchronously outside the PPU Fiber's execution path.
# 'Optcarrot::PPU' => %w[setup_frame] used to live here (PPU#setup_frame runs
# outside the Fiber, so it was always fine on its own) but is redundant now
# that Optcarrot::PPU is entirely excluded from ONLY_OWNERS above -- it never
# gets a compiled entry point to match against, so keeping the row here would
# be a silent no-op.
FIBER_SAFE_FRAME_BOUNDARY_METHODS = {
  # NES#step calls Video#tick after CPU#run and all PPU Fiber resumes return.
  'Optcarrot::Video' => %w[tick],
  # NES#step calls APU#vsync after PPU#vsync returns; its audio clock update
  # and sample bookkeeping stay outside the PPU Fiber execution path.
  'Optcarrot::APU' => %w[flush_sound vsync]
}.freeze
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
  # A class in `embeds` gets its whole instance type switched to
  # MRB_TT_DATA (an opaque embedded ivar struct in place of the ordinary
  # ivar table) for EVERY instance, program-wide -- MRB_SET_INSTANCE_TT is
  # a class-level flag, not a per-call-site choice. Once that flag is set,
  # ANY method of that class that still runs interpreted is unsound: the
  # interpreter's OP_SETIV/OP_GETIV only ever reads/writes the ordinary
  # `obj->iv` table (src/variable.c), which has no idea the real ivars now
  # live in the struct bc2cpp's own compiled methods read via DATA_PTR(self)
  # -- and a compiled method reached from Fiber-safe code (e.g. NES#reset's
  # devirtualized call into APU#reset) reads that struct through DATA_PTR
  # unconditionally, with no fallback. If that class's own #initialize
  # never ran compiled (never called mrb_data_init on this instance),
  # DATA_PTR(self) is still the zeroed pointer mrb_obj_alloc leaves behind,
  # so the very first such read is a null-pointer dereference -- confirmed
  # by reproducing it here: `Optcarrot::APU` is embeddable (ivars proven
  # embeddable program-wide) but was never in FIBER_SAFE_OWNERS, so
  # `APU.new`'s dynamic-dispatch `#initialize` (SPLAT `n=*`, not eligible
  # for DIRECT_CONSTRUCT devirtualization) ran the ordinary interpreted
  # bytecode, leaving DATA_PTR null; `NES#reset`'s devirtualized, direct
  # C++ call into `Optcarrot__APU_reset_impl` then dereferenced it and
  # segfaulted (`gdb bt`: Optcarrot__APU_reset_impl, called directly from
  # Optcarrot__NES_reset_impl, no mrb_funcall/mrb_vm_exec frame in between
  # -- SIGSEGV on `DATA_PTR(self)->cycles_ratecounter = ...`). This
  # reproduced in the plain (non-GPROF) 180-frame run too, so it is not a
  # profiling-build artifact: the "no longer reproducible" claim in
  # README.md's "Compiled runtime check" section no longer holds against
  # this bc2cpp.rb, presumably because the ivar-embedding proof (a
  # separate, actively-developed piece of bc2cpp) newly covers
  # Optcarrot::APU/APU::DMC/Pad, which it evidently didn't when that claim
  # was last verified.
  #
  # The fix: whenever a class needs MRB_TT_DATA, install ALL of its own
  # compiled methods too (matching how FIBER_SAFE_OWNERS already installs
  # every one of CPU/PPU/NES/Config/Opt's methods), not just whichever
  # ones happen to be Fiber-safety-listed -- so every instance of an
  # embedded class is always constructed AND always operated on through
  # the same compiled, struct-aware code, and the ordinary interpreter
  # never touches its ivars at all. This is computed from `embeds` itself
  # (the same diagnostics section MRB_SET_INSTANCE_TT is emitted from), so
  # it tracks whichever classes bc2cpp's ivar-embedding analysis decides
  # to embed automatically, rather than a hand-maintained list that can
  # silently fall out of sync with that analysis the way FIBER_SAFE_OWNERS
  # just did.
  embeds = section_lines(diagnostics, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')
  rows = section_lines(diagnostics, 'compiled entry points').filter_map do |line|
    match = line.match(/^\s*(\w+) \/ \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$/)
    next unless match

    entry, owner, name, extra = match.captures
    safe_setup = FIBER_SAFE_SETUP_METHODS.fetch(owner, []).include?(name)
    safe_frame_boundary = FIBER_SAFE_FRAME_BOUNDARY_METHODS.fetch(owner, []).include?(name)
    next unless FIBER_SAFE_OWNERS.include?(owner) || safe_setup || safe_frame_boundary || embeds.include?(owner)

    raise "cannot register protected method #{owner}##{name}" if extra.include?('[protected')

    [entry, owner, name, extra.include?('[private')]
  end

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
  # Excludes Optcarrot::PPU itself, not just its nested helper classes: a
  # devirtualized call (a direct C++ call from one compiled method's body
  # into another's) reaches a compiled `_impl` function regardless of
  # whether that method is ever registered via FIBER_SAFE_OWNERS/emit_register
  # below -- registration only controls Ruby-level dispatch, not whole-program
  # devirtualization. So leaving `Optcarrot::PPU` itself in ONLY_OWNERS would
  # still compile (and let other compiled code devirtualize into)
  # `Optcarrot__PPU_run_impl`, hitting the FIBER_SAFE_OWNERS comment's own
  # FiberError even though PPU is no longer "installed." See that comment for
  # the full mechanism.
  owners = section_lines(scan_diagnostics, 'compiled entry points').filter_map do |line|
    line[/\(([^#]+)#/, 1]
  end.uniq.reject { |owner| owner.start_with?('Optcarrot::PPU') }
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
  puts "bc2cpp installed #{count} compiled methods, including CPU/PPU/NES's own"
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
      summary.puts 'The generated optcarrot bundle calls CPU opcode handlers with fixed positional arguments to avoid per-opcode splat arrays. Config, Opt, CPU, PPU, NES (including the PPU Fiber loop), ROM.load, ROM#initialize, PPU#setup_frame, and the post-Fiber Video#tick and APU#flush_sound/APU#vsync hooks are all compiled; Video and APU besides those two hooks remain interpreted.'
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
