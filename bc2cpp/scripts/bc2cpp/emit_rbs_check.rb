#!/usr/bin/env ruby
# frozen_string_literal: true

# Check `type_check.rb --emit-rbs` (docs/adr/0414, tools/bc2cpp/type_check_rbs.rb).
#
# 1. On a hand-written facts file (no MRBC): the exact RBS text for a class with typed / untyped / optional parameters,
#    ivars, a constant, a private and a singleton method, a module, a superclass; an unknown class becomes `untyped`,
#    bare Array / Hash become `Array[untyped]` / `Hash[untyped, untyped]`, a reopened core class gets only the methods the
#    core RBS lacks, `initialize` returns void; every written file parses with the rbs gem.
# 2. Round trip on a fixture (needs MRBC): the emitted RBS read back as signatures reports no error and no
#    contradiction (everything it says is what the analysis proved), and editing one emitted type to a wrong one is a
#    TC1001 at that line of the emitted file.
#
# BC2CPP_TOOLS_DIR points at a mutant copy of tools/bc2cpp (emit_rbs_mutation_check.rb).
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/emit_rbs_check.rb [--unit-only]

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOLS_DIR'] || File.join(ROOT, 'tools/bc2cpp')
$LOAD_PATH.unshift(TOOLS)
require 'type_check_rbs'
require 'rbs'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def prm(pos, name, type)
  { 'pos' => pos, 'name' => name, 'type' => type, 'source' => type && 'inferred:call-sites', 'reason' => nil }
end

def mth(owner, name, params, ret, opt: 0, rest: false, key: 0, vis: 'public', scope: 'engine')
  { 'owner' => owner, 'name' => name, 'file' => 'a.rb', 'line' => 1, 'col' => 1, 'scope' => scope, 'req' => params.size, 'opt' => opt,
    'rest' => rest, 'key' => key, 'kdict' => false, 'visibility' => vis, 'params' => params,
    'return' => { 'type' => ret, 'source' => ret && 'inferred:return-analysis', 'reason' => nil }, 'annotated' => false }
end

FACTS = {
  'classes' => [
    { 'name' => 'Game', 'kind' => 'module', 'superclass' => nil },
    { 'name' => 'Game::Base', 'kind' => 'class', 'superclass' => nil },
    { 'name' => 'Game::Actor', 'kind' => 'class', 'superclass' => 'Game::Base' },
    { 'name' => 'Array', 'kind' => 'class', 'superclass' => nil }
  ],
  'methods' => [
    mth('Game::Actor', 'initialize', [prm(1, 'hp', 'Integer'), prm(2, 'kind', 'Symbol')], nil, vis: 'private'),
    mth('Game::Actor', 'target', [prm(1, 'other', 'Game::Actor')], 'Game::Actor?'),
    mth('Game::Actor', 'mix', [prm(1, 'a', nil), prm(2, 'b', 'Gone::Class'), prm(3, 'c', 'Array')], 'Array', opt: 1, rest: true, key: 1),
    mth('Game::Actor', 'hit?', [], 'bool'),
    mth('Game::Actor', 'sum', [prm(1, 'x', 'Integer | Float')], 'Integer'),
    mth('Game::Actor', 'pick', [], 'Integer | Float'),
    mth('Game::Actor.singleton', 'build', [], 'Game::Actor'),
    mth('Game::Base', 'name', [], 'String'),
    mth('Array', 'size', [], 'Integer'),
    mth('Array', 'second', [], nil),
    mth('Hidden', 'secret', [], 'Integer', scope: 'core')
  ],
  'ivars' => [
    { 'owner' => 'Game::Actor', 'name' => '@hp', 'type' => 'Integer', 'scope' => 'engine' },
    { 'owner' => 'Game::Actor', 'name' => '@items', 'type' => 'Array', 'scope' => 'engine' },
    { 'owner' => 'Game::Actor', 'name' => '@owner', 'type' => nil, 'scope' => 'engine' }
  ],
  'constants' => [
    { 'name' => 'Game::Actor::MAX', 'owner' => 'Game::Actor', 'type' => 'Integer', 'scope' => 'engine' },
    { 'name' => 'Game::Actor::TABLE', 'owner' => 'Game::Actor', 'type' => nil, 'scope' => 'engine' }
  ]
}.freeze

