#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_DEF_RETURN (codegen_declared_returns.rb): a call the exact-class flow resolves to one definition reads that
# definition's own checked declaration, even where the name admits no name-wide fact (another definer, here an
# attr_accessor, refuses it as info). The declaring body then carries its DECLARED_RETURN_GUARD, so the value is what
# the declaration says or the call raises BC2cppDeclarationViolation.
#
#   1. generated: `t = targets; t.empty?` on a self-call of a `-> Array` definition whose name another class answers
#      with an accessor is the Array body with no class-test chain, and the declaring body is guarded; so is a call
#      on a fresh exact receiver; a self-call that a subclass override may answer, a `-> Array` declared on a
#      body nothing resolves to, and BC2CPP_DECLARED_DEF_RETURNS=0 keep the chain; a native table's later copy of
#      the declaration (`# bc2cpp-native:`) leaves the program declaration in force;
#   2. a guarded leaf body is not inlined (CALL_INLINE would skip the guard); an `@x: Array[T]` declaration is
#      guarded at its stores and, seeded into the slot's pool, makes a read of the slot exactly an Array; so is an
#      `@x: Array?` slot an attr_accessor writes (the synthesized writer is guarded too), and `(x || []).empty?` is
#      then the Array body; a slot whose name reflection writes, and BC2CPP_DECLARED_IVAR_ACCESSOR=0, stay unseeded;
#   3. run on a full-core mruby against interpreted: the resolved sends answer as interpreted, and a wrong
#      declaration (or ivar store, or attr_writer store) raises the violation instead of reaching the unchecked body;
#   4. a resolved body's `String?` result is a String once nil is tested (SCOPED_NILABLE_RESULT); and with mruby's own
#      Ruby compiled in, an exact Array's `reject { }` (CORE_TARGET_ONE_BODY), `uniq { }` (CORE_RUBY_SELF), `sort`
#      (VETTED_FRESH_ARRAY) and `size` (core_results) results are exact, each switch keeps the chain, and the
#      compiled run answers as the interpreted one.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/declared_def_return_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/native_core_result_sigs'

suite = FixtureCheck.new('declared_def_return_check')
check = suite.method(:check)
suite.require_mrbc!
runtime = Bc2cppFixtureRuntime

SOURCE = <<~RUBY
  class State
    attr_accessor :targets
    # A second definer of `label`, so Tag#label's declaration is no name-wide fact.
    attr_reader :label
    def initialize
      @targets = { 3 => 1, 1 => 2 }
      nil
    end
  end

  class Menu
    def initialize(state)
      @state = state
      nil
    end

    def targets
      @state.targets.keys.sort.map { |id| [id, id + 1] }
    end

    def count
      t = targets
      return 0 if t.empty?
      t.size
    end

    def bad
      @state.targets
    end

    def bad_count
      bad.empty?
    end

    def ratio(x)
      x
    end

    def use_ratio
      ratio('half')
    end
  end

  class Outside
    def probe(state)
      Menu.new(state).targets.empty?
    end
  end

  class Base
    def initialize
      @rows = [1, 2]
      nil
    end

    def rows
      @rows.map { |r| r }
    end

    def first_empty?
      rows.empty?
    end
  end

  class Sub < Base
    def rows
      ''
    end
  end

  class Roster
    def initialize(list)
      @members = list
      nil
    end

    def none?
      @members.empty?
    end
  end

  class Fighter
    attr_accessor :states

    def initialize(states = nil)
      @states = states
      nil
    end

    def calm?
      (states || []).empty?
    end

    def bare?
      (@states || []).empty?
    end
  end

  class Tag
    attr_accessor :text

    def initialize
      @text = 'x'
      nil
    end

    def label
      @text
    end

    def blank?
      n = label
      n.nil? || n.empty?
    end
  end

  class Poked
    attr_accessor :items

    def initialize
      @items = nil
      nil
    end

    def none?
      (@items || []).empty?
    end

    def poke
      instance_variable_set(:@items, [1])
    end
  end
