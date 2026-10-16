#!/usr/bin/env ruby
# frozen_string_literal: true

# Check SUBTREE_DISPATCH (docs/adr/0453): a receiver hinted to "C or a descendant" dispatches over C's closed
# subtree (one guarded direct call, or a per-root slot table) instead of the name-wide chains.
#
# 1. Generated code (needs MRBC):
#    positive  an ivar written with Base.new and Sub.new joins to SUBTREE(Base): a name every subtree class resolves
#              to one definition is a SUBTREE_DIRECT call, an overridden one a SUBTREE_TABLE slot; an RBS return type
#              and an RBS parameter type naming the base class are subtree hints, never exact TYPED guards.
#    negative  a hierarchy the closed world cannot enumerate (Class.new subclass), stores whose only common ancestor is
#              Object, the kill switch (no SUBTREE code; byte-identical to BC2CPP_SUBTREE_BASE_TOOL's output when
#              that names the baseline bc2cpp.rb), the `subtree` strict family staying out of the default set.
#    error     an RBS `class C < S` naming a superclass the program does not give C is TC1016 and aborts the build.
# 2. Behaviour on real mruby (BC2CPP_MRUBY_FULL, or one built by fixture_runtime): interpreted and compiled answer
#    alike, a Sub receiver included, and the subtree sites make no dynamic dispatch. SD_GENERATED_ONLY=1 skips it.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/subtree_dispatch_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime
ENV['BC2CPP_SIG_DIRS'] = ''

SOURCE = <<~RUBY
  # A mixin on the chain keeps the exact-receiver union proofs (closed_world_exact_target) out of the way.
  module SdMix
    def mixed; 1; end
  end
  class SdBase
    include SdMix
    def initialize(v); @v = v; end
    def value; @v; end
    def kind; :base; end
    def tag; :b; end
    def scaled(k); @v * k; end
  end
  class SdSub < SdBase
    def kind; :sub; end
    def tag; :s; end
  end
  # Defines the same names outside the subtree, so none of them is MONO.
  class SdOther
    def value; 9; end
    def kind; :other; end
    def scaled(k); k; end
  end

  class SdHolder
    def initialize; @it = nil; end
    def open(sub)
      if sub
        @it = SdSub.new(2)
      else
        @it = SdBase.new(1)
      end
      sub
    end
    def hold_value; return 0 unless @it; @it.value; end
    def hold_kind; return :none unless @it; @it.kind; end
    def hold_scaled; @it ? @it.scaled(5) : 0; end
  end

  # RBS: `pick` returns SdBase (a base class), `use` takes one.
  class SdMaker
    def pick(sub); sub ? SdSub.new(3) : SdBase.new(3); end
    def picked_kind(sub); pick(sub).kind; end
    def use(b); b.kind; end
    def use_tag(b); b.tag; end
  end

  # Two classes share the last segment Node; the subclass names its parent by full path (the engine's
  # `RPG2k3::Scene::Battle < RPG2k::Scene::Battle`).
  module SdNs1
    class Node
      include SdMix
      def label; :n1; end
    end
  end
  module SdNs2
    class Node < SdNs1::Node
      def label; :n2; end
    end
  end
  class SdTwinHolder
    def initialize; @node = nil; end
    def open(two)
      if two
        @node = SdNs2::Node.new
      else
        @node = SdNs1::Node.new
      end
      two
    end
    def label; @node ? @node.label : :none; end
  end

  # Answers anything, so an else arm over a parameter hint keeps its by-name send.
  class SdGhost
    def method_missing(name, *args); :ghost; end
    def respond_to_missing?(name, priv = false); true; end
  end

  # -- negatives
  class NcBase
    def nc_kind; :ncbase; end
  end
  class NcSub < NcBase
    def nc_kind; :ncsub; end
  end
  NcDyn = Class.new(NcBase)
  class NcHolder
    def initialize; @it = nil; end
    def a; @it = NcBase.new; end
    def b; @it = NcSub.new; end
    def run; @it.nc_kind; end
  end

  class ObA; def ob_kind; :a; end; end
  class ObB; def ob_kind; :b; end; end
  class ObHolder
    def initialize; @it = nil; end
    def a; @it = ObA.new; end
    def b; @it = ObB.new; end
    def run; @it.ob_kind; end
  end
