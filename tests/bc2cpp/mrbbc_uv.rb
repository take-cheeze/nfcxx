#!/usr/bin/env ruby
# frozen_string_literal: true

# Real host I/O through the optional libuv runtime, compared with Ruby in every value layout under GC stress.
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
lower = File.join(root, 'build/mrbbc/mrbbc_lower')
qbe = ENV.fetch('QBE', File.join(root, 'build/qbe/qbe'))
abort 'run scripts/setup-mrbbc.sh and scripts/setup-qbe.sh first' unless [lower, qbe].all? { |p| File.executable?(p) }
uv, error, status = Open3.capture3('pkg-config', '--cflags', '--libs', 'libuv')
abort "libuv development files are required (pkg-config libuv): #{error}" unless status.success?
uv_flags = Shellwords.split(uv)
cc = ENV.fetch('CC', 'cc')
extra = Shellwords.split(ENV.fetch('RT_CFLAGS', ''))
checks = 0
check = lambda do |message, condition|
  raise message unless condition

  checks += 1
end

Dir.mktmpdir('mrbbc-uv') do |dir|
  env = ENV.keys.grep(/\A(?:BC2CPP_|OUT_DIR\z|OUT_SYMBOL\z|ONLY_OWNERS\z|OTHER_OWNERS\z|NATIVE_SRCS\z|FOREIGN_RUBY_SRCS\z)/)
           .to_h { |key| [key, nil] }
  env.merge!('BC2CPP_NO_MRBC' => '1', 'BC2CPP_WORLD_ROOT' => File.join(dir, 'no-world'), 'OUT_DIR' => dir,
             'OUT_SYMBOL' => 'host', 'BC2CPP_MRBBC_LOWER' => lower)
  build = lambda do |value, name, sources, hosted = true|
    ir, err, result = Open3.capture3(env, RbConfig.ruby, File.join(root, 'bc2cpp/tools/bc2cpp/bc2cpp.rb'),
                                  '--backend=mrbbc', "--mrbbc-value=#{value}", *sources)
    check.call("lower #{name}: #{err}", result.success?)
    ir_path = File.join(dir, "#{name}.ir")
    File.binwrite(ir_path, ir)
    ssa, err, result = Open3.capture3(RbConfig.ruby, File.join(root, 'scripts/pathb-qbe-emit.rb'), ir_path)
    check.call("emit #{name}: #{err}", result.success?)
    ssa_path = File.join(dir, "#{name}.ssa")
    File.write(ssa_path, ssa)
    asm, err, result = Open3.capture3(qbe, ssa_path)
    check.call("qbe #{name}: #{err}", result.success?)
    asm_path = File.join(dir, "#{name}.s")
    File.write(asm_path, asm)
    exe = File.join(dir, name)
    rt = File.join(root, 'tests/mrbbc/runtime')
    flags = hosted ? ['-DMRBBC_LIBUV=1', File.join(rt, 'mrbrt_uv.c'), *uv_flags] : []
    _, err, result = Open3.capture3(cc, '-std=c99', '-Wall', '-Wextra', '-Werror', "-DMRBBC_VALUE=#{value}",
                                  '-DMRBBC_GC_THRESHOLD=1', *extra, asm_path, File.join(rt, 'mrbrt.c'),
                                  File.join(rt, 'uv_driver.c'), *flags, '-o', exe)
    check.call("link #{name}: #{err}", result.success?)
    exe
  end
  fixture = lambda do |name, source|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    path
  end
  state = File.join(root, 'scripts/nfcxx-state.rb')
  harness = File.join(root, 'tests/mrbbc/nfcxx/state_io_entry.rb')
  byte_mode = '$stdin.binmode; $stdout.binmode; $stderr.binmode; ARGV.map!(&:b)' + "\n"
  reference = fixture.call('reference', byte_mode + "require #{state.dump}\n" + File.read(harness))
  io = fixture.call('streams', <<~'RUBY')
    a = ARGV
    a << "mutated"
    $stdout.write([a == ARGV, ARGV, $stdin.read, $stdin.read, STDIN == $stdin, STDOUT == $stdout, STDERR == $stderr].inspect)
    $stderr.write("stderr\x00ok")
  RUBY
  override = fixture.call('override', <<~'RUBY')
    class Reader
      def read
        "user read"
      end
      def write(data)
        "user " + data
      end
    end
    $stdout.write([Reader.new.read, Reader.new.write("write")].inspect)
  RUBY
  predicates = fixture.call('predicates', <<~'RUBY')
    $stdout.write([File.exist?(ARGV[0]), File.file?(ARGV[0]), File.directory?(ARGV[0]), Dir.exist?(ARGV[0]),
                   File.exist?(ARGV[1]), File.file?(ARGV[1]), File.directory?(ARGV[1]), Dir.exist?(ARGV[1]),
                   File.file?(ARGV[2]), Dir.exist?(ARGV[2]), File.executable?(ARGV[2]), File.read(ARGV[2])].inspect)
  RUBY
  plain = File.join(dir, 'plain')
  File.write(plain, 'symlink bytes')
  File.chmod(0o600, plain)
  linked = File.join(dir, 'linked')
  File.symlink(plain, linked)
  cases = {
    'missing' => ['File.read(ARGV[0])', 'Errno::ENOENT'],
    'nul' => ['File.read("bad\x00path")', 'ArgumentError'],
    'write_type' => ['File.write(ARGV[0], 1)', 'NotImplementedError'],
    'read_stdout' => ['$stdout.read', 'IOError'],
    'write_stdin' => ['$stdin.write("no")', 'IOError'],
    'read_length' => ['$stdin.read(1)', 'NotImplementedError'],
    'host_new' => ['File.new', 'NotImplementedError']
  }
  %w[8 4 16].each do |value|
    exe = build.call(value, "state#{value}", [state, harness])
    path = File.join(dir, "records#{value}")
    args = [path, dir, "space argument", "日本語", ""]
    ["", ("a\x00\xff\n".b * 20000)].each do |input|
      expected, expected_err, expected_status = Open3.capture3(RbConfig.ruby, reference, *args, stdin_data: input)
      bytes = File.binread(path)
      actual, err, result = Open3.capture3(exe, *args, stdin_data: input)
      check.call("state status layout #{value}", expected_status.success? && result.success?)
      check.call("state stdout layout #{value}", actual.b == expected.b)
      check.call("state stderr layout #{value}", err == expected_err)
      check.call("state file layout #{value}", File.binread(path) == bytes)
    end
    [[io, "streams#{value}", ["one", "two"]], [override, "override#{value}", []],
     [predicates, "predicates#{value}", [dir, File.join(dir, 'absent'), linked]]].each do |src, name, args2|
      exe = build.call(value, name, [src])
      ref = fixture.call("reference_#{name}", byte_mode + File.read(src))
      expected, expected_err, expected_status = Open3.capture3(RbConfig.ruby, ref, *args2, stdin_data: "input\x00bytes")
      actual, err, result = Open3.capture3(exe, *args2, stdin_data: "input\x00bytes")
      check.call("#{name} differs: #{[actual, err, result.exitstatus].inspect} != #{[expected, expected_err, expected_status.exitstatus].inspect}",
                 expected_status.success? && result.success? && actual == expected && err == expected_err)
    end
    cases.each do |name, (source, error_class)|
      src = fixture.call(name, source)
      exe = build.call(value, "#{name}#{value}", [src])
      target = File.join(dir, name == 'missing' ? 'nonexistent' : 'sentinel')
      File.write(target, 'preserved') unless name == 'missing'
      out, err, result = Open3.capture3(exe, target)
      check.call("#{name} error layout #{value}: #{err}", result.exitstatus == 1 && out.empty? && err.end_with?("(#{error_class})\n"))
      check.call('invalid write truncated its target', File.read(target) == 'preserved') if name == 'write_type'
    end
    src = fixture.call('unhosted', '$stdout.write("no")')
    exe = build.call(value, "unhosted#{value}", [src], false)
    out, err, result = Open3.capture3(exe)
    check.call('unhosted I/O was not refused', result.exitstatus == 1 && out.empty? && err.include?('MRBBC_LIBUV=1'))
  end
end
puts "bc2cpp mrbbc libuv runtime: #{checks} checks passed"
