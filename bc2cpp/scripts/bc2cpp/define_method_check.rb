#!/usr/bin/env ruby
# frozen_string_literal: true

# DEFINE_METHOD_LOOPS: a `define_method` that runs while a class body is defined is an
# ordinary method definition whose body is the block: `define_method(:x) { }` in the body (including one with a `return`), and `define_method(n) { }` in a class-body loop over a literal container, once per
# name, with the loop variable the block reads compiled as that iteration's Symbol. Everything else stays
# a dynamic installer.
#
# 1. Registry (MRBC): what each shape registers, what the expansion's body loads, and that every refused
#    shape registers nothing and keeps poisoning the installed names (CodeGen#symbol_installed_names nil).
# 2. Generated code (MRBC): calls to the expanded methods are direct, the loop variable is a Symbol
#    constant; a refused loop keeps the call a dynamic send.
# 3. Behaviour on real mruby (MRBC, g++, and BC2CPP_MRUBY_FULL or a core-only build, BC2CPP_MRUBY_CORE or
#    the tree's build*/mruby/host/mrbc): interpreted and compiled answer alike for a literal site, a loop
#    over a frozen %i[] constant, strict arity, `self`, `return`, the captured loop variable, and a refused
#    loop that stays dynamic.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/define_method_check.rb

require 'set'
require 'tmpdir'

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
runtime = Bc2cppFixtureRuntime

# [registry after settle, ireps, kept, dropped, CodeGen#symbol_installed_names] for +source+.
registry_of = lambda do |source, trusted: true|
  runtime.registry_snapshot(source) do |registry, ireps|
    DefineMethodSites.settle(registry, trusted: trusted)
  end
end
defined_by = ->(registry, name) { registry.fetch(name, []).select(&:installer) }

puts '-- registry'
POSITIVE = <<~RUBY
  class DmA
    NAMES = %i[da_x da_y].freeze
    NAMES.each { |n| define_method(n) { |v| return n if v.nil?; v } }
    %i[da_p da_q].each do |n|
      define_method(n) { self }
    end
    define_method(:da_lit) { |a| return a if a; 0 }
  end
RUBY
registry, ireps, kept, dropped, installed = registry_of.call(POSITIVE)
check.call('the loops and the literal site register five definitions', kept == 5 && dropped.zero?)
xs = defined_by.call(registry, 'da_x') + defined_by.call(registry, 'da_y')
check.call('each loop name is a public method of the class body', xs.size == 2 && xs.all? { |d| d.owner == 'DmA' && d.visibility == :public })
check.call('each expansion has its own irep, numbered in iteration order',
           xs.map(&:irep).uniq.size == 2 && xs.map { |d| d.irep[/~dm\d+\z/] } == %w[~dm0 ~dm1])
loads = xs.map { |d| ireps.fetch(d.irep).instructions.select { |i| i.op == 'LOADSYM' }.map(&:sym) }
check.call('the loop variable is the Symbol each iteration bound', loads == [['da_x'], ['da_y']])
check.call('no expansion reads an upvar', xs.none? { |d| ireps.fetch(d.irep).instructions.any? { |i| i.op.end_with?('UPVAR') } })
check.call('a body without captures registers too (`self`)', defined_by.call(registry, 'da_p').size == 1 && defined_by.call(registry, 'da_q').size == 1)
check.call('a literal site whose body returns registers (ADR 0288 refused it)', defined_by.call(registry, 'da_lit').size == 1)
check.call('settled sends install nothing unknown', !installed.nil? && (installed & %w[da_x da_y da_p da_q da_lit]).empty?)
DynamicNames.settled_sends = DefineMethodSites.loop_sites(registry)
stems, computed = DynamicNames.analyze(ireps)
check.call('a settled loop send names exactly its expansions, not a computed name', !computed && %w[da_x da_y].all? { |n| stems.include?(n) })
DynamicNames.settled_sends = nil
check.call('without the settled sends a loop send is a computed name', DynamicNames.analyze(ireps).last)

# Shapes that stay dynamic installers: nothing registered, and the installed names stay unknown.
WRAP = ->(body) { "class DmN\n#{body}end\n" }
REFUSED = {
  'a String name' => "  %w[dn_a].each { |n| define_method(n) { 1 } }\n",
  'a computed name' => "  %i[dn_a].each { |n| define_method(\"x_\#{n}\") { 1 } }\n",
  'a container a call could have reached' => "  NAMES = %i[dn_a]\n  NAMES.push(:dn_b)\n  NAMES.each { |n| define_method(n) { 1 } }\n",
  'a container that is not a literal' => "  def self.names; %i[dn_a]; end\n  names.each { |n| define_method(n) { 1 } }\n",
  'a body reading a class-body local' => "  k = 1\n  %i[dn_a].each { |n| define_method(n) { k } }\n",
  'a body reading a loop variable that is not a Symbol' => "  { dn_a: 1 }.each { |n, v| define_method(n) { v } }\n",
  'a loop variable reassigned after the install' => "  %i[dn_a].each { |n| define_method(n) { n }; n = 1 }\n",
  'a body with a nested block' => "  %i[dn_a].each { |n| define_method(n) { [1].map { |v| v } } }\n",
  'an optional parameter' => "  %i[dn_a].each { |n| define_method(n) { |a = 1| a } }\n",
  'block_given?' => "  %i[dn_a].each { |n| define_method(n) { block_given? } }\n",
  'a return from a nested block' => "  define_method(:dn_a) { [1].each { |v| return v }; 0 }\n",
  'a conditional install' => "  %i[dn_a].each { |n| define_method(n) { 1 } if $dn }\n",
  'a singleton class body' => "  class << self\n    %i[dn_a].each { |n| define_method(n) { 1 } }\n  end\n"
}.freeze
REFUSED.each do |what, body|
  registry, _ireps, kept, _dropped, installed = registry_of.call(WRAP.call(body))
  check.call("#{what} registers nothing", kept.zero? && defined_by.call(registry, 'dn_a').empty?)
  check.call("#{what} keeps the installed names unknown", installed.nil? || installed.include?('dn_a'))
