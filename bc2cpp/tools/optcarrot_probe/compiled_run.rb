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
# Optcarrot::PPU used to be entirely excluded here (a real, 100%-
# reproducible FiberError -- `PPU#run`'s `@fiber ||= Fiber.new { ... }`
# compiled its block through the same BLOCK_FALLBACK path every other block
# literal uses, wrapping it as a cfunc-backed RProc mruby's own `init_fiber`
# (3rd/mruby/mrbgems/mruby-fiber/src/fiber.c) explicitly rejects). Fixed in
# `tools/bc2cpp/bc2cpp.rb` two ways, both required: FIBER_NEW_BLOCK_UNSAFE_
# SUPPORT refuses to compile the `Fiber.new { block }` call site itself
# (falls back to interpreted, exactly like any other unsupported
# construct), and FIBER_REACHABILITY_UNSAFE_SUPPORT refuses to compile
# every method transitively reachable (via same-owner self-sends) from
# that block's own body, down to and including every `Fiber.yield` call
# site -- verified necessary, not just sufficient-looking on paper: the
# narrower fix alone (only the `Fiber.new` site) still crashed the real
# 180-frame benchmark with a second FiberError (`resuming dead fiber`),
# traced to mruby's own `vmexec`-reentrant fiber-resume path getting
# confused by ANY native, VM-invisible compiled frame between the fiber's
# entry point and wherever it actually yields, not only the frame that
# happens to call `Fiber.yield` directly. See both SUPPORT comments in
# `bc2cpp.rb` and `tools/optcarrot_probe/README.md` for the full mechanism.
# `Optcarrot::PPU` is back in `ONLY_OWNERS` below now that both fixes are
# landed; its own fiber-body-reachable methods (`main_loop` and everything
# it calls, `run` itself) still compile to an honest `#error` and stay
# interpreted, same as always -- only the REST of PPU's own methods
# (`sync`/`vsync`/accessors/setup) newly compile.
#
# CPU/NES/Video/APU used to be excluded here too, for a real,
# CI-reproducible SIGSEGV that took several rounds to root-cause: every
# `Optcarrot::Video#tick` call after the third (`@times`, a plain
# non-embedded Array ivar, grows by one element per call; mruby's embedded-
# array storage -- `MRB_ARY_EMBED_LEN_MAX == 3` on this word-boxed 64-bit
# build -- holds the first three elements inline, and the fourth `push` is
# what forces `mrb_ary_push`/`ary_expand_capa` to de-embed the array onto the
# heap) crashed inside bc2cpp's generated code for `@times.last`. The actual
# defect was in bc2cpp itself, not in anything Fiber- or devirtualization-
# related: `tools/bc2cpp/native_expression_devirt.rb`'s
# `exact_array_no_argument_element_expression` (the code that turns real
# mruby C bodies like `mrb_ary_last` -- `struct RArray *a = mrb_ary_ptr(self);
# ... return ARY_PTR(a)[ARY_LEN(a) - 1];` -- into a single call-site C++
# expression) independently re-substituted that local `a` everywhere it was
# used instead of materializing it once, the way the real C body does. For
# `#last` that assembled a single expression calling `mrb_ary_ptr(recv)`
# three times (once for the `> 0` length guard, once for the `- 1` index,
# once more hardcoded for the `ARY_PTR` base), each expansion re-nesting the
# `ARY_EMBED_P`/`ARY_LEN`/`ARY_PTR` macros' own embed-vs-heap ternary. `gdb`,
# reading a real `-O0` build of the generated `.cpp` at the crash, found the
# array's own `RArray` struct (`flags`/`len`/`capa`/`ptr`) completely intact
# at every checkpoint, including inside the crashing statement's own
# `mrb_val_union` calls -- but GCC's code generation for that specific
# triply-nested ternary tree left one code path (the one skipping the
# now-redundant middle computation) reading an uninitialized callee-saved
# register instead of a freshly computed pointer, a genuine compiler-facing
# code-generation defect triggered by the redundant, repeated call shape
# (reproduced identically at `-O0`, with and without `-fno-strict-aliasing`,
# and under AddressSanitizer, ruling out an optimization-level-dependent
# stale-register-cache theory an earlier revision of this comment guessed).
# `Optcarrot::Array#first` has the same latent two-call shape (no second
# `ARY_LEN` -- its index is the literal `0`) and never reproduced a crash in
# this same probe, but nothing guarantees the C++ standard merges repeated
# calls to an equivalent expression, so the fix hoists both: the generated
# expression now materializes `mrb_ary_ptr(recv)` into a single local via a
# GNU statement expression and reuses it, exactly like the real C body does,
# instead of re-deriving it per use. With that landed, CPU/NES/Video/APU
# compile and run the full 180-frame `nes.run` loop clean (matching CRuby's
# and the plain mruby interpreter's checksum) and are back in this list.
# `Optcarrot::PPU` is not added here even now that its own FiberError above
# is fixed: `emit_register`'s own `rows` filter below already installs every
# compiled method of any class `embeds` names (see that function's own
# comment), and `Optcarrot::PPU` is such a class (its own ivars prove
# embeddable under BC2CPP_SELF_REGISTERING) -- adding it to this
# hand-maintained list too would be a redundant no-op, not a behavior
# change.
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

