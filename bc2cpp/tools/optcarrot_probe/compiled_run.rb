#!/usr/bin/env ruby
# frozen_string_literal: true

# Build an isolated mruby binary with bc2cpp's optcarrot methods installed,
# then run the normal headless checksum benchmark. See README.md for limits.

removed_optimizations = %w[OPTCARROT_STATIC_DISPATCH OPTCARROT_STATIC_PPU
                           OPTCARROT_IR_LUT BC2CPP_IR_CPU_DISPATCH]
requested = removed_optimizations.select { |name| ENV[name] == '1' }
abort "Removed workload-specific optimization: #{requested.join(', ')}; use general IR inlining" unless requested.empty?

require 'fileutils'
require 'etc'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
ROOT = File.expand_path('../..', __dir__)
MRUBY = File.join(ROOT, '3rd/mruby')
PROBE_MRBC = ENV['MRBC'] || File.join(MRUBY, 'bin/mrbc')
FRAMES = Integer(ARGV.fetch(0, '180'))
ROM = ARGV.fetch(1, File.join(ROOT, '3rd/optcarrot/examples/Lan_Master.nes'))
GRAY_STACK_SIZE = Integer(ENV.fetch('OPTCARROT_GRAY_STACK_SIZE', '16384'), 10)
unless (1024..262_144).cover?(GRAY_STACK_SIZE)
  abort 'OPTCARROT_GRAY_STACK_SIZE must be between 1024 and 262144 pointers'
end

# Every compiled entry point is installed over its interpreted method (emit_register). bc2cpp itself refuses the
# methods a Fiber.yield can cross (the yield analysis, docs/bc2cpp-yield-c-boundary.md) and compiles PPU#main_loop
# as a resumable step function, so no hand-kept list of Fiber-safe owners is needed; one left a compiled method
# uninstalled, and every by-name call into it (PPU's memory-mapped I/O through Method objects) ran interpreted.
abort "#{PROBE_MRBC} is missing -- build the optcarrot probe mrbc first" unless File.executable?(PROBE_MRBC)
abort "#{ROM} is missing -- initialize the optcarrot submodule first" unless File.file?(ROM)

require File.join(ROOT, 'tools/bc2cpp/compiled_gems')
require_relative 'sealed_build'

def section_lines(text, header)
  start = text.index("== #{header} ==")
  raise "missing bc2cpp diagnostic section: #{header}" unless start

  rest = text[start..]
  stop = rest.index("\n==", 1)
  body = stop ? rest[0...stop] : rest
  body.lines.drop(1).map(&:strip).reject(&:empty?)
end

