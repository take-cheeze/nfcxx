# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'

module Bc2cppSelfCompile
  PROGRAM_CONTEXT_KEYS = %w[ONLY_OWNERS OTHER_OWNERS OTHER_DECLS_HEADER BC2CPP_TYPE_CHECK_ONLY BC2CPP_TYPE_FACTS
    BC2CPP_TYPE_FACTS_ROOT BC2CPP_MAIN_AST BC2CPP_STATIC_DISPATCH_LISTS BC2CPP_CONSTANT_PROOF_CANDIDATES
    BC2CPP_CONSTANT_PROOF_OUT BC2CPP_SELF_STATS BC2CPP_MRUBY_RUNNER BC2CPP_RUBY BC2CPP_MRUBY
    BC2CPP_RUNNER_LIBRARY BC2CPP_REQUIRE_SELF_AOT BC2CPP_RUNNER_MRBC_MODE BC2CPP_KEEP_DIR
    BC2CPP_MRUBY_CORE BC2CPP_MRUBY_FULL BC2CPP_SCCACHE BC2CPP_CXXFLAGS].freeze

  module_function

  def generation_environment(base, caller_env = ENV)
    # Guest metadata (including future BC2CPP_* controls) belongs to the eventual
    # compiler invocation. Only the explicit self-generation settings cross this boundary.
    keys = PROGRAM_CONTEXT_KEYS + %w[FIXNUM_NIL_IVARS HARNESSES] + caller_env.keys.grep(/\ABC2CPP_/)
    env = base.merge(keys.uniq.reject { |key| base.key?(key) }.to_h { |key| [key, nil] })
    selectors = %w[BC2CPP_HOST_RUBY BC2CPP_SELF_BUILD_DIR BC2CPP_SELF_CXX BC2CPP_SELF_SHARDS BC2CPP_BUILD_JOBS]
    controls = caller_env.select { |key, _| selectors.include?(key) }.sort.to_h
    [env, controls]
  end

  def write_changed(path, contents)
    File.write(path, contents) unless File.file?(path) && File.binread(path) == contents.b
  end

  def section(text, heading)
    text.split("== #{heading} ==", 2).fetch(1).split("\n==", 2).first
  end

  def write_gem(generation, gem_dir)
    diagnostics = File.read(File.join(generation, 'generation.log'))
    entries = section(diagnostics, 'compiled entry points').scan(/^\s+(\S+) \/ \S+\s+\(/).flatten.to_set
    raise 'self compilation produced no entry points' if entries.empty?
    embeddings = section(diagnostics, 'classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)').strip
    raise 'late self installation cannot change existing object layouts' unless embeddings.empty?

    src = File.join(gem_dir, 'src')
    generated = File.join(gem_dir, 'generated')
    FileUtils.mkdir_p([src, generated])
    units = Dir[File.join(generation, 'bc2cpp_self_gen*.cpp')].sort
    wanted = units.map { |path| File.basename(path) }
    Dir[File.join(src, 'bc2cpp_self_gen_shard*.cpp')].each do |path|
      File.unlink(path) unless wanted.include?(File.basename(path))
    end
    Dir[File.join(generation, 'bc2cpp_self_*.h')].each do |header|
      write_changed(File.join(generated, File.basename(header)), File.binread(header))
    end
    seen = Set.new
    units.each do |path|
      text = File.read(path).gsub(/^((?:static )?mrb_value ([\w$]+)\(mrb_state\* M, mrb_value self\) \{\n)/) do |head|
        name = Regexp.last_match(2)
        next head unless entries.include?(name)
        raise "duplicate compiled entry #{name}" unless seen.add?(name)
        head + "  if (bc2cpp_self_count_calls) ++bc2cpp_self_compiled_calls;\n"
      end
      text = "extern bool bc2cpp_self_count_calls;\nextern unsigned long long bc2cpp_self_compiled_calls;\n" + text
      dir = File.basename(path) == 'bc2cpp_self_gen.cpp' ? generated : src
      write_changed(File.join(dir, File.basename(path)), text)
    end
    raise "missing compiled entry definitions: #{(entries - seen).to_a.join(', ')}" unless entries == seen

    write_changed(File.join(src, 'register.cxx'), <<~CPP)
      #include <mruby.h>
      #include <cstdlib>
      #include "bc2cpp_self_decls.h"
      #include "bc2cpp_self_gen.cpp"
      bool bc2cpp_self_count_calls = false;
      unsigned long long bc2cpp_self_compiled_calls = 0;
      static mrb_value register_compiled(mrb_state* M, mrb_value) {
        bc2cpp_self_count_calls = std::getenv("BC2CPP_SELF_STATS") != nullptr;
        // The source graph has already run. Register bodies without reexecuting
        // its top-level statements or class bodies.
        bc2cpp_reset_const_site_cache();
        bc2cpp_reset_owner_classes();
        bc2cpp_register_owner_methods(M);
        bc2cpp_capture_direct_construct_classes(M);
        bc2cpp_frame_free_install(M);
        return mrb_int_value(M, #{entries.size});
      }
      static mrb_value compiled_calls(mrb_state* M, mrb_value) {
        return mrb_int_value(M, (mrb_int)bc2cpp_self_compiled_calls);
      }
      extern "C" void mrb_mruby_bc2cpp_self_compiled_gem_init(mrb_state* M) {
        struct RClass* mod = mrb_define_module(M, "BC2CPPRunner");
        mrb_define_module_function(M, mod, "register_compiled", register_compiled, MRB_ARGS_NONE());
        mrb_define_module_function(M, mod, "compiled_calls", compiled_calls, MRB_ARGS_NONE());
        mrb_define_const(M, mod, "AOT_METHOD_COUNT", mrb_int_value(M, #{entries.size}));
      }
      extern "C" void mrb_mruby_bc2cpp_self_compiled_gem_final(mrb_state*) { bc2cpp_gem_final(); }
    CPP
    write_changed(File.join(gem_dir, 'mrbgem.rake'), <<~RAKE)
      MRuby::Gem::Specification.new('mruby-bc2cpp-self-compiled') do |spec|
        spec.license = 'MIT'
        spec.authors = 'take-cheeze'
        spec.add_dependency 'mruby-bc2cpp-runner'
        spec.cxx.include_paths << File.join(dir, 'generated')
        spec.cxx.include_paths << File.join(BC2CPP_WORLD_ROOT, 'include')
        spec.cxx.flags << '-std=c++17'
      end
    RAKE
    skipped = section(diagnostics, 'skipped (unsupported, left on the interpreter)').lines.map(&:strip).reject(&:empty?)
    write_changed(File.join(generation, 'coverage.json'), JSON.pretty_generate(
      'compiled_methods' => entries.size, 'interpreted_methods' => skipped.size, 'fallbacks' => skipped))
    entries.size
  end
end
