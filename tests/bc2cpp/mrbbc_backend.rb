#!/usr/bin/env ruby
# frozen_string_literal: true

# bc2cpp's standalone mrbbc route: actual lowering and runtime execution, plus refusal/CLI isolation.
# scripts/setup-mrbbc.sh and scripts/setup-qbe.sh build the two tools; no C mrbc or mruby interpreter is needed.
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../bc2cpp/tools/bc2cpp/backend'

root = File.expand_path('../..', __dir__)
entry = File.join(root, 'bc2cpp/tools/bc2cpp/bc2cpp.rb')
lower = ENV.fetch('BC2CPP_MRBBC_LOWER', File.join(root, 'build/mrbbc/mrbbc_lower'))
qbe = ENV.fetch('QBE', File.join(root, 'build/qbe/qbe'))
abort 'run scripts/setup-mrbbc.sh first' unless File.executable?(lower)
abort 'run scripts/setup-qbe.sh first (or set QBE)' unless File.executable?(qbe)

checks = 0
check = lambda do |message, condition|
  raise message unless condition

  checks += 1
end
%w[cpp mrbbc].each do |name|
  argv = ["--backend=#{name}", 'one.rb', 'two.rb']
  check.call('backend selector changes the source list', Bc2cppBackend.take_argv!(argv) == name && argv == %w[one.rb two.rb])
end
argv = ['one.rb']
check.call('the default backend is C++', Bc2cppBackend.take_argv!(argv) == 'cpp' && argv == ['one.rb'])