RUBY

SIGNATURES = <<~RBS
  class Menu
    def targets: () -> Array
    def bad: () -> Array
    %a{bc2cpp:hint}
    def ratio: (untyped) -> Integer
  end
  class Base
    def rows: () -> Array
  end
  class Roster
    @members: Array[Integer]
  end
  class Fighter
    @states: Array?
  end
  class Poked
    @items: Array?
  end
  class Tag
    %a{bc2cpp:hint}
    def label: () -> String?
  end

  # A native table's later copy of a program declaration does not erase it.
  # bc2cpp-native: typed_returns
  class Menu
    def targets: () -> Array
  end
RBS
OWNERS = %w[State Menu Outside Base Sub Roster Fighter Poked Tag].freeze

HARNESS = <<~'CPP'
  static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
  static int scenario(mrb_state* M) {
    mrb_value state = mrb_obj_new(M, mrb_class_get(M, "State"), 0, nullptr);
    mrb_value menu = mrb_obj_new(M, mrb_class_get(M, "Menu"), 1, &state);
    call(M, "count", menu, "count");
    mrb_value outside = mrb_obj_new(M, mrb_class_get(M, "Outside"), 0, nullptr);
    call(M, "outside probe", outside, "probe", 1, &state);
    mrb_value base = mrb_obj_new(M, mrb_class_get(M, "Base"), 0, nullptr);
    call(M, "base first_empty?", base, "first_empty?");
    mrb_value sub = mrb_obj_new(M, mrb_class_get(M, "Sub"), 0, nullptr);
    call(M, "sub first_empty?", sub, "first_empty?");
    eval(M, "$empty = State.new; $empty.targets = {}");
    mrb_value empty = eval(M, "$empty");
    mrb_value menu2 = mrb_obj_new(M, mrb_class_get(M, "Menu"), 1, &empty);
    call(M, "count of none", menu2, "count");
    call(M, "wrong declaration", menu, "bad_count");
    call(M, "wrong hinted leaf", menu, "use_ratio");
    mrb_value list = eval(M, "[1]");
    mrb_value roster = mrb_obj_new(M, mrb_class_get(M, "Roster"), 1, &list);
    call(M, "roster none?", roster, "none?");
    mrb_value text = eval(M, "'x'");
    call(M, "wrong ivar", mrb_obj_value(mrb_class_get(M, "Roster")), "new", 1, &text);
    mrb_value fighter = mrb_obj_new(M, mrb_class_get(M, "Fighter"), 0, nullptr);
    call(M, "fighter calm?", fighter, "calm?");
    mrb_value one = eval(M, "[1]");
    call(M, "fighter states=", fighter, "states=", 1, &one);
    call(M, "fighter bare?", fighter, "bare?");
    call(M, "wrong accessor", fighter, "states=", 1, &text);
    mrb_value tag = mrb_obj_new(M, mrb_class_get(M, "Tag"), 0, nullptr);
    call(M, "tag blank?", tag, "blank?");
    return 0;
  }
CPP

# { "Owner#name" => generated body } and the run's stderr, with the given switches.
generate = lambda do |dir, env|
  env.each { |k, v| ENV[k] = v }
  sigs = File.join(dir, 'sig')
  FileUtils.mkdir_p(sigs)
  File.write(File.join(sigs, 'menu.rbs'), SIGNATURES)
  ENV['BC2CPP_SIG_DIRS'] = sigs
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  [code, err, code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }]
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  env.each_key { |k| ENV.delete(k) }
end
chain = ->(body) { body.to_s.include?('bc2cpp_owner_call(') || body.to_s.match?(/mrb_array_p\(r\d+\) && mrb_obj_ptr/) }
exact_empty = ->(body) { body.to_s.include?('CLOSED_WORLD_NATIVE_EXACT :empty? -> Array') }
exact_str_empty = ->(body) { body.to_s.include?('CLOSED_WORLD_NATIVE_EXACT :empty? -> String') }

