#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/class_world.rb on what makes a class exact:
#   folded   a computed constant PureEval folds (data built from literals) is static, as LoadCompile compiles it; it is
#            listed under `folded` and is not a blocker
#   refused  a computed constant that is not data (a lambda) or an Integer outside 32 bits stays a blocker, and its
#            module stays unknown
#   core     RuntimeError is C-defined under StandardError (3rd/mruby/src/error.c): a class under it is exact when its
#            own bodies are, and a DSL call that reopens RuntimeError makes it and its subclasses unknown
#   real     the five classes the report listed as unknown, read from their mrblib files: what each one blocks on
#
#   ruby scripts/bc2cpp/class_world_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/class_world'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = ->(name, ok) { failures << name unless ok }

# The world of the given sources (name => text), as one root in load order.
def world_of(sources)
  Dir.mktmpdir('class_world') do |dir|
    paths = sources.map do |name, text|
      File.join(dir, "#{name}.rb").tap { |path| File.write(path, text) }
    end
    ClassWorld.build([ClassBodyScan.scan(paths)])
  end
end

def blockers_of(facts) = facts['bodies'].flat_map { |b| b['blockers'] }
def folded_of(facts) = facts['bodies'].flat_map { |b| b['folded'] }

GAME_STATE = <<~'RUBY'
  module Game
    class State
      SAVE_FIELD = (0..11).each_with_object({}) { |slot, h| h[slot] = 91 + slot }.freeze
      def save_field(slot)
        SAVE_FIELD[slot]
      end
    end
  end
RUBY

RGSS_AUDIO = <<~'RUBY'
  module RGSS
    module Audio
      EXTS = ["", ".ogg", ".wav"].freeze
      SPELLINGS = begin
        list = []
        EXTS.each do |e|
          list << e
          list << e.upcase
        end
        list
      end
    end
  end
RUBY

SCHEMA_LAMBDA = <<~'RUBY'
  module LCF
    module Schema
      TABLE = { 1 => { elements: -> { { 2 => 3 } } } }.freeze
    end
  end
RUBY

WIDE_INT = <<~'RUBY'
  module LCF
    MASK = 0xffff_ffff
  end
RUBY

LOAD_ERROR = <<~'RUBY'
  module RGSS
    class Bitmap
      class LoadError < RuntimeError
        attr_reader :path, :reason

        def initialize(path, reason)
          @path = path
          @reason = reason
          super("Failed to init bitmap: #{path} (#{reason})")
        end
      end
    end
  end
RUBY

RUNTIME_ERROR_DSL = <<~'RUBY'
  class RuntimeError
    register_thing :x
  end
RUBY

ORPHANS = <<~'RUBY'
  class Orphan < MissingBase; end
  class Child < Orphan; end
RUBY

# 1. Game::State: its only computed constant is folded.
state = world_of(game_state: GAME_STATE).facts['Game::State']
check.call('a class whose computed constant folds to data is exact', state['exact'])
check.call('the folded constant is listed as folded, not as a blocker',
           folded_of(state) == ['const_computed(SAVE_FIELD)'] && blockers_of(state).empty?)

# 2. RGSS::Audio: a module whose computed constant folds to a list of Strings.
audio = world_of(audio: RGSS_AUDIO).facts['RGSS::Audio']
check.call('a module whose computed constant folds to Strings is exact', audio['exact'])
check.call('its folded constant is listed as folded', folded_of(audio) == ['const_computed(SPELLINGS)'])

# 3. A constant that holds a lambda is not data and is not folded: its module stays unknown.
schema = world_of(schema: SCHEMA_LAMBDA).facts['LCF::Schema']
check.call('a constant holding a lambda is not folded, so its module stays unknown',
           !schema['exact'] && blockers_of(schema) == ['const_computed(TABLE)'] && folded_of(schema).empty?)

# 4. An Integer outside 32 bits folds too: it is built from its decimal text at load, so the module is exact.
lcf = world_of(lcf: WIDE_INT).facts['LCF']
check.call('an Integer outside 32 bits is folded, so its module stays exact',
           lcf['exact'] && blockers_of(lcf).empty?)

# 5. RuntimeError as a superclass: a known core class, exact when nothing reopens it with a DSL call.
load_error = world_of(load_error: LOAD_ERROR).facts['RGSS::Bitmap::LoadError']
check.call('a superclass that is RuntimeError is a known one, with no reason', load_error['superclass'] == 'RuntimeError' && load_error['reasons'].empty?)
check.call('its ancestors run RuntimeError, StandardError, Exception (C-defined)',
           load_error['ancestors'].first(4) == %w[RGSS::Bitmap::LoadError RuntimeError StandardError Exception])
check.call('a class under RuntimeError is exact', load_error['exact'])

reopened = world_of(load_error: LOAD_ERROR, runtime_error: RUNTIME_ERROR_DSL).facts
check.call('a DSL call that reopens RuntimeError makes it and its subclass unknown',
           !reopened['RuntimeError']['exact'] && !reopened['RGSS::Bitmap::LoadError']['exact'])

# 6. An unknown superclass stays a reason, and unknown spreads to subclasses.
orphans = world_of(orphans: ORPHANS).facts
check.call('an undefined superclass is a reason, and its subclass is unknown too',
           !orphans['Orphan']['exact'] && orphans['Orphan']['reasons'] == ['superclass MissingBase'] && !orphans['Child']['exact'])

# 7. The native RuntimeError entry matches the mruby core source.
error_c = File.read(File.join(ROOT, '3rd/mruby/src/error.c'))
check.call('RuntimeError is defined by mruby core under StandardError (3rd/mruby/src/error.c)',
           error_c.match?(/MRB_SYM\(RuntimeError\), E_STANDARD_ERROR\)/) && ClassWorld::NATIVE.key?('RuntimeError') &&
           ClassWorld.native_fact('RuntimeError').superclass == 'StandardError')

# 8. The five classes from the report, read from their own mrblib files.
real = ->(path) { ClassWorld.build([ClassBodyScan.scan([File.join(ROOT, path)])]).facts }
game = real.('mruby-rpg2k/mrblib/game/lsd_io.rb')
check.call('real Game::State: its SYSTEM_SFX_SAVE_FIELD folds, no blocker',
           blockers_of(game['Game::State']).empty? && folded_of(game['Game::State']) == ['const_computed(SYSTEM_SFX_SAVE_FIELD)'])
lcf_real = real.('mruby-lcf/mrblib/lcf.rb')
check.call('real LCF: its three INT32 constants are no longer blockers',
           blockers_of(lcf_real['LCF']).none? { |b| b.include?('INT32') })
schema_real = real.('mruby-lcf/mrblib/schema.rb')
check.call('real LCF::Schema: DATABASE and MAP_UNIT (lambdas) stay blockers',
           blockers_of(schema_real['LCF::Schema']) == %w[const_computed(DATABASE) const_computed(MAP_UNIT)])
rgss = real.('mruby-rgss/mrblib/lib.rb')
check.call('real RGSS::Audio: EXT_SPELLINGS folds, no blocker',
           blockers_of(rgss['RGSS::Audio']).empty? && folded_of(rgss['RGSS::Audio']) == ['const_computed(EXT_SPELLINGS)'])
check.call('real RGSS::Bitmap::LoadError: superclass RuntimeError, no reason',
           rgss['RGSS::Bitmap::LoadError']['superclass'] == 'RuntimeError' && rgss['RGSS::Bitmap::LoadError']['reasons'].empty?)

if failures.empty?
  puts 'class world check: PASS'
else
  puts "class world check: FAIL #{failures.join('; ')}"
  exit 1
end