RUBY

OWNERS = %w[SdMix SdBase SdSub SdOther SdGhost SdHolder SdMaker SdNs1::Node SdNs2::Node SdTwinHolder NcBase NcSub NcHolder ObA ObB ObHolder].freeze

SIG = <<~RBS
  class SdSub < SdBase
  end
  class SdMaker
    def pick: (untyped sub) -> SdBase
    def use: (SdBase b) -> untyped
    def use_tag: (SdBase b) -> untyped
  end
RBS

BAD_SIG = <<~RBS
  class SdSub < SdOther
  end
RBS

# The generated body of Owner#name.
def body_of(code, owner, name)
  head = "\nmrb_value #{owner.gsub('::', '__')}_#{name}_impl(mrb_state* M"
  start = code.index(head) or return ''
  code[start, (code.index("\n}\n", start) || code.size) - start]
end

def with_env(pairs)
  saved = pairs.keys.to_h { |k| [k, ENV[k]] }
  pairs.each { |k, v| ENV[k] = v }
  yield
ensure
  saved.each { |k, v| ENV[k] = v }
end

def generate_with(runtime, dir, sig: nil, env: {})
  sig_dir = File.join(dir, 'sig')
  FileUtils.mkdir_p(sig_dir)
  File.write(File.join(sig_dir, 'fixture.rbs'), sig) if sig
  with_env({ 'BC2CPP_SIG_DIRS' => sig ? sig_dir : '' }.merge(env)) do
    runtime.generate(SOURCE, File.join(dir, 'gen'), only_owners: OWNERS)
  end
end

