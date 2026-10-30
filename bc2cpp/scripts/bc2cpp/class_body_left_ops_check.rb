#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_LEFT_OPS: a guard on the class-body driver's coverage. It runs class_body_compile_list.rb over the closed
# roots and asserts that (a) at least MIN_COMPILED of the class bodies compile, and (b) every op that still refuses a body
# is one of the known remaining ops, and none of the ops made compilable (BLOCK, SENDB, CLASS, DEF, METHOD, TCLASS,
# SSEND, SSEND0, SEND, LAMBDA, SETCONST-folded constants) refuses again. Needs MRBC and the static dispatch lists
# (BC2CPP_STATIC_DISPATCH_LISTS); without them it prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc BC2CPP_STATIC_DISPATCH_LISTS=build/bc2cpp/static_dispatch_lists.json \
#     ruby scripts/bc2cpp/class_body_left_ops_check.rb

require 'open3'

ROOT = File.expand_path('../..', __dir__)
MIN_COMPILED = 248
KNOWN_LEFT = %w[ALIAS TDEF].freeze
MADE_COMPILABLE = %w[BLOCK SENDB CLASS DEF METHOD TCLASS SSEND SSEND0 SEND SCLASS LAMBDA].freeze

if ENV['MRBC'].to_s.empty? || ENV['BC2CPP_STATIC_DISPATCH_LISTS'].to_s.empty?
  puts 'class_body_left_ops_check: SKIP (needs MRBC and BC2CPP_STATIC_DISPATCH_LISTS)'
  exit 0
end

out, status = Open3.capture2e({ 'BC2CPP_BUILD_NAME' => 'closed' }, 'ruby', File.join(ROOT, 'scripts/bc2cpp/class_body_compile_list.rb'))
abort "class_body_left_ops_check: the compile list failed:\n#{out.lines.last(5).join}" unless status.success?

compiled = out[/^(\d+) of \d+ class and module bodies compile/, 1].to_i
refusing = out.lines.drop_while { |line| !line.start_with?('refusing opcodes') }.drop(1)
                .filter_map { |line| line.strip.split(/\s+/).first if line.start_with?('  ') }

failures = []
failures << "only #{compiled} bodies compile, expected at least #{MIN_COMPILED}" if compiled < MIN_COMPILED
unknown = refusing - KNOWN_LEFT
failures << "unexpected refusing ops: #{unknown.join(' ')}" unless unknown.empty?
back = refusing & MADE_COMPILABLE
failures << "ops made compilable refuse again: #{back.join(' ')}" unless back.empty?

failures.each { |f| puts "  FAIL #{f}" }
puts "  ok   #{compiled} of 254 bodies compile; refusing ops within #{KNOWN_LEFT.join(' ')}" if failures.empty?
puts "class_body_left_ops_check: #{failures.empty? ? 'passed' : "#{failures.size} failed"}"
exit(failures.empty? ? 0 : 1)
