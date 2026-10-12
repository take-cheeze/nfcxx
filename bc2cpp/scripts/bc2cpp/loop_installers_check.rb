#!/usr/bin/env ruby
# frozen_string_literal: true

# LOOP_INSTALLERS (docs/adr/0304): a class-body loop over a literal container whose body sends
# attr_reader/attr_writer/attr_accessor registers exactly the names CRuby installs, as ordinary ivar
# accessors; any loop the interpreter in tools/bc2cpp/loop_installers.rb cannot follow stays the
# dynamic installer it was.
#
# 1. Registry (needs MRBC): the registered names equal what CRuby installs for each positive world
#    (including the names a `next if` leaves out); every negative world registers nothing and keeps
#    the closed world's dynamic-installer withdrawal.
# 2. Generated code (needs MRBC): a call of a loop-installed name devirtualizes like a literal
#    attr_reader's, and a dynamic installer elsewhere still withdraws the proofs.
# 3. Behaviour on real mruby (needs MRBC, a mruby build and g++): interpreted and compiled answer
#    alike on a 64-bit full-core build, a core-only build (the iterators come from a core-sourced
#    polyfill, the core build has no mrblib), and (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32) a 32-bit
#    `mrb_int` build.
#
# LP_REGISTRY_ONLY=1 runs the registry half alone, plus the one closed-world withdrawal the mutation
# check needs.
# BC2CPP_TOOLS_DIR / BC2CPP_TOOL name another copy of tools/bc2cpp (scripts/bc2cpp/loop_installers_mutation_check.rb).
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/loop_installers_check.rb

require 'set'
require 'stringio'
require 'tmpdir'

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

require File.join(ENV.fetch('BC2CPP_TOOLS_DIR') { File.expand_path('../../tools/bc2cpp', __dir__) }, 'bc2cpp')
require_relative 'fixture_runtime'

REGISTRY_ONLY = ENV['LP_REGISTRY_ONLY'] == '1'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
runtime = Bc2cppFixtureRuntime
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

# [owner => sorted accessor names the registry holds for it, bc2cpp's loop-installer diagnostics]
def registry_names(source)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'fx.rb')
    File.write(path, source)
    ireps, root = compile_ireps(path, 'lp_fx', dir)
    saved = $stderr
    $stderr = StringIO.new
    begin
      registry, = build_registry(ireps, root)
      diagnostics = $stderr.string
    ensure
      $stderr = saved
    end
    names = Hash.new { |h, k| h[k] = [] }
    registry.each_value do |defs|
      defs.each { |d| names[d.owner] << d.name if d.kind == :ivar_accessor }
    end
    loop_owners = registry.each_value.flat_map { |defs| defs.select(&:site).map(&:owner) }.uniq
    [names.transform_values(&:sort), loop_owners, diagnostics]
  end
end

# What CRuby itself installs on +klass+ once +source+ has run (each world uses names of its own).
def cruby_names(source, klass)
  TOPLEVEL_BINDING.eval(source)
  Object.const_get(klass).instance_methods(false).map(&:to_s).sort
end

# -- 1. the registry --------------------------------------------------------------------------