Dir.mktmpdir('declared-def-return-off') do |dir|
  _, _, off = generate.call(dir, 'BC2CPP_DECLARED_DEF_RETURNS' => '0', 'BC2CPP_DECLARED_IVAR_ACCESSOR' => '0')
  check.call('before: `t.empty?` on the declared self-call result keeps the class-test chain',
             chain.call(off['Menu#count']) && !exact_empty.call(off['Menu#count']))
  check.call('before: the info-refused declaration has no guard',
             !off['Menu#targets'].to_s.include?('DECLARED_RETURN_GUARD Menu#targets'))
  check.call('before: an accessor-written declared slot is not seeded, so `(states || []).empty?` keeps its chain',
             chain.call(off['Fighter#calm?']) && !exact_empty.call(off['Fighter#calm?']))
end

Dir.mktmpdir('declared-def-return-nilable-off') do |dir|
  _, _, off = generate.call(dir, 'BC2CPP_SCOPED_NILABLE_RESULTS' => '0')
  check.call('BC2CPP_SCOPED_NILABLE_RESULTS=0: a `String?` result keeps its by-name `empty?`', !exact_str_empty.call(off['Tag#blank?']))
end

Dir.mktmpdir('declared-def-return') do |dir|
  code, err, on = generate.call(dir, {})
  check.call('the name is refused name-wide (the accessor defines it too)',
             err.include?('Menu#targets -> Array: `targets` also has a native or accessor definition'))
  check.call('the declaring body carries its guard', on['Menu#targets'].to_s.include?('DECLARED_RETURN_GUARD Menu#targets -> Array'))
  check.call('`t.empty?` on the self-call result is the Array body, no chain',
             exact_empty.call(on['Menu#count']) && !chain.call(on['Menu#count']))
  check.call('a call on a fresh exact receiver reads the declaration too', exact_empty.call(on['Outside#probe']))
  check.call('a self-call a subclass override may answer keeps its chain',
             !exact_empty.call(on['Base#first_empty?']) && chain.call(on['Base#first_empty?']))
  check.call('a declared `@x: Array[T]` store is guarded and its read is the Array body (CORE_IVAR_KINDS)',
             on['Roster#initialize'].to_s.include?('DECLARED_IVAR_GUARD Roster#@members') &&
               exact_empty.call(on['Roster#none?']) && !chain.call(on['Roster#none?']))
  check.call('the synthesized attr_writer of a declared slot is guarded',
             on['Fighter#states='].to_s.include?('DECLARED_IVAR_GUARD Fighter#@states'))
  check.call('an accessor-written `@x: Array?` slot is seeded (ACCESSOR_GUARDED_WRITER)',
             err.include?('DECLARED_IVAR Fighter#@states: Array?, guarded stores, pool seeded'))
  check.call('`(x || [])` of the seeded slot, through the reader or the ivar, is the Array body',
             %w[Fighter#calm? Fighter#bare?].all? { |k| exact_empty.call(on[k]) && !chain.call(on[k]) })
  check.call('a slot whose name reflection writes is not seeded and keeps its chain',
             !err.include?('DECLARED_IVAR Poked#@items: Array?, guarded stores, pool seeded') &&
               chain.call(on['Poked#none?']))
  check.call('a resolved `String?` result tested for nil is the String body (SCOPED_NILABLE_RESULT)',
             exact_str_empty.call(on['Tag#blank?']) && on['Tag#label'].to_s.include?('DECLARED_RETURN_GUARD Tag#label -> String?'))
  check.call('the guarded leaf is not inlined', !on['Menu#use_ratio'].to_s.include?('CALL_INLINE Menu#ratio') &&
                                                on['Menu#use_ratio'].to_s.include?('Menu_ratio_impl('))

  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, HARNESS, build: build, full: true)
    sections = runtime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    compiled = plain.call(sections['compiled'])
    interpreted = plain.call(sections['interpreted'])
    wrong = ->(lines) { lines.grep(/\Awrong /) }
    check.call('built and ran', built)
    check.call('the resolved sends answer as interpreted',
               !compiled.empty? && compiled - wrong.call(compiled) == interpreted - wrong.call(interpreted))
    check.call('a wrong declaration raises the violation in the compiled run',
               wrong.call(compiled) == ['wrong declaration => raised BC2cppDeclarationViolation',
                                        'wrong hinted leaf => raised BC2cppDeclarationViolation',
                                        'wrong ivar => raised BC2cppDeclarationViolation',
                                        'wrong accessor => raised BC2cppDeclarationViolation'])
    warn output unless built && compiled.size == interpreted.size
  else
    puts '  SKIP run: no full-core mruby build'
  end
  File.write(File.join(dir, 'keep.cpp'), code) if ENV['BC2CPP_KEEP_DIR']
end

# Results on an exact Array, with mruby's own Ruby in the closed world (core: true).
CORE_SOURCE = <<~RUBY
  class Pile
    def initialize
      @ids = [3, 1, 2]
      nil
    end

    def kept_none?
      @ids.reject { |x| x > 2 }.empty?
    end

    def uniq_none?
      @ids.uniq { |x| x % 2 }.empty?
    end

    def sorted_none?
      @ids.sort.empty?
    end

    def count_text
      @ids.size.to_s
    end
  end
RUBY
CORE_OWNERS = %w[Pile].freeze
CORE_SWITCHES = { 'Pile#kept_none?' => 'BC2CPP_CORE_TARGET_ONE_BODY', 'Pile#uniq_none?' => 'BC2CPP_CORE_RUBY_SELF',
                  'Pile#sorted_none?' => 'BC2CPP_VETTED_FRESH_ARRAY' }.freeze
core_generate = lambda do |dir, env|
  env.each { |k, v| ENV[k] = v }
  ENV['BC2CPP_SIG_DIRS'] = ''
  code, err = runtime.generate(CORE_SOURCE, dir, core: true, only_owners: CORE_OWNERS)
  [code, err, code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }]
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  env.each_key { |k| ENV.delete(k) }
end

