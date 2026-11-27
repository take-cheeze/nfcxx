#!/usr/bin/env ruby
# frozen_string_literal: true

# Optional real-library integrations; C/C++ only. Select dependencies with TVM_FFI_ROOT/LIBTORCH/QT6_PREFIX or QT6=1.
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
selected = []
selected << 'tvm' if ENV['TVM_FFI_ROOT']
selected << 'torch' if ENV['LIBTORCH']
selected << 'qt' if ENV['QT6_PREFIX'] || ENV['QT6'] == '1'
selected << 'chain' if selected.size == 3
selected << 'nfcast' if ENV['NFCAST'] == '1'
if selected.empty?
  warn 'skip: set TVM_FFI_ROOT, LIBTORCH, QT6_PREFIX, QT6=1 or NFCAST=1 for integration tests'
  exit 77
end
checks = 0
run = lambda do |*args|
  out, err, status = Open3.capture3(*args)
  abort "#{args.inspect}:\n#{err}" unless status.success?
  checks += 1
  out
end
qbe = ENV.fetch('QBE', File.join(root, 'build/qbe/qbe'))
cc = ENV.fetch('CC', 'cc')
cxx = ENV.fetch('CXX', 'c++')
extra = Shellwords.split(ENV.fetch('RT_CFLAGS', ''))
qt_env = {}
qt_flags = []
moc = nil
if selected.include?('qt')
  prefix = ENV['QT6_PREFIX'] && File.expand_path(ENV['QT6_PREFIX'])
  if prefix
    qt_env['PKG_CONFIG_PATH'] = [File.join(prefix, 'lib/x86_64-linux-gnu/pkgconfig'), File.join(prefix, 'lib/pkgconfig'), ENV['PKG_CONFIG_PATH']].compact.join(':')
  end
  variables = prefix ? ["--define-variable=prefix=#{prefix}"] : []
  qt_flags = Shellwords.split(run.call(qt_env, 'pkg-config', *variables, '--cflags', '--libs', 'Qt6Core'))
  libexec = run.call(qt_env, 'pkg-config', *variables, '--variable=libexecdir', 'Qt6Core').strip
  moc = ENV.fetch('MOC', File.join(libexec, 'moc'))
  qt_flags << "-Wl,-rpath,#{File.join(prefix, 'lib/x86_64-linux-gnu')}" if prefix
