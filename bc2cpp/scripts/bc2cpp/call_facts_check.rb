#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CALL_FACTS (docs/adr/0317): after `x.bump` returned normally, `x` is an instance of a class that answers
# `bump`, so the guard chain of a later `x.name` on the same value (a name mruby also defines natively, whose
# else arm used to be kept) ends in a proven-dead `bc2cpp_nomethod`.
#
# 1. Generated code (needs MRBC): each positive loses its by-name else; each negative keeps it (no call yet, a
#    rewrite of the register, a branch, a call result, a handler edge, a block that writes the local, an ivar, a
#    class a native also answers for); each way of losing the proof (a method_missing class, a computed
#    definition, an instance singleton, a subclass of a core class, a foreign reopen or a foreign definer of the
#    fact name, an alias, the kill switch, the open world) withdraws it.
# 2. Behaviour on real mruby: the compiled answers equal the interpreted ones in every world, for the receivers a
#    wrong proof would mis-dispatch (the class the fact leaves out, a module-provided definition, a singleton,
#    a method_missing object), and the proven sites make no dynamic dispatch. Run on a full-core build, a
#    core-only build and, with BC2CPP_MRUBY_FULL32 and BC2CPP_MRBC32, a 32-bit mrb_int build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/call_facts_check.rb
# CF_GENERATED_ONLY=1 skips the behavioural half (the mutation check uses it).

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class CfWidget
    def kind; :widget; end
    def name; 11; end
    def first; :first_widget; end
    def delete(v); v; end
    def at(v); v; end
    def pop; self; end
    def bump; self; end
    def other; CfPlain.new; end
  end

  class CfGadget
    def kind; :gadget; end
    def name; 22; end
    def first; :first_gadget; end
    def delete(v); v; end
    def at(v); v; end
    def pop; self; end
    def bump; self; end
    def other; self; end
  end

  # Answers `bump` but not `name`: a member of the fact's set the checked name leaves out.
  class CfBare
    def bump; self; end
  end

  # Answers `name` but not `bump`, `first` or `other`.
  class CfPlain
    def kind; :plain; end
    def name; 33; end
  end
RUBY

# `name` is spelled by natives (String#name is not, but RGSS and Struct are), so its else is kept without a fact.
FIXTURE = <<~RUBY
  class CfFx
    # -- positives: x answered bump on every path to x.name
    def pos_one(x); x.bump; x.name; end
    def pos_two(x); x.bump; x.kind; x.name; end
    def pos_alias(x); y = x; y.bump; x.name; end
    def pos_loop(x); x.bump; i = 0; while i < 2; x.bump; i += 1; end; x.name; end
    def pos_both(x, f); if f then x.bump else x.bump end; x.name; end
    def pos_del(x); x.bump; x.delete(1); end
    def pos_rescue(x); begin; x.bump; x.name; rescue NoMethodError; :rescued; end; end

    # -- negatives: the fact is missing, rewritten or not on every path
    def neg_none(x); x.name; end
    def neg_reassign(x, y); x.bump; x = y; x.name; end
    def neg_branch(x, f); x.bump if f; x.name; end
    def neg_result(x); x.other.name; end
    # Array#pop is only native, so its registration is what puts Array in the set (Array#at gets no fact, so it cannot show it).
    def neg_native(x); x.pop; x.name; end
    def neg_global(x); x.bump; x = $cf_g; x.name; end
    def neg_after_rescue(x); begin; x.bump; rescue NoMethodError; 0; end; x.name; end
    def neg_block_write(x, y); x.bump; [1].each { x = y }; x.name; end
    def neg_ivar(x); @h = x; @h.bump; @h.name; end
    def neg_loop_swap(x, y); x.bump; i = 0; while i < 2; x = y; i += 1; end; x.name; end
  end
RUBY

OWNERS = %w[CfWidget CfGadget CfPlain CfBare CfGhost CfList CfWidget2 CfFx].freeze
POSITIVE = %w[pos_one pos_two pos_alias pos_loop pos_both pos_rescue].freeze
# `delete` is natively defined on Array and Hash: a user class beside them is kept unless the facts exclude them.
DELETE_SITE = 'pos_del'
NEGATIVE = %w[neg_none neg_reassign neg_branch neg_result neg_native neg_global neg_after_rescue neg_block_write neg_ivar neg_loop_swap].freeze