POSITIVES = {
  'an Array constant, attr_accessor' => ['LpArr', <<~RUBY],
    class LpArr
      LP_NAMES = %i[lp_a1 lp_a2]
      LP_NAMES.each { |n| attr_accessor n }
    end
  RUBY
  'a frozen Array constant' => ['LpFrozen', <<~RUBY],
    class LpFrozen
      LP_NAMES = %i[lp_f1 lp_f2].freeze
      LP_NAMES.each { |n| attr_reader n }
    end
  RUBY
  'a literal Array receiver, reader and writer loops' => ['LpLit', <<~RUBY],
    class LpLit
      %i[lp_l1 lp_l2].each { |n| attr_reader n }
      [:lp_l3].each { |n| attr_writer n }
    end
  RUBY
  'a Hash constant through each_key, each_value and each' => ['LpHash', <<~RUBY],
    class LpHash
      LP_TABLE = { lp_h1: nil, lp_h2: true, lp_h3: false }.freeze
      LP_TABLE.each_key { |k| attr_reader k }
      LP_TABLE.each { |k, v| attr_writer k unless v }
    end
  RUBY
  'the optcarrot shape: nested loops, next, a side table, computed values' => ['LpConf', <<~RUBY],
    module LpSrc
      LIST = %i[lp_x lp_y]
    end
    class LpConf
      OPTS = {
        main: { lp_c1: { default: 1 }, lp_skip: { shortcut: "--a" }, lp_c2: { type: LpSrc::LIST } },
        more: { lp_c3: { default: nil }, lp_skip2: { aliases: :q, shortcut: %w[--b --c] } },
      }
      DEFAULTS = {}
      OPTS.each_value do |group|
        group.each do |id, opt|
          next if opt[:shortcut]
          DEFAULTS[id] = opt[:default] if opt.key?(:default)
          attr_reader id
        end
      end
      attr_reader :lp_rom
    end
  RUBY
  'two loops over one constant' => ['LpTwice', <<~RUBY],
    class LpTwice
      LP_NAMES = %i[lp_t1 lp_t2]
      LP_NAMES.each { |n| attr_reader n }
      LP_NAMES.each { |n| attr_writer n }
    end
  RUBY
  'a mutation after the loop is too late to matter' => ['LpLate', <<~RUBY],
    class LpLate
      LP_NAMES = %i[lp_z1]
      LP_NAMES.each { |n| attr_reader n }
      LP_NAMES << :lp_z2
    end
  RUBY
  'a break that never runs (mrbc turns nil? into a jump)' => ['LpBrk', <<~RUBY],
    class LpBrk
      LP_NAMES = %i[lp_b1]
      LP_NAMES.each { |n| break if n.nil?; attr_reader n }
    end
  RUBY
  'a module body' => ['LpMod', <<~RUBY]
    module LpMod
      LP_NAMES = %i[lp_m1 lp_m2]
      LP_NAMES.each { |n| attr_accessor n }
    end
  RUBY
}.freeze

puts '-- registry: the names equal what CRuby installs'
POSITIVES.each do |what, (klass, source)|
  names, loop_owners, diagnostics = registry_names(source)
  expected = cruby_names(source, klass)
  got = names[klass]
  check.call("#{what}: #{expected.size} names, as CRuby", loop_owners.include?(klass) && got == expected)
  puts "       registry #{got.inspect}\n       cruby    #{expected.inspect}\n#{diagnostics}" unless got == expected
end

