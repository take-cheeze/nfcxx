#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_outside_owner_call'

module OutsideOwnerFallbackCheck
  class World
    attr_accessor :lifted

    def with_outside_owner_call(_name)
      @lifted = true
      yield
    ensure
      @lifted = false
    end
  end

  class Base
    def guarded_fallback_line(*)
      @closed_world.lifted ? @lifted : 'dispatch(); /* CLOSED_WORLD kept: core_or_native */'
    end
  end

  class Emitter < Base
    include OutsideOwnerCall

    def initialize(lifted)
      @closed_world = World.new
      @lifted = lifted
    end

    def outside_owner_call_owners(*) = ['Object']

    def outside_owner_call_line(*)
      # mruby-onig reuses a match region: the caller must save its boundary first.
      /.+/.match('a different match region')
      'OWNER_CALL'
    end
  end

  cases = 0
  ['self', 'r12', 'values[index + 1]', 'é_receiver'].product(['work', '[]=', 'a.b?', 'méthode']).each do |recv, name|
    prefix = "r7 = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\""
    error = %r{r7 = bc2cpp_nomethod_named\(M, #{Regexp.escape(recv)}, "#{Regexp.escape(name)}"[^\n]*?\); /\* CLOSED_WORLD nomethod: (?:self|recv)\.\S+ @ \S+ \*/}
    ['', ', 2, r8, r9'].product(['self', 'recv']).each do |args, kind|
      call = "#{prefix}#{args}); /* CLOSED_WORLD nomethod: #{kind}.#{name} @ source.rb:12 */"
      [call, "é before\n  #{call}\n after", "#{call}\n#{call}",
       "#{prefix}\n#{call}", "#{prefix}\nnot a marker", "#{prefix}); /* wrong marker */\n#{call}",
       call.sub('r7 =', 'r70 ='), call.sub('nomethod:', 'kept:'), call.sub('); /*', ");\n/*")].each do |lifted|
        expected = lifted.sub(error) { 'OWNER_CALL' }
        actual = Emitter.new(lifted).guarded_fallback_line(7, recv, name, [], [], {})
        raise "fallback replacement changed: #{[lifted, expected, actual].inspect}" unless actual == expected

        cases += 1
      end
    end
  end
  puts "outside owner fallback: #{cases} replacement comparisons passed"
end