end
registry, _ireps, kept, = registry_of.call("%i[dn_a].each { |n| define_method(n) { 1 } }\n")
check.call('a loop at top level registers nothing', kept.zero? && defined_by.call(registry, 'dn_a').empty?)

# Settle: one loop send keeps all of its expansions or none.
registry, _ireps, kept, dropped, installed = registry_of.call(WRAP.call("  %i[dn_a dn_b].each { |n| define_method(n) { 1 } }\n  def dn_a; 2; end\n"))
check.call('a def of one expanded name drops every expansion of that send',
           kept.zero? && dropped == 2 && defined_by.call(registry, 'dn_b').empty? && installed.nil?)
registry, _ireps, kept, dropped, = registry_of.call(WRAP.call("  %i[dn_a dn_a].each { |n| define_method(n) { 1 } }\n"))
check.call('a name a loop installs twice is dropped', kept.zero? && dropped == 2 && defined_by.call(registry, 'dn_a').empty?)
_registry, _ireps, kept, dropped, installed = registry_of.call(POSITIVE, trusted: false)
check.call('an untrusted define_method drops every site', kept.zero? && dropped == 5 && installed.nil?)

body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
SITES_LINE = /== define_method sites \((\d+) registered as definitions, (\d+) left as installers\)/

WORLD = <<~RUBY
  class DmLoop
    def initialize; @n = 10; end
    NAMES = %i[dl_a dl_b].freeze
    NAMES.each { |n| define_method(n) { |x| return n if x.nil?; x + @n } }
    %i[dl_c dl_d].each { |n| define_method(n) { n } }
    define_method(:dl_lit) { |a, b| return a if b.nil?; a + b }
    define_method(:dl_self) { self }
    def same?; dl_self.equal?(self); end
    def run(x); dl_a(x) + dl_b(x) + dl_lit(x, 1); end
    def names; [dl_c, dl_d, dl_a(nil), dl_b(nil), dl_lit(3, nil)]; end
  end
  # Not compiled: calls through OP_SEND, where the VM checks a registered entry's aspec as it checks a
  # strict proc's ENTER.
  class DmProbe
    def self.a0(o); o.dl_a; end
    def self.a2(o); o.dl_a(1, 2); end
    def self.c1(o); o.dl_c(1); end
    def self.lit1(o); o.dl_lit(1); end
  end
RUBY
REFUSED_WORLD = <<~RUBY
  class DmKept
    k = 5
    %i[dk_a].each { |n| define_method(n) { |x| x + k } }
    def run(x); dk_a(x); end
  end
RUBY

full = runtime.full || (runtime.core ? nil : runtime.full_or_build)
build = full || runtime.core
runtime_fixtures = {}
reuse_runtime = full && runtime.compiler?

puts '-- generated code'
Dir.mktmpdir do |dir|
  code, err = if reuse_runtime
                shape, fixture = runtime.generate_owner_variants(WORLD, dir, [nil, %w[DmLoop]])
                runtime_fixtures[[WORLD, %w[DmLoop]]] = fixture
                [shape.code, shape.diagnostics]
              else
                runtime.generate(WORLD, dir)
              end
  check.call('the world registers six definitions', err[SITES_LINE, 1] == '6' && err[SITES_LINE, 2] == '0')
  run = body_of.call(code, 'DmLoop_run')
  check.call('run calls the expanded and literal methods directly',
             %w[dl_a dl_b dl_lit].all? { |m| run.include?("DmLoop_#{m}_impl(M, self") } && !run.include?('bc2cpp_send('))
  check.call('names calls each expansion directly', %w[dl_c dl_d dl_a dl_b].all? { |m| body_of.call(code, 'DmLoop_names').include?("DmLoop_#{m}_impl(M, self") })
  syms = %w[dl_c dl_d].map { |m| body_of.call(code, "DmLoop_#{m}") }
  check.call('each expansion loads its own Symbol constant and reads no upvar',
             syms.all? { |b| b.include?('mrb_symbol_value(') && !b.include?('upvar') } && syms.uniq.size == 2)
