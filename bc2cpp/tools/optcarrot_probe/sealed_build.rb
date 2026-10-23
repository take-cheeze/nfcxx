# frozen_string_literal: true

require 'fileutils'
require 'shellwords'
require_relative 'onig_aliases'

module OptcarrotSealedBuild
  def self.prepare(root, temp, compiled_gem)
    mruby = File.join(root, '3rd/mruby')
    excluded = BC2CPP_OPEN_WORLD_GEMS + %w[mruby-compiler mruby-bin-mrbc mruby-test mruby-sleep]
    gems = Dir[File.join(mruby, 'mrbgems/mruby-*/mrbgem.rake')].sort.to_h do |path|
      [File.basename(File.dirname(path)), File.dirname(path)]
    end.reject { |name, _| excluded.include?(name) || name.start_with?('mruby-bin-') }
    hal = RUBY_PLATFORM.match?(/mswin|mingw/) ? 'win' : 'posix'
    %w[dir io socket task].each do |name|
      gem_name = "hal-#{hal}-#{name}"
      gems[gem_name] = File.join(mruby, 'mrbgems', gem_name)
    end
    gems['mruby-onig-regexp'] = OptcarrotOnigAliases.prepare(root, temp)
    gems['optcarrot-compiled'] = compiled_gem
    # The mruby- prefix keeps the bundle's path gem-relative, so its predicates can be keyed in predicate_whitelist.txt.
    benchmark = gems['optcarrot-benchmark'] = File.join(temp, 'mruby-optcarrot-benchmark')
    FileUtils.mkdir_p([File.join(benchmark, 'mrblib'), File.join(benchmark, 'src')])
    bundle = File.join(benchmark, 'mrblib/benchmark.rb')
    system(RbConfig.ruby, File.join(root, 'tools/optcarrot_probe/build_bundle.rb'), bundle, exception: true)
    source = File.read(bundle)
    tail = File.read(File.join(root, 'tools/optcarrot_probe/runner_tail.rb'))
    raise 'benchmark tail changed' unless source.end_with?(tail)

    source = source.delete_suffix(tail)
    source << "\nmodule OptcarrotBenchmark\n  def self.run\n    OptcarrotProbe.install!\n"
    source << tail.lines.map { |line| "    #{line}" }.join
    source << "  end\nend\n"
    File.write(bundle, source)
    File.write(File.join(benchmark, 'mrbgem.rake'), <<~RUBY)
      MRuby::Gem::Specification.new('optcarrot-benchmark') do |spec|
        spec.license = 'MIT'
        spec.authors = 'probe'
        spec.add_dependency 'optcarrot-compiled'
      end
    RUBY
    File.write(File.join(benchmark, 'src/main.cxx'), <<~CPP)
      #include <mruby.h>
      #include <mruby/array.h>
      #include <mruby/string.h>
      #include <mruby/variable.h>
      #include <cstdio>
      extern "C" void mrb_optcarrot_benchmark_gem_init(mrb_state*) {}
      extern "C" void mrb_optcarrot_benchmark_gem_final(mrb_state*) {}
      int main(int argc, char** argv) {
        if (argc != 3) { std::fprintf(stderr, "usage: optcarrot ROM FRAMES\\n"); return 2; }
        mrb_state* M = mrb_open();
        if (!M) { std::fprintf(stderr, "cannot initialize mruby\\n"); return 1; }
        if (M->exc) { mrb_print_error(M); mrb_close(M); return 1; }
        mrb_value args = mrb_ary_new_capa(M, 2);
        mrb_ary_push(M, args, mrb_str_new_cstr(M, argv[1]));
        mrb_ary_push(M, args, mrb_str_new_cstr(M, argv[2]));
        mrb_define_global_const(M, "ARGV", args);
        mrb_funcall(M, mrb_obj_value(mrb_module_get(M, "OptcarrotBenchmark")), "run", 0);
        int failed = M->exc != nullptr;
        if (failed) { mrb_print_error(M); }
        mrb_close(M);
        return failed;
      }
    CPP
    [bundle, gems]
  end

  # bc2cpp compiles closed-world programs only, so a probe of the benchmark compiles this sealed
  # world too. Returns [sources, env]: the bundle and the closed-world inputs (the outside sources of the build).
  def self.bc2cpp_world(root, temp)
    bundle, gems = prepare(root, temp, File.join(temp, 'gem'))
    native, ruby = bc2cpp_closed_world_outside_srcs('optcarrot-probe', gems, root)
    [[bundle], environment(gems).merge('NATIVE_SRCS' => Shellwords.join(native), 'FOREIGN_RUBY_SRCS' => Shellwords.join(ruby),
                                       'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_SIG_DIRS' => '')]
  end

  def self.environment(gems)
    {
      'BC2CPP_BUILD_NAME' => 'optcarrot-probe',
      'BC2CPP_BUILD_GEMS' => Shellwords.join(gems.map { |name, dir| "#{name}=#{dir}" })
    }
  end
end
