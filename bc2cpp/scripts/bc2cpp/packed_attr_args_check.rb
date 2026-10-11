#!/usr/bin/env ruby
# encoding: UTF-8
# Check that build_registry sees every name of an attr_*/visibility/
# module_function call with 15 or more arguments. mruby packs those into one
# ARRAY and sends them as `n=*` (CALL_MAXARGS). Before this was handled, all
# the names were silently dropped: Game::Enemy's 15-name attr_reader left
# atk/def/agi/max_hp embedded behind mruby's native attr_reader, which reads the
# empty iv_tbl, so every enemy fought with nil stats in RPGMAKER_BC2CPP builds.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

NAMES = (1..15).map { |i| "a#{i}" }.freeze
SRC = <<~RUBY
  class Foe
    attr_reader #{NAMES.map { |n| ":#{n}" }.join(', ')}
    attr_accessor :b1, :b2
  end
  module Codec
    #{NAMES.map { |n| "def #{n}; end" }.join("\n  ")}
    module_function #{NAMES.map { |n| ":#{n}" }.join(', ')}
  end
RUBY

SPLAT = <<~RUBY
  class Foe
    NAMES = %i[x y]
    attr_reader(*NAMES)
  end
RUBY

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def registry_for(src, name)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, src)
    ireps, root_label = compile_ireps(path, "bc2cpp_#{name}", dir)
    order = dfs_order(ireps, root_label)
    build_registry(ireps, root_label)[0]
  end
end

registry = registry_for(SRC, 'packed_attr_args')
readers = NAMES.select { |n| Array(registry[n]).any? { |d| d.owner == 'Foe' && d.kind == :ivar_accessor } }
check.call('all 15 names of a packed attr_reader are ivar accessors', readers.size == NAMES.size)
check.call('an ordinary short attr_accessor still registers reader and writer',
           Array(registry['b2']).any? { |d| d.owner == 'Foe' } && Array(registry['b2=']).any? { |d| d.owner == 'Foe' })
functions = NAMES.select { |n| Array(registry[n]).any? { |d| d.owner == 'Codec.singleton' } }
check.call('all 15 names of a packed module_function get a singleton copy', functions.size == NAMES.size)

raised = begin
  registry_for(SPLAT, 'splat_attr_args')
  false
rescue RuntimeError => e
  e.message.include?('splat')
end
check.call('a real splat argument is refused, not silently ignored', raised)

if failures.empty?
  puts 'bc2cpp packed attr args check: PASS'
else
  warn "bc2cpp packed attr args check: #{failures.size} failure(s)"
  exit 1
end