# World name => extra Ruby, a build gem's files (outside Ruby), and whether the positives must keep their else
# (`kept: true`) or still lose it. generated_only worlds cannot run: the interpreter would not see the outside source.
WORLDS = {
  'a method_missing class answers every name' => {
    ruby: "class CfGhost\n  def method_missing(n, *a); :ghost; end\n  def respond_to_missing?(n, p = false); true; end\nend\n", kept: true
  },
  'a name defined from a computed list' => {
    ruby: "class CfPlain\n  %w[bump].each { |n| define_method(n) { self } }\nend\n", kept: true
  },
  'an alias of the fact name' => {
    ruby: "class CfPlain\n  alias_method :bump, :kind\nend\n", kept: true
  },
  'an instance with a singleton method' => {
    ruby: "class CfFx\n  def single; o = CfPlain.new; def o.bump; self; end; o; end\nend\n", kept: true
  },
  'a subclass of Array defines the fact name' => {
    ruby: "class CfList < Array\n  def bump; self; end\nend\n", kept: true, still_dead: %w[pos_two]
  },
  'an outside Ruby source subclasses a class of the set' => {
    gem: { 'mrblib/cf_kid.rb' => "class CfBareKid < CfBare\n  def name; 7; end\nend\n" }, kept: true, generated_only: true, still_dead: %w[pos_two]
  },
  'an outside Ruby source defines the fact name on Array' => {
    gem: { 'mrblib/cf_array.rb' => "class Array\n  def bump; self; end\nend\n" }, kept: true, generated_only: true,
    still_dead: %w[pos_two]
  },
  'a module gives Array the fact name' => {
    ruby: "module CfBumpy\n  def bump; self; end\nend\nclass Array\n  include CfBumpy\nend\n", kept: true, still_dead: %w[pos_two], del_kept: true
  },
  'a module provides the fact name' => {
    ruby: "module CfBumpy\n  def bump; self; end\nend\nclass CfPlain\n  include CfBumpy\nend\n", kept: false
  },
  'a subclass overrides the checked name' => {
    ruby: "class CfWidget2 < CfWidget\n  def name; 44; end\nend\n", kept: false
  }
}.freeze

gem_dir = lambda do |root, name, files|
  File.join(root, name).tap do |gem|
    files.each { |rel, text| FileUtils.mkdir_p(File.dirname(File.join(gem, rel))) && File.write(File.join(gem, rel), text) }
  end
end

