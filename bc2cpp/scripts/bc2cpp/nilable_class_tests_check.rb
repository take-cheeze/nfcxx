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

    def bump; @x += 1; end
    def text_size(s); s; end
    def draw_text(a, b); a; end
    def blt(a, b, c, d); a; end
    def stretch_blt(a, b, c); a; end
    def copy_blt(a, b, c, d); a; end
    def fill_rect(a, b, c, d, e); a; end
    def tone=(v); @tone = v; end
    def opacity=(v); @opacity = v; end
  end

  class ChildSpot < Spot
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

    def direct_bump; Spot.new.bump; end
    def nilable_bump; @spot.bump; end
    def unknown_bump(o); o.bump; end
    def nested_bump; s = Spot.new; r = []; 2.times { r << s.bump }; r; end
    def rescued_bump; s = Spot.new; s.bump; rescue ArgumentError; :bad; end
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
    result = code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
    result['Holder#rescued_bump'] += code[/^static mrb_value Holder_rescued_bump_impl_rescue_try[^\n]*\n.*?^\}/m].to_s
    result
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

mono_off = bodies.call('BC2CPP_MONO_EXACT_FLOW' => '0')
%w[direct_bump nested_bump rescued_bump].each do |name|
  check.call("#{name}: exact receiver removes the embedded payload class guard",
             mono_off["Holder##{name}"].to_s.include?('MONO_EMBED_GUARD :bump') &&
               on["Holder##{name}"].to_s.include?('MONO_EXACT_FLOW :bump') &&
               class_tests.call(on["Holder##{name}"]) < class_tests.call(mono_off["Holder##{name}"]))
end
%w[unknown_bump].each do |name|
  check.call("#{name}: nilable and unknown receivers retain their embedded payload guard",
             on["Holder##{name}"].to_s.include?('MONO_EMBED_GUARD :bump') &&
               class_tests.call(on["Holder##{name}"]).positive?)
end

check.call('nilable_bump: the nil test still protects the exact non-nil payload call',
           on['Holder#nilable_bump'].to_s.include?('NILABLE_RECEIVER :bump') &&
             on['Holder#nilable_bump'].include?('bc2cpp_nil_receiver('))

runtime_source = <<~RUBY
  class MonoSpot
    def initialize; @x = 1; end
    def bump; @x += 1; end
  end
  class MonoChild < MonoSpot; end
  class MonoWrong; end
  class MonoHolder
    def initialize; @spot = nil; end
    def place; @spot = MonoSpot.new; nil; end
    def direct_bump; MonoSpot.new.bump; end
    def nested_bump; s = MonoSpot.new; r = []; 2.times { r << s.bump }; r; end
    def rescued_bump; s = MonoSpot.new; s.bump; rescue ArgumentError; :bad; end
    def nilable_bump; @spot.bump; end
    def unknown_bump(o); o.bump; end
  end
RUBY
Dir.mktmpdir('mono-exact-runtime') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(runtime_source, dir, only_owners: %w[MonoSpot MonoChild MonoWrong MonoHolder])
  singleton_code, = Bc2cppFixtureRuntime.generate(SOURCE + "class Holder; def touch(o); o.singleton_class; end; end",
                                                File.join(dir, 'singleton'), only_owners: %w[Spot ChildSpot Mark Holder])
  check.call('a singleton maker withdraws the general exact receiver proof', !singleton_code.include?('MONO_EXACT_FLOW :bump'))
  unless ENV['CC_GENERATED_ONLY'] == '1'
    build = Bc2cppFixtureRuntime.full_or_build
    if build
      driver = <<~'RUBY'
        h = MonoHolder.new
        show = lambda do |name, &block|
          begin
            puts "#{name}: #{block.call.inspect}"
          rescue Exception => e
            puts "#{name}: #{e.class}: #{e.message}"
          end
        end
        show.call('direct') { h.direct_bump }
        show.call('nested') { h.nested_bump }
        show.call('rescue') { h.rescued_bump }
        show.call('nilable nil') { h.nilable_bump }
        h.place
        show.call('nilable value') { h.nilable_bump }
        show.call('unknown Spot') { h.unknown_bump(MonoSpot.new) }
        show.call('unknown subclass') { h.unknown_bump(MonoChild.new) }
        show.call('unknown nil') { h.unknown_bump(nil) }
        show.call('unknown wrong class') { h.unknown_bump(MonoWrong.new) }
        puts 'end'
      RUBY
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          std::fflush(stdout);
          mrb_load_string(M, R"MONO(#{driver})MONO");
          std::fflush(stdout);
          if (M->exc) { mrb_print_error(M); return 1; }
          return 0;
        }
      CPP
      built, output = Bc2cppFixtureRuntime.run(dir, err, %w[MonoSpot MonoChild MonoWrong MonoHolder], harness, build: build, full: true)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      compiled = sections['compiled']
      check.call('monomorphic exact receiver runtime fixture builds and runs', built)
      check.call('monomorphic exact receiver values and errors match interpreted mruby',
                 interpreted && interpreted.last == 'end' && interpreted == compiled)
      puts output unless built && interpreted && interpreted == compiled
    else
      puts '  SKIP: no full-core mruby build for monomorphic receiver runtime checks'
    end
  end
end

suite.finish!
