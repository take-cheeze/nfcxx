#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CLASS_OBJECT_NEW: a `klass.new(...)` whose receiver is a parameter every caller passes class constants for
# constructs directly: one exact-class arm per class (the allocation Class#new makes, then the initialize that class
# resolves to, each marked INITIALIZER_DIRECT) and a closed-world violation for any other receiver. A helper that is
# also handed a computed class keeps the by-name send, and a class whose initialize is not one direct call does too.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/class_object_new_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class CnBase
    def initialize(a, b); @a = a; @b = b; end
    def a; @a; end
  end
  class CnKid < CnBase
    def initialize(a, b); @a = a * 10; @b = b; end
  end
  class CnOther
    def initialize(a, b); @a = b; @b = a; end
    def a; @a; end
  end
  class CnMaker
    def build(klass, a, b); klass.new(a, b); end
    def build_all(klass, a, b); [1, 2].map { |i| klass.new(a + i, b) }; end
    def leaky(klass, a, b); klass.new(a, b); end
    def go
      build(CnBase, 1, 2)
      build(CnKid, 3, 4)
      build_all(CnOther, 5, 6)
      leaky(CnBase, 1, 2)
      leaky($cn_class, 7, 8)
    end
  end
RUBY
OWNERS = %w[CnBase CnKid CnOther CnMaker].freeze

body = ->(code, fn) { code[/^mrb_value #{fn}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

Dir.mktmpdir('class-object-new') do |dir|
  code, = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'class_object_new.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  build = body.call(code, 'CnMaker_build')
  check.call('build: an arm per class its callers pass, each a direct allocation and initialize call',
             build.include?('CLASS_OBJECT_NEW') && build.include?('CnBase_initialize_impl(M, ') &&
               build.include?('CnKid_initialize_impl(M, ') && build.scan('bc2cpp_direct_alloc(').size == 2)
  check.call('build: INITIALIZER_DIRECT marks the site for each initialize it reaches',
             build.scan('INITIALIZER_DIRECT').size == 2 && build.scan('INITIALIZER_SITE').size == 1)
  check.call('build: any other receiver is a closed-world violation, never a by-name send',
             build.include?('bc2cpp_guard_violation(') && !build.include?('bc2cpp_send(') && !build.include?('bc2cpp_owner_call('))
  loop_body = body.call(code, 'CnMaker_build_all')
  check.call('build_all: the site inside a block is direct too',
             loop_body.include?('CnOther_initialize_impl(M, ') && !loop_body.include?('bc2cpp_owner_call('))
  leaky = body.call(code, 'CnMaker_leaky')
  check.call('leaky: a computed class among the callers keeps the by-name construction',
             !leaky.include?('CLASS_OBJECT_NEW') && leaky.include?('bc2cpp_owner_call('))
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp class object new check: PASS'
