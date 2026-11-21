#!/usr/bin/env ruby
# frozen_string_literal: true

# CHECKED_SEND / IO_PUTS_MODEL: a send that keeps its by-name call makes the checks OP_SEND makes and mrb_funcall does
# not (symbol_cache.rb bc2cpp_check_send, bc2cpp.rb bc2cpp_io_puts).
#
#   1. generated: `s.strip(1)` on a name with an unknown definer stays a checked by-name send, and `s.puts` the shared
#      bc2cpp_io_puts with the caller's self;
#   2. run on a full-core mruby against interpreted: a raw C function given too many arguments raises ArgumentError
#      (its registered aspec), and `s.puts` on a String raises NoMethodError (Kernel#puts is private); the plain calls
#      answer as interpreted.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/kept_send_parity_check.rb

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('kept_send_parity_check')
check = suite.method(:check)
suite.require_mrbc!
runtime = Bc2cppFixtureRuntime

ENV['BC2CPP_SIG_DIRS'] = ''

SOURCE = <<~RUBY
  class Bag; end
  # A definition the closed world cannot attribute: every `strip` send keeps its by-name call.
  Bag.send(:define_method, :strip) { :bag }

  class KeptFx
    def strip0(s); s.strip; end
    def strip1(s); s.strip(1); end
    def puts_on(s); s.puts; end

    def run
      out = [strip0(' a '), Bag.new.strip]
      begin
        strip1(' b ')
      rescue ArgumentError => e
        out << e.class
      end
      begin
        puts_on('c')
      rescue NoMethodError => e
        out << e.class
      end
      out
    end
  end
RUBY
OWNERS = %w[Bag KeptFx].freeze

HARNESS = <<~'CPP'
  static int scenario(mrb_state* M) {
    mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "KeptFx"), 0, nullptr);
    call(M, "run", fx, "run");
    return 0;
  }
CPP

Dir.mktmpdir('kept-send-parity') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS, core: true)
  by = code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  check.call('`s.strip(1)` keeps a checked by-name send', by['KeptFx#strip1'].to_s.match?(/bc2cpp_send\(M, r\d+, \d+, 1, r\d+, self\)/))
  check.call('`s.puts` is bc2cpp_io_puts with the caller self', by['KeptFx#puts_on'].to_s.match?(/bc2cpp_io_puts\(M, r\d+, .*, 0, NULL, self\)/))

  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, HARNESS, build: build, full: true)
    sections = runtime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    compiled = plain.call(sections['compiled'])
    check.call('built and ran', built)
    check.call('compiled answers as interpreted', built && !compiled.empty? && compiled == plain.call(sections['interpreted']))
    check.call('the too-long call raised ArgumentError and the private one NoMethodError',
               compiled.any? { |l| l.include?('ArgumentError') && l.include?('NoMethodError') })
  else
    puts '  SKIP: no full-core libmruby (set BC2CPP_FULL_BUILD_DIR); the behavioural check needs it'
  end
end

suite.finish!