Dir.mktmpdir('declared-def-return-core') do |dir|
  code, err, on = core_generate.call(dir, {})
  CORE_SWITCHES.each_key do |key|
    check.call("#{key}: the Array result answers `empty?` with the Array body", exact_empty.call(on[key]))
  end
  # The world's core.rbs names the result kind; a world without the declaration keeps Array#size untyped.
  if NativeCoreResultSigs.kinds.dig('Array', 'size')
    check.call('Pile#count_text: an exact Array#size is an Integer (core_results)',
               on['Pile#count_text'].to_s.include?('NUMERIC_NATIVE_EXACT :to_s -> Integer'))
  else
    puts '  SKIP Array#size result: the world declares no core_results kind for it'
  end
  CORE_SWITCHES.each do |key, switch|
    Dir.mktmpdir('declared-def-return-core-off') do |off_dir|
      _, _, off = core_generate.call(off_dir, switch => '0')
      check.call("#{switch}=0 keeps #{key}'s by-name `empty?`", !exact_empty.call(off[key]))
    end
  end

  build = runtime.full_or_build
  if build
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        mrb_load_string(M, "p = Pile.new; puts [p.kept_none?, p.uniq_none?, p.sorted_none?, p.count_text].inspect");
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, CORE_OWNERS, body, build: build, full: true)
    sections = runtime.sections(output)
    check.call('the core fixture builds and runs', built)
    check.call('compiled and interpreted Array results agree',
               sections['interpreted'] == sections['compiled'] && sections['compiled'].to_a.include?('[false, false, false, "3"]'))
    warn output unless built && sections['interpreted'] == sections['compiled']
  else
    puts '  SKIP core run: no full-core mruby build'
  end
  File.write(File.join(dir, 'keep_core.cpp'), code) if ENV['BC2CPP_KEEP_DIR']
end

suite.finish!