end
Dir.mktmpdir do |dir|
  code, err = if reuse_runtime
                shape, fixture = runtime.generate_owner_variants(REFUSED_WORLD, dir, [nil, %w[DmKept]])
                runtime_fixtures[[REFUSED_WORLD, %w[DmKept]]] = fixture
                [shape.code, shape.diagnostics]
              else
                runtime.generate(REFUSED_WORLD, dir)
              end
  run = body_of.call(code, 'DmKept_run')
  check.call('a refused loop registers nothing', err[SITES_LINE, 1].to_i.zero?)
  check.call('a refused loop keeps its call a dynamic send', !run.empty? && !run.include?('DmKept_dk_a_impl(') && run.include?('bc2cpp_send('))
end

# Array#each for a build whose mrblib is empty; core-sourced, so it is still mruby's own iterator.
POLYFILL = <<~RUBY
  class Array
    def each
      i = 0
      while i < size
        yield self[i]
        i += 1
      end
      self
    end
  end
RUBY

SCENARIO = <<~CPP
  static mrb_value num(int n) { return mrb_fixnum_value(n); }
  static int scenario(mrb_state* M) {
    mrb_value o = mrb_obj_new(M, mrb_class_get(M, "DmLoop"), 0, nullptr);
    mrb_value probe = mrb_obj_value(mrb_class_get(M, "DmProbe"));
    mrb_value a4 = num(4), nil = mrb_nil_value();
    call(M, "run(4)", o, "run", 1, &a4);
    call(M, "names", o, "names");
    call(M, "same?", o, "same?");
    call(M, "dl_a(4)", o, "dl_a", 1, &a4);
    call(M, "dl_b(nil)", o, "dl_b", 1, &nil);
    call(M, "dl_c", o, "dl_c");
    call(M, "probe.a0", probe, "a0", 1, &o);
    call(M, "probe.a2", probe, "a2", 1, &o);
    call(M, "probe.c1", probe, "c1", 1, &o);
    call(M, "probe.lit1", probe, "lit1", 1, &o);
    return 0;
  }
CPP
REFUSED_SCENARIO = <<~CPP
  static int scenario(mrb_state* M) {
    mrb_value o = mrb_obj_new(M, mrb_class_get(M, "DmKept"), 0, nullptr);
    mrb_value a4 = mrb_fixnum_value(4);
    call(M, "kept.run(4)", o, "run", 1, &a4);
    call(M, "kept.dk_a(4)", o, "dk_a", 1, &a4);
    call(M, "kept.dk_a()", o, "dk_a");
    return 0;
  }
CPP

if build.nil? || !runtime.compiler?
  puts '  SKIP run: needs g++ and a mruby build (BC2CPP_MRUBY_FULL, BC2CPP_MRUBY_CORE or build*/mruby/host/mrbc)'
else
  puts "-- fixtures on real mruby (#{full ? 'full-core' : 'core only'}), interpreted and compiled"
  values = ->(sections, name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
  [[WORLD, %w[DmLoop], SCENARIO, 10], [REFUSED_WORLD, %w[DmKept], REFUSED_SCENARIO, 3]].each do |world, owners, scenario, calls|
    Dir.mktmpdir do |dir|
      err = if full
              runtime_fixtures.fetch([world, owners]).write(dir)
            else
              runtime.generate(POLYFILL, dir, only_owners: owners, path: '3rd/mruby/mrblib/dm_polyfill.rb',
                               extra: [['fixture.rb', world]]).last
            end
      built, output = runtime.run(dir, err, owners, scenario, build: build, full: !full.nil?, exact_arity: true)
      check.call("#{owners.first} compiles and runs against real mruby", built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = values.call(sections, 'interpreted')
      compiled = values.call(sections, 'compiled')
      puts output if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call("#{owners.first}: compiled answers what the interpreter answers (#{interpreted.size} calls)",
                 interpreted.size == calls && interpreted == compiled)
      text = interpreted.join("\n")
      if owners == %w[DmLoop]
        check.call('the methods answer: loop variable, return, self',
                   text.include?('run(4) => 33') && text.include?('names => [:dl_c, :dl_d, :dl_a, :dl_b, 3]') &&
                     text.include?('same? => true') && text.include?('dl_b(nil) => :dl_b'))
        check.call('strict arity raises ArgumentError for each shape',
                   %w[a0 a2 c1 lit1].all? { |p| text.include?("probe.#{p} => raised ArgumentError") })
        dispatches = sections.fetch('compiled', []).each_cons(2).select { |c, n| c.start_with?('run(4)', 'names') && n.include?('dispatches=') }
        check.call('a compiled run and names make no dynamic dispatch', dispatches.size == 2 && dispatches.all? { |_, n| n.strip == 'dispatches=0' })
      else
        check.call('the refused loop still answers through the interpreted proc',
                   text.include?('kept.run(4) => 9') && text.include?('kept.dk_a() => raised ArgumentError'))
      end
    end
  end
end

puts(failures.empty? ? 'bc2cpp_define_method_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
