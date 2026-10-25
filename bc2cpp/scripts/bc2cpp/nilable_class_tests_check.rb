#!/usr/bin/env ruby
# frozen_string_literal: true

# RUBY_EXACT_PAST_NATIVE_ARMS and NILABLE_CLASS_TESTS: a zero-argument name an RGSS native also answers (`x`, `y`,
# `width`, `dispose`) went to the native-arm block before any receiver proof was read, so even a receiver the
# exact-class flow proves to be one Ruby class got the native arms and a class-test chain (POLY_SMALL_N). Such a
# receiver now skips the native arms, and a nil-or-K one takes the nil test and K's direct call (NILABLE_RECEIVER)
# also when that only removes class tests. Generated end to end by bc2cpp.rb (no mruby build needed);
# BC2CPP_RUBY_EXACT_PAST_NATIVE=0 BC2CPP_NILABLE_CLASS_TESTS=0 is the output before them.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/nilable_class_tests_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('nilable_class_tests_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Spot
    def initialize
      @x = 1
      nil
    end

    def x
      @x + 1
    end

    def text_size(s); s; end
    def draw_text(a, b); a; end
    def blt(a, b, c, d); a; end
    def stretch_blt(a, b, c); a; end
    def copy_blt(a, b, c, d); a; end
    def fill_rect(a, b, c, d, e); a; end
    def tone=(v); @tone = v; end
    def opacity=(v); @opacity = v; end
  end

  class Mark
    def x
      2
    end
  end

  class Holder
    def initialize
      @spot = nil
      nil
    end

    def place
      @spot = Spot.new
      nil
    end

    def where
      @spot.x
    end

    def nilable_measure; @spot.text_size('hello'); end
    def unknown_measure(o); o.text_size('hello'); end
    def measure; Spot.new.text_size('hello'); end
    def draw; Spot.new.draw_text(1, 2); end
    def blit; Spot.new.blt(1, 2, 3, 4); end
    def stretch; Spot.new.stretch_blt(1, 2, 3); end
    def copy; Spot.new.copy_blt(1, 2, 3, 4); end
    def paint; Spot.new.fill_rect(1, 2, 3, 4, 5); end
    def tint; s = Spot.new; s.tone = 1; end
    def fade; s = Spot.new; s.opacity = 2; end

    def mark
      Mark.new.x
    end
  end
RUBY

# { "Owner#name" => generated body } of one run with the given switches.
bodies = lambda do |env|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('nilable_class_tests') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Spot Mark Holder])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  env.each_key { |k| ENV.delete(k) }
end
on = bodies.call({})
off = bodies.call('BC2CPP_RUBY_EXACT_PAST_NATIVE' => '0', 'BC2CPP_NILABLE_CLASS_TESTS' => '0')
class_tests = ->(body) { body.to_s.scan('mrb_obj_class(M,').size }

check.call('before, `@spot.x` and `Mark.new.x` are class-test chains behind the RGSS arms',
           off['Holder#where'].to_s.include?('POLY_SMALL_N :x') && off['Holder#mark'].to_s.include?('POLY_SMALL_N :x'))
check.call('a nil-or-Spot receiver takes the nil test and Spot#x',
           on['Holder#where'].to_s.include?('NILABLE_RECEIVER :x -- receiver is nil or exactly Spot') &&
             !on['Holder#where'].include?('POLY_SMALL_N') && class_tests.call(on['Holder#where']).zero?)
check.call('an exact Mark receiver calls Mark#x with no class test',
           !on['Holder#mark'].to_s.include?('POLY_SMALL_N') && class_tests.call(on['Holder#mark']).zero?)

%w[measure paint tint fade draw blit stretch copy].each do |name|
  before = off["Holder##{name}"].to_s
  after = on["Holder##{name}"].to_s
  check.call("#{name}: exact Ruby receivers skip native wrapper tests", class_tests.call(before).positive? && class_tests.call(after).zero?)
  check.call("#{name}: direct Ruby call replaces dispatch", after.include?('Spot_') && !after.include?('bc2cpp_send(M,'))
end

check.call('a nil-or-Ruby receiver reaches the nil guard and direct text_size call',
           on['Holder#nilable_measure'].to_s.include?('NILABLE_RECEIVER :text_size') &&
             class_tests.call(on['Holder#nilable_measure']).zero?)

before_args = bodies.call('BC2CPP_RUBY_EXACT_PAST_NATIVE_ARGS' => '0')
check.call('argument-only switch preserves the old native arm for text_size',
           class_tests.call(before_args['Holder#measure']).positive?)
check.call('argument-only switch keeps the existing zero-argument proof',
           class_tests.call(before_args['Holder#mark']).zero?)
check.call('an unproven receiver retains its native class guard and dispatch fallback',
           class_tests.call(on['Holder#unknown_measure']).positive? &&
             on['Holder#unknown_measure'] == before_args['Holder#unknown_measure'])

suite.finish!
