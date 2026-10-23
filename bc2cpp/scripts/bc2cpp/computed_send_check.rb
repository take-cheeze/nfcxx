#!/usr/bin/env ruby
# frozen_string_literal: true

# COMPUTED_SEND_EXPANSION: a `__send__(name, ...)` whose name register provably holds one of a finite
# set of Symbols becomes a chain of direct calls (codegen_computed_send.rb, computed_send_names.rb).
# A generated fixture covers each proven shape (constant table, copy, join, hash table, constant
# element) and each refused one (a parameter name, a computed string), then checks the emitted C++:
# every proven site has its expansion and no by-name arm, every refused site keeps its by-name
# send, and BC2CPP_COMPUTED_SEND=0 restores the single computed send. Needs MRBC; without it the
# fixture part prints SKIP.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/bc2cpp/closed_world_env'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

# By-name dispatch the expansion must not leave behind in a live line.
BY_NAME = /\bbc2cpp_send\(|\bbc2cpp_owner_call(?:_named)?\(|\bmrb_funcall\w*\(/

FIXTURE = <<~RUBY
  module CsCheck
    TABLE = %i[alpha beta gamma].freeze
    BY_KEY = { 0 => :alpha, 1 => :beta }.freeze
    ELEMENT_ALPHA = :alpha
    ELEMENTS = [ELEMENT_ALPHA, :beta].freeze

    class Box
      def alpha(x) = x + 1
      def beta(x) = x + 2
      def gamma(x) = x + 3

      def table(i, x)
        __send__(TABLE[i], x)
      end

      def copy(i, x)
        name = TABLE[i]
        other = name
        __send__(other, x)
      end

      def join(c, x)
        name = c ? :alpha : :beta
        __send__(name, x)
      end

      def hash_table(k, x)
        __send__(BY_KEY[k], x)
      end

      def constant_element(i, x)
        __send__(ELEMENTS[i], x)
      end

      def from_param(name, x)
        __send__(name, x)
      end

      def computed_string(i, x)
        __send__(TABLE[i] + "", x)
      end
    end
  end
RUBY

MRBC_BIN = ENV['MRBC']
puts '  SKIP generated fixture: set MRBC' if MRBC_BIN.nil?
Dir.mktmpdir do |dir|
  src = File.join(dir, 'cs.rb')
  File.write(src, FIXTURE)
  generate = lambda do |switch|
    out_dir = File.join(dir, "out-#{switch}")
    Dir.mkdir(out_dir)
    env = { 'MRBC' => MRBC_BIN, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'cs', 'OUT_DIR' => out_dir,
            'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_SIG_DIRS' => '', 'BC2CPP_COMPUTED_SEND' => switch }
    out, err, status = Open3.capture3(bc2cpp_closed_world_probe_env(env), RbConfig.ruby, BC2CPP, '--annotated', src)
    abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?
    out
  end
  if MRBC_BIN
    on = generate.call('1')
    off = generate.call('0')
    # The body of one generated method: from its _impl definition to the next top-level definition. A
    # nested block of the body can close at column 0, so a closing brace does not end it.
    body = lambda do |code, name|
      code[/^mrb_value CsCheck__Box_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value |\z)/m].to_s
    end
    # By-name dispatch in the live lines of a body (the notes name the send they replaced, so they are skipped).
    by_name_lines = lambda do |text|
      text.lines.reject { |line| line.lstrip.start_with?('//') }.grep(BY_NAME)
    end
    expanded = ->(name) { body.call(on, name).include?('// COMPUTED_SEND :__send__') }
    by_name = ->(name) { by_name_lines.call(body.call(on, name)).any? }

    %w[table copy join hash_table].each do |name|
      check.call("#{name}: the name is expanded into direct arms", expanded.call(name))
      check.call("#{name}: the expanded method has no by-name send", !by_name.call(name))
    end
    %w[from_param computed_string constant_element].each do |name|
      check.call("#{name}: the unproven name is not expanded and keeps its by-name send",
                 !expanded.call(name) && by_name.call(name))
    end
    check.call('the kill switch BC2CPP_COMPUTED_SEND=0 emits no COMPUTED_SEND line',
               off.lines.none? { |line| line.include?('// COMPUTED_SEND') })
    check.call('the kill switch keeps the proven table site as a by-name send',
               by_name_lines.call(body.call(off, 'table')).any?)
  end
end if MRBC_BIN

if failures.empty?
  puts 'bc2cpp computed send check: PASS'
else
  warn "bc2cpp computed send check: #{failures.size} failure(s)"
  exit 1
end