Dir.mktmpdir('bc2cpp-mrbbc') do |dir|
  # The backend needs no world signature files, native metadata, external mrbc, or inherited C++ controls.
  env = ENV.keys.grep(/\A(?:BC2CPP_|OUT_DIR\z|OUT_SYMBOL\z|ONLY_OWNERS\z|OTHER_OWNERS\z|NATIVE_SRCS\z|FOREIGN_RUBY_SRCS\z)/)
           .to_h { |key| [key, nil] }
  env.merge!('BC2CPP_WORLD_ROOT' => File.join(dir, 'no-world'), 'BC2CPP_NO_MRBC' => '1',
             'BC2CPP_MRBBC_LOWER' => lower, 'OUT_DIR' => dir, 'OUT_SYMBOL' => 'fixture')
  source = File.join(dir, 'input $(touch injected).rb')
  File.write(source, "def twice(x); x * 2; end\ntwice(21)\n")
  run = lambda do |args, overrides = {}|
    Open3.capture3(env.merge(overrides), RbConfig.ruby, entry, *args, chdir: dir)
  end
  build_and_run = lambda do |ir, value, name|
    ir_path = File.join(dir, "#{name}.ir")
    File.write(ir_path, ir)
    ssa, error, status = Open3.capture3(RbConfig.ruby, File.join(root, 'scripts/pathb-qbe-emit.rb'), ir_path)
    check.call("IR emission failed: #{error}", status.success?)
    ssa_path = File.join(dir, "#{name}.ssa")
    File.write(ssa_path, ssa)
    asm, error, status = Open3.capture3(qbe, ssa_path)
    check.call("QBE failed: #{error}", status.success?)
    asm_path = File.join(dir, "#{name}.s")
    File.write(asm_path, asm)
    binary = File.join(dir, name)
    _, error, status = Open3.capture3(ENV.fetch('CC', 'cc'), '-std=c99', "-DMRBBC_VALUE=#{value}",
      '-DMRBBC_GC_THRESHOLD=1', asm_path, File.join(root, 'tests/mrbbc/runtime/mrbrt.c'),
      File.join(root, 'tests/mrbbc/runtime/driver.c'), '-o', binary)
    check.call("runtime link failed: #{error}", status.success?)
    output, error, status = Open3.capture3(binary)
    check.call("runtime failed: #{error}", status.success?)
    output
  end

  %w[8 4 16].each do |value|
    output, error, status = run.call(['--backend=mrbbc', "--mrbbc-value=#{value}", source])
    check.call("lowering failed: #{error}", status.success? && output.start_with?('(ir-module '))
    direct, error, status = Open3.capture3(lower, "--value=#{value}", File.join(dir, 'fixture.mrb'))
    check.call("adapter differs from mrbbc: #{error}", status.success? && direct == output)
    check.call("wrong result for layout #{value}", build_and_run.call(output, value, "method#{value}") == "42\n")
  end
  check.call('a filename was executed by a shell', !File.exist?(File.join(dir, 'injected')))

  first = File.join(dir, 'class.rb')
  second = File.join(dir, 'use.rb')
  File.write(first, "class Counter\n  def initialize(n); @n = n; end\n  def step(x); @n = @n + x; end\nend\ndef visit\n  yield 1\n  yield 2\n  yield 3\nend\n")
  File.write(second, "c = Counter.new(4)\ntotal = 0\nvisit { |x| total = total + c.step(x) }\n[total, c.step(0)]\n")
  output, error, status = run.call(['--backend', 'mrbbc', '--mrbbc-value', '8', first, second])
  check.call("multi-file lowering failed: #{error}", status.success?)
  check.call('multi-file class/block/GC result differs', build_and_run.call(output, '8', 'classes') == "[22, 10]\n")

  frozen_source = File.join(dir, 'frozen.rb')
  File.write(frozen_source, "# frozen_string_literal: true\n'no thawing'\n")
  output, error, status = run.call(['--backend=mrbbc', frozen_source])
  check.call('FSTRING lost its semantics', status.exitstatus == 3 && output.empty? && error.start_with?('refused:') && error.include?('FSTRING'))
  refused = File.join(dir, 'refused.rb')
  File.write(refused, "`echo no_shell`\n")
  output, error, status = run.call(['--backend=mrbbc', refused])
  check.call('unsupported code did not refuse atomically', status.exitstatus == 3 && output.empty? && error.start_with?('refused:'))

  bad_args = [[], ['--mrbbc-value=7', source], ['--mrbbc-value=8', '--mrbbc-value=4', source],
              ['--annotated', source], ['--units', 'plan.json', source]]
  bad_args.each do |args|
    output, error, status = run.call(['--backend=mrbbc', *args])
    check.call("invalid mrbbc arguments accepted: #{args.inspect}", status.exitstatus == 2 && output.empty? && error.start_with?('bc2cpp:'))
  end
  [['--backend=unknown', source], ['--backend'], ['--backend=cpp', '--backend=mrbbc', source],
   ['--mrbbc-value=8', source]].each do |args|
    output, error, status = run.call(args)
    check.call("invalid backend selector accepted: #{args.inspect}", status.exitstatus == 2 && output.empty? && error.start_with?('bc2cpp:'))
  end
  %w[BC2CPP_BUILD_GEMS NATIVE_SRCS FOREIGN_RUBY_SRCS BC2CPP_LINKED_NATIVE_SRCS BC2CPP_LINKED_RUBY_SRCS
     ONLY_OWNERS OTHER_OWNERS BC2CPP_TYPE_FACTS BC2CPP_TYPE_CHECK_ONLY BC2CPP_SELF_REGISTERING].each do |key|
    value = %w[BC2CPP_TYPE_CHECK_ONLY BC2CPP_SELF_REGISTERING].include?(key) ? '1' : 'unhandled'
    output, error, status = run.call(['--backend=mrbbc', source], key => value)
    check.call("C++ build input #{key} was ignored", status.exitstatus == 2 && output.empty? && error.include?(key))
  end
  output, error, status = run.call(['--backend=mrbbc', source], 'BC2CPP_MRBBC_LOWER' => File.join(dir, 'missing-lower'))
  check.call('missing lowerer not diagnosed', status.exitstatus == 1 && output.empty? && error.include?('setup-mrbbc.sh'))
  output, error, status = run.call(['--backend=mrbbc', File.join(dir, 'missing.rb')])
  check.call('missing source not diagnosed', status.exitstatus == 1 && output.empty? && error.include?('missing.rb'))
  syntax = File.join(dir, 'syntax.rb')
  File.write(syntax, "def broken(\n")
  output, error, status = run.call(['--backend=mrbbc', syntax])
  check.call('invalid Ruby leaked output or succeeded', status.exitstatus == 1 && output.empty? && !error.empty?)

  partial = File.join(dir, 'partial lower')
  File.write(partial, "#!/bin/sh\nprintf 'partial IR'\nprintf 'refused: test refusal\\n' >&2\nexit 3\n")
  FileUtils.chmod(0o755, partial)
  output, error, status = run.call(['--backend=mrbbc', source], 'BC2CPP_MRBBC_LOWER' => partial)
  check.call('failed lowerer leaked partial IR or lost its status',
             status.exitstatus == 3 && output.empty? && error == "refused: test refusal\n")
  File.write(partial, "#!/bin/sh\nexit 0\n")
  output, error, status = run.call(['--backend=mrbbc', source], 'BC2CPP_MRBBC_LOWER' => partial)
  check.call('empty successful lowering accepted', status.exitstatus == 1 && output.empty? && error.include?('no IR'))
end
puts "bc2cpp mrbbc backend: #{checks} checks passed"