body_all = lambda do |code, fn|
  code.scan(/^(?:static )?mrb_value CfFx_#{fn}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
# How the chain of `name` in `fn` ends: its else is a proven-dead nomethod (:dead) or a kept by-name send (:kept).
name_else = lambda do |code, fn|
  checked = fn == DELETE_SITE ? 'delete' : 'name'
  kind = body_all.call(code, fn)[%r{POLY_SMALL_N :#{checked} .*?(?:(CLOSED_WORLD kept: \w+)|(CLOSED_WORLD nomethod: recv\.#{checked}))}m, 0]
  kind.nil? ? nil : (kind.include?('CLOSED_WORLD kept:') ? :kept : :dead)
end
dead_else = ->(code, fn) { name_else.call(code, fn) == :dead }
kept_else = ->(code, fn) { name_else.call(code, fn) == :kept }

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
    code, err = generate.call(CLASSES + FIXTURE, dir)
    POSITIVE.each do |fn|
      check.call("#{fn}: the earlier call proves the receiver set, so x.name has no by-name else", dead_else.call(code, fn))
    end
    check.call('pos_two: a second fact keeps the set (and the proof)', dead_else.call(code, 'pos_two'))
    check.call('pos_del: Array and Hash are not in the set, so the native delete cannot reach x.delete', dead_else.call(code, DELETE_SITE))
    NEGATIVE.each do |fn|
      check.call("NEG #{fn}: the else of x.name stays", kept_else.call(code, fn))
    end

    WORLDS.each do |what, world|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      # An outside source is a build gem whose mrblib the closed world scans.
      gems = world[:gem] ? [['cf_outside_gem', gem_dir.call(d, 'cf_outside_gem', world[:gem])]] : []
      wcode, = generate.call(CLASSES + FIXTURE + world.fetch(:ruby, ''), d, build_gems: gems)
      # A second fact (kind) can still bound the set when the first one no longer does.
      positives = POSITIVE.reject do |fn|
        world[:kept] && !world.fetch(:still_dead, []).include?(fn) ? kept_else.call(wcode, fn) : dead_else.call(wcode, fn)
      end
      puts "    wrong: #{positives.join(' ')}" unless positives.empty?
      check.call(world[:kept] ? "NEG #{what}: the positives keep their else" : "#{what}: the positives still lose the else", positives.empty?)
      if world[:del_kept]
        check.call("NEG #{what}: x.delete keeps its else", kept_else.call(wcode, DELETE_SITE))
      end
      negatives = NEGATIVE.reject { |fn| kept_else.call(wcode, fn) }
      puts "    wrong: #{negatives.join(' ')}" unless negatives.empty?
      check.call("#{what}: the negatives keep their else", negatives.empty?)
    end

    Dir.mktmpdir do |kd|
      kcode, = generate.call(CLASSES + FIXTURE, kd, env: { 'BC2CPP_CALL_FACTS' => '0' })
      check.call('NEG kill switch (BC2CPP_CALL_FACTS=0): every site keeps its else',
                 (POSITIVE + NEGATIVE).all? { |fn| kept_else.call(kcode, fn) })
    end
    Dir.mktmpdir do |od|
      ocode, = generate.call(CLASSES + FIXTURE, od, closed: false)
      check.call('NEG the open world proves nothing', POSITIVE.none? { |fn| body_all.call(ocode, fn).include?('CLOSED_WORLD nomethod') })
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
# -no-pie: the fallback glue keeps a block function's address in an mrb_int, which a 32-bit mrb_int on a
# 64-bit host only holds for code below 2 GB (a real 32-bit target has 32-bit pointers).
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32 (full-core)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie', true]
end
builds << ['full-core', runtime.full_or_build, ENV.fetch('MRBC', nil), '', true] if builds.empty? && runtime.compiler? && runtime.full_or_build

if ENV['MRBC'] && !builds.empty? && runtime.compiler? && !ENV['CF_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  # [label, method, receiver variables]: the receivers are made in C++, so no Ruby call site pools their class.
  calls = []
  one = %w[pos_one pos_two pos_alias pos_loop pos_rescue neg_none neg_native neg_after_rescue neg_ivar]
  one.each { |m| %w[w g p].each { |v| calls << [m, [v]] } }
  calls << ['neg_native', ['arr']]
  calls << ['pos_one', ['arr']]
  calls << ['neg_none', ['arr']]
  %w[w g].each { |v| calls << ['pos_del', [v]] }
  %w[pos_both neg_branch].each { |m| [%w[w true], %w[p true], %w[p false], %w[g false]].each { |a| calls << [m, a] } }
  %w[neg_reassign neg_block_write neg_loop_swap].each { |m| [%w[w p], %w[p w], %w[g g]].each { |a| calls << [m, a] } }
  %w[w g p].each { |v| calls << ['neg_result', [v]] }
  # World-specific receivers: [world, extra calls, the objects they need].
  world_calls = {
    'a method_missing class answers every name' => [%w[pos_one pos_two neg_none neg_after_rescue].map { |m| [m, ['ghost']] }],
    'a name defined from a computed list' => [%w[pos_one pos_alias neg_after_rescue].map { |m| [m, ['p']] }],
    'an alias of the fact name' => [%w[pos_one pos_two pos_loop].map { |m| [m, ['p']] }],
    'an instance with a singleton method' => [%w[pos_one pos_alias neg_none].map { |m| [m, ['single']] }],
    'a subclass of Array defines the fact name' => [%w[pos_one pos_two neg_none].map { |m| [m, ['list']] }],
    'a module provides the fact name' => [%w[pos_one pos_two pos_alias pos_loop pos_rescue].map { |m| [m, ['p']] }],
    'a module gives Array the fact name' => [%w[pos_one pos_two pos_del neg_none].map { |m| [m, ['arr']] }],
    'a subclass overrides the checked name' => [%w[pos_one pos_two pos_alias pos_loop pos_rescue].map { |m| [m, ['w2']] }]
  }
  objects = {
    'w' => 'mrb_obj_new(M, mrb_class_get(M, "CfWidget"), 0, nullptr)',
    'g' => 'mrb_obj_new(M, mrb_class_get(M, "CfGadget"), 0, nullptr)',
    'p' => 'mrb_obj_new(M, mrb_class_get(M, "CfPlain"), 0, nullptr)',
    'arr' => 'mrb_ary_new(M)',
    'true' => 'mrb_true_value()',
    'false' => 'mrb_false_value()'
  }
  extra_objects = {
    'ghost' => 'mrb_obj_new(M, mrb_class_get(M, "CfGhost"), 0, nullptr)',
    'list' => 'mrb_obj_new(M, mrb_class_get(M, "CfList"), 0, nullptr)',
    'w2' => 'mrb_obj_new(M, mrb_class_get(M, "CfWidget2"), 0, nullptr)',
    'single' => '(mrb_funcall(M, fx, "single", 0))'
  }
  scenario = lambda do |extra|
    all = calls + extra
    vars = all.flat_map { |_, args| args }.uniq
    decls = vars.map { |v| "  mrb_value v_#{v} = #{objects[v] || extra_objects.fetch(v)};" }
    lines = all.map do |m, args|
      list = args.map { |a| "v_#{a}" }.join(', ')
      label = "#{m}(#{args.join(',')})"
      "  { mrb_value a[] = { #{list} }; call(M, #{label.dump}, fx, #{m.dump}, #{args.size}, a); }"
    end
    <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "CfFx"), 0, nullptr);
      #{decls.join("\n")}
      #{lines.join("\n")}
        return 0;
      }
    CPP
  end
  worlds = { 'the base fixture' => ['', [], []] }
  WORLDS.reject { |_, w| w[:generated_only] }.each do |what, w|
    worlds[what] = [w.fetch(:ruby, ''), *world_calls.fetch(what, [[]]).first(1), []]
  end

  builds.each do |build_name, build, mrbc, flags, full_core|
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS', 'BC2CPP_BLOCK_DIRECT_ENTRY')
    ENV['MRBC'] = mrbc
    # ADR 0271 keeps a block's entry as an address in an mrb_int: a 32-bit build on a 64-bit host cannot.
    ENV['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if flags.include?('MRB_INT32')
    # include/ holds rgss_construct.hxx, which the generated code includes once a probe compile used a native construct.
    ENV['BC2CPP_CXXFLAGS'] = "#{flags} -I#{File.expand_path('../../include', __dir__)}"
    begin
      worlds.each do |world, (extra, extra_calls, _)|
        label = "#{build_name}, #{world}"
        # Array#each is mrblib: a core-only VM cannot load a class body that iterates.
        next if !full_core && world == 'a name defined from a computed list'

        Dir.mktmpdir do |dir|
          _code, err = generate.call(CLASSES + FIXTURE + extra, dir)
          built, output = runtime.run(dir, err, OWNERS, scenario.call(extra_calls || []), build: build, full: full_core)
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
          next unless world == 'the base fixture'

          # `raised` names the build's own exception class (a core-only build raises its own NoMethodError text).
          expected = ['pos_one(w) => 11', 'pos_one(g) => 22', 'pos_one(p) => raised', 'pos_rescue(p) => :rescued',
                      'pos_both(g,false) => 22', 'neg_none(p) => 33', 'neg_reassign(w,p) => 33', 'neg_reassign(p,w) => raised',
                      'neg_branch(p,false) => 33', 'neg_branch(p,true) => raised', 'neg_result(w) => 33', 'neg_result(g) => 22',
                      'neg_native(arr) => raised', 'neg_after_rescue(p) => 33', 'neg_block_write(w,p) => 33',
                      'neg_ivar(p) => raised', 'neg_loop_swap(w,p) => 33']
          # A core-only VM has no Array#each and raises its own base class: the interpreter's line is the reference there.
          expected = expected.reject { |want| want.match?(/pos_rescue|neg_after_rescue|neg_block_write/) } unless full_core
          missing = expected.reject { |want| compiled.any? { |line| line.start_with?(want) } }
          puts "  missing compiled answers: #{missing.inspect}" unless missing.empty?
          check.call("#{label}: the answers are the ones Ruby gives", missing.empty?)
          lines = sections.fetch('compiled', [])
          # An Array receiver has no `name`: the kept else dispatches, which proves the compiled bodies ran.
          at = lines.index { |l| l.start_with?('neg_none(arr) =>') }
          check.call("#{label}: the compiled bodies ran (a kept else dispatched)", at && lines[at + 1].to_s[/dispatches=(\d+)/, 1].to_i.positive?)
          %w[pos_one(w) pos_one(g) pos_two(w) pos_alias(g) pos_loop(w) pos_rescue(w) pos_both(w,true) pos_both(g,false)].each do |m|
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
  puts 'bc2cpp call facts check: PASS'
else
  warn "bc2cpp call facts check: #{failures.size} failure(s)"
  exit 1
end
