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
#      body nothing resolves to, and BC2CPP_DECLARED_DEF_RETURNS=0 keep the chain;
#   2. a guarded leaf body is not inlined (CALL_INLINE would skip the guard);
#   3. run on a full-core mruby against interpreted: the resolved sends answer as interpreted, and a wrong
#      declaration raises the violation instead of reaching the unchecked body.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/declared_def_return_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('declared_def_return_check')
check = suite.method(:check)
suite.require_mrbc!
runtime = Bc2cppFixtureRuntime

SOURCE = <<~RUBY
  class State
    attr_accessor :targets
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
RBS
OWNERS = %w[State Menu Outside Base Sub].freeze

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

Dir.mktmpdir('declared-def-return-off') do |dir|
  _, _, off = generate.call(dir, 'BC2CPP_DECLARED_DEF_RETURNS' => '0')
  check.call('before: `t.empty?` on the declared self-call result keeps the class-test chain',
             chain.call(off['Menu#count']) && !exact_empty.call(off['Menu#count']))
  check.call('before: the info-refused declaration has no guard',
             !off['Menu#targets'].to_s.include?('DECLARED_RETURN_GUARD Menu#targets'))
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
                                        'wrong hinted leaf => raised BC2cppDeclarationViolation'])
    warn output unless built && compiled.size == interpreted.size
  else
    puts '  SKIP run: no full-core mruby build'
  end
  File.write(File.join(dir, 'keep.cpp'), code) if ENV['BC2CPP_KEEP_DIR']
end

suite.finish!
