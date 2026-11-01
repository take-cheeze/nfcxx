# frozen_string_literal: true

require 'stringio'
require_relative 'native_vm'

module NativeVM
  SOURCES = [__FILE__, File.join(__dir__, 'native_vm.rb')].freeze

  module GemDependencies
    def setup_compilers
      if build.cc.defines.include?('MRB_NATIVE_ONLY') && %w[mruby-compiler mruby-eval].include?(name)
        raise "native-only runtime cannot include #{name}"
      end
      super
    end

    def define_gem_init_builder
      super
      return unless build.instance_variable_get(:@native_vm_dir)

      Rake::FileTask.define_task("#{build_dir}/gem_init.c" => NativeVM::SOURCES)
    end
  end

  module_function

  def configure(build, native_only: build.name == 'closed' && ENV.fetch('BC2CPP_NATIVE_ONLY', '1') != '0')
    dir = File.join(build.build_dir, 'native-vm')
    header = File.join(dir, 'dispatch.inc')
    FileUtils.mkdir_p(dir)
    mode_file = File.join(dir, 'runtime-mode')
    mode = native_only ? 'native-only' : 'mixed'
    unless File.exist?(mode_file) && File.read(mode_file) == mode
      File.write(mode_file, mode)
      %w[load dump cdump codedump vm vm-cxx].each do |name|
        base = File.join(build.build_dir, 'src', name)
        FileUtils.rm_f([build.objfile(base), "#{base}.pi"])
      end
    end
    NativeVM.builtins(dir)
    build.instance_variable_set(:@native_vm_dir, dir)
    # Recreate archives so members from an earlier gem set cannot retain bytecode or compiler entry points.
    if native_only
      [build.libmruby_static, build.libmruby_core_static].each do |archive|
        Rake::FileTask.define_task(archive) { |task| FileUtils.rm_f(task.name) }
      end
    end
    MRuby::Gem::Specification.prepend(GemDependencies) unless MRuby::Gem::Specification < GemDependencies
    Rake::FileTask.define_task(File.join(build.build_dir, 'mrblib/mrblib.c') => SOURCES)
    [build.cc, build.cxx].each do |tool|
      tool.defines << %(MRB_NATIVE_VM_DISPATCH_HEADER='"#{header}"')
      tool.defines << 'MRB_NATIVE_VM_REQUIRE'
      tool.defines << 'MRB_NATIVE_ONLY' if native_only
    end
    build.mrbc.define_singleton_method(:run) do |out, *args, **kwargs|
      raise 'native VM requires C-struct output' if kwargs[:cdump] == false

      buffer = StringIO.new
      buffer.define_singleton_method(:path) { out.path }
      method(:run).super_method.call(buffer, *args, **kwargs)
      out.puts NativeVM.transform(buffer.string, dir)
    end
    update = "native-vm:update:#{build.name}"
    Rake::Task.define_task(update) do
      Rake::Task[build.presym.list_path].invoke
      NativeVM.dispatch(dir, header)
    end
    Rake::FileTask.define_task(header => update)
    %w[vm vm-cxx].each do |name|
      src = name == 'vm' ? File.join(MRUBY_ROOT, 'src/vm.c') : File.join(build.build_dir, 'src/vm-cxx.cxx')
      Rake::FileTask.define_task(build.objfile(File.join(build.build_dir, 'src', name)) => [src, header, mode_file])
    end
  end
end
