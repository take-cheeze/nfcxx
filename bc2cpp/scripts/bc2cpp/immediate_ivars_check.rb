#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the report-only "immediate ivars" fact (tools/bc2cpp/escape_immediate_ivars.rb, docs/bc2cpp-immediate-ivars.md)
# on small fixtures compiled by bc2cpp:
#   1. an object whose every ivar store is an immediate (integers, nil, true; also one set through a send on it and
#      through an attribute writer) is classified immediate, with its store count;
#   2. an object storing a string, an array, or a parameter is not immediate (a parameter is not provably immediate);
#   3. a confined object that a closure in its creating frame may run with is not immediate (the closure is unmodelled);
#   4. an object stored into a global, or kept by its own initialize, is not confined, so it gets no ivars row;
#   5. the report changes no generated code: the same fixture generates byte-identical C++ with and without it.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/immediate_ivars_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
unless ENV['MRBC'] && system(ENV['MRBC'], '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

FIXTURE = <<~'RUBY'
  class IvInt
    def initialize; @a = 1; @b = nil; @c = true; end
    def bump; @a = 2; nil; end
  end
  class IvStr
    def initialize; @s = 'x'; end
  end
  class IvArr
    def initialize; @a = [1, 2]; end
  end
  class IvParam
    def initialize(v); @v = v; end
  end
  class IvKeep
    def initialize; @me = self; end
  end
  class IvAcc
    attr_accessor :q
    def initialize; self.q = 3; end
  end
  class IvSet
    def initialize; @v = 0; end
    def set(v); @v = v; nil; end
  end
  class IvUse
    def run_int; o = IvInt.new; o.bump; 0; end
    def run_acc; o = IvAcc.new; 0; end
    def run_str; o = IvStr.new; 0; end
    def run_arr; o = IvArr.new; 0; end
    def run_param; o = IvParam.new(5); 0; end
    def run_set; o = IvSet.new; o.set(4); 0; end
    def run_closure; o = IvInt.new; [1].each { |x| x }; 0; end
    def run_esc; o = IvKeep.new; 0; end
    def run_glob; $iv_check_g = IvInt.new; 0; end
  end
RUBY

OWNERS = %w[IvInt IvStr IvArr IvParam IvKeep IvAcc IvSet IvUse].freeze
failures = []
check = lambda do |label, condition|
  puts "#{condition ? 'ok  ' : 'FAIL'} #{label}"
  failures << label unless condition
end

# The ivars rows by owner ("Class#method"), and the site rows (verdict per creation site).
def parse(tsv)
  rows = File.readlines(tsv, chomp: true).map { |line| line.split("\t", -1) }
  ivars = rows.select { |r| r[0] == 'ivars' }.to_h { |r| [r[2], r] }
  sites = rows.select { |r| r[0] == 'site' && r[5] == 'object' }
  [ivars, sites]
end

Dir.mktmpdir('immediate-ivars') do |root|
  with_dir = File.join(root, 'with')
  without_dir = File.join(root, 'without')
  tsv = File.join(with_dir, 'escape.tsv')
  FileUtils.mkdir_p(with_dir)
  FileUtils.mkdir_p(without_dir)

  ENV['BC2CPP_ESCAPE_REPORT'] = tsv
  with_code, = Bc2cppFixtureRuntime.generate(FIXTURE, with_dir, only_owners: OWNERS)
  ENV.delete('BC2CPP_ESCAPE_REPORT')
  without_code, = Bc2cppFixtureRuntime.generate(FIXTURE, without_dir, only_owners: OWNERS)

  check.call('the escape report is written', File.exist?(tsv))
  # The fixture's own directory appears in the comments of the output (`@ .../fixture.rb:26`), so it is normalised.
  check.call('the generated C++ is byte-identical with and without the report',
             with_code.gsub(with_dir, 'DIR') == without_code.gsub(without_dir, 'DIR'))

  ivars, sites = parse(tsv)
  verdict = ->(owner) { ivars[owner] && ivars[owner][7] }
  detail = ->(owner) { ivars[owner] && ivars[owner][8] }
  confined = ->(owner) { sites.any? { |r| r[2] == owner && r[6] == 'confined' } }

  check.call('IvUse#run_int: integer, nil and true ivars, one set by a send on the object, is immediate',
             verdict.call('IvUse#run_int') == 'immediate' && ivars['IvUse#run_int'][9] == 'IvInt' &&
             ivars['IvUse#run_int'][8].to_i.positive?)
  check.call('IvUse#run_acc: a store through an attribute writer is immediate', verdict.call('IvUse#run_acc') == 'immediate')
  check.call('IvUse#run_str: a string ivar is not immediate', verdict.call('IvUse#run_str') == 'not_immediate' &&
             detail.call('IvUse#run_str').include?('not provably immediate'))
  check.call('IvUse#run_arr: an array ivar is not immediate', verdict.call('IvUse#run_arr') == 'not_immediate')
  check.call('IvUse#run_param: a stored parameter is not provably immediate', verdict.call('IvUse#run_param') == 'not_immediate')
  check.call('IvUse#run_set: a store of a parameter through a method on the object is not immediate',
             verdict.call('IvUse#run_set') == 'not_immediate')
  check.call('IvUse#run_closure: a closure in the creating frame is unenumerated, so not immediate',
             verdict.call('IvUse#run_closure') == 'not_immediate' && detail.call('IvUse#run_closure').include?('closure'))
  check.call('IvUse#run_esc: kept by its own initialize, so not confined and no ivars row',
             !confined.call('IvUse#run_esc') && verdict.call('IvUse#run_esc').nil?)
  check.call('IvUse#run_glob: stored into a global, so not confined and no ivars row',
             !confined.call('IvUse#run_glob') && verdict.call('IvUse#run_glob').nil?)
  check.call('every ivars row belongs to a confined site', ivars.values.all? { |r| r[6] == 'confined' })
end

if failures.empty?
  puts 'immediate_ivars_check: all checks passed'
else
  puts "immediate_ivars_check: #{failures.size} failure(s)"
  exit 1
end
