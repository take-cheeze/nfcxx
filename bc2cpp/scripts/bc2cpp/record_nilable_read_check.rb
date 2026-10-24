#!/usr/bin/env ruby
# frozen_string_literal: true

# RECORD_NILABLE_READ: a record read `@slot[:key]` enters the exact-class flow as its stored classes plus nil, so the
# flow's truthiness narrowing makes `@slot[:key] || []` and `return unless x` exact receivers. Generated end to end
# by bc2cpp.rb (no mruby build needed); BC2CPP_RECORD_NILABLE_READS=0 is the output before it.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/record_nilable_read_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''

suite = FixtureCheck.new('record_nilable_read_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Scene
    def initialize
      @ui = {}
      nil
    end

    def start
      @ui[:sprites] = []
      @ui[:list] = make_list
      nil
    end

    def make_list
      [1].map { |x| x }
    end

    def total
      (@ui[:sprites] || []).size
    end

    def each_sprite
      (@ui[:sprites] || []).each { |s| s }
    end

    def guarded
      s = @ui[:sprites]
      return 0 unless s
      s.size
    end

    def plain
      @ui[:sprites].size
    end

    def call_stored
      (@ui[:list] || []).size
    end
  end

  class Leaky
    def initialize
      @h = {}
      nil
    end

    def start
      @h[:items] = []
      nil
    end

    def hand_out
      @h
    end

    def total
      (@h[:items] || []).size
    end
  end
RUBY

# { "Owner#name" => generated body } of one run.
bodies = lambda do |flag|
  ENV['BC2CPP_RECORD_NILABLE_READS'] = flag
  Dir.mktmpdir('record_nilable_read') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Scene Leaky])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  ENV.delete('BC2CPP_RECORD_NILABLE_READS')
end
on = bodies.call('1')
off = bodies.call('0')
exact_size = ->(body) { body.to_s.include?('CLOSED_WORLD_NATIVE_EXACT :size') }

check.call('`@ui[:k] || []` is an exact Array for size', exact_size.call(on['Scene#total']))
check.call('without the read it keeps its class chain', !exact_size.call(off['Scene#total']))
# The by-name block send, or its owner call carrying the block (BLOCK_OWNER_CALL).
by_name_block = /mrb_funcall_with_block\(|bc2cpp_owner_call\(M, [^;]*BC2CPP_OWNERS\([^)]*\), (?!mrb_nil_value\(\))/
check.call('`(@ui[:k] || []).each` drops its guard and by-name fallback',
           !on['Scene#each_sprite'].match?(by_name_block) &&
           !on['Scene#each_sprite'].include?('GUARDED_BLOCK_INLINE'))
check.call('without the read `each` keeps its fallback', off['Scene#each_sprite'].match?(by_name_block))
check.call('`return 0 unless x` narrows the read to Array', exact_size.call(on['Scene#guarded']))
check.call('an unnarrowed read keeps its nil test (NILABLE_RECEIVER) before the exact Array body',
           on['Scene#plain'].include?('NILABLE_RECEIVER :size -- receiver is nil or exactly Array') &&
           on['Scene#plain'].include?('bc2cpp_nil_receiver(') && exact_size.call(on['Scene#plain']))
check.call('without the read a plain read has no nil test', !off['Scene#plain'].include?('NILABLE_RECEIVER'))
check.call('a key stored from a call result stays unknown', !exact_size.call(on['Scene#call_stored']))
check.call('a record that escapes gives no read class', !exact_size.call(on['Leaky#total']))

suite.finish!
