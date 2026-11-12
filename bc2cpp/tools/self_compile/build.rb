#!/usr/bin/env ruby
# frozen_string_literal: true

unless RUBY_ENGINE == 'ruby' && RUBY_VERSION.start_with?('4.') &&
       defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  abort 'bc2cpp self compilation requires CRuby 4 with YJIT; set BC2CPP_HOST_RUBY to that ruby executable'
end

require 'digest'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'shellwords'
require_relative '../bc2cpp/world_root'
require_relative '../bc2cpp/bake_sources'
require_relative '../../host-libs/mruby-bc2cpp-runner/mrblib/runner'
require_relative 'artifacts'

tree = BC2CPP_TREE_ROOT
repo = File.dirname(tree)
world = BC2CPP_WORLD_ROOT
out = File.expand_path(ENV.fetch('BC2CPP_SELF_BUILD_DIR', File.join(repo, 'build', 'bc2cpp-self')))
FileUtils.mkdir_p(out)
lock = File.open(File.join(out, '.lock'), 'w')
lock.flock(File::LOCK_EX)

config = File.join(tree, 'host-libs/mruby-bc2cpp-runner/build_config.rb')
bootstrap = File.join(out, 'bootstrap')
manifest_path = File.join(out, 'runtime.json')
compiler = ENV.fetch('BC2CPP_SELF_CXX', File.join(repo, 'nfcxx'))
common = {
  'LD' => nil, 'BC2CPP_WORLD_ROOT' => world, 'BC2CPP_TREE_ROOT' => tree,
  'MRUBY_CONFIG' => config, 'BC2CPP_RUNNER_OPT' => '1', 'BC2CPP_RUNNER_CXX' => compiler,
  'NFCXX_BACKEND' => ENV.fetch('NFCXX_BACKEND', 'gcc')
}
jobs = ENV.fetch('BC2CPP_BUILD_JOBS', '8')
build = lambda do |env, log, *tasks|
  File.open(log, 'w') do |io|
    ok = system(common.merge(env), RbConfig.ruby, '-S', 'rake', "-j#{jobs}", *tasks,
                chdir: File.join(world, '3rd/mruby'), out: io, err: io)
    abort "bc2cpp self build failed; see #{log}" unless ok
  end
end

warn 'bc2cpp-self: building bootstrap runtime'
build.call({ 'MRUBY_BUILD_DIR' => bootstrap, 'BC2CPP_RUNNER_MANIFEST' => manifest_path,
             'BC2CPP_RUNNER_SELF' => nil, 'BC2CPP_MRBC_RB' => '0' },
           File.join(out, 'bootstrap.log'), 'all', 'bc2cpp_runner_manifest')
manifest = JSON.parse(File.read(manifest_path))
mrbc = File.join(bootstrap, 'bc2cpp-runner/bin/mrbc')

generation = File.join(out, 'generation')
inputs = File.join(generation, 'inputs')
FileUtils.mkdir_p(inputs)
files = bake('tools/bc2cpp/bc2cpp.rb').filter_map do |name, source|
  next if BC2CPPRunner::DEBUG_SOURCES.include?(name)
  path = File.join(inputs, "#{name}.rb")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, source) unless File.file?(path) && File.binread(path) == source.b
  path
end
env = {
  'BC2CPP_WORLD_ROOT' => world, 'BC2CPP_TREE_ROOT' => tree,
  'MRBC' => mrbc, 'BC2CPP_MRBC_RB' => '', 'BC2CPP_BUILD_NAME' => 'bc2cpp-self',
  'BC2CPP_BUILD_GEMS' => Shellwords.join(manifest.fetch('gems').map { |name, dir| "#{name}=#{dir}" }),
  'NATIVE_SRCS' => Shellwords.join(manifest.fetch('native')),
  'FOREIGN_RUBY_SRCS' => Shellwords.join(manifest.fetch('ruby')),
  'OUT_DIR' => generation, 'OUT_SYMBOL' => 'bc2cpp_self', 'SKIP_UNSUPPORTED' => '1',
  'BC2CPP_SIG_DIRS' => '', 'BC2CPP_SELF_REGISTERING' => '1',
  'BC2CPP_SHARDS' => ENV.fetch('BC2CPP_SELF_SHARDS', '16'),
  'BC2CPP_PROBE_DEPTH' => ENV.fetch('BC2CPP_PROBE_DEPTH', '4'),
  'BC2CPP_PROFILE_TIMINGS' => '1', 'BC2CPP_CLASS_BODY_EMIT' => '0'
}
# These describe the caller's input program, not the compiler being built.
# In particular ONLY_OWNERS must not filter every compiler method out.
env, controls = Bc2cppSelfCompile.generation_environment(env)
dependencies = (files + manifest.fetch('native') + manifest.fetch('ruby') + manifest.fetch('headers')).uniq.sort
fingerprint = Digest::SHA256.hexdigest(JSON.generate([RUBY_DESCRIPTION, env.reject { |_, value| value.nil? }, controls, manifest.fetch('defines'),
  dependencies.map { |path| [path, Digest::SHA256.file(path).hexdigest] }]))
stamp = File.join(generation, 'fingerprint')
main = File.join(generation, 'bc2cpp_self_gen.cpp')
outputs = [main, File.join(generation, 'bc2cpp_self_decls.h'), File.join(generation, 'bc2cpp_self_entry.h')]
outputs.concat((1...Integer(env.fetch('BC2CPP_SHARDS'))).map { |i| File.join(generation, "bc2cpp_self_gen_shard#{i}.cpp") })
unless File.file?(stamp) && File.read(stamp) == fingerprint && outputs.all? { |path| File.size?(path) }
  warn "bc2cpp-self: compiling #{files.size} Ruby files with #{RUBY_DESCRIPTION}"
  File.write(File.join(generation, 'host.json'), JSON.pretty_generate(
    'ruby' => RUBY_DESCRIPTION, 'yjit' => RubyVM::YJIT.enabled?, 'sources' => files,
    'environment' => env, 'fingerprint' => fingerprint))
  File.open(main, 'w') do |output|
    File.open(File.join(generation, 'generation.log'), 'w') do |log|
      ok = system(env, RbConfig.ruby, '--yjit', File.join(tree, 'tools/bc2cpp/bc2cpp.rb'),
                  '--annotated', *files, out: output, err: log)
      abort "self code generation failed; see #{log.path}" unless ok
    end
  end
  File.write(stamp, fingerprint)
end

gem_dir = File.join(out, 'compiled-gem')
previous_units = Dir[File.join(gem_dir, 'src/bc2cpp_self_gen_shard*.cpp')]
count = Bc2cppSelfCompile.write_gem(generation, gem_dir)
warn "bc2cpp-self: building #{count} translated methods with #{compiler}"
target = File.join(out, 'runtime')
unless previous_units == Dir[File.join(gem_dir, 'src/bc2cpp_self_gen_shard*.cpp')]
  # ar replaces existing members but does not remove an old shard that vanished.
  FileUtils.rm_f(File.join(target, 'bc2cpp-self/lib/libmruby.a'))
end
build.call({ 'MRUBY_BUILD_DIR' => target, 'BC2CPP_RUNNER_SELF' => '1',
             'BC2CPP_RUNNER_SELF_GEM' => gem_dir, 'BC2CPP_RUNNER_MANIFEST' => nil,
             'MRBC' => mrbc, 'BC2CPP_MRBC_RB' => '0' }, File.join(out, 'build.log'), 'all',
           File.join(target, 'bc2cpp-self/lib/libmruby.flags.mak'))
puts File.join(target, 'bc2cpp-self/bin/mruby')
