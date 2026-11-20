#!/usr/bin/env ruby
# frozen_string_literal: true

# ENSURE_BODY_BLOCKS (recognize_ensure_region blocks: true, emit_ensure_guard): an ensure body that calls a block
# (`saved.each_with_index { ... }`, `keys.each { ... }`) runs that call from the glue compile_method's block passes made
# for it, inside the guard's lambda. The fixture's method restores state in its ensure body after a normal exit, a
# raise and a `break` out of its caller's block, and checks that it compiles and behaves as the interpreter does. A
# block holding `break` in the ensure body would leave the destructor by a C++ exception, so that method stays on the
# interpreter. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('ensure_body_block_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class EbState
    NAMES = %i[@a @b].freeze

    def initialize
      @a = 1
      @b = 2
      @log = []
    end

    def with_fresh
      saved = NAMES.map { |ivar| instance_variable_get(ivar) }
      NAMES.each { |ivar| instance_variable_set(ivar, 0) }
      yield
    ensure
      NAMES.each_with_index { |ivar, index| instance_variable_set(ivar, saved[index]) } if saved
    end

    def restore_all(table)
      @log << table.size
      table.size
    ensure
      table.each { |k, v| @log << [k, v] }
    end

    def breaking(items)
      items.size
    ensure
      items.each { |i| break if i > 1 }
    end

    def run_ok
      r = with_fresh { [@a, @b] }
      [r, @a, @b]
    end

    def run_raise
      begin
        with_fresh { raise ArgumentError, 'boom' }
      rescue ArgumentError => e
        [e.message, @a, @b]
      end
    end

    def run_break
      r = [1, 2, 3].each { |v| with_fresh { break v * 10 if v == 2 } }
      [r, @a, @b]
    end

    def run_table
      [restore_all({ x: 1, y: 2 }), @log, breaking([1, 2, 3])]
    end
  end
RUBY

OWNERS = %w[EbState].freeze

def compiled?(code, name)
  code.match?(/^mrb_value EbState_#{name}_impl\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-ensure-body-block') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  suite.check('ensure bodies with block calls compile', compiled?(code, 'with_fresh') && compiled?(code, 'restore_all'))
  with_fresh = code[/^mrb_value EbState_with_fresh_impl\(mrb_state\* M.*?^}/m].to_s
  suite.check('the block call is inside the guard lambda',
              with_fresh[/auto bc2cpp_ensure_fn = \[&\]\(\) \{.*?bc2cpp_ensure_guard</m].to_s.include?('instance_variable_set'))
  suite.check('a breaking block in an ensure body stays interpreted', !compiled?(code, 'breaking'))

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP ensure body block behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        for (const char* m : {"run_ok", "run_raise", "run_break", "run_table"}) {
          mrb_value o = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "EbState")), mrb_intern_lit(M, "new"), 0, nullptr);
          call(M, m, o, m);
        }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter restores on every exit',
                interpreted.include?('run_ok => [[0, 0], 1, 2]') && interpreted.include?('run_raise => ["boom", 1, 2]') &&
                interpreted.include?('run_break => [[1, 2, 3], 1, 2]'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
