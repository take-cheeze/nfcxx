#!/usr/bin/env ruby
# frozen_string_literal: true

# Check NATIVE_CLASS_ARMS (docs/adr/0323): a chain site whose receiver set is proven (exact-class flow or call
# facts) judges the whole-name gates against that set instead of the whole name.
#
#   * a `def`/`alias_method` inside `class << <module or class constant>` lands on that object, so it does not
#     make the name an unknown definer or an installed name for a set of instance classes;
#   * a name a native or outside Ruby also spells is judged per class: when the lookup of every class of the set
#     reaches a Ruby definition of the registry first, the else arm is dead;
#   * a flow-proven exact core receiver (`@h.delete` on an ivar that only ever holds a Hash) calls the compiled core
#     body instead of the chain over the user classes that also define the name (FLOW_CORE_DIRECT).
#
# 1. Generated code (needs MRBC): each positive loses its by-name else; each negative keeps it (an unproven
#    receiver, a native class in the set, a core receiver that has no compiled body or another class in its set);
#    each way of losing the proof (a singleton maker, an install the class-object proof cannot place, a rebound
#    constant, an instance-level alias, a method_missing class of the set, an outside Ruby or native definer that
#    reaches a class of the set, a reopened Hash#delete) withdraws it; so do the kill switch and the open world.
# 2. Behaviour on real mruby: compiled answers equal interpreted ones in every world, values and exceptions, for
#    receivers a wrong proof would mis-dispatch; the proven sites make no dynamic dispatch and a kept else is
#    shown to dispatch (the compiled bodies ran). Run on a full-core build, a core-only build and, with
#    BC2CPP_MRUBY_FULL32 and BC2CPP_MRBC32, a 32-bit mrb_int build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/native_class_arms_check.rb
# NA_GENERATED_ONLY=1 skips the behavioural half (the mutation check uses it).

require 'fileutils'
# Isolate the class-arm gate from independently exhaustive user receiver calls.
ENV['BC2CPP_USER_RECEIVER_UNIONS'] = '0'

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class NaBox
    def count; 5; end
    def name; :box; end
    def delete(v); [:box, v]; end
    def bump; self; end
    def nil?; false; end
    def na_zork; :zork_box; end
  end

  class NaCrate
    def count; 6; end
    def name; :crate; end
    def delete(v); [:crate, v]; end
    def bump; self; end
    def nil?; false; end
    def na_zork; :zork_crate; end
  end

  class NaGhost
  end

  class NaBase
  end

  # A definition on the module object itself: `name` is also a name natives spell.
  module NaTool
    def self.name; :tool; end
  end
  class << NaTool
    alias_method :_na_update, :name
    def name; _na_update; end
  end
RUBY

FIXTURE = <<~RUBY
  class NaFx
    def initialize
      @box = NaBox.new
      @h = { a: 1 }
      @pair = NaBox.new
      @mixed = NaBox.new
      @arr = [1, 2]
      @mh = { a: 2 }
      @nl = nil
      @nl2 = nil
      @nl3 = nil
    end

    def flip
      @box = NaCrate.new
      @pair = NaCrate.new
      @mixed = [3]
      @mh = NaBox.new
      @nl = NaCrate.new
      @nl2 = NaCrate.new
      @nl3 = NaCrate.new
      :flipped
    end

    def rebox
      @nl = NaBox.new
      @nl2 = NaBox.new
      @nl3 = NaBox.new
      :reboxed
    end

    # Never called: a class-object def inside a method body is no registry definition (an unknown definer), the
    # shape of the `class << Graphics` probe in mruby-rgss.
    def probe_unknown_definer
      class << NaNativeLike
        def name; :native_like; end
      end
    end

    # -- positives
    def pos_update; @box.name; end
    def pos_count; @pair.count; end
    def pos_fact(x); x.bump; x.name; end
    def pos_two; @pair.name; end
    # nil may reach these: NilClass answers neither `name` nor `rebox`, so the proof stands
    def pos_nilable_name; @nl2.name; end
    # nil may reach this one too: a world in which a native gives NilClass `na_zork` must keep its else
    def pos_nilable_zork; @nl3.na_zork; end
    def pos_delete_hash; @h.delete(:a); end

    # -- negatives
    def neg_unproven(x); x.name; end
    def neg_core_native; @mixed.count; end
    def neg_array_delete; @arr.delete(1); end
    def neg_hash_unproven(h); h.delete(:a); end
    def neg_mixed_hash; @mh.delete(:a); end
    # nil answers nil? (a native of NilClass), so a nil the flow cannot exclude keeps the by-name else
    def neg_nilable_to_s; @nl.nil?; end
  end