# A world the interpreter must not follow. Each keeps its names out of the registry.
HEAD = "class LpNg\n"
NEGATIVES = {
  'a mutation before the loop' => "  LP_NAMES = %i[lp_n1]\n  LP_NAMES << :lp_n2\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a mutation through an alias' =>
    "  LP_NAMES = %i[lp_n1]\n  LP_OTHER = LP_NAMES\n  LP_OTHER << :lp_n2\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a mutated local container' => "  k = %i[lp_n1]\n  k << :lp_n2\n  k.each { |n| attr_reader n }\n",
  'a loop repeated by a do-while' =>
    "  LP_NAMES = %i[lp_n1]\n  i = 0\n  begin\n    LP_NAMES.each { |n| attr_reader n }\n    i += 1\n  end while i < 2\n",
  'a name that is not an attribute name' => "  LP_NAMES = %i[lp_n1?]\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a one-parameter block over Hash#each' => "  LP_TABLE = { lp_n1: 1 }\n  LP_TABLE.each { |pair| attr_reader pair }\n",
  'a two-parameter block over an Array' => "  LP_NAMES = [[:lp_n1, 1]]\n  LP_NAMES.each { |a, b| attr_reader a }\n",
  'a mutation of the container inside the loop' =>
    "  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each { |n| attr_reader n; LP_NAMES << :lp_n2 }\n",
  'a write into the iterated Hash inside the loop' =>
    "  LP_TABLE = { lp_n1: 1 }\n  LP_TABLE.each { |k, v| LP_TABLE[k] = 2; attr_reader k }\n",
  'a computed name' => "  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each { |n| attr_reader :\"\#{n}_x\" }\n",
  'a name converted by a call' => "  LP_NAMES = %w[lp_n1]\n  LP_NAMES.each { |n| attr_reader n.to_sym }\n",
  'a container built by a call' => "  LP_NAMES = Array.new(1) { :lp_n1 }\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a container joined from two' => "  LP_NAMES = [:lp_n1] + [:lp_n2]\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a container from another scope' =>
    "  LP_NAMES = LpNgSrc::LIST\n  LP_NAMES.each { |n| attr_reader n }\n",
  'an element that is not a literal' =>
    "  LP_NAMES = [LpNgSrc::LIST.first]\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a Hash with a key that is not a Symbol' => "  LP_TABLE = { 'lp_n1' => 1 }\n  LP_TABLE.each_key { |k| attr_reader k }\n",
  'a constant read between the build and the loop' =>
    "  LP_NAMES = %i[lp_n1]\n  LpNgSrc\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a call between the build and the loop' =>
    "  LP_NAMES = %i[lp_n1]\n  LP_SPARE = 1\n  puts\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a loop under a branch' => "  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each { |n| attr_reader n } if $lp_flag\n",
  'a loop in a while body' => "  LP_NAMES = %i[lp_n1]\n  i = 0\n  while i < 2\n    LP_NAMES.each { |n| attr_reader n }\n    i += 1\n  end\n",
  'a branch on a global inside the loop' => "  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each { |n| next if $lp_flag; attr_reader n }\n",
  'a block that closes over a local' => "  k = :lp_n1\n  [:lp_n2].each { |n| attr_reader k }\n",
  'a break that runs' => "  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each { |n| break if n; attr_reader n }\n",
  'a private default visibility' => "  private\n  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each { |n| attr_reader n }\n",
  'a loop built and run under a branch' =>
    "  if $lp_flag\n    LP_NAMES = %i[lp_n1]\n    LP_NAMES.each { |n| attr_reader n }\n  end\n",
  'a loop retried by a rescue' =>
    "  LP_NAMES = %i[lp_n1]\n  n = 0\n  begin\n    LP_NAMES.each { |m| attr_reader m }\n    n += 1\n    raise 'again' if n < 2\n  rescue RuntimeError\n    retry\n  end\n",
  'a branch on a value the walk does not know' =>
    "  LP_TABLE = { lp_n1: { type: LpNgSrc::LIST } }\n  LP_TABLE.each { |k, o| attr_reader k if o[:type] }\n",
  'an iterator with no model' => "  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each_with_index { |n, i| attr_reader n }\n",
  'an iterator redefined for Array' =>
    ["  LP_NAMES = %i[lp_n1]\n  LP_NAMES.each { |n| attr_reader n }\n", "class Array\n  def each; yield :lp_n9; end\nend\n"],
  'an iterator redefined for Hash' =>
    ["  LP_TABLE = { lp_n1: 1 }\n  LP_TABLE.each_key { |k| attr_reader k }\n", "class Hash\n  def each_key; yield :lp_n9; end\nend\n"],
  'a lookup redefined for Hash' =>
    ["  LP_TABLE = { lp_n1: { lp_n2: 1 } }\n  LP_TABLE.each_value { |g| g.each { |k, v| attr_reader k if g[k] } }\n",
     "class Hash\n  def [](k); false; end\nend\n"],
  'freeze redefined' =>
    ["  LP_NAMES = %i[lp_n1].freeze\n  LP_NAMES.each { |n| attr_reader n }\n", "class Array\n  def freeze; self << :lp_n9; end\nend\n"],
  'attr_reader redefined for the class' =>
    "  LP_NAMES = %i[lp_n1]\n  def self.attr_reader(*names); super; end\n  LP_NAMES.each { |n| attr_reader n }\n"
}.freeze

puts '-- registry: a loop the interpreter cannot follow registers nothing'
NEGATIVES.each do |what, (body, after)|
  source = "#{HEAD}#{body}end\nmodule LpNgSrc\n  LIST = %i[lp_n1]\nend\n#{after}"
  _names, loop_owners, diagnostics = registry_names(source)
  check.call("#{what}: nothing registered", loop_owners.empty?)
  puts diagnostics if loop_owners.any? || ENV['BC2CPP_CHECK_VERBOSE']
  next if REGISTRY_ONLY && what != 'a computed name'

  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(source, dir)
    check.call("#{what}: the closed world keeps its dynamic-installer withdrawal",
               err.include?('global refusal: dynamic_install'))
  end
end
if REGISTRY_ONLY
  puts 'bc2cpp loop installers check: PASS' if failures.empty?
  exit(failures.empty? ? 0 : 1)
end

# -- 2. generated code ----------------------------------------------------------------------

USE = <<~RUBY
  class LpUse
    def probe(c)
      c.lp_two = c.lp_one + 1
      c.lp_two + c.lp_one
    end
  end
