#!/usr/bin/env ruby
# frozen_string_literal: true

# RESCUE_MULTI_CLASS (recognize_rescue_class_handler): a clause naming several classes (`rescue A, B => e`) tests each
# class in turn and jumps to its one handler; the clause's `JMP next` follows only its last class. A whole-method
# rescue, a `begin ... end` value and a chain mixing single- and multi-class clauses compile, and each matches, misses
# (re-raises) and binds the exception as the interpreter does. The behaviour part needs BC2CPP_MRUBY_FULL, or rake and a
# C++ compiler.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('rescue_multi_class_check')
suite.require_mrbc!

SOURCE = <<~RUBY
  class RmParse
    # Raises by kind, so every exception class is the program's own choice.
    def conv(x)
      case x
      when Integer then x
      when nil then raise TypeError, 'nil'
      when :index then raise IndexError, 'index'
      when :key then raise KeyError, 'key'
      else raise ArgumentError, 'bad'
      end
    end

    def parse(x)
      conv(x)
    rescue ArgumentError, TypeError => e
      [:bad, e.class]
    end

    def parse_value(x)
      n = begin
        conv(x)
      rescue TypeError, ArgumentError
        nil
      end
      [n]
    end

    def parse_chain(x)
      conv(x)
    rescue KeyError
      :key
    rescue TypeError, IndexError => e
      [:type_or_index, e.class]
    end

    def missed(x)
      conv(x)
    rescue TypeError, IndexError
      :never
    end

    def run
      [parse(12), parse('zz'), parse(nil), parse_value(7), parse_value('q'), parse_value(nil),
       parse_chain(:key), parse_chain(:index), parse_chain(nil), parse_chain(2),
       begin
         missed('zz')
       rescue ArgumentError => e
         [:reraised, e.class]
       end]
    end
  end
RUBY

OWNERS = %w[RmParse].freeze

def compiled?(code, name)
  code.match?(/^mrb_value RmParse_#{name}_impl\(mrb_state\* M/)
end

Dir.mktmpdir('bc2cpp-rescue-multi-class') do |dir|
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  missing = %w[parse parse_value parse_chain missed].reject { |name| compiled?(code, name) }
  suite.check("multi-class rescue clauses compile (missing: #{missing.join(', ')})", missing.empty?)

  build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP multi-class rescue behaviour: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake and g++)'
  else
    scenario = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value o = mrb_funcall_argv(M, mrb_obj_value(mrb_class_get(M, "RmParse")), mrb_intern_lit(M, "new"), 0, nullptr);
        call(M, "run", o, "run");
        mrb_value bad = mrb_str_new_lit(M, "zz");
        mrb_value key = mrb_symbol_value(mrb_intern_lit(M, "key"));
        call(M, "missed_key", o, "missed", 1, &key);
        call(M, "missed", o, "missed", 1, &bad);
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario, build: build, full: true)
    suite.check('fixture builds and runs', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    plain = ->(lines) { lines.to_a.reject { |l| l.start_with?('  dispatches=') } }
    interpreted = plain.call(sections['interpreted'])
    compiled = plain.call(sections['compiled'])
    suite.check('the interpreter matches each class of a clause',
                interpreted.include?('run => [12, [:bad, ArgumentError], [:bad, TypeError], [7], [nil], [nil], :key, ' \
                                     '[:type_or_index, IndexError], [:type_or_index, TypeError], 2, ' \
                                     '[:reraised, ArgumentError]]') &&
                interpreted.include?('missed => raised ArgumentError'))
    suite.check('compiled matches interpreted', compiled == interpreted)
  end
end

suite.finish!
