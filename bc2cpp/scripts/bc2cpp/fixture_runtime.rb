# frozen_string_literal: true

# Shared by bc2cpp registry fixtures and checks that compile with bc2cpp.rb
# and run against a real mruby: generation, the C++ driver that
# registers the compiled methods over the interpreted ones, and the run.
#
# Two mruby builds are used, both optional (a check prints SKIP without them):
#   BC2CPP_MRUBY_CORE  a dir with lib/libmruby_core.a and include/ (no gems);
#   BC2CPP_MRUBY_FULL  the same with lib/libmruby.a and the full-core gems, for
#                      fixtures that need Enumerable, Integer#positive?, ...
# Both must be built from the patched 3rd/mruby the tree carries.
# BC2CPP_CXXFLAGS adds compiler flags, e.g. -DMRB_INT32 for a build whose mrb_int is 32 bits
# wide (the Emscripten width); run with that build's own MRBC.
# BC2CPP_KEEP_DIR=path keeps the last fixture directory (generated code, binary).
require 'etc'
require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/shared_generation'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/closed_world_env'
require_relative 'cxx'

module Bc2cppFixtureRuntime
  ROOT = File.expand_path('../..', __dir__)
  # BC2CPP_TOOL names another bc2cpp.rb (a mutant copy, scripts/bc2cpp/class_pools_mutation_check.rb).
  BC2CPP = ENV.fetch('BC2CPP_TOOL') { File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb') }

  # The `- & | <<` helpers call exported gem bodies, which a core-only libmruby lacks: fixtures link one by
  # default, so generation leaves those helpers by name unless a check that runs against the full-core build opts in.
  @collection_exports_linked = false

  class << self
    attr_accessor :collection_exports_linked
  end

  module_function

  def mrbc
    ENV['MRBC'] || 'mrbc'
  end

  # A build dir holding `library` and include/, from `env` or nil.
  def build_dir(env, library)
    dir = ENV[env]
    dir if dir && File.exist?(File.join(dir, 'lib', library)) && File.directory?(File.join(dir, 'include'))
  end

  def core
    build_dir('BC2CPP_MRUBY_CORE', 'libmruby_core.a') ||
      Dir[File.join(ROOT, 'build*/mruby/host/mrbc')].find { |dir| File.exist?(File.join(dir, 'lib/libmruby_core.a')) }
  end

  def full
    build_dir('BC2CPP_MRUBY_FULL', 'libmruby.a')
  end

  def compiler?
    system('g++', '--version', out: File::NULL, err: File::NULL)
  end

  FULL_CORE_CONFIG = <<~RUBY
    MRuby::Build.new('host') do |conf|
      toolchain :gcc
      conf.gembox 'full-core'
      conf.gem '#{ROOT}/3rd/mruby-stringio'
      conf.cxx.flags << '-std=gnu++17'
      enable_cxx_exception
      enable_debug
      [conf.cc, conf.cxx].each { |t| t.flags = t.flags.flatten.delete_if { |v| v == '-O0' } << '-O1' }
    end
  RUBY

  # A full-core libmruby build dir (lib/libmruby.a and include/), for fixtures that need Fiber,
  # Integer#step and the rest of mrblib: BC2CPP_MRUBY_FULL, else one built here with rake
  # (minutes; BC2CPP_FULL_BUILD_DIR keeps it for the next check). nil without rake, g++ or
  # 3rd/mruby, so the caller can skip the behavioural half.
  def full_or_build
    return full if full
    return nil unless system('rake', '--version', out: File::NULL, err: File::NULL) && compiler? &&
                      File.exist?(File.join(ROOT, '3rd/mruby/Rakefile'))

    work = ENV['BC2CPP_FULL_BUILD_DIR'] || (@full_build_dir ||= Dir.mktmpdir('bc2cpp_full'))
    host = File.join(work, 'host')
    return host if File.exist?(File.join(host, 'lib/libmruby.a'))

    FileUtils.mkdir_p(File.join(work, 'repos/host'))
    FileUtils.ln_sf(File.join(ROOT, '3rd/mgem-list'), File.join(work, 'repos/host/mgem-list'))
    File.write(File.join(work, 'config.rb'), FULL_CORE_CONFIG)
    env = { 'MRUBY_CONFIG' => File.join(work, 'config.rb'), 'MRUBY_BUILD_DIR' => work }.merge(Bc2cppCxx.rake_env)
    out, status = Open3.capture2e(env, 'rake', '-m', "-j#{[Etc.nprocessors, 16].min}", 'all', chdir: File.join(ROOT, '3rd/mruby'))
    File.write(File.join(work, 'build.log'), out)
    raise "full-core mruby build failed:\n#{out.lines.last(30).join}" unless status.success?

    host
  end

  GeneratedFixture = Struct.new(:code, :diagnostics, :bytecode) do
    def write(dir)
      File.binwrite(File.join(dir, 'fixture_gen.cpp'), code)
      File.binwrite(File.join(dir, 'fixture.mrb'), bytecode)
      diagnostics
    end
  end

  # Owner selection is an emission-only unit key; every other input is shared explicitly.
  # Results live only in this call's caller, with no cross-world or cross-process cache.
  def generate_owner_variants(source, dir, owners)
    generate(source, dir, owner_variants: owners)
  end

  # Runs bc2cpp.rb over `source` in the closed world with the real core
  # sources; `only_owners` limits what
  # is compiled. Returns [code, stderr].
  # `path` places the fixture below `dir`: a path under 3rd/mruby/mrblib/ makes bc2cpp treat
  # it as mruby's own Ruby (CoreDefs.core_source?), so a check can exercise the core-only proofs.
  # `extra` is more sources ([path, text] pairs) compiled after the fixture, e.g. engine Ruby
  # next to a core fixture. `build_gems` ([name, dir] pairs) adds gems to the closed-world build, whose
  # src/ and mrblib/ then count as outside native and Ruby sources.
  # `drop_gems` (names) leaves gems out of that list while their sources stay in the scanned ones: a build that lacks them.
  # `core` compiles mruby's own mrblib (BC2CPP_CORE_OWNERS) in front of the fixture, as a build does.
  # `skip_unsupported: false` drops SKIP_UNSUPPORTED, so a method the compiler
  # refuses keeps its `#error` in the output instead of being dropped whole --
  # what a check that asserts on a refusal needs.
  def generate(source, dir, only_owners: nil, path: 'fixture.rb', extra: [],
               native: [], foreign: [], build_gems: [], drop_gems: [], core: false, skip_unsupported: true, owner_variants: nil)
    src = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(src))
    File.write(src, source)
    extra_srcs = extra.map do |extra_path, text|
      File.join(dir, extra_path).tap { |file| FileUtils.mkdir_p(File.dirname(file)) && File.write(file, text) }
    end
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'fixture', 'OUT_DIR' => dir,
            'BC2CPP_SELF_REGISTERING' => '1' }
    env['SKIP_UNSUPPORTED'] = '1' if skip_unsupported
    only_owners = BC2CPP_CORE_OWNERS + only_owners if core && only_owners
    env['ONLY_OWNERS'] = only_owners.join(',') if only_owners
      # `native`/`foreign` are [name, text] pairs of outside sources the closed world must scan.
      write_outside = lambda do |pairs|
        pairs.map { |name, text| File.join(dir, name).tap { |file| File.write(file, text) } }
      end
      # A core fixture links libmruby_core or the full-core build, neither of which has mruby-rgss, so its
      # closed world leaves those sources out: a native-direct arm never names an rgss:: symbol it cannot link.
      world = closed_world_native_srcs
      world = world.reject { |path| path.include?('/mruby-rgss/src/') } if core
      natives = world + write_outside.call(native)
    env = bc2cpp_closed_world_probe_env(env.merge(
      'NATIVE_SRCS' => Shellwords.join(natives),
                 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT) + write_outside.call(foreign)),
      'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.closed_gems(ROOT).merge(build_gems.to_h).except(*drop_gems).map { |n, d| "#{n}=#{d}" })
    ), ROOT)
      env['BC2CPP_COLLECTION_EXPORTS'] = '1' if Bc2cppFixtureRuntime.collection_exports_linked
    core_srcs = core ? core_compiled_mrblib_srcs(ROOT) : []
    if owner_variants
      raise ArgumentError, 'owner variants require their own owner selection' if only_owners

      unit_envs = owner_variants.each_with_index.map do |owners, index|
        unit_dir = File.join(dir, "unit-#{index}")
        FileUtils.mkdir_p(unit_dir)
        { 'OUT_DIR' => unit_dir, 'OUT_SYMBOL' => 'fixture', 'ONLY_OWNERS' => owners&.join(',') }
      end
      results = SharedGeneration.run(tool: BC2CPP, srcs: [*core_srcs, src, *extra_srcs],
                                     common_env: env.reject { |key, _| SharedGeneration::UNIT_KEYS.include?(key) },
                                     unit_envs: unit_envs, extra_args: ['--annotated'])
      return results.zip(unit_envs).map do |(code, err, status), unit|
        raise "bc2cpp.rb failed:\n#{(err[-3000..] || err)}" unless status.success?

        GeneratedFixture.new(code, err, File.binread(File.join(unit.fetch('OUT_DIR'), 'fixture.mrb')))
      end
    end

    code, err, status = generator_run(env, [*core_srcs, src, *extra_srcs])
    raise "bc2cpp.rb failed:\n#{(err[-3000..] || err)}" unless status.success?

    File.write(File.join(dir, 'fixture_gen.cpp'), code)
    [code, err]
  end

  # Keep each installer/refusal world separate; callers supply their own settle policy.
  def registry_snapshot(source)
    require_relative '../../tools/bc2cpp/bc2cpp'

    Dir.mktmpdir('bc2cpp-registry') do |dir|
      path = File.join(dir, 'fixture.rb')
      File.write(path, source)
      ireps, root = compile_ireps(path, 'registry_fixture', dir)
      registry = build_registry(ireps, root)[0]
      kept, dropped = yield registry, ireps
      installed = CodeGen.new(ireps, registry, {}).send(:symbol_installed_names)
      [registry, ireps, kept, dropped, installed]
    end
  end

  # The outside-world sources a closed-world run scans before its own `native` ones (generate's NATIVE_SRCS).
  def closed_world_native_srcs
    core_native_srcs("#{ROOT}/3rd/mruby") + Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + external_gem_native_srcs(ROOT)
  end

  # One bc2cpp.rb run over `argv` with `env`, as a subprocess: [stdout, stderr, status].
  # Fixture checks read the generated C++'s proof comments, so every run asks for them.
  def generator_run(env, argv)
    Open3.capture3(env, RbConfig.ruby, BC2CPP, '--annotated', *argv)
  end

  # `mrb_define_method` lines registering every compiled entry point of `owners`. With
  # `exact_arity` an entry registers MRB_ARGS_REQ(arity) as the build's own registration does for
  # a method with required parameters only, so the VM's argument-count check runs; otherwise
  # MRB_ARGS_ANY() (the entry's own mrb_get_args is then the only check).
  def registrations(err, owners, exact_arity: false)
    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                 .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity (\d+)\)(.*)$})
    entries.filter_map do |entry, owner, name, arity, extra|
      next unless owners.include?(owner)

      holder = owner.delete_suffix('.singleton')
      scope = holder.split('::').inject('mrb_obj_value(M->object_class)') do |outer, part|
        "mrb_const_get(M, #{outer}, mrb_intern_cstr(M, #{part.dump}))"
      end
      klass = "mrb_class_ptr(#{scope})"
      fn = if owner.end_with?('.singleton') then 'mrb_define_class_method'
           elsif extra.include?('[private') then 'mrb_define_private_method'
           else 'mrb_define_method'
           end
      "  #{fn}(M, #{klass}, #{name.dump}, #{entry}, #{exact_arity ? "MRB_ARGS_REQ(#{arity})" : 'MRB_ARGS_ANY()'});"
    end
  end

  # Builds and runs a program: `body` is C++ run once per VM (it sees `M`, and
  # `compiled` says whether the compiled methods are registered). The fixture's
  # bytecode is loaded first. Returns [built, output]. With `envs` (an Array of
  # environment Hashes) the binary runs once per entry, each in its own process
  # so one crashing scenario cannot hide the others, and `output` is the Array
  # of their outputs paired with the exit status: [[output, success], ...].
  def run(dir, err, owners, body, build:, full: false, vms: [false, true], envs: nil, exact_arity: false)
    regs = registrations(err, owners, exact_arity: exact_arity).join("\n")
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      static int dispatches = 0;
      // Every dynamic dispatch the compiled bodies make.
      #define mrb_funcall_argv(M, ...) (++dispatches, (mrb_funcall_argv)(M, __VA_ARGS__))
      #define mrb_funcall_id(M, ...) (++dispatches, (mrb_funcall_id)(M, __VA_ARGS__))
      #define mrb_funcall(M, ...) (++dispatches, (mrb_funcall)(M, __VA_ARGS__))
      #include "fixture_gen.cpp"
      #include <mruby/irep.h>
      #include <mruby/array.h>
      #include <mruby/class.h>
      #include <mruby/data.h>
      #include <mruby/hash.h>
      #include <mruby/string.h>
      #include <mruby/variable.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      #{full ? '' : 'extern "C" void mrb_init_mrblib(mrb_state*) {}'}
      static void show(mrb_state* M, const char* label, mrb_value v) {
        mrb_value s = mrb_inspect(M, v);
        std::printf("%s => %.*s\\n", label, (int)RSTRING_LEN(s), RSTRING_PTR(s));
      }
      static void show_exc(mrb_state* M, const char* label) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value cls = mrb_str_new_cstr(M, mrb_obj_classname(M, e));
        std::printf("%s => raised %.*s\\n", label, (int)RSTRING_LEN(cls), RSTRING_PTR(cls));
      }
      // Calls obj.meth(*args) and shows its value or the exception class.
      // A compiled run also prints, indented, how many dynamic dispatches the call made.
      static bool compiled = false;
      static mrb_value call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                            const mrb_value* argv = nullptr) {
        dispatches = 0;
        mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
        int made = dispatches;
        if (M->exc) show_exc(M, label); else show(M, label, r);
        if (compiled) std::printf("  dispatches=%d\\n", made);
        return M->exc ? mrb_nil_value() : r;
      }
      #{body}
      static int run_vm(const std::vector<uint8_t>& bin, bool with_compiled) {
        mrb_state* M = #{full ? 'mrb_open()' : 'mrb_open_core()'};
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        compiled = with_compiled;
        if (with_compiled) {
          bc2cpp_set_instance_tts(M);
      #{regs}
        }
        int rc = scenario(M);
        mrb_close(M);
        if (with_compiled) bc2cpp_reset_owner_classes();
        return rc;
      }
      int main(int, char** argv) {
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        for (int vm = 0; vm < #{vms.size}; ++vm) {
          static const bool modes[] = { #{vms.map { |v| v ? 'true' : 'false' }.join(', ')} };
          std::printf("== %s\\n", modes[vm] ? "compiled" : "interpreted");
          if (int rc = run_vm(bin, modes[vm])) return rc;
        }
        return 0;
      }
    CPP
    lib = full ? "#{build}/lib/libmruby.a" : "#{build}/lib/libmruby_core.a"
    binary = File.join(dir, 'fixture')
    flags = %w[-std=c++17 -fexceptions -DMRB_USE_CXX_EXCEPTION -w]
    flags << '-DMRB_NO_GEMS' unless full
    flags.concat(Shellwords.split(ENV.fetch('BC2CPP_CXXFLAGS', '')))
    built = Bc2cppCxx.system(*flags, "-I#{dir}", "-I#{build}/include", "-I#{ROOT}/3rd/mruby/include",
                   "-I#{ROOT}/mruby-rgss/src", "-I#{ROOT}/include", File.join(dir, 'main.cpp'), lib, '-lm', '-o', binary)
    return [false, ''] unless built

    FileUtils.cp_r(dir, ENV['BC2CPP_KEEP_DIR'], remove_destination: true) if ENV['BC2CPP_KEEP_DIR']
    mrb = File.join(dir, 'fixture.mrb')
    if envs
      results = envs.map do |env|
        out = IO.popen(env, [binary, mrb], err: %i[child out], &:read)
        [out, $?.success?]
      end
      return [true, results]
    end
    output = IO.popen([binary, mrb], err: %i[child out], &:read)
    [$?.success?, output]
  end

  # The lines of `output` between "== compiled"/"== interpreted" headers.
  def sections(output)
    output.split(/^== /).reject(&:empty?).to_h do |chunk|
      head, *rest = chunk.lines
      [head.strip, rest.map(&:chomp)]
    end
  end
end
