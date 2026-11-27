#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
lower = File.join(root, 'build/mrbbc/mrbbc_lower')
qbe = ENV.fetch('QBE', File.join(root, 'build/qbe/qbe'))
abort 'run scripts/setup-mrbbc.sh and scripts/setup-qbe.sh first' unless [lower, qbe].all? { |p| File.executable?(p) }
entry = File.join(root, 'bc2cpp/tools/bc2cpp/bc2cpp.rb')
source = File.join(root, 'tests/mrbbc/call/library.rb')
exports = %w[sum divide answer wrong_result failed_join failed_inspect after_error]
checks = 0
check = lambda do |ok, message|
  raise message unless ok

  checks += 1
end
run = lambda do |*args|
  out, err, result = Open3.capture3(*args)
  check.call(result.success?, "#{args.last}: #{err}")
  out
end
Dir.mktmpdir('mrbbc-call') do |dir|
  env = ENV.keys.grep(/\A(?:BC2CPP_|OUT_DIR\z|OUT_SYMBOL\z|ONLY_OWNERS\z|OTHER_OWNERS\z|NATIVE_SRCS\z|FOREIGN_RUBY_SRCS\z)/)
           .to_h { |key| [key, nil] }
  env.merge!('BC2CPP_NO_MRBC' => '1', 'BC2CPP_WORLD_ROOT' => File.join(dir, 'no-world'), 'OUT_DIR' => dir,
             'OUT_SYMBOL' => 'library', 'BC2CPP_MRBBC_LOWER' => lower)
  %w[8 4 16].each do |value|
    ir = run.call(env, RbConfig.ruby, entry, '--backend=mrbbc', "--mrbbc-value=#{value}",
                  *exports.map { |name| "--mrbbc-export-i64=#{name}" }, source)
    path = File.join(dir, "library#{value}")
    File.write("#{path}.ir", ir)
    File.write("#{path}.ssa", run.call(RbConfig.ruby, File.join(root, 'scripts/pathb-qbe-emit.rb'), "#{path}.ir"))
    File.write("#{path}.s", run.call(qbe, "#{path}.ssa"))
    rt = File.join(root, 'tests/mrbbc/runtime')
    run.call(ENV.fetch('CC', 'cc'), '-std=c99', '-Wall', '-Wextra', '-Werror', '-O2', "-DMRBBC_VALUE=#{value}",
             '-DMRBBC_GC_THRESHOLD=1', *Shellwords.split(ENV.fetch('RT_CFLAGS', '')), "#{path}.s",
             File.join(rt, 'mrbrt.c'), File.join(rt, 'mrbrt_call.c'), File.join(root, 'tests/mrbbc/call/driver.c'), '-o', path)
    output = run.call(path)
    check.call(output.match?(/boxed\/direct call ABI: \d+ checks passed/), "missing runtime checks: #{output}")
    puts "layout #{value}: #{output.strip}"
    values_exe = File.join(dir, "values#{value}")
    run.call(ENV.fetch('CC', 'cc'), '-std=c99', '-Wall', '-Wextra', '-Werror', '-O2', "-DMRBBC_VALUE=#{value}",
             '-DMRBBC_GC_THRESHOLD=1', *Shellwords.split(ENV.fetch('RT_CFLAGS', '')), "#{path}.s",
             File.join(rt, 'mrbrt.c'), File.join(rt, 'mrbrt_call.c'), File.join(root, 'tests/mrbbc/call/values_driver.c'), '-o', values_exe)
    puts "layout #{value}: #{run.call(values_exe).strip}"
  end
  {
    'missing' => 'def other; 1; end',
    'optional' => 'def sum(x = 1); x; end',
    'rest' => 'def sum(*xs); 1; end',
    'keywords' => 'def sum(x:); x; end',
    'class_only' => 'class A; def sum(x); x; end; end',
    'redefined_arity' => 'def sum(a); a; end; def sum(a,b); b; end'
  }.each do |name, text|
    input = File.join(dir, "#{name}.rb")
    File.write(input, text)
    out, err, result = Open3.capture3(env, RbConfig.ruby, entry, '--backend=mrbbc', '--mrbbc-export-i64=sum', input)
    check.call(result.exitstatus == 3 && out.empty? && err.include?('refused: i64 export'), "export refusal #{name}: #{err}")
  end
  [['--mrbbc-export-i64=bad!'], ['--mrbbc-export-i64'], ['--mrbbc-export-i64=sum', '--mrbbc-export-i64=sum']].each do |flags|
    out, err, result = Open3.capture3(env, RbConfig.ruby, entry, '--backend=mrbbc', source, *flags)
    check.call(result.exitstatus == 2 && out.empty? && err.start_with?('bc2cpp:'), "invalid export flags: #{err}")
  end
  out, err, result = Open3.capture3(env, RbConfig.ruby, entry, '--backend=cpp', '--mrbbc-export-i64=sum', source)
  check.call(result.exitstatus == 2 && out.empty? && err.include?('require --backend=mrbbc'), "C++ export isolation: #{err}")
  # The common interface is usable from C++ without a language runtime or libuv.
  cpp = File.join(dir, 'native.cpp')
  File.write(cpp, <<~CPP)
    #include "#{root}/lib/pathb/call.h"
    #include <cassert>
    static int64_t add(int64_t x, int64_t y) { return x + y; }
    static int64_t thunk(void *, const int64_t *a) { return add(a[0], a[1]); }
    int main() {
      int64_t x = 20, y = 22, out = 0;
      NfcCallSlot args[] = {nfc_call_i64_slot(&x), nfc_call_i64_slot(&y)}, result = nfc_call_i64_slot(&out);
      NfcCallFrame frame = {NFC_CALL_VERSION, args, 2, &result, 1, 0, nullptr, {0}};
      NfcI64Target target = {2, thunk, nullptr};
      NfcCallable fn = {nfc_call_i64_entry, &target};
      assert(add(x, y) == 42 && nfc_call_invoke(&fn, &frame) == NFC_CALL_OK && out == 42);
    }
  CPP
  native = File.join(dir, 'native')
  run.call(ENV.fetch('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', cpp, '-o', native)
  run.call(native)
end
puts "bc2cpp mrbbc call exports: #{checks} checks passed"
