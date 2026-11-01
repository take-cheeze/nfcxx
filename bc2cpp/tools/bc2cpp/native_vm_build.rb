# frozen_string_literal: true

require 'stringio'
require_relative 'native_vm'

module NativeVM
  SOURCES = [__FILE__, File.join(__dir__, 'native_vm.rb')].freeze

  module GemDependencies
    def define_gem_init_builder
      super
      return unless build.instance_variable_get(:@native_vm_dir)

      Rake::FileTask.define_task("#{build_dir}/gem_init.c" => NativeVM::SOURCES)
    end
  end

  module_function

  def configure(build)
    dir = File.join(build.build_dir, 'native-vm')
    header = File.join(dir, 'dispatch.inc')
    FileUtils.mkdir_p(dir)
    NativeVM.builtins(dir)
    build.instance_variable_set(:@native_vm_dir, dir)
    MRuby::Gem::Specification.prepend(GemDependencies) unless MRuby::Gem::Specification < GemDependencies
    Rake::FileTask.define_task(File.join(build.build_dir, 'mrblib/mrblib.c') => SOURCES)
    [build.cc, build.cxx].each do |tool|
      tool.defines << %(MRB_NATIVE_VM_DISPATCH_HEADER='"#{header}"')
      tool.defines << 'MRB_NATIVE_VM_REQUIRE'
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
      Rake::FileTask.define_task(build.objfile(File.join(build.build_dir, 'src', name)) => [src, header])
    end
  end
end