puts '== emitted text on a hand-written facts file'
Dir.mktmpdir do |dir|
  out = TypeCheckRbs.emit(FACTS, dir)
  read = ->(*path) { File.exist?(File.join(dir, *path)) ? File.read(File.join(dir, *path)) : '' }
  actor = read.call('Game', 'Actor.rbs')
  check.call('one file per class below its namespace directory', File.exist?(File.join(dir, 'Game/Actor.rbs')) && File.exist?(File.join(dir, 'Game/Base.rbs')))
  check.call('the superclass the program defines is written', actor.start_with?("class Game::Actor < Game::Base\n"))
  check.call('typed parameters, void initialize, private section',
             actor.include?("  private\n  def initialize: (Integer, Symbol) ?{ (*untyped) -> untyped } -> void\n"))
  check.call('a nilable return stays nilable', actor.include?('def target: (Game::Actor) ?{ (*untyped) -> untyped } -> Game::Actor?'))
  check.call('optional, rest, keyword parameters are untyped; unknown class and untyped parameter are untyped; Array gets arguments',
             actor.include?('def mix: (untyped, untyped, Array[untyped], ?untyped, *untyped, **untyped) ?{ (*untyped) -> untyped } -> Array[untyped]'))
  check.call('bool and a union are kept', actor.include?('def hit?: () ?{ (*untyped) -> untyped } -> bool') &&
             actor.include?('def sum: (Integer | Float) ?{ (*untyped) -> untyped } -> Integer'))
  check.call('a union return is parenthesised', actor.include?('def pick: () ?{ (*untyped) -> untyped } -> (Integer | Float)'))
  check.call('a singleton method is def self.', actor.include?('def self.build: () ?{ (*untyped) -> untyped } -> Game::Actor'))
  check.call('ivars and constants', actor.include?("  @hp: Integer\n") && actor.include?("  @items: Array[untyped]\n") && actor.include?("  @owner: untyped\n") &&
             actor.include?("  MAX: Integer\n") && actor.include?("  TABLE: untyped\n"))
  check.call('a module is written as a module', read.call('Game.rbs').start_with?('module Game'))
  check.call('a reopened core class gets only the methods core RBS lacks',
             read.call('Array.rbs').include?('def second:') && !read.call('Array.rbs').include?('def size:'))
  check.call('core-scope members are not written', !File.exist?(File.join(dir, 'Hidden.rbs')))
  check.call('every file parses with the rbs gem', out[:files].all? do |f|
    RBS::Parser.parse_signature(File.read(f))
    true
  rescue RBS::ParsingError
    false
  end)
  check.call('the counts', out[:files].size == 4 && out[:methods] == 9 && out[:skipped].empty?)
end

# ------------------------------------------------------------------------------------------------ 2. round trip
if ARGV.include?('--unit-only') || !ENV['MRBC']
  puts(ARGV.include?('--unit-only') ? '-- round trip skipped (--unit-only)' : '-- SKIP round trip: set MRBC')
else
  SRC = <<~RUBY
    class RtPoint
      def initialize(x, y)
        @x = x
        @y = y
      end

      def x
        @x
      end

      def scaled(k)
        @x * k
      end

      def tag
        :point
      end
    end

    class RtUser
      LIMIT = 10

      def initialize
        @pts = []
        @owner = RtPoint.new(1, 2)
      end

      def use(p)
        @pts << p
        p.scaled(2)
      end

      def run
        use(RtPoint.new(3, 4))
        @owner
      end
    end
  RUBY
  script = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')
  tc = lambda do |dir, *args|
    Open3.capture3({ 'BC2CPP_TOOLS_DIR' => TOOLS, 'MRBC' => ENV.fetch('MRBC') }, RbConfig.ruby, script, *args, chdir: dir)
  end
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'rt.rb'), SRC)
    puts '== round trip: emitted RBS read back as signatures'
    _o, err, st = tc.call(dir, '--files', 'rt.rb', '--emit-rbs', 'out', '--no-sends', '-q')
    check.call("emit succeeds (#{err.lines.first&.strip})", st.exitstatus.zero? && File.exist?(File.join(dir, 'out/RtPoint.rbs')))
    emitted = File.exist?(File.join(dir, 'out/RtPoint.rbs')) ? File.read(File.join(dir, 'out/RtPoint.rbs')) : ''
    check.call('typed parameters of the fixture are in the file', emitted.include?('def initialize: (Integer, Integer)') && emitted.include?('def scaled: (Integer)'))
    out, err, st = tc.call(dir, '--files', 'rt.rb', '--sig', 'out', '--no-sends', '-q')
    check.call("read back: exit 0 and no error/contradiction (#{(out + err).lines.first&.strip})", st.exitstatus.zero? && !out.include?(': error:'))
    line = emitted.lines.index { |l| l.include?('def scaled:') }
    File.write(File.join(dir, 'out/RtPoint.rbs'), emitted.sub('def scaled: (Integer)', 'def scaled: (Symbol)'))
    out, _e, st = tc.call(dir, '--files', 'rt.rb', '--sig', 'out', '--no-sends', '-q')
    check.call('a wrong edit is TC1001 at that line of the emitted file',
               st.exitstatus == 1 && out.include?("out/RtPoint.rbs:#{line + 1}:3: error: RtPoint#scaled parameter 1: declared Symbol, inferred Integer (signature) [TC1001]"))

    puts '== IR suggestions round trip through RBS'
    File.write(File.join(dir, 'union.rb'), <<~RUBY)
      class IrSuggestion
        def choose(flag)
          flag ? 1.5 : :tag
        end
      end
    RUBY
    out, err, st = tc.call(dir, '--files', 'union.rb', '--sig', 'no-signatures', '--emit-rbs-suggestions', 'suggested', '--no-sends', '--format', 'json')
    check.call("IR suggestion export succeeds #{err.lines.first&.strip}", st.success?)
    report = JSON.parse(out)
    check.call('an independently inferred union return improves the facts', report['methods'].first['return']['type'] == 'Float | Symbol' &&
               report['methods'].first['return']['source'] == 'inferred:bytecode-ir')
    text = File.read(File.join(dir, 'suggested/IrSuggestion.rbs'))
    check.call('candidate RBS includes the inferred union', text.include?('-> (Float | Symbol)'))
    out, err, st = tc.call(dir, '--files', 'union.rb', '--sig', 'suggested', '--no-sends', '--format', 'json')
    check.call("IR candidate read back succeeds #{err.lines.first&.strip}", st.success?)
    report = JSON.parse(out)
    check.call('reading the candidate back reports a signature with independent inferred feedback',
               report['methods'].first['return']['source'] == 'signature' && report['ir_feedback'].any? { |row|
                 row['kind'] == 'return' && row['status'] == 'inferred' && row['expected'] == 'Float | Symbol'
               })
  end
end

if failures.empty?
  puts 'ok'
else
  warn "FAILED: #{failures.size}"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
