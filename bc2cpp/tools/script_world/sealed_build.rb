# frozen_string_literal: true

require_relative '../bc2cpp/world_root'
require 'fileutils'
require 'shellwords'

# The script-world build kind (compiled_gems.rb BC2CPP_PROBE_BUILDS): one mruby script as a closed-world program. The
# script is a gem's mrblib, its top-level statements that need the command line (the tail) are moved into
# ScriptWorld.run, and a fixed C main calls that. Same sealed gem set as tools/optcarrot_probe/sealed_build.rb, without
# the regexp gem (the scripts have no Regexp).
module ScriptSealedBuild
  PROBE = 'ScriptWorldProbe'

  def self.sealed_gems(root, compiled_gem)
    mruby = File.join(root, '3rd/mruby')
    excluded = BC2CPP_OPEN_WORLD_GEMS + %w[mruby-compiler mruby-bin-mrbc mruby-test mruby-sleep]
    gems = Dir[File.join(mruby, 'mrbgems/mruby-*/mrbgem.rake')].sort.to_h do |path|
      [File.basename(File.dirname(path)), File.dirname(path)]
    end.reject { |name, _| excluded.include?(name) || name.start_with?('mruby-bin-') }
    %w[dir io socket task].each do |name|
      gem_name = "hal-posix-#{name}"
      gems[gem_name] = File.join(mruby, 'mrbgems', gem_name)
    end
    gems['script-compiled'] = compiled_gem
    gems
  end

  # `source` is the script; it must end with `tail` (the statements that run it), which becomes the body of
  # ScriptWorld.run with `entry` in its place. Returns [program text, gems].
  def self.program(source, tail:, entry:)
    raise "the script no longer ends with its tail: #{tail.inspect}" unless source.end_with?(tail)

    body = source.delete_suffix(tail)
    # CORE_PRELUDE_INSTALL: the compiled core methods go in before the script's first line runs; on that line, so the
    # script's line numbers stay its own.
    text = "#{PROBE}.install_prelude!; #{body}"
    text << "\nmodule ScriptWorld\n  def self.run\n    #{PROBE}.install!\n    rc = #{entry}\n"
    text << "    $stdout.flush\n    $stderr.flush\n    rc\n  end\nend\n"
  end

  def self.prepare(root, temp, compiled_gem, script:, tail:, entry:)
    gems = sealed_gems(root, compiled_gem)
    # CONST_RESOLVE: the program reads ScriptWorldProbe, which register.cxx (written after the scan) defines; this stub
    # names it to the scan as a native binding, emit_register overwrites it.
    FileUtils.mkdir_p(File.join(compiled_gem, 'src'))
    File.write(File.join(compiled_gem, 'src/register.cxx'), "// scan stub\nmrb_define_module(M, \"#{PROBE}\");\n")
    gem = gems['script-benchmark'] = File.join(temp, 'mruby-script-benchmark')
    FileUtils.mkdir_p([File.join(gem, 'mrblib'), File.join(gem, 'src')])
    bundle = File.join(gem, 'mrblib/script.rb')
    File.write(bundle, program(File.read(script), tail: tail, entry: entry))
    File.write(File.join(gem, 'mrbgem.rake'), <<~RUBY)
      MRuby::Gem::Specification.new('script-benchmark') do |spec|
        spec.license = 'MIT'
        spec.authors = 'script world'
        spec.add_dependency 'script-compiled'
      end
    RUBY
    File.write(File.join(gem, 'src/main.cxx'), <<~CPP)
      #include <mruby.h>
      #include <mruby/array.h>
      #include <mruby/string.h>
      #include <mruby/variable.h>
      #include <cstdio>
      #include <cstdlib>
      extern "C" void mrb_script_benchmark_gem_init(mrb_state*) {}
      extern "C" void mrb_script_benchmark_gem_final(mrb_state*) {}
      int main(int argc, char** argv) {
        mrb_state* M = mrb_open();
        if (!M) { std::fprintf(stderr, "cannot initialize mruby\\n"); return 1; }
        if (M->exc) { mrb_print_error(M); mrb_close(M); return 1; }
        // SCRIPT_WORLD_NO_GC=1: no collection at all, the bound on what the GC costs a batch program.
        if (std::getenv("SCRIPT_WORLD_NO_GC")) M->gc.disabled = TRUE;
        mrb_value args = mrb_ary_new_capa(M, argc);
        for (int i = 1; i < argc; ++i) mrb_ary_push(M, args, mrb_str_new_cstr(M, argv[i]));
        mrb_define_global_const(M, "ARGV", args);
        mrb_value rc = mrb_funcall(M, mrb_obj_value(mrb_module_get(M, "ScriptWorld")), "run", 0);
        if (M->exc) { mrb_print_error(M); mrb_close(M); return 1; }
        int status = mrb_integer_p(rc) ? (int)mrb_integer(rc) : 0;
        mrb_close(M);
        return status;
      }
    CPP
    [bundle, gems]
  end

  # Same as OptcarrotSealedBuild.environment: the enum-step driver is compiled by mrb_load_string, which this world
  # excludes (docs/bc2cpp-enum-step.md, Known limits).
  def self.environment(gems)
    {
      'BC2CPP_BUILD_NAME' => 'script-world',
      'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |name, dir| "#{name}=#{dir}" }),
      'BC2CPP_ENUM_STEP' => '0'
    }
  end
end
