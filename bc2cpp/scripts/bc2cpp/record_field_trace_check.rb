#!/usr/bin/env ruby
# frozen_string_literal: true

# RECORD_FIELD_TRACE (rbs_record_values.rb): a declared record field (`@ui: { ?allies: Array }`) is checked against
# stores whose value is a core block iterator on a traced receiver, a program call whose every definition returns
# that class, an attr_reader of an ivar every store of which is that class, or a join of those. The checked field is
# a guarded receiver hint (RECORD_TYPE ... hints); recursion is solved as a fixpoint. A definition that may return
# another class, a literal block that `break`s, a native name, an attr_writer and a store of another class keep
# TC1009, which aborts the run.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/record_field_trace_check.rb
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('record_field_trace_check')
check = suite.method(:check)
suite.require_mrbc!
runtime = Bc2cppFixtureRuntime

BASE = <<~RUBY
  class Member
    def initialize(n); @n = n; nil; end
    def n; @n; end
  end
  class Troop
    attr_reader :roster
    def initialize
      @roster = []
      @roster << Member.new(1)
      nil
    end
  end
  class Party
    attr_reader :actors
    def initialize
      @actors = [Member.new(2)]
      nil
    end
    def battle_items
      @actors.select { |a| a.n > 0 }.map { |a| [a, 1] }
    end
    def battle_skills(actor)
      return [] unless actor
      @actors.map { |a| [a.n, 0] }
    end
  end
  class Scene
    def initialize(party)
      @party = party
      @ui = {}
      nil
    end
    def start
      troop = Troop.new
      allies = @party.actors.map { |a| a }
      foes = troop.roster.map { |m| m }
      @ui.update({ allies: allies, foes: foes, skills: [], items: [] })
      nil
    end
    def open_skills(actor)
      list = actor ? @party.battle_skills(actor) : []
      list = list.reject { |s| s.nil? } if actor
      @ui[:skills] = list
      nil
    end
    def open_items
      @ui[:items] = @party.battle_items
      nil
    end
    def count
      @ui[:allies].size + @ui[:foes].size + @ui[:skills].size + @ui[:items].size
    end
  end
RUBY
SIG = <<~RBS
  class Scene
    @ui: { ?allies: Array, ?foes: Array, ?skills: Array, ?items: Array }
  end
RBS

# [stderr, nil, generated code] of a run, or [nil, failure text] when bc2cpp.rb aborts.
run = lambda do |source, sig, env = {}|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('record-field-trace') do |dir|
    sigs = File.join(dir, 'sig')
    FileUtils.mkdir_p(sigs)
    File.write(File.join(sigs, 'record.rbs'), sig)
    ENV['BC2CPP_SIG_DIRS'] = sigs
    code, err = runtime.generate(source, dir, only_owners: %w[Member Troop Party Scene Other])
    [err, nil, code]
  rescue RuntimeError => e
    [nil, e.message]
  ensure
    ENV.delete('BC2CPP_SIG_DIRS')
    env.each_key { |k| ENV.delete(k) }
  end
end
body = ->(code, name) { code.to_s.split(%r{^(?=// \w+#)}).find { |part| part.start_with?("// #{name}") }.to_s }
exact_size = ->(code) { body.call(code, 'Scene#count').scan('NILABLE_RECEIVER :size -- receiver is nil or exactly Array').size }

err, failure, code = run.call(BASE, SIG)
check.call('the record of block-iterator, call-result and joined stores is verified',
           failure.nil? && err.include?('RECORD_TYPE  Scene#@ui  (4 keys; hints: :allies Array, :foes Array, ' \
                                        ':items Array, :skills Array)'))
warn failure if failure
check.call('each traced field read is nil or exactly an Array (RECORD_NILABLE_READ)', exact_size.call(code) == 4)
_, _, off = run.call(BASE, SIG, 'BC2CPP_RECORD_FIELD_TRACE' => '0')
check.call('BC2CPP_RECORD_FIELD_TRACE=0 leaves the reads unknown', exact_size.call(off).zero?)

recursive = BASE + "class Other\n  def battle_items; deep(3); end\n  def deep(n); n > 0 ? deep(n - 1) : []; end\nend\n"
err, failure = run.call(recursive, SIG)
check.call('a recursive definition is solved as a fixpoint', failure.nil? && err.include?('hints: :allies Array'))

refused = lambda do |what, source, pattern|
  _, text = run.call(source, SIG)
  check.call(what, text.to_s.include?('TC1009') && text.to_s.match?(pattern))
end
refused.call('a second definition that returns a String keeps TC1009',
             BASE + "class Other\n  def battle_items; ''; end\nend\n",
             /Scene\#@ui: value of :items is String, declared Array/)
refused.call('a recursive definition with a String exit keeps TC1009',
             recursive.sub('deep(n - 1) : []', "deep(n - 1) : ''"),
             /Scene\#@ui: value of :items is String, declared Array/)
refused.call('a literal block that breaks keeps TC1009',
             BASE.sub('allies = @party.actors.map { |a| a }', 'allies = @party.actors.map { |a| break 1 if a.n > 5; a }'),
             /Scene\#@ui: value of :allies cannot be traced/)
refused.call('an attr_writer on the read ivar keeps TC1009',
             BASE + "class Other\n  attr_writer :roster\nend\n",
             /Scene\#@ui: value of :foes cannot be traced/)
refused.call('a name with a native definition of unknown owner keeps TC1009 (Struct#members)',
             BASE.sub('attr_reader :roster', 'attr_reader :roster, :members').sub('troop.roster.map', 'troop.members.map')
                 .sub('@roster = []', '@roster = []; @members = []'),
             /Scene\#@ui: value of :foes cannot be traced/)
refused.call('a store of another class keeps TC1009',
             BASE.sub('@actors = [Member.new(2)]', '@actors = [Member.new(2)]; @actors = {} if @actors.empty?'),
             /Scene\#@ui: value of :allies cannot be traced/)

suite.finish!
