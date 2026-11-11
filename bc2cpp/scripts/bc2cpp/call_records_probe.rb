#!/usr/bin/env ruby
# frozen_string_literal: true

# CALL_RECORDS: the registry (visibility, attr_* names, module_function), ALIAS_SITES, DEFINE_METHOD_SITES and the escape world's
# naming-send scan read the literal names of a send from the emitter's `call` record (ClassScope.call_at) when the irep carries
# annotations, and from the register dataflow when it does not. Each fixture is compiled once; its registry is built from the
# annotated tree and from the same tree with the annotations ignored (BC2CPP_CLASS_SCOPE=0), and the two must be equal. The
# cross-check (BC2CPP_CALL_CROSSCHECK=1) must agree with both on every fixture, and must report the one thing the dataflow
# cannot read (a String name). Needs no mrbc: the Ruby emitter compiles the fixtures.
#
# Usage: ruby scripts/bc2cpp/call_records_probe.rb
# (Named *_probe, not *_check: the world's check registry demands a policy entry in rpg-maker-clone for every *_check.rb.)

require 'tmpdir'
require 'set'
require_relative '../../tools/bc2cpp/call_records'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |description, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{description}"
  failures << description unless ok
end

FIXTURE = <<~RUBY
  class Cr
    attr_reader :ra, :rb
    attr_writer :wa
    attr_accessor :aa, :ab
    def pub1; end
    def hide_a; end
    def hide_b; end
    def prot; end
    private :hide_a, :hide_b
    protected :prot
    private def inline_private = 1
    def kept; end
    alias_method :al_new, :kept
    def between; end
    private
    def after_private; end
    public
    def after_public; end
    define_method(:dm) { 1 }
  end
  class CrDyn
    def kept; end
    private alias_method :al_hidden, :kept
    2.times { alias_method :al_loop, :kept }
    alias_method :"al_\#{ENV.size}", :kept
    alias_method :al_fine, :kept
  end
  module CrMod
    module_function
    def mf; end
  end
  module CrNamed
    def named; end
    module_function :named
  end
RUBY

# [registry as comparable rows, escape world] of the Ruby +sources+ (a String: one fixture file; an Array: files of the world).
analyze = lambda do |sources, annotated: true|
  Dir.mktmpdir('call_records') do |dir|
    paths = if sources.is_a?(String)
              File.write(File.join(dir, 'fixture.rb'), sources)
              [File.join(dir, 'fixture.rb')]
            else
              sources
            end
    ENV['BC2CPP_CLASS_SCOPE'] = '0' unless annotated
    begin
      ireps, root = compile_ireps(paths, 'call_records', dir, mrbc: nil)
    ensure
      ENV.delete('BC2CPP_CLASS_SCOPE')
    end
    carried = ireps.each_value.all?(&:class_scope)
    registry, superclass_of, = build_registry(ireps, root)
    world = EscapeAnalysis::World.new(ireps: ireps, defs: registry, aliases: Hash.new { |h, k| h[k] = [] }, native_names: nil,
                                      native_files: {}, native_owners: {}, superclass_of: superclass_of, included: {},
                                      prepended: {}, unknown_mixins: Set.new, modules: Set.new, struct_classes: [],
                                      hidden_owners: nil, invisible: nil)
    rows = registry.sort.flat_map do |name, defs|
      defs.map { |d| [name, d.owner, d.visibility, d.kind, d.installer, d.irep.nil?, d.copy_owner] }
    end
    { annotated: carried, rows: rows, dynamic: world.dynamic_sites.map { |_l, _i, what| what }.sort,
      aliases: world.aliases.to_a.sort, registry: registry }
  end
end

puts '== registry, alias and escape scans: record against dataflow'
CallRecords.reset!
ann = analyze.call(FIXTURE)
flow = analyze.call(FIXTURE, annotated: false)
check.call('the annotated tree carries the call records, the other none', ann[:annotated] && !flow[:annotated])
check.call('the registry is the same with and without the records', ann[:rows] == flow[:rows])
check.call('the escape world sees the same dynamic sites and aliases', ann[:dynamic] == flow[:dynamic] && ann[:aliases] == flow[:aliases])
reg = ann[:registry]
vis = ->(name, owner = 'Cr') { reg[name].find { |d| d.owner == owner }&.visibility }
check.call('private :a, :b hides both', vis.call('hide_a') == :private && vis.call('hide_b') == :private)
check.call('protected :a', vis.call('prot') == :protected)
check.call('private def x', vis.call('inline_private') == :private)
check.call('a bare private applies to the defs after it, a bare public ends it',
           vis.call('after_private') == :private && vis.call('after_public') == :public)