def run_bc2cpp(sources, env)
  command = [RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', *sources]
  stdout, stderr, status = Open3.capture3(env, *command)
  raise "bc2cpp failed (#{status.exitstatus}):\n#{stderr[-4000..] || stderr}" unless status.success?

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

# The .text a linked mruby actually contains, so a comparison is a code-size
# measurement and not a guess from the generated C++. `size -A`
# prints one "section size" per line; absent (non-ELF host) is nil, not 0.
def text_size(binary)
  output, status = Open3.capture2e('size', '-A', binary)
  return nil unless status.success?

  line = output.lines.find { |l| l.start_with?('.text') }
  line && line.split[1].to_i
rescue Errno::ENOENT
  nil
end

def owner_class_expr(owner)
  singleton = owner.end_with?('.singleton')
  parts = owner.sub(/\.singleton\z/, '').split('::')
  raise "unexpected optcarrot owner: #{owner}" unless parts.all? { |part| part.match?(/\A[A-Z]\w*\z/) }

  parent = 'M->object_class'
  parts.each do |part|
    parent = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(#{parent}), " \
             "mrb_intern_cstr(M, #{part.dump})))"
  end
  [parent, singleton]
end

def emit_register(diagnostics, out_dir)
  # A class in `embeds` keeps its ivars in a DATA struct (MRB_SET_INSTANCE_TT) that only compiled methods read, so
  # every one of its compiled methods must be installed; installing every entry point covers that too.
  embeds = section_lines(diagnostics, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)')
  rows = section_lines(diagnostics, 'compiled entry points').filter_map do |line|
    match = line.match(/^\s*(\w+) \/ \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$/)
    next unless match

    entry, owner, name, extra = match.captures
    raise "cannot register protected method #{owner}##{name}" if extra.include?('[protected')

    [entry, owner, name, extra.include?('[private')]
  end

  File.open(File.join(out_dir, 'register.cxx'), 'w') do |file|
    file.puts '#include <mruby.h>'
    file.puts '#include "optcarrot_probe_decls.h"'
    file.puts '#include "optcarrot_probe_gen.cpp"'
    file.puts 'static mrb_value optcarrot_install(mrb_state* M, mrb_value) {'
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
  # The gem's src/ dir holds both the generated C++ and register.cxx. Created
  # here (and register.cxx touched below, before the gem is added to a build)
  # because mruby discovers a gem's sources by globbing src/ at add time.
  output_dir = File.join(temp, 'gem', 'src')
  FileUtils.mkdir_p(scan_dir)
  FileUtils.mkdir_p(output_dir)
  # bc2cpp compiles closed-world programs only, so the benchmark always runs sealed.
  benchmark_source, sealed_gems = OptcarrotSealedBuild.prepare(ROOT, temp, File.dirname(output_dir))
  sources = [benchmark_source]
  native_sources, foreign_sources = bc2cpp_closed_world_outside_srcs('optcarrot-probe', sealed_gems, ROOT)
  base_env = {
    'MRBC' => PROBE_MRBC,
    'OUT_SYMBOL' => 'optcarrot_probe',
    'NATIVE_SRCS' => Shellwords.join(native_sources),
    'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_sources),
    # Every other real bc2cpp build integration in this repo sets this
    # (mruby-lcf-compiled/mrbgem.rake, mruby-rgss-compiled/mrbgem.rake,
    # mruby-rpg2k-compiled/mrbgem.rake, tools/bc2cpp/wio_registered_methods.rb,
    # even this same directory's own optcarrot_bc2cpp_coverage_report.rb for
    # its "shipped" run) -- this file was the one holdout, and it cost a real
    # CI failure: a method inside one of the still-compiled classes
    # (Config/Opt/ROM) hit bc2cpp's honest `#error unhandled opcode
    # BLOCK`/`SENDB` marker (an unmodeled block/`send`-with-block construct
    # bc2cpp can't safely translate), which -- without SKIP_UNSUPPORTED=1 --
    # bc2cpp leaves *in* the generated C++ instead of quietly dropping the
    # one method, turning an isolated, already-documented "this method stays
    # interpreted" fallback into a hard C++ compile failure for the whole
    # probe. With it set, exactly as everywhere else in this codebase, that
    # one method silently falls back to interpreted bytecode (still correct
    # -- optcarrot's checksum only depends on behavior, not on which methods
    # got compiled) and the build no longer depends on every reachable
    # method inside a compiled class happening to fit bc2cpp's supported
    # subset.
    'SKIP_UNSUPPORTED' => '1',
    # BC2CPP_SELF_REGISTERING: bc2cpp.rb's own EMBED_WIRED allowlist
    # (compiled_gems.rb's BC2CPP_WIRED_EMBEDDINGS) exists only because the
    # REAL compiled gems' hand-written register.cxx does not install every
    # compiled entry point of an embedding class by construction. This
    # file's own `emit_register` below has no such gap: it installs every
    # compiled method of any owner its own `embeds` diagnostic names (see
    # that function's own comment), computed from the exact same
    # diagnostic bc2cpp.rb itself prints -- so "embeddable" and
    # "installed" can never drift apart here the way they can for a
    # hand-maintained register.cxx. Setting this tells bc2cpp.rb's driver
    # to skip that allowlist (nothing in this closed world is on it
    # anyway -- it names only real-project classes) and let every ivar
    # IvarLayout/drop_unsafe_embeddings themselves already proved safe
    # actually embed, instead of silently falling back to the ordinary
    # dynamic ivar table the way every Optcarrot::CPU/PPU field has,
    # unconditionally, since this file was first written.
    'BC2CPP_SELF_REGISTERING' => '1',
    # sig/bc2cpp describes RPG engine classes that the optcarrot program does not define (RBS_SIGNATURES would abort).
    'BC2CPP_SIG_DIRS' => ''
  }
  base_env.merge!(OptcarrotSealedBuild.environment(sealed_gems))
  # NILABLE_EMBED_EXPERIMENT: OPTIN set only for the A/B run, so the default
  # three-mode benchmark and the CI job below are untouched. It adds a SECOND
  # compiled target from the same sources, differing only in one thing: bc2cpp is
  # told `Optcarrot::CPU#@opcode` is Integer-or-nil (NILABLE_EMBED_SUPPORT), so
  # that one field embeds as a tagged payload instead of living in iv_tbl.
  # CPU#@opcode is written nil in #initialize (cpu.rb:59) and a fetched
  # instruction byte before every dispatch (cpu.rb:930 -> 940), so it is read
  # and written on the hottest loop in the program. The declaration is a
  # reviewed assertion, not a proof; the generated writer still raises TypeError
  # on a non-Integer/non-nil value, and a wrong declaration costs correctness,
  # not memory safety.
  nullable = !ENV['OPTCARROT_FIXNUM_NIL_IVARS'].to_s.empty?
  nullable_ivars = ENV['OPTCARROT_FIXNUM_NIL_IVARS'].to_s
  scan_env = nullable ? base_env.merge('FIXNUM_NIL_IVARS' => nullable_ivars) : base_env
  _scan_cpp, scan_diagnostics = run_bc2cpp(sources, scan_env.merge('OUT_DIR' => scan_dir))
  lines = scan_diagnostics.lines
  world_header = lines.index { |line| line.start_with?('== closed world (') }
  puts lines[world_header, 2] if world_header
  puts lines.grep(/\A== closed world (fallbacks|guard violations|nil receivers|nomethod sites|proven-class miss sites)/)
  # Every class with a compiled entry point; bc2cpp refuses the Fiber-unsafe methods itself.
  owners = section_lines(scan_diagnostics, 'compiled entry points').filter_map do |line|
    line[/\(([^#]+)#/, 1]
  end.uniq
  compiled_env = scan_env.merge('OUT_DIR' => temp, 'ONLY_OWNERS' => owners.join(','))
  compiled_cpp, diagnostics = run_bc2cpp(sources, compiled_env)
  File.write(File.join(output_dir, 'optcarrot_probe_gen.cpp'), compiled_cpp)
  FileUtils.cp(File.join(temp, 'optcarrot_probe_decls.h'), output_dir)
  count = emit_register(diagnostics, output_dir)

  gem_dir = File.join(temp, 'gem')
  # mruby's Gem::Specification#setup globs `src/*.{c,cc,cpp,cxx}` (gem.rb's own
  # srcs_to_objs) when the gem is added, and only then turns on C++ exception
  # compilation if it found any. So the translation unit has to EXIST before
  # `gem #{gem_dir}` below -- emit_register writes the real contents into this
  # same path, and an empty placeholder is enough to get the object registered.
  # Without it the build died at "Don't know how to build task
  # .../optcarrot-compiled/src/register.o".
  FileUtils.mkdir_p(output_dir)
  FileUtils.touch(File.join(output_dir, 'register.cxx'))
  File.write(File.join(gem_dir, 'mrbgem.rake'), <<~RUBY)
    MRuby::Gem::Specification.new('optcarrot-compiled') do |spec|
      spec.license = 'MIT'
      spec.authors = 'probe'
      spec.add_dependency 'mruby-onig-regexp'
      # bc2cpp's emitted `#include "rgss_construct.hxx"`, the same wiring the
      # real compiled gems use.
      spec.cxx.include_paths << #{File.join(ROOT, 'include').dump}
    end
  RUBY
  profiling = ENV['GPROF'] == '1'
  debug = ENV['OPTCARROT_DEBUG'] == '1'
  build_mode = debug ? 'debug (-O0)' : 'release (-O3)'
  target_suffix = "#{debug ? '' : 'release'}#{profiling ? 'profile' : ''}"
  # The stack is embedded in mrb_gc; every translation unit must share its layout.
  target_suffix += "gray#{GRAY_STACK_SIZE}"
  build_mode += ", gray stack=#{GRAY_STACK_SIZE}"
  gray_stack_config = "cc.defines << 'MRB_GRAY_STACK_SIZE=#{GRAY_STACK_SIZE}'\ncxx.defines << 'MRB_GRAY_STACK_SIZE=#{GRAY_STACK_SIZE}'"
  interpreted_target = "optcarrotinterpreted#{target_suffix}"
  target_suffix += 'sealed'
  compiled_target = "optcarrotcompiled#{target_suffix}"
  puts "Optcarrot build mode: #{build_mode}"
  puts 'Optcarrot core: original CPU dispatch, Fiber PPU, and LUT initializer'
  config = File.join(temp, 'mruby_build_config.rb')
  compiled_base = ["toolchain", "self.mrbcfile = #{File.expand_path(PROBE_MRBC).dump}",
                   (debug ? 'enable_debug' : nil),
                   *sealed_gems.reject { |name, _| name.start_with?('optcarrot-') }.values.map { |dir| "gem #{dir.dump}" }].compact.join("\n      ")
  File.write(config, <<~RUBY)
    base = proc do
      toolchain
      # full-core adds mruby-cmath, whose C _Complex cproc (the qbe back end) does not support; the default gembox has
      # everything else this probe needs (Fiber, Set, Struct, Complex, Rational, metaprog).
      gembox(ENV['NFCXX_BACKEND'] == 'qbe' ? 'default' : 'full-core')
      gem #{File.join(ROOT, '3rd/mruby-onig-regexp').dump}
      # QBE has no indirect jump, so the computed-goto dispatch (goto *label, which EDG emits for the C++ VM) cannot be
      # compiled by the qbe back end; the switch dispatch can. Only the qbe build changes; the gcc build keeps computed goto.
      if ENV['NFCXX_BACKEND'] == 'qbe'
        cc.defines << 'MRB_USE_VM_SWITCH_DISPATCH'
        cxx.defines << 'MRB_USE_VM_SWITCH_DISPATCH'
      end
      #{debug ? 'enable_debug' : '# Keep the toolchain optimization defaults for FPS measurements.'}
    end
    # mruby's gperf step (mrbgems/mruby-compiler/mrbgem.rake) runs on MRuby.targets['host'], which the default
    # build config provides and this generated config would otherwise lack.
    MRuby::Build.new('host') { toolchain }
    MRuby::Build.new(#{interpreted_target.dump}) do
      instance_eval(&base)
      #{gray_stack_config}
      if #{profiling}
        cc.flags << '-pg'
        linker.flags << '-pg'
      end
    end
    MRuby::Build.new(#{compiled_target.dump}) do
      #{compiled_base}
      #{gray_stack_config}
      # The compiled gem's only source is C++ (register.cxx), and its generated
      # code raises real C++ exceptions (its own bc2cpp_ensure_guard /
      # bc2cpp_block_break), so the build needs MRB_USE_CXX_EXCEPTION and the
      # C++ compiler's rules for an OUT-OF-TREE gem. mruby only turns that on by
      # itself for a gem whose src/ it scans (load_gems.rb: `cxx_srcs = Dir.glob
      # ...; enable_cxx_exception unless cxx_srcs.empty?`), and
      # Gem::Specification#setup_compilers defines a non-core gem's rules from
      # the compilers it is given (gem.rb:98). Doing it here, before
      # `gem #{gem_dir}`, is what makes .../src/register.o buildable at all;
      # without it the build stops at "Don't know how to build task
      # .../optcarrot-compiled/src/register.o".
      enable_cxx_exception
      gem #{gem_dir.dump}
      gem #{sealed_gems.fetch('optcarrot-benchmark').dump}
      if #{profiling}
        cc.flags << '-pg'
        cxx.flags << %w(-pg -fno-inline)
        linker.flags << '-pg'
      end
    end
    #{<<~VERIFY}
      task :verify_optcarrot_world do
        actual = MRuby.targets.fetch(#{compiled_target.dump}).gems.to_h { |g| [g.name, File.expand_path(g.dir)] }
        expected = #{sealed_gems.inspect}
        unless actual == expected
          raise "sealed gem manifest differs from actual build: extra=\#{actual.to_a - expected.to_a}; missing=\#{expected.to_a - actual.to_a}"
        end
      end
      task :link_optcarrot => :all do
        build = MRuby.targets.fetch(#{compiled_target.dump})
        build.linker.run File.join(build.build_dir, 'bin/optcarrot'), build.libraries, *build.gems.linker_attrs
      end
    VERIFY
  RUBY
  # The generated C++ depends on this repo's own mruby patches (M->errinfo for
  # VM_UNWIND_RESTORE, the rdata ivar slots, the goto-table element type). They
  # live in the pinned 3rd/mruby fork commit, so the probe builds that tree as
  # pinned and applies nothing here.
  # nix's dev shell exports LD=ld, and mruby's Linker takes its command
  # straight from the environment (build/command.rb:193, `ENV['LD'] || 'ld'`).
  # Raw `ld` adds no -lc and no startfiles, so the host mrbc's link dies with
  # "undefined reference to symbol 'fgetc@@GLIBC_2.2.5' ... DSO missing from
  # command line" -- in the base interpreted build, before any of the two
  # targets this file is about.
  #
  # Deleting LD is NOT the fix: mruby's default is plain `ld` too, so removing
  # it reproduces the same broken link. (`'LD' => nil` in a spawn env is worse
  # still -- that sets the EMPTY STRING, leaving mruby's link command blank,
  # "sh: 1: -o: not found".) The linker has to go through the compiler driver,
  # which is what adds libc: LD=CC, the same `cc` the compile half already uses.
  # Temporary gem paths can leave stale objects in a kept build directory.
  # Always rebuild generated code so timings and counters describe this run.
  FileUtils.rm_rf(File.join(MRUBY, "build/#{compiled_target}/mrbgems/optcarrot-compiled"))
  gems_dir = File.join(MRUBY, "build/#{compiled_target}/mrbgems")
  FileUtils.rm_rf(File.join(gems_dir, 'optcarrot-benchmark'))
  FileUtils.rm_rf(File.join(gems_dir, 'mruby-onig-regexp/src'))
  FileUtils.rm_f(Dir[File.join(gems_dir, 'mruby-onig-regexp/gem_init.{c,pi,o}')])
  # The mruby build runs its own Ruby processes. Under `bundle exec` (which bc2cpp needs) they would inherit this
  # bundle's RUBYOPT, RUBYLIB and BUNDLE_*/BUNDLER_* and fail to resolve the mruby tree's own gems. Open3 merges this
  # hash into the inherited environment, so a dropped variable is set to nil (unset), not left out.
  rake_env = ENV.to_h.to_h do |key, value|
    [key, key.start_with?('BUNDLE') || %w[RUBYOPT RUBYLIB].include?(key) ? nil : value]
  end.merge('MRUBY_CONFIG' => config)
  rake_env['LD'] = rake_env['CC'] || 'cc'
  tasks = %w[verify_optcarrot_world link_optcarrot]
  output, status = Open3.capture2e(rake_env, 'rake', *tasks, "-j#{Etc.nprocessors}", chdir: MRUBY)
  raise "mruby build failed (#{status.exitstatus}):\n#{output[-6000..] || output}" unless status.success?

  compiled_binary = File.join(MRUBY, "build/#{compiled_target}/bin/optcarrot")

  bundle = File.join(temp, 'optcarrot.rb')
  cruby_bundle = File.join(temp, 'optcarrot_cruby.rb')
  system(RbConfig.ruby, File.join(ROOT, 'tools/optcarrot_probe/build_bundle.rb'), bundle, exception: true)
  system({ 'OPTCARROT_NO_SHIMS' => '1' }, RbConfig.ruby,
         File.join(ROOT, 'tools/optcarrot_probe/build_bundle.rb'), cruby_bundle, exception: true)

  interpreted_binary = File.join(MRUBY, "build/#{interpreted_target}/bin/mruby")
  compiled_entries = section_lines(diagnostics, 'compiled entry points').join("\n")
  cpu_run_mode = compiled_entries.include?('(Optcarrot::CPU#run,') ? 'compiled' : 'interpreted'
  ppu_loop_mode = compiled_entries.include?('(Optcarrot::PPU#main_loop,') ? 'compiled' : 'interpreted'
  ppu_run_mode = compiled_entries.include?('(Optcarrot::PPU#run,') ? 'compiled' : 'interpreted'
  puts "bc2cpp installed #{count} compiled methods; " \
       "CPU#run=#{cpu_run_mode}; PPU#run=#{ppu_run_mode}; PPU#main_loop=#{ppu_loop_mode}"
  benchmarks = []
  benchmarks << run_benchmark('CRuby', [RbConfig.ruby, cruby_bundle, ROM, FRAMES.to_s])
  profile_dir = File.join(temp, 'profile')
  interpreted_profile_dir = File.join(profile_dir, 'interpreted')
  compiled_profile_dir = File.join(profile_dir, 'compiled')
  FileUtils.mkdir_p([interpreted_profile_dir, compiled_profile_dir]) if profiling
  benchmarks << run_benchmark('mruby interpreter', [interpreted_binary, bundle, ROM, FRAMES.to_s],
                              chdir: (interpreted_profile_dir if profiling))
  core_label = nullable ? 'mruby + bc2cpp (nullable @opcode)' : 'mruby + bc2cpp'
  modes = ['sealed']
  core_label += " (#{modes.join(', ')})" unless modes.empty?
  compiled_command = [compiled_binary, ROM, FRAMES.to_s]
  compiled_result = run_benchmark(core_label, compiled_command,
                                  chdir: (compiled_profile_dir if profiling))
  benchmarks << compiled_result
  # The A/B size figure, when the experiment ran: this binary's own .text, so
  # the cost of the tagged field is a measurement of the artifact that was
  # benchmarked rather than an estimate from generated C++.
  if nullable
    bytes = text_size(compiled_binary)
    puts "nullable @opcode .text: #{bytes ? format('%d bytes', bytes) : 'unavailable'}" \
         " (binary #{File.size(compiled_binary)} bytes)"
    compiled_result[:text_bytes] = bytes
  end
  checksums = benchmarks.map { |result| result[:checksum] }.uniq
  raise "benchmark checksums differ: #{benchmarks.map { |result| "#{result[:label]}=#{result[:checksum]}" }.join(', ')}" unless checksums.size == 1

  if (summary_path = ENV['GITHUB_STEP_SUMMARY']) && !summary_path.empty?
    File.open(summary_path, 'a') do |summary|
      summary.puts "## Optcarrot benchmark (#{FRAMES} frames, #{build_mode})", '',
                   '| Runtime | Wall time | Wall fps | Optcarrot fps | Checksum |',
                   '| --- | ---: | ---: | ---: | ---: |'
      benchmarks.each do |result|
        summary.puts format('| %s | %.2f s | %.2f | %s | %s |', result[:label], result[:seconds],
                            FRAMES / result[:seconds], result[:reported_fps] || 'n/a', result[:checksum])
      end
      summary.puts '', 'All three runtimes produced the same checksum.'
      summary.puts format('Wall-time ratios: mruby/CRuby %.2fx; bc2cpp/mruby %.2fx (lower is faster).',
                          benchmarks[1][:seconds] / benchmarks[0][:seconds],
                          benchmarks[2][:seconds] / benchmarks[1][:seconds])
      summary.puts "Installed #{count} compiled methods; CPU#run is #{cpu_run_mode}; PPU#run is #{ppu_run_mode}; PPU#main_loop is #{ppu_loop_mode}. " \
                   'Unsupported and Fiber-unsafe methods stay interpreted.'
      summary.puts 'A compiled PPU#main_loop uses a resumable step function (ADR 0273).'
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