RUBY
BOX = <<~RUBY
  class LpBox
    LP_NAMES = %i[lp_one lp_two]
    LP_NAMES.each { |n| attr_accessor n }
    def initialize
      @lp_one = 1
      @lp_two = 2
    end
  end
RUBY

puts '-- generated code'
Dir.mktmpdir do |dir|
  code, err = runtime.generate("#{BOX}#{USE}", dir)
  probe = body_of.call(code, 'LpUse_probe')
  check.call('the loop registers as one recognized loop', err.include?('== loop installers (1 of 1 registered'))
  check.call('the closed world no longer refuses on the loop', err.include?('global refusal: none'))
  check.call('probe calls the reader and writer directly', probe.include?('LpBox_lp_one_impl(M, ') &&
                                                           probe.include?('LpBox_lp_two_eq_impl(M, ') &&
                                                           probe.include?('LpBox_lp_two_impl(M, '))
  check.call('probe makes no dispatch by name and proves the miss', !probe.include?('bc2cpp_send(') &&
                                                                    probe.include?('CLOSED_WORLD nomethod'))
end
Dir.mktmpdir do |dir|
  code, err = runtime.generate("#{BOX}#{USE}class LpElsewhere\n  def self.inst(n); attr_reader n; end\nend\n", dir)
  probe = body_of.call(code, 'LpUse_probe')
  check.call('a dynamic installer elsewhere withdraws the closed-world proof', err.include?('global refusal: dynamic_install') &&
                                                                              !probe.include?('CLOSED_WORLD nomethod'))
  check.call('and the registered call still works as a guarded direct call', probe.include?('LpBox_lp_one_impl(M, '))
end
Dir.mktmpdir do |dir|
  code, err = runtime.generate("#{BOX}#{USE}", dir, closed: false)
  probe = body_of.call(code, 'LpUse_probe')
  check.call('open world: the registered call is a guarded direct call', err.include?('== loop installers (1 of 1 registered') &&
                                                                         probe.include?('LpBox_lp_one_impl(M, '))
end

# -- 3. behaviour on real mruby -------------------------------------------------------------------

WORLD = <<~RUBY
  module LpSrc
    LIST = [:lp_q]
  end
  class LpBox
    SPEC = {
      main: { lp_a: { default: 1 }, lp_skip: { shortcut: "--a" }, lp_c: { type: LpSrc::LIST } },
      more: { lp_d: { default: 4 } },
    }
    SPEC.each_value do |group|
      group.each do |id, opt|
        next if opt[:shortcut]
        attr_reader id
      end
    end
    %i[lp_e lp_f].each { |n| attr_accessor n }
    def initialize
      @lp_a = 1
      @lp_c = 3
      @lp_d = 4
      @lp_e = 5
      @lp_f = 6
    end
  end
  class LpSub < LpBox
    def lp_a
      super + 100
    end
  end
  class LpOther
    def lp_a
      :other
    end
  end
  class LpUse
    def sum(c)
      c.lp_a + c.lp_c + c.lp_d + c.lp_e + c.lp_f
    end

    def set(c, v)
      c.lp_e = v
      c.lp_f = c.lp_e + 1
      c.lp_f
    end

    def skipped(c)
      c.lp_skip
    end


    def other(o)
      o.lp_a
    end

    def missing(c)
      c.lp_zzz
    end
  end
RUBY

# Array#each and Hash#each* for a build whose mrblib is empty; core-sourced so the iterators still count as mruby's own.
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
  class Hash
    def each_value
      keys.each { |k| yield self[k] }
      self
    end

    def each
      keys.each { |k| yield k, self[k] }
      self
    end
  end
RUBY