RUBY

OWNERS = %w[NaBox NaCrate NaGhost NaBase NaTool NaFx NaBaseKid NaRebindable].freeze
# method => the name whose else the site keeps or loses
SITE_NAME = { 'pos_update' => 'name', 'pos_count' => 'count', 'pos_fact' => 'name', 'pos_two' => 'name', 'pos_nilable_name' => 'name', 'neg_nilable_to_s' => 'nil?', 'pos_nilable_zork' => 'na_zork',
              'neg_unproven' => 'name', 'neg_core_native' => 'count' }.freeze
POSITIVE = %w[pos_update pos_count pos_fact pos_two pos_nilable_name].freeze
# Worlds that also generate with mruby's own mrblib compiled (Hash#delete has a compiled body only then).
CORE_WORLDS = ['an instance with a singleton method', 'a constant that is not a class is reopened as a singleton',
               'Hash#delete is reopened in the project'].freeze
NEGATIVE = %w[neg_unproven neg_core_native neg_nilable_to_s].freeze
CORE_DIRECT = 'pos_delete_hash'
CORE_NEGATIVE = %w[neg_array_delete neg_hash_unproven neg_mixed_hash].freeze

# World => extra Ruby / outside sources (generated_only: an alias or define_method over an existing definition is
# not seen by the chain arms of master either, so the interpreter and the compiled code differ with the switch off), whether the positives keep their else (`kept: true`) or still lose it
# (`still_dead:` lists the positives that survive a withdrawal), and what the Hash#delete site does.
WORLDS = {
  'an instance with a singleton method' => {
    ruby: "class NaFx\n  def single; o = NaBox.new; def o.name; :single; end; o; end\nend\n", kept: true, core_kept: true,
    generated_only: true
  },
  'a singleton class opened on an object' => {
    ruby: "class NaFx\n  def open(o); class << o; def name; :opened; end; end; o; end\nend\n", kept: true, core_kept: true
  },
  'a constant that is not a class is reopened as a singleton' => {
    ruby: "NaRebindable = Object.new\nclass << NaRebindable\n  def name; :r; end\nend\n", kept: true, core_kept: true
  },
  'an instance-level alias of the name' => {
    ruby: "class NaCrate\n  alias_method :name, :count\nend\n", kept: true, still_dead: %w[], core_kept: false, generated_only: true
  },
  'an instance-level alias keyword' => {
    ruby: "class NaCrate\n  alias name count\nend\n", kept: true, still_dead: %w[pos_count], core_kept: false, generated_only: true
  },
  'a computed definition of the name' => {
    ruby: "class NaCrate\n  [:name].each { |n| define_method(n) { :computed } }\nend\n", kept: true, core_kept: false, generated_only: true
  },
  'a def nested in a block of the class-object body' => {
    ruby: "class << NaTool\n  [1].each { def name; :nested; end }\nend\n", kept: true, still_dead: %w[pos_count], core_kept: false
  },
  'an install on another class from the class-object body' => {
    ruby: "class << NaTool\n  NaBox.alias_method :name, :count\nend\n", kept: true, still_dead: %w[], core_kept: false
  },
  'a method_missing class in the set' => {
    ruby: "class NaBox\n  def method_missing(n, *a); :ghost; end\n  def respond_to_missing?(n, p = false); true; end\nend\n",
    kept: true, core_kept: true
  },
  'a method_missing class outside the set' => {
    ruby: "class NaGhost\n  def method_missing(n, *a); :ghost; end\n  def respond_to_missing?(n, p = false); true; end\nend\n",
    kept: false, kept_some: %w[pos_fact], core_kept: false
  },
  'an outside Ruby source reopens a class of the set' => {
    gem: { 'mrblib/na_box.rb' => "class NaBox\n  def name; :outside; end\n  def count; :outside; end\nend\n" },
    kept: true, generated_only: true, core_kept: false
  },
  'an outside Ruby source defines the name on Array only' => {
    gem: { 'mrblib/na_array.rb' => "class Array\n  def name; :a; end\nend\n" }, kept: false, generated_only: true, core_kept: false
  },
  'an outside Ruby source subclasses a class of the set' => {
    gem: { 'mrblib/na_kid.rb' => "class NaBaseKid < NaBox\n  def count; 7; end\nend\n" },
    kept: true, generated_only: true, core_kept: false
  },
  'a native source defines the name on a class of the set' => {
    native: "void na_init(mrb_state *mrb) {\n  struct RClass *c = mrb_define_class(mrb, \"NaBox\", mrb->object_class);\n" \
            "  mrb_define_method(mrb, c, \"name\", f, MRB_ARGS_NONE());\n  mrb_define_method(mrb, c, \"count\", f, MRB_ARGS_NONE());\n}\n",
    kept: true, generated_only: true, core_kept: false
  },
  'Hash#delete is reopened in the project' => {
    ruby: "class Hash\n  def delete(k, &b); :mine; end\nend\n", kept: false, core_kept: true
  },
  'a module provides the name to a class of the set' => {
    ruby: "module NaMix\n  def name; :mixed; end\nend\nclass NaGhost\n  include NaMix\nend\n", kept: true, still_dead: %w[pos_count],
    core_kept: false
  }
}.freeze