# The .text a linked mruby actually contains, so a comparison is a code-size
# measurement and not a guess from the generated C++ (ADR 0216's rule). `size -A`
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
  # The gem's src/ dir holds both the generated C++ and register.cxx. Created
  # here (and register.cxx touched below, before the gem is added to a build)
  # because mruby discovers a gem's sources by globbing src/ at add time.
  output_dir = File.join(temp, 'gem', 'src')
  FileUtils.mkdir_p(scan_dir)
  FileUtils.mkdir_p(output_dir)
  base_env = {
    'MRBC' => MRBC,
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
    'BC2CPP_SELF_REGISTERING' => '1'
  }
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
  # Optcarrot::PPU used to be excluded here entirely -- a devirtualized call
  # (a direct C++ call from one compiled method's body into another's)
  # reaches a compiled `_impl` function regardless of whether that method is
  # ever registered via FIBER_SAFE_OWNERS/emit_register below, so leaving
  # PPU in ONLY_OWNERS while any of its own methods still hit the FiberError
  # documented above (and in bc2cpp.rb's own FIBER_NEW_BLOCK_UNSAFE_SUPPORT/
  # FIBER_REACHABILITY_UNSAFE_SUPPORT) would compile straight into it. Now
  # that bc2cpp.rb itself refuses to compile the fiber-unsafe subset of
  # PPU's own methods (an honest `#error`, same mechanism SKIP_UNSUPPORTED
  # already relies on for every other unmodeled construct), PPU no longer
  # needs a whole-class exclusion here -- the per-method one bc2cpp.rb now
  # enforces is exact where this blunter, whole-class one was only
  # conservative.
  owners = section_lines(scan_diagnostics, 'compiled entry points').filter_map do |line|
    line[/\(([^#]+)#/, 1]
  end.uniq
  compiled_cpp, diagnostics = run_bc2cpp(sources, scan_env.merge(
    'OUT_DIR' => temp,
    'ONLY_OWNERS' => owners.join(',')
  ))
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
      if #{profiling}
        cc.flags << '-pg'
        cxx.flags << %w(-pg -fno-inline)
        linker.flags << '-pg'
      end
    end
  RUBY
  # The generated C++ depends on this repo's own mruby patches, not just on
  # upstream mruby: bc2cpp's VM_UNWIND_RESTORE helper reads
  # `M->errinfo`/`M->errinfo_ci_depth`, which only patches/mruby-dollar-bang-
  # scoped.patch adds to mrb_state (cmake/build-mruby.cmake applies it for the
  # real build). Applying only the module-function patch -- what this used to
  # do -- left `register.cxx` uncompilable ("'mrb_state' has no member named
  # 'errinfo'"), so the probe could not link at all. Same set the real build
  # uses, so the probe's mruby is the mruby bc2cpp is written against.
  %w[
    mruby-colon3-assign-setmcnst.patch
    mruby-dollar-bang-scoped.patch
    mruby-defined-keyword.patch
    mruby-module-function-scope.patch
    mruby-parser-dump-back-nth-ref.patch
    mruby-nomemoryerror-reentrant-alloc.patch
    mruby-gc-type-live-counts.patch
  ].each do |patch|
    path = File.join(ROOT, 'patches', patch)
    system(File.join(ROOT, 'scripts/apply_mruby_patch.bash'), MRUBY, path, exception: true)
  end
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
  rake_env = ENV.to_h.merge('MRUBY_CONFIG' => config)
  rake_env['LD'] = rake_env['CC'] || 'cc'
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
  puts "bc2cpp installed #{count} compiled methods, including CPU/NES/Video/APU's own and " \
       "PPU's own fiber-safe subset (main_loop and everything reachable from it stay interpreted)"
  benchmarks = []
  benchmarks << run_benchmark('CRuby', [RbConfig.ruby, cruby_bundle, ROM, FRAMES.to_s])
  profile_dir = File.join(temp, 'profile')
  interpreted_profile_dir = File.join(profile_dir, 'interpreted')
  compiled_profile_dir = File.join(profile_dir, 'compiled')
  FileUtils.mkdir_p([interpreted_profile_dir, compiled_profile_dir]) if profiling
  benchmarks << run_benchmark('mruby interpreter', [interpreted_binary, bundle, ROM, FRAMES.to_s],
                              chdir: (interpreted_profile_dir if profiling))
  core_label = nullable ? 'mruby + bc2cpp (nullable @opcode)' : 'mruby + bc2cpp'
  compiled_result = run_benchmark(core_label, [compiled_binary, compiled_bundle, ROM, FRAMES.to_s],
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
      summary.puts 'The generated optcarrot bundle calls CPU opcode handlers with fixed positional arguments to avoid per-opcode splat arrays. Config, Opt, CPU, NES, ROM.load, ROM#initialize, and the post-Fiber Video#tick and APU#flush_sound/APU#vsync hooks are all compiled; PPU (and its own Fiber-driven #run loop) stays interpreted, and Video/APU besides those two hooks remain interpreted too.'
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