BODY = <<~CPP
  static mrb_value num(int n) { return mrb_fixnum_value(n); }
  static mrb_value inst(mrb_state* M, const char* cls) { return mrb_obj_new(M, mrb_class_get(M, cls), 0, nullptr); }
  static int scenario(mrb_state* M) {
    mrb_value use = inst(M, "LpUse"), box = inst(M, "LpBox"), sub = inst(M, "LpSub"), other = inst(M, "LpOther");
    mrb_value plain = mrb_obj_value(mrb_obj_alloc(M, MRB_TT_OBJECT, M->object_class));
    mrb_value a_box[] = { box }, a_sub[] = { sub }, a_other[] = { other }, a_plain[] = { plain };
    mrb_value a_set[] = { box, num(7) };
    call(M, "sum(box)", use, "sum", 1, a_box);
    call(M, "sum(sub)", use, "sum", 1, a_sub);
    call(M, "set(box, 7)", use, "set", 2, a_set);
    call(M, "sum(box) after set", use, "sum", 1, a_box);
    call(M, "skipped(box)", use, "skipped", 1, a_box);
    call(M, "other(box)", use, "other", 1, a_box);
    call(M, "other(sub)", use, "other", 1, a_sub);
    call(M, "other(other)", use, "other", 1, a_other);
    call(M, "other(plain)", use, "other", 1, a_plain);
    call(M, "missing(box)", use, "missing", 1, a_box);
    mrb_value skip = mrb_symbol_value(mrb_intern_cstr(M, "lp_skip"));
    mrb_value one = mrb_symbol_value(mrb_intern_cstr(M, "lp_a"));
    call(M, "respond_to?(:lp_skip)", box, "respond_to?", 1, &skip);
    call(M, "respond_to?(:lp_a)", box, "respond_to?", 1, &one);
    call(M, "box.lp_d", box, "lp_d");
    return 0;
  }
CPP
OWNERS = %w[LpUse LpBox LpSub LpOther].freeze

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['mrb_int 64, full-core', full, true, ENV['MRBC'], '', false] if full
builds << ['mrb_int 64, core only', runtime.core, false, ENV['MRBC'], '', true] if runtime.core
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], true, ENV['BC2CPP_MRBC32'],
             '-DMRB_32BIT -DMRB_INT32 -no-pie', false]
end
builds.clear unless runtime.compiler?
puts '-- SKIP run: set BC2CPP_MRUBY_FULL (or BC2CPP_MRUBY_CORE) and have g++' if builds.empty?

values = ->(sections, name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }

builds.each do |label, build, full_flag, mrbc, flags, polyfill|
  puts "== fixture on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = [saved.last, flags].compact.reject(&:empty?).join(' ')
  begin
    Dir.mktmpdir do |dir|
      _code, err = if polyfill
                     runtime.generate(POLYFILL, dir, only_owners: OWNERS, path: '3rd/mruby/mrblib/lp_polyfill.rb',
                                                     extra: [['fixture.rb', WORLD]])
                   else
                     runtime.generate(WORLD, dir, only_owners: OWNERS)
                   end
      check.call('the world registers its loops', err.include?('== loop installers (2 of 2 registered'))
      built, output = runtime.run(dir, err, OWNERS, BODY, build: build, full: full_flag, exact_arity: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = values.call(sections, 'interpreted')
      compiled = values.call(sections, 'compiled')
      puts output if interpreted != compiled || ENV['BC2CPP_CHECK_VERBOSE']
      check.call("compiled answers what the interpreter answers (#{interpreted.size} calls)",
                 interpreted.size == 13 && interpreted == compiled)
      text = interpreted.join("\n")
      check.call('the names the loops install answer', text.include?('sum(box) => 19') && text.include?('box.lp_d => 4') &&
                                                       text.include?('respond_to?(:lp_a) => true'))
      check.call('the writers write', text.include?('set(box, 7) => 8') && text.include?('sum(box) after set => 23'))
      check.call('a name a `next` leaves out is not defined', text.match?(/skipped\(box\) => raised (NoMethodError|Exception)/) &&
                                                              text.include?('respond_to?(:lp_skip) => false') &&
                                                              text.match?(/missing\(box\) => raised (NoMethodError|Exception)/))
      check.call('a receiver of another class answers or raises as before', text.include?('other(other) => :other') &&
                                                                           text.match?(/other\(plain\) => raised (NoMethodError|Exception)/) &&
                                                                           text.include?('other(sub) => 101'))
      compiled_calls = sections.fetch('compiled', []).each_cons(2).select { |call, n| call.start_with?('sum(box)') && n.include?('dispatches=') }
      check.call('a compiled run of the loop-installed readers makes no dispatch by name',
                 compiled_calls.any? && compiled_calls.all? { |_, n| n.strip == 'dispatches=0' })
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

if failures.empty?
  puts 'bc2cpp loop installers check: PASS'
else
  warn "bc2cpp loop installers check: #{failures.size} failure(s)"
  exit 1
end