puts '== generated code'
Dir.mktmpdir('bc2cpp_subtree') do |dir|
  code, err = generate_with(runtime, File.join(dir, 'on'), sig: SIG)
  FileUtils.cp_r(File.join(dir, 'on'), ENV['BC2CPP_KEEP_DIR'], remove_destination: true) if ENV['BC2CPP_KEEP_DIR']
  facts = err.lines.grep(/SUBTREE_FACT/).map(&:strip)
  puts facts.map { |line| "    #{line}" }
  check.call('the Base.new / Sub.new ivar joins to SUBTREE(SdBase)',
             facts.include?('SUBTREE_FACT join SdHolder#@it (SdBase)'))
  check.call('a superclass named by the full path of a declared class joins too (two classes named Node)',
             facts.include?('SUBTREE_FACT join SdTwinHolder#@node (SdNs1::Node)') &&
               body_of(code, 'SdTwinHolder', 'label').include?('// SUBTREE_TABLE :label/0'))
  check.call('the RBS base-class return is a subtree fact',
             facts.include?('SUBTREE_FACT rbs-return SdMaker#pick (SdBase)'))
  check.call('the RBS base-class parameter is a subtree fact',
             facts.include?('SUBTREE_FACT rbs-param SdMaker#use #1 (SdBase)'))
  check.call('a class-typed RBS slot naming a class with subclasses is noted as a subtree hint',
             err.include?('class SdBase has subclasses; a subtree hint, not an exact one'))
  check.call('a common ancestor of Object gives no fact', facts.none? { |line| line.include?('ObHolder') })
  check.call('a hierarchy with a Class.new subclass gives no fact', facts.none? { |line| line.include?('NcHolder') })

  value = body_of(code, 'SdHolder', 'hold_value')
  kind = body_of(code, 'SdHolder', 'hold_kind')
  scaled = body_of(code, 'SdHolder', 'hold_scaled')
  check.call('one definition over the subtree is a SUBTREE_DIRECT call',
             value.include?('// SUBTREE_DIRECT :value -> SdBase#value') && value.include?('mrb_obj_is_kind_of(M, '))
  check.call('an argument-taking send with one definition is SUBTREE_DIRECT too',
             scaled.include?('// SUBTREE_DIRECT :scaled -> SdBase#scaled'))
  check.call('an override is a SUBTREE_TABLE slot', kind.include?('// SUBTREE_TABLE :kind/0 -> bc2cpp_vtbl_0 slot 0'))
  check.call('the subtree sites keep no name-wide chain',
             [value, kind, scaled].none? { |b| b.include?('POLY_SMALL_N :') })
  check.call('the table has one row per subtree class and a column per (name, argc)',
             code.include?('static const bc2cpp_vtbl_fn bc2cpp_vtbl_0_fns[2][2]') &&
               code.include?('reinterpret_cast<bc2cpp_vtbl_fn>(SdSub_kind_impl)'))
  check.call('the table lookup is memoized and its memo cleared with OWNER_CLASS_CACHE',
             code.include?('for (bc2cpp_vtbl_memo& m : bc2cpp_vtbl_memos) m = {};'))
  check.call('the else arm is the ordinary fallback, not forced by default',
             !kind.include?('bc2cpp_hint_violation') && !value.include?('bc2cpp_hint_violation'))
  picked = body_of(code, 'SdMaker', 'picked_kind')
  use = body_of(code, 'SdMaker', 'use')
  check.call('the RBS base-class return receiver dispatches over the subtree, never an exact TYPED guard',
             picked.include?('// SUBTREE_TABLE :kind/0') && !picked.include?('TYPED :kind'))
  check.call('the RBS base-class parameter receiver dispatches over the subtree, never an exact TYPED guard',
             use.include?('// SUBTREE_TABLE :kind/0') && !use.include?('TYPED :kind'))
  check.call('the Class.new hierarchy keeps its chain', !body_of(code, 'NcHolder', 'run').include?('SUBTREE'))
  check.call('the Object-rooted stores keep their chain', !body_of(code, 'ObHolder', 'run').include?('SUBTREE'))

  strict_code, = generate_with(runtime, File.join(dir, 'strict'), sig: SIG,
                                                                  env: { 'BC2CPP_STRICT_HINTS' => 'subtree',
                                                                         'BC2CPP_STRICT_HINTS_UNREVIEWED' => 'allow' })
  check.call('BC2CPP_STRICT_HINTS=subtree forces the else arm of a subtree site',
             body_of(strict_code, 'SdMaker', 'use_tag').include?('STRICT_HINT subtree: tag'))
  check.call('the default strict tier forces no subtree site', !code.include?('STRICT_HINT subtree'))

  off_code, off_err = generate_with(runtime, File.join(dir, 'off'), sig: SIG, env: { 'BC2CPP_SUBTREE_DISPATCH' => '0' })
  check.call('the kill switch leaves no SUBTREE code, table or fact',
             !off_code.include?('SUBTREE') && !off_code.include?('bc2cpp_vtbl') && !off_err.include?('SUBTREE_FACT'))
  if (base_tool = ENV['BC2CPP_SUBTREE_BASE_TOOL'])
    # Same directory for both runs: the generated code names its source paths.
    same = File.join(dir, 'same')
    off_plain, = generate_with(runtime, same, env: { 'BC2CPP_SUBTREE_DISPATCH' => '0' })
    FileUtils.rm_rf(same)
    tool = runtime::BC2CPP
    runtime.send(:remove_const, :BC2CPP)
    runtime.const_set(:BC2CPP, base_tool)
    begin
      base_code, = generate_with(runtime, same)
    ensure
      runtime.send(:remove_const, :BC2CPP)
      runtime.const_set(:BC2CPP, tool)
    end
    check.call('the kill switch is byte-identical to the baseline tool', off_plain == base_code)
  else
    puts '  -- SKIP byte-identical kill switch: set BC2CPP_SUBTREE_BASE_TOOL to the baseline bc2cpp.rb'
  end

  begin
    generate_with(runtime, File.join(dir, 'bad'), sig: BAD_SIG)
    check.call('an RBS superclass the program does not give the class aborts the build (TC1016)', false)
  rescue RuntimeError => e
    check.call('an RBS superclass the program does not give the class aborts the build (TC1016)',
               e.message.include?('[TC1016]') && e.message.include?('declares superclass SdOther'))
  end