gem_dir = lambda do |root, name, files|
  File.join(root, name).tap do |gem|
    files.each { |rel, text| FileUtils.mkdir_p(File.dirname(File.join(gem, rel))) && File.write(File.join(gem, rel), text) }
  end
end

body_all = lambda do |code, fn|
  code.scan(/^(?:static )?mrb_value NaFx_#{fn}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
# How the chain of the site's name in `fn` ends: a proven-dead nomethod (:dead), a kept by-name send (:kept).
name_else = lambda do |code, fn|
  checked = Regexp.escape(SITE_NAME.fetch(fn))
  kind = body_all.call(code, fn)[%r{POLY_SMALL_N :#{checked} .*?(?:(CLOSED_WORLD kept: \w+)|(CLOSED_WORLD nomethod: recv\.#{checked}))}m, 0]
  kind.nil? ? nil : (kind.include?('CLOSED_WORLD kept:') ? :kept : :dead)
end
dead_else = ->(code, fn) { name_else.call(code, fn) == :dead }
kept_else = ->(code, fn) { name_else.call(code, fn) == :kept }
core_direct = ->(code, fn) { body_all.call(code, fn).include?('// CORE_EXACT_DIRECT :delete') }
core_chain = ->(code, fn) { body_all.call(code, fn).match?(/POLY_SMALL_N :delete/) || body_all.call(code, fn).include?('POLY :delete') }

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, = generate.call(CLASSES + FIXTURE, dir)
    POSITIVE.each do |fn|
      check.call("#{fn}: the proven receiver set gives x.#{SITE_NAME[fn]} no by-name else", dead_else.call(code, fn))
    end
    NEGATIVE.each { |fn| check.call("NEG #{fn}: the else stays", kept_else.call(code, fn)) }
    check.call('pos_nilable_zork: nothing answers na_zork on nil, so the else is dead', dead_else.call(code, 'pos_nilable_zork'))
    Dir.mktmpdir do |nd|
      # A native that gives NilClass the name: a nil the flow cannot exclude may reach the else, which must dispatch.
      nsrc = "void na_init(mrb_state *mrb) {\n  struct RClass *n = mrb_define_class(mrb, \"NilClass\", mrb->object_class);\n" \
             "  mrb_define_method(mrb, n, \"na_zork\", f, MRB_ARGS_NONE());\n}\n"
      gem = [['na_nil_gem', gem_dir.call(nd, 'na_nil_gem', 'src/na_nil.cxx' => nsrc)]]
      ncode, = generate.call(CLASSES + FIXTURE, nd, build_gems: gem, native: [['na_nil.cxx', nsrc]])
      check.call('NEG a native source defines na_zork on NilClass: the else of a possibly nil receiver stays',
                 kept_else.call(ncode, 'pos_nilable_zork'))
    end
    Dir.mktmpdir do |cd|
      ccode, = generate.call(CLASSES + FIXTURE, cd, core: true)
      check.call("#{CORE_DIRECT}: a flow-proven Hash calls the compiled Hash#delete body, no chain", core_direct.call(ccode, CORE_DIRECT))
      CORE_NEGATIVE.each { |fn| check.call("NEG #{fn}: no direct core call", !core_direct.call(ccode, fn)) }
    end

    WORLDS.each do |what, world|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      # An outside native is both a build gem's src/ (the closed world's outside source) and a NATIVE_SRCS entry
      # (the name registry), as in a real build.
      files = world.fetch(:gem, {}).merge(world[:native] ? { 'src/na_native.cxx' => world[:native] } : {})
      gems = files.empty? ? [] : [['na_outside_gem', gem_dir.call(d, 'na_outside_gem', files)]]
      natives = world[:native] ? [['na_native.cxx', world[:native]]] : []
      wcode, = generate.call(CLASSES + FIXTURE + world.fetch(:ruby, ''), d, build_gems: gems, native: natives)
      wrong = POSITIVE.reject do |fn|
        keep = world[:kept] ? !world.fetch(:still_dead, []).include?(fn) : world.fetch(:kept_some, []).include?(fn)
        keep ? kept_else.call(wcode, fn) : dead_else.call(wcode, fn)
      end
      puts "    wrong: #{wrong.join(' ')}" unless wrong.empty?
      check.call(world[:kept] ? "NEG #{what}: the positives keep their else" : "#{what}: the positives still lose the else", wrong.empty?)
      negatives = NEGATIVE.reject { |fn| kept_else.call(wcode, fn) }
      puts "    wrong: #{negatives.join(' ')}" unless negatives.empty?
      check.call("#{what}: the negatives keep their else", negatives.empty?)
      next unless CORE_WORLDS.include?(what)

      Dir.mktmpdir do |cd|
        ccode, = generate.call(CLASSES + FIXTURE + world.fetch(:ruby, ''), cd, core: true)
        check.call(world[:core_kept] ? "NEG #{what}: Hash#delete is not called directly" : "#{what}: the proven Hash still calls the core body",
                   world[:core_kept] ? !core_direct.call(ccode, CORE_DIRECT) : core_direct.call(ccode, CORE_DIRECT))
      end
    end

    Dir.mktmpdir do |kd|
      kcode, = generate.call(CLASSES + FIXTURE, kd, env: { 'BC2CPP_NATIVE_CLASS_ARMS' => '0' })
      kcore, = generate.call(CLASSES + FIXTURE, File.join(kd, 'core').tap { |c| Dir.mkdir(c) }, core: true,
                                                                                               env: { 'BC2CPP_NATIVE_CLASS_ARMS' => '0' })
      check.call('NEG kill switch (BC2CPP_NATIVE_CLASS_ARMS=0): every positive keeps its else and delete its chain',
                 (POSITIVE + NEGATIVE).all? { |fn| kept_else.call(kcode, fn) } && !core_direct.call(kcore, CORE_DIRECT) &&
                 core_chain.call(kcore, CORE_DIRECT))
    end
    Dir.mktmpdir do |od|
      ocode, = generate.call(CLASSES + FIXTURE, od, closed: false)
      check.call('NEG the open world proves nothing',
                 POSITIVE.none? { |fn| body_all.call(ocode, fn).include?('CLOSED_WORLD nomethod') } && !core_direct.call(ocode, CORE_DIRECT))
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['full-core', full, ENV.fetch('MRBC', nil), '', true] if full
builds << ['core-only', runtime.core, ENV.fetch('MRBC', nil), '', false] if runtime.core
# -no-pie: see bc2cpp_call_facts_check.rb (a block function's address in a 32-bit mrb_int).
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32 (full-core)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie', true]
end
if builds.empty? && !ENV['NA_GENERATED_ONLY'] && runtime.compiler?
  built = runtime.full_or_build
  builds << ['full-core', built, ENV.fetch('MRBC', nil), '', true] if built
end

if ENV['MRBC'] && !builds.empty? && runtime.compiler? && !ENV['NA_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  objects = {
    'w' => 'mrb_obj_new(M, mrb_class_get(M, "NaBox"), 0, nullptr)',
    'c' => 'mrb_obj_new(M, mrb_class_get(M, "NaCrate"), 0, nullptr)',
    'g' => 'mrb_obj_new(M, mrb_class_get(M, "NaGhost"), 0, nullptr)',
    'arr' => 'mrb_ary_new(M)',
    'hash' => 'mrb_hash_new(M)',
    'single' => '(mrb_funcall(M, fx, "single", 0))'
  }
  base_calls = []
  %w[pos_update pos_count pos_two pos_nilable_name neg_nilable_to_s neg_core_native neg_array_delete neg_mixed_hash pos_delete_hash].each { |m| base_calls << [m, m, []] }
  %w[pos_fact neg_unproven].each { |m| %w[w c g arr].each { |v| base_calls << ["#{m}(#{v})", m, [v]] } }
  %w[hash w arr].each { |v| base_calls << ["neg_hash_unproven(#{v})", 'neg_hash_unproven', [v]] }
  after_flip = %w[pos_nilable_name neg_nilable_to_s pos_update pos_two pos_count neg_core_native neg_mixed_hash].map { |m| ["flipped:#{m}", m, []] }
  world_calls = {
    'an instance with a singleton method' => [%w[pos_fact neg_unproven].map { |m| ["#{m}(single)", m, ['single']] }],
    'an instance-level alias of the name' => [[]],
    'an instance-level alias keyword' => [%w[pos_two].map { |m| ["alias:#{m}", m, []] }],
    'a computed definition of the name' => [[]],
    'a method_missing class in the set' => [%w[pos_update pos_count pos_fact].map { |m| ["mm:#{m}", m, m == 'pos_fact' ? ['w'] : []] }],
    'a method_missing class outside the set' => [%w[neg_unproven].map { |m| ["mm:#{m}(g)", m, ['g']] }],
    'a module provides the name to a class of the set' => [%w[neg_unproven].map { |m| ["mix:#{m}(g)", m, ['g']] }],
    'Hash#delete is reopened in the project' => [[]]
  }
  scenario = lambda do |extra|
    all = base_calls + [['flip', 'flip', []]] + after_flip + extra
    vars = all.flat_map { |_, _, args| args }.uniq
    decls = vars.map { |v| "  mrb_value v_#{v} = #{objects.fetch(v)};" }
    lines = all.map do |label, m, args|
      list = args.empty? ? 'mrb_nil_value()' : args.map { |a| "v_#{a}" }.join(', ')
      "  { mrb_value a[] = { #{list} }; call(M, #{label.dump}, fx, #{m.dump}, #{args.size}, a); }"
    end
    <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "NaFx"), 0, nullptr);
      #{decls.join("\n")}
      #{lines.join("\n")}
        return 0;
      }
    CPP
  end
  worlds = { 'the base fixture' => ['', [], false], 'the base fixture over the compiled core' => ['', [], true] }
  WORLDS.reject { |_, w| w[:generated_only] }.each do |what, w|
    next unless world_calls.key?(what)

    worlds[what] = [w.fetch(:ruby, ''), world_calls.fetch(what).first, CORE_WORLDS.include?(what)]
  end

  builds.each do |build_name, build, mrbc, flags, full_core|
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS', 'BC2CPP_BLOCK_DIRECT_ENTRY')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if flags.include?('MRB_INT32')
    ENV['BC2CPP_CXXFLAGS'] = "#{flags} -I#{File.expand_path('../../include', __dir__)}"
    begin
      worlds.each do |world, (extra, extra_calls, core)|
        next if ENV['NA_WORLD'] && !world.include?(ENV['NA_WORLD'])

        label = "#{build_name}, #{world}"
        # Array#each is mrblib: a core-only VM cannot load a class body that iterates, nor run the compiled core.
        next if !full_core && (world == 'a computed definition of the name' || core)

        Dir.mktmpdir do |dir|
          _code, err = generate.call(CLASSES + FIXTURE + extra, dir, core: core)
          built, output = runtime.run(dir, err, core ? BC2CPP_CORE_OWNERS + OWNERS : OWNERS, scenario.call(extra_calls || []), build: build, full: full_core)
          check.call("#{label}: the fixture compiles and runs against real mruby", built)
          puts output unless built
          next unless built

          sections = runtime.sections(output)
          values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
          values.call('interpreted').zip(values.call('compiled')).reject { |a, b| a == b }.first(8).each do |a, b|
            puts "    interpreted: #{a}\n    compiled:    #{b}"
          end
          check.call("#{label}: every call answers what the interpreter answers (#{values.call('interpreted').size} lines), values and exceptions alike",
                     !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
          compiled = values.call('compiled')
          next unless world.start_with?('the base fixture')

          # `raised` names the build's own exception class.
          expected = ['pos_update => :box', 'pos_count => 5', 'flipped:pos_count => 6', 'pos_fact(w) => :box', 'pos_fact(c) => :crate', 'pos_fact(g) => raised',
                      'neg_unproven(c) => :crate', 'neg_unproven(arr) => raised', 'pos_delete_hash => 1', 'neg_array_delete => 1',
                      'neg_mixed_hash => 2', 'neg_hash_unproven(hash) => nil', 'neg_hash_unproven(w) => [:box, :a]',
                      'flipped:pos_two => :crate', 'pos_nilable_name => raised', 'neg_nilable_to_s => true', 'flipped:pos_nilable_name => :crate',
                      'flipped:neg_nilable_to_s => false', 'flipped:pos_update => :crate', 'flipped:neg_core_native => 1', 'flipped:neg_mixed_hash => [:box, :a]']
          # A core-only VM has no Hash#delete, Enumerable#count or Array#each: the interpreter's line is the reference there.
          expected = expected.reject { |want| want.match?(/delete_hash|mixed_hash|hash_unproven\(hash|neg_core_native/) } unless full_core
          missing = expected.reject { |want| compiled.any? { |line| line.start_with?(want) } }
          puts "  missing compiled answers: #{missing.inspect}" unless missing.empty?
          check.call("#{label}: the answers are the ones Ruby gives", missing.empty?)
          lines = sections.fetch('compiled', [])
          at = lines.index { |l| l.start_with?('neg_unproven(arr) =>') }
          check.call("#{label}: the compiled bodies ran (a kept else dispatched)", at && lines[at + 1].to_s[/dispatches=(\d+)/, 1].to_i.positive?)
          %w[pos_update pos_count pos_two pos_fact(w) pos_fact(c) flipped:pos_two flipped:pos_update flipped:pos_count].each do |m|
            at = lines.index { |l| l.start_with?("#{m} =>") }
            n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
            check.call("#{label}: #{m}: the proven site makes no dynamic dispatch", n == 0)
          end
        end
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'], block_entry = saved
      block_entry ? ENV['BC2CPP_BLOCK_DIRECT_ENTRY'] = block_entry : ENV.delete('BC2CPP_BLOCK_DIRECT_ENTRY')
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp native class arms check: PASS'
else
  warn "bc2cpp native class arms check: #{failures.size} failure(s)"
  exit 1
end
