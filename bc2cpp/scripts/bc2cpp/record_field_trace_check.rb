#!/usr/bin/env ruby
# frozen_string_literal: true

# RECORD_FIELD_TRACE (rbs_record_values.rb): a declared record field (`@ui: { ?allies: Array }`) is checked against
# stores whose value is a core block iterator on a traced receiver, a program call whose every definition returns
# that class, an attr_reader of an ivar every store of which is that class, or a join of those. The checked field is
# a guarded receiver hint (RECORD_TYPE ... hints). A definition that may return another class, a literal block that
# `break`s, a native name and a reflected ivar keep TC1009, which aborts the run.
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

# [stderr, nil] of a run, or [nil, failure text] when bc2cpp.rb aborts.
run = lambda do |source, sig|
  Dir.mktmpdir('record-field-trace') do |dir|
    sigs = File.join(dir, 'sig')
    FileUtils.mkdir_p(sigs)
    File.write(File.join(sigs, 'record.rbs'), sig)
    ENV['BC2CPP_SIG_DIRS'] = sigs
    _code, err = runtime.generate(source, dir, only_owners: %w[Member Troop Party Scene Other])
    [err, nil]
  rescue RuntimeError => e
    [nil, e.message]
  ensure
    ENV.delete('BC2CPP_SIG_DIRS')
  end
end

err, failure = run.call(BASE, SIG)
check.call('the record of block-iterator, call-result and joined stores is verified',
           failure.nil? && err.include?('RECORD_TYPE  Scene#@ui  (4 keys; hints: :allies Array, :foes Array, ' \
                                        ':items Array, :skills Array)'))
warn failure if failure

refused = lambda do |what, source, pattern|
  _, text = run.call(source, SIG)
  check.call(what, text.to_s.include?('TC1009') && text.to_s.match?(pattern))
  warn text.to_s.lines.grep(/TC1009/).join if ENV['RFT_DEBUG']
end
refused.call('a second definition that returns a String keeps TC1009',
             BASE + "class Other\n  def battle_items; ''; end\nend\n",
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