end

builds = []
if ENV['SD_GENERATED_ONLY'] == '1'
  puts '-- SKIP run: SD_GENERATED_ONLY=1'
elsif (full = runtime.full_or_build) && runtime.compiler?
  builds << full
end
if builds.empty?
  unless ENV['SD_GENERATED_ONLY'] == '1'
    puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
  end
else
  puts '== fixture on real mruby, interpreted and compiled'
  scenario = <<~CPP
    static mrb_value obj(mrb_state* M, const char* name) {
      return mrb_obj_new(M, mrb_class_get(M, name), 0, nullptr);
    }
    static int scenario(mrb_state* M) {
      mrb_value t = mrb_true_value(), f = mrb_false_value();
      mrb_value h = obj(M, "SdHolder");
      call(M, "empty kind", h, "hold_kind");
      call(M, "open base", h, "open", 1, &f);
      call(M, "base value", h, "hold_value");
      call(M, "base kind", h, "hold_kind");
      call(M, "base scaled", h, "hold_scaled");
      call(M, "open sub", h, "open", 1, &t);
      call(M, "sub value", h, "hold_value");
      call(M, "sub kind", h, "hold_kind");
      call(M, "sub scaled", h, "hold_scaled");
      mrb_value m = obj(M, "SdMaker");
      call(M, "picked base", m, "picked_kind", 1, &f);
      call(M, "picked sub", m, "picked_kind", 1, &t);
      mrb_value other = obj(M, "SdOther");
      call(M, "use other", m, "use", 1, &other);
      mrb_value sub = mrb_funcall(M, m, "pick", 1, t);
      call(M, "use sub", m, "use", 1, &sub);
      mrb_value twin = obj(M, "SdTwinHolder");
      call(M, "twin open 1", twin, "open", 1, &f);
      call(M, "twin 1", twin, "label");
      call(M, "twin open 2", twin, "open", 1, &t);
      call(M, "twin 2", twin, "label");
      mrb_value ghost = obj(M, "SdGhost");
      call(M, "use ghost", m, "use", 1, &ghost);
      call(M, "tag sub", m, "use_tag", 1, &sub);
      call(M, "tag ghost", m, "use_tag", 1, &ghost);
      return 0;
    }
  CPP
  builds.each do |build|
    Dir.mktmpdir('bc2cpp_subtree_run') do |dir|
      _code, gen_err = generate_with(runtime, dir, sig: SIG)
      built, output = runtime.run(File.join(dir, 'gen'), gen_err, OWNERS, scenario, build: build, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
      check.call("every call answers what the interpreter answers (#{values.call('interpreted').size} lines)",
                 !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
      lines = sections.fetch('compiled', [])
      check.call('a Sub receiver takes its override',
                 lines.include?('sub kind => :sub') && lines.include?('picked sub => :sub'))
      check.call('a receiver outside the subtree takes the fallback', lines.include?('use ghost => :ghost') &&
                                                                     lines.include?('use other => :other'))
      ['twin 2', 'base kind', 'sub kind', 'sub value', 'sub scaled', 'picked sub', 'use sub'].each do |label|
        at = lines.index { |l| l.start_with?("#{label} =>") }
        n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
        check.call("#{label}: the compiled call makes no dynamic dispatch", n&.zero?)
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp subtree dispatch check: PASS'
else
  warn "bc2cpp subtree dispatch check: #{failures.size} failure(s)"
  exit 1
end