check.call('attr_* names are accessors of Cr',
           %w[ra rb wa= aa aa= ab ab=].all? { |n| reg[n].any? { |d| d.owner == 'Cr' && d.kind == :ivar_accessor } })
check.call('alias_method :new, :old is a definition of new', reg['al_new'].any? { |d| d.owner == 'Cr' && d.installer == :alias })
check.call('define_method(:dm) { } is a definition of dm', reg['dm'].any? { |d| d.owner == 'Cr' && d.installer == :define_method })
check.call('a bare module_function copies the later defs', reg['mf'].any? { |d| d.owner == 'CrMod.singleton' && d.kind == :module_function })
check.call('module_function :named copies named', reg['named'].any? { |d| d.owner == 'CrNamed.singleton' && d.kind == :module_function })
check.call('an alias handed to private, or in a loop, registers nothing; a plain one after them still does',
           %w[al_hidden al_loop].all? { |n| reg[n].none? { |d| d.installer == :alias } } && reg['al_fine'].any? { |d| d.installer == :alias })
check.call('the computed alias is a dynamic site, with and without the records', ann[:dynamic] == ['alias_method'])

puts '== cross-check (BC2CPP_CALL_CROSSCHECK=1)'
ENV['BC2CPP_CALL_CROSSCHECK'] = '1'
CallRecords.reset!
analyze.call(FIXTURE)
check.call('the record and the dataflow agree on every site of the fixture', CallRecords.disagreements.empty?)
check.call('it checked the argument counts, the names, the alias and the define_method sites',
           %i[argc names alias_names define_method_name naming_names].all? { |k| CallRecords.summary.include?("  #{k}: ") })
long = Array.new(16) { |i| ":l#{i}" }.join(', ')
CallRecords.reset!
packed = analyze.call("class CrLong\n  attr_reader #{long}\n  private #{long}\nend\n")
check.call('a call of 16 names (packed into an Array) is read from the record, and agrees where the dataflow can read it',
           packed[:rows].count { |r| r[1] == 'CrLong' && r[3] == :ivar_accessor } == 16 && CallRecords.disagreements.empty?)

CallRecords.reset!
strings = analyze.call("class CrStr\n  attr_reader \"sname\", :pname\n  private \"sname\"\nend\n")
check.call('attr_reader "name": the record names it, and the registry has it',
           strings[:rows].any? { |r| r[0] == 'sname' && r[1] == 'CrStr' && r[3] == :ivar_accessor })
check.call('the dataflow cannot read a String name: the cross-check reports it as a disagreement',
           CallRecords.disagreements.any? { |r| r.kind == :names && r.annotated.include?('sname') })
check.call('the registry without records misses it (the known bug of the dataflow)',
           analyze.call("class CrStr\n  attr_reader \"sname\"\nend\n", annotated: false)[:rows].none? { |r| r[0] == 'sname' })

# The corpus: the closed world the compiled gems are built from (the pinned rpg-maker-clone's mrblib sets), when it is there.
puts '== corpus (the closed world)'
world = BC2CPP_WORLD_ROOT
if Dir.exist?(File.join(world, 'mruby-rpg2k', 'mrblib')) && Dir.exist?(File.join(world, '3rd', 'mruby', 'mrblib'))
  srcs = closed_world_mrblib_srcs(world, core_gems: BC2CPP_CANONICAL_CORE_GEMS, tts: false)
  CallRecords.reset!
  corpus = analyze.call(srcs)
  disagreeing = CallRecords.disagreements.dup
  puts CallRecords.summary
  check.call("#{srcs.size} files: the cross-check finds no site where the record and the dataflow disagree", disagreeing.empty?)
  ENV.delete('BC2CPP_CALL_CROSSCHECK')
  plain = analyze.call(srcs, annotated: false)
  check.call('the corpus registry, aliases and dynamic sites are the same with and without the records',
             corpus[:annotated] && !plain[:annotated] && corpus[:rows] == plain[:rows] && corpus[:aliases] == plain[:aliases] &&
             corpus[:dynamic] == plain[:dynamic])
else
  puts '  SKIP: no world (BC2CPP_WORLD_ROOT) to read the corpus from'
end
ENV.delete('BC2CPP_CALL_CROSSCHECK')
CallRecords.reset!

if failures.empty?
  puts 'call_records_probe: all checks passed'
else
  warn "call_records_probe: #{failures.size} check(s) failed"
  exit 1
end