end
Dir.mktmpdir('mrbbc-external') do |dir|
  env = ENV.keys.grep(/\A(?:BC2CPP_|OUT_DIR\z|OUT_SYMBOL\z|ONLY_OWNERS\z|OTHER_OWNERS\z|NATIVE_SRCS\z|FOREIGN_RUBY_SRCS\z)/)
           .to_h { |key| [key, nil] }
  env.merge!('BC2CPP_NO_MRBC' => '1', 'BC2CPP_WORLD_ROOT' => File.join(dir, 'no-world'), 'OUT_DIR' => dir, 'OUT_SYMBOL' => 'library')
  rt = File.join(root, 'tests/mrbbc/runtime')
  test_dir = File.join(root, 'tests/mrbbc/call')
  qt_sources = []
  ast_objects = []
  if selected.include?('nfcast')
    sources = %w[nfcast_core nfcast_ops nfcast_parse nfcast_nodes nfcast_lib nfcast_tier nfcast_jit nfcast_bytecode]
                .map { |name| File.join(root, "lib/ast/#{name}.cpp") }
    sources << File.join(root, 'tools/lua54bc/lua54_chunk.cpp')
    sources.each_with_index do |source, i|
      object = File.join(dir, "nfcast#{i}.o")
      run.call(cxx, '-std=c++20', '-O1', '-pthread', *extra, '-c', source, '-o', object)
      ast_objects << object
    end
  end
  if selected.include?('qt')
    %w[lib/pathb/call_qt.hpp tests/mrbbc/call/qt_object.hpp].each_with_index do |header, i|
      generated = File.join(dir, "moc#{i}.cpp")
      run.call(moc, File.join(root, header), '-o', generated)
      qt_sources << generated
    end
    qt_sources << File.join(root, 'lib/pathb/call_qt.cpp')
  end
  ENV.fetch('MRBBC_VALUES', '8 4 16').split.each do |value|
    abort 'MRBBC_VALUES must contain only 8, 4 or 16' unless %w[8 4 16].include?(value)
    base = File.join(dir, "library#{value}")
    ir = run.call(env, RbConfig.ruby, File.join(root, 'bc2cpp/tools/bc2cpp/bc2cpp.rb'), '--backend=mrbbc',
                  "--mrbbc-value=#{value}", '--mrbbc-export-i64=sum', '--mrbbc-export-i64=divide', File.join(test_dir, 'library.rb'))
    File.write("#{base}.ir", ir)
    File.write("#{base}.ssa", run.call(RbConfig.ruby, File.join(root, 'scripts/pathb-qbe-emit.rb'), "#{base}.ir"))
    File.write("#{base}.s", run.call(qbe, "#{base}.ssa"))
    objects = %w[mrbrt mrbrt_call].map do |name|
      object = File.join(dir, "#{name}#{value}.o")
      run.call(cc, '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror', "-DMRBBC_VALUE=#{value}", '-DMRBBC_GC_THRESHOLD=1',
               *extra, '-c', File.join(rt, "#{name}.c"), '-o', object)
      object
    end
    flags_by_adapter = {}
    selected.each do |adapter|
      flags = []
      sources = []
      case adapter
      when 'tvm'
        tvm = File.expand_path(ENV.fetch('TVM_FFI_ROOT'))
        libs = File.expand_path(ENV.fetch('TVM_FFI_LIBDIR', File.join(tvm, 'build/lib')))
        flags = ['-isystem', File.join(tvm, 'include'), '-isystem', File.join(tvm, '3rdparty/dlpack/include'),
                 "-L#{libs}", "-Wl,-rpath,#{libs}", '-ltvm_ffi']
      when 'torch'
        torch = File.expand_path(ENV.fetch('LIBTORCH'))
        config = File.read(File.join(torch, 'share/cmake/Torch/TorchConfig.cmake'))
        abi = ENV.fetch('TORCH_CXX11_ABI', config[/_GLIBCXX_USE_CXX11_ABI=([01])/, 1] || '1')
        abort 'TORCH_CXX11_ABI must be 0 or 1' unless %w[0 1].include?(abi)
        flags = ["-D_GLIBCXX_USE_CXX11_ABI=#{abi}", '-isystem', File.join(torch, 'include'),
                 '-isystem', File.join(torch, 'include/torch/csrc/api/include'), "-L#{torch}/lib", "-Wl,-rpath,#{torch}/lib",
                 '-ltorch', '-ltorch_cpu', '-lc10']
      when 'qt'
        flags = qt_flags
        sources = qt_sources
      when 'chain'
        flags = flags_by_adapter.values.flatten + ['-DQT_NO_KEYWORDS']
        sources = qt_sources
      when 'nfcast'
        sources = ast_objects
        flags = ['-ldl']
      end
      flags_by_adapter[adapter] = flags
      exe = File.join(dir, "#{adapter}#{value}")
      run.call(cxx, '-std=c++20', '-O1', '-fPIC', '-pthread', '-Wall', '-Wextra', '-Werror', "-DMRBBC_VALUE=#{value}",
               *Shellwords.split(ENV.fetch('CXXFLAGS', '')), *extra, File.join(test_dir, "#{adapter}.cpp"), *sources,
               "#{base}.s", *objects, *flags, '-o', exe)
      puts "layout #{value}: #{run.call(exe).strip}"
    end
  end
end
puts "external boxed calls: #{checks} build/run checks passed"
