#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../../bc2cpp/tools/self_compile/artifacts'
require_relative '../../bc2cpp/host-libs/mruby-bc2cpp-runner/mrblib/runner'

base = { 'BC2CPP_BUILD_NAME' => 'bc2cpp-self', 'BC2CPP_BUILD_GEMS' => 'compiler=runtime',
         'BC2CPP_TREE_ROOT' => '/compiler', 'BC2CPP_MRBC_RB' => '' }
plain = Bc2cppSelfCompile.generation_environment(base, {})
guest = Bc2cppSelfCompile.generation_environment(base, {
  'ONLY_OWNERS' => 'Guest', 'BC2CPP_BUILD_NAME' => 'closed', 'BC2CPP_BUILD_GEMS' => 'guest=world',
  'BC2CPP_TREE_ROOT' => '/compiler', 'BC2CPP_TYPE_CHECK_ONLY' => '1', 'BC2CPP_SELF_STATS' => '1',
  'BC2CPP_MRUBY_RUNNER' => '/launcher', 'BC2CPP_SCCACHE' => '0'
})
raise 'guest inputs invalidate or alter the compiler build' unless plain == guest
raise 'guest owner filter leaked into generation' unless guest.first['ONLY_OWNERS'].nil?
isolated, controls = Bc2cppSelfCompile.generation_environment(base,
  { 'BC2CPP_EXACT_ARITH' => '0', 'BC2CPP_NATIVE_INVENTORY' => '/guest/inventory.json' })
raise 'guest metadata leaked into the compiler build' unless controls.empty? &&
  isolated['BC2CPP_EXACT_ARITH'].nil? && isolated['BC2CPP_NATIVE_INVENTORY'].nil?

keys = BC2CPPRunner::SELF_DYNAMIC_OPTIONS + ['BC2CPP_STRICT_KEYS']
saved = keys.to_h { |key| [key, ENV[key]] }
begin
  keys.each { |key| ENV.delete(key) }
  BC2CPPRunner.validate_self_options!
  ['BC2CPP_ESCAPE_REPORT', 'BC2CPP_STRICT_KEYS'].each do |key|
    ENV[key] = key == 'BC2CPP_STRICT_KEYS' ? '0' : 'report.tsv'
    begin
      BC2CPPRunner.validate_self_options!
      raise 'accepted a definition graph change'
    rescue RuntimeError => error
      raise unless error.message.include?('changes the fixed compiler definition graph')
    ensure
      ENV.delete(key)
    end
  end
ensure
  saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
end
builder = File.expand_path('../../bc2cpp/tools/self_compile/build.rb', __dir__)
message, status = Open3.capture2e(RbConfig.ruby, '--disable-yjit', builder)
raise 'accepted bootstrap without CRuby 4 + YJIT' if status.success? || !message.include?('requires CRuby 4 with YJIT')

Dir.mktmpdir('self-compile-check') do |dir|
  generation = File.join(dir, 'generation')
  gem = File.join(dir, 'gem')
  FileUtils.mkdir_p(generation)
  diagnostics = <<~TEXT
    == compiled entry points ==
      Foo_f / Foo_f_impl  (Foo#f, arity 0)
    == classes needing MRB_SET_INSTANCE_TT(..., MRB_TT_DATA) ==
    == skipped (unsupported, left on the interpreter) ==
      Foo#g: unsupported fixture opcode
    == compiled method report ==
      {"entry": "Foo_f", "owner": "Foo", "name": "f", "tier": "O2", "compile_seconds": 0.001234}
    == end ==
  TEXT
  log = File.join(generation, 'generation.log')
  File.write(log, diagnostics)
  source = File.join(generation, 'bc2cpp_self_gen.cpp')
  File.write(source, "mrb_value Foo_f(mrb_state* M, mrb_value self) {\n  return self;\n}\n")
  File.write(File.join(generation, 'bc2cpp_self_decls.h'), "#pragma once\n")
  count = Bc2cppSelfCompile.write_gem(generation, gem)
  raise 'wrong translated count' unless count == 1
  actual = File.join(gem, 'generated/bc2cpp_self_gen.cpp')
  raise 'entry counter missing' unless File.read(actual).include?('++bc2cpp_self_compiled_calls;')
  coverage = JSON.parse(File.read(File.join(generation, 'coverage.json')))
  raise 'lost VM fallback' unless coverage.values_at('compiled_methods', 'interpreted_methods') == [1, 1]
  unless coverage['methods'] == [{ 'entry' => 'Foo_f', 'owner' => 'Foo', 'name' => 'f', 'tier' => 'O2',
                                   'compile_seconds' => 0.001234 }]
    raise 'coverage lost the per-method tier or timing'
  end
  File.utime(Time.at(1), Time.at(1), actual)
  stale = File.join(gem, 'src/bc2cpp_self_gen_shard99.cpp')
  File.write(stale, '// obsolete shard')
  Bc2cppSelfCompile.write_gem(generation, gem)
  raise 'kept an obsolete shard' if File.exist?(stale)
  raise 'warm setup rewrites generated code' unless File.mtime(actual) == Time.at(1)
  File.write(source, '// no translated body')
  begin
    Bc2cppSelfCompile.write_gem(generation, gem)
    raise 'accepted missing translated body'
  rescue RuntimeError => error
    raise unless error.message.start_with?('missing compiled entry definitions:')
  end
  File.write(log, diagnostics.sub("== skipped", "  Foo\n== skipped"))
  begin
    Bc2cppSelfCompile.write_gem(generation, gem)
    raise 'accepted unsafe late layout change'
  rescue RuntimeError => error
    raise unless error.message == 'late self installation cannot change existing object layouts'
  end
end
puts 'self compilation registration, counters, fallbacks and incremental artifacts: PASS'
