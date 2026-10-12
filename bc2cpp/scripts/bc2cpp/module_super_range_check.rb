#!/usr/bin/env ruby
# encoding: UTF-8
# Real-Range parity for MODULE_SUPER_SUPPORT (ADR 0329), measured on the SAME
# whole-program pass the coverage report counts: the five unhandled-SUPER
# `#error`s this removes are mruby's own `Range#max`, `Range#min` (two sites
# each) and `Range#to_a`, whose `super` reaches `Enumerable#max` / `#min` /
# `#entries`.
#
# What is checked here is the generated code -- the emitted super call, its
# forwarded block, and that no unhandled-SUPER marker survives. The behavioural
# half is scripts/bc2cpp/module_super_check.rb, which runs compiled code
# against the interpreter; driving the real Range through a fixture would need
# the whole wio gem set, so the two together cover code shape and semantics
# without pretending the fixture is the shipped build.
require 'shellwords'
require 'open3'
require 'tmpdir'
require 'set'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

srcs = closed_world_mrblib_srcs(ROOT)
native_srcs = Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{ROOT}/3rd/mruby") +
              external_gem_native_srcs(ROOT)
all_owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }

env = {
  'MRBC' => ENV['MRBC'] || 'mrbc',
  'OUT_SYMBOL' => 'range_super',
  'ONLY_OWNERS' => all_owners.join(','),
  'NATIVE_SRCS' => Shellwords.join(native_srcs),
  'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
  'BC2CPP_CLOSED_WORLD' => '1',
  'BC2CPP_BUILD_NAME' => 'wio',
  'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
  NomethodReviewed::ALLOW_ENV => 'allow'
}
cmd = [RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), *srcs].shelljoin

generate = lambda do |dir|
  Dir.mktmpdir do |d|
    e = env.merge('OUT_DIR' => d)
    out, err, status = Open3.capture3(e, cmd)
    raise "bc2cpp.rb failed: #{err.lines.first(8).join}" unless status.success?

    [out, err]
  end
end

# The kill switch must restore every one of the five markers.
ENV['BC2CPP_MODULE_SUPER'] = '0'
off, = generate.call(nil)
off_super = {}
cur = nil
off.each_line do |l|
  cur = $1 if l =~ %r{^// (\S+#\S+) \(compiled from irep \d+, \d+ insns\)$}
  next unless cur&.start_with?('Range#')

  off_super[cur] = off_super.fetch(cur, 0) + 1 if l.include?('#error unhandled opcode SUPER')
end
check.call("the kill switch restores the five unhandled-SUPER markers (#{off_super.values.sum}: #{off_super.keys.sort.join(', ')})",
           off_super.values.sum == 5 && %w[Range#max Range#min Range#to_a].all? { |k| off_super.key?(k) })
ENV['BC2CPP_MODULE_SUPER'] = nil

on, = generate.call(nil)
on_super = 0
cur = nil
on.each_line do |l|
  cur = $1 if l =~ %r{^// (\S+#\S+) \(compiled from irep \d+, \d+ insns\)$}
  next unless cur&.start_with?('Range#')

  on_super += 1 if l.include?('#error unhandled opcode SUPER')
end
check.call('no Range method carries an unhandled-SUPER #error with the support on', on_super.zero?)

%w[Range_max Range_min Range_to_a].each do |fn|
  body = on[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^\}$)/m].to_s
  check.call("#{fn} compiles to a body", !body.empty?)
  check.call("#{fn} has no #error", !body.include?('#error'))
end

check.call('Range#max reaches Enumerable#max carrying this frame\'s block',
           on.include?('Enumerable_max_impl(M, self, bc2cpp_blk)'))
check.call('Range#min reaches Enumerable#min carrying this frame\'s block',
           on.include?('Enumerable_min_impl(M, self, bc2cpp_blk)'))
check.call("Range#to_a reaches Enumerable#entries (an alias, resolved through the core index)",
           on.match?(/Range_to_a_impl.*?Enumerable_entries_impl\(M, self\)/m))
check.call('the emitting path builds no ARGARY array', !on[/Range_(?:max|min)_impl.*?ARGARY/m].to_s.include?('ARGARY'))

abort "module super (real Range): #{failures.size} failure(s): #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp module super (real Range) check: PASS'
