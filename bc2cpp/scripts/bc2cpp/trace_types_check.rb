#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks scripts/bc2cpp/trace_types.rb (candidates) on a synthetic dump: observed unions, true/false as bool, an overflowed
# site left out, a never-reached parameter left as untyped, names that are not plain Ruby identifiers skipped,
# and the output parses as RBS.
#
#   ruby scripts/bc2cpp/trace_types_check.rb

require 'tempfile'
require 'rbs'
require_relative 'trace_types'

DUMP = <<~TSV
  PARAM_SITE\tfx\t0\t3\t0\tBox#put\tBox_put_impl\tmethod\treq\t1\tv\tnone:mono
  PARAM_CLASS\tfx\t0\tInteger\t2
  PARAM_CLASS\tfx\t0\tString\t1
  PARAM_SITE\tfx\t1\t2\t0\tBox#flag\tBox_flag_impl\tmethod\treq\t1\tb\tnone:mono
  PARAM_CLASS\tfx\t1\tTrueClass\t1
  PARAM_CLASS\tfx\t1\tFalseClass\t1
  PARAM_SITE\tfx\t2\t5\t3\tBox#over\tBox_over_impl\tmethod\treq\t1\tx\tnone:mono
  PARAM_CLASS\tfx\t2\tInteger\t5
  PARAM_SITE\tfx\t3\t0\t0\tBox#unused\tBox_unused_impl\tmethod\treq\t1\tx\tnone:mono
  PARAM_SITE\tfx\t6\t1\t0\tBox#wide\tBox_wide_impl\tmethod\treq\t1\tx\tnone:mono
  PARAM_CLASS\tfx\t6\tInteger\t1
  PARAM_CLASS\tfx\t6\tString\t1
  PARAM_CLASS\tfx\t6\tSymbol\t1
  PARAM_CLASS\tfx\t6\tFloat\t1
  PARAM_CLASS\tfx\t6\tArray\t1
  PARAM_SITE\tfx\t4\t1\t0\tBox#<\tBox_lt_impl\tmethod\treq\t1\tother\tnone:mono
  PARAM_CLASS\tfx\t4\tInteger\t1
  RETURN_SITE\tfx\t0\t2\t0\tBox#put\tBox_put_impl\tmethod\treturn\t0\treturn#1\tret=none
  RETURN_CLASS\tfx\t0\tNilClass\t1
  RETURN_CLASS\tfx\t0\tInteger\t1
  RETURN_SITE\tfx\t1\t1\t0\tBox#flag\tBox_flag_impl\tmethod\treturn\t0\treturn#1\tret=none
  RETURN_CLASS\tfx\t1\tTrueClass\t1
  PARAM_SITE\tfx\t5\t1\t0\tBox#initialize\tBox_init_impl\tmethod\treq\t1\tsize\tnone:mono
  PARAM_CLASS\tfx\t5\tInteger\t1
  RETURN_SITE\tfx\t5\t1\t0\tBox#initialize\tBox_init_impl\tmethod\treturn\t0\treturn#1\tret=none
  RETURN_CLASS\tfx\t5\tBox\t1
TSV

HIERARCHY = <<~TSV
  SUPER\tBox::Sub1\tBox::Base
  SUPER\tBox::Sub2\tBox::Base
  SUPER\tBox::Sub3\tBox::Base
  SUPER\tBox::Sub4\tBox::Base
  SUPER\tBox::Sub5\tBox::Base
  DEF\tBox::Base\tname
  DEF\tBox::Base\tsize
  DEF\tBox::Sub1\tinitialize
  DEF\tU1\tsize
  DEF\tU1\teach
  DEF\tU2\tsize
  DEF\tU2\teach
  DEF\tU2\tother
  DEF\tU3\tsize
  DEF\tU3\teach
  DEF\tU4\tsize
  DEF\tU4\teach
  DEF\tU5\tsize
  DEF\tU5\teach
TSV

WIDE = <<~TSV
  PARAM_SITE\tfx\t0\t10\t0\tBox#put\tBox_put_impl\tmethod\treq\t1\tv\tnone:mono
  PARAM_CLASS\tfx\t0\tBox::Sub1\t2
  PARAM_CLASS\tfx\t0\tBox::Sub2\t2
  PARAM_CLASS\tfx\t0\tBox::Sub3\t2
  PARAM_CLASS\tfx\t0\tBox::Sub4\t2
  PARAM_CLASS\tfx\t0\tBox::Sub5\t2
  PARAM_SITE\tfx\t1\t10\t0\tBox#pick\tBox_pick_impl\tmethod\treq\t1\tv\tnone:mono
  PARAM_CLASS\tfx\t1\tU1\t2
  PARAM_CLASS\tfx\t1\tU2\t2
  PARAM_CLASS\tfx\t1\tU3\t2
  PARAM_CLASS\tfx\t1\tU4\t2
  PARAM_CLASS\tfx\t1\tU5\t2
TSV

failures = []
check = ->(name, ok) { failures << name unless ok }

Tempfile.create(['trace_types', '.txt']) do |dump|
  dump.write(DUMP)
  dump.flush
  params, rets = TraceTypes::Candidates.read_dumps([dump.path])
  text = TraceTypes::Candidates.render(TraceTypes::Candidates.candidates(params, rets))

  check.call('a parameter seen as Integer and String is their union, a return of Integer and nil is parenthesized',
              text.include?('def put: (Integer | String) -> (Integer | nil)'))
  check.call('true and false together give bool', text.include?('def flag: (bool) -> bool'))
  check.call('a parameter with more classes than a guarded union holds is untyped', text.include?('def wide: (untyped)'))
  check.call('an overflowed parameter is left out of the candidates', !text.include?('def over'))
  check.call('a never-reached method with no returns is left out', !text.include?('def unused'))
  check.call('an operator name is not written into RBS', !text.include?('def <'))
  check.call('initialize keeps its parameter types and its return is untyped (Ruby discards it)',
              text.include?('def initialize: (Integer) -> untyped'))
  Tempfile.create(['hierarchy', '.tsv']) do |hier_file|
    hier_file.write(HIERARCHY)
    hier_file.flush
    Tempfile.create(['wide', '.txt']) do |wide_dump|
      wide_dump.write(WIDE)
      wide_dump.flush
      wparams, wrets = TraceTypes::Candidates.read_dumps([wide_dump.path])
      hierarchy = TraceTypes::Candidates::Hierarchy.read(hier_file.path)
      wtext = TraceTypes::Candidates.render(TraceTypes::Candidates.candidates(wparams, wrets, hierarchy), hierarchy.interfaces)
      check.call('five subclasses of one base are typed as the common ancestor', wtext.include?('def put: (Box::Base) -> untyped'))
      check.call('unrelated classes sharing methods get a named interface, without initialize',
                 wtext.match?(/interface _Shared\w+\n  def each: \(\*untyped\) -> untyped\n  def size: \(\*untyped\) -> untyped\nend/))
      check.call('the interface is used as the parameter type', wtext.match?(/def pick: \(_Shared\w+\) -> untyped/))
      check.call('the candidates with hierarchy parse as RBS', begin
        RBS::Parser.parse_signature(wtext)
        true
      rescue RBS::ParsingError
        false
      end)
    end
  end
  check.call('the output parses as RBS', begin
    RBS::Parser.parse_signature(text)
    true
  rescue RBS::ParsingError
    false
  end)
end

# Two runs of one method with different classes merge into one union (the sites are numbered per run).
run_a = "PARAM_SITE\tfx\t0\t1\t0\tBox#read\tBox_read_impl\tmethod\treq\t1\ts\tnone:mono\nPARAM_CLASS\tfx\t0\tFile\t1\n"
run_b = "PARAM_SITE\tfx\t7\t1\t0\tBox#read\tBox_read_impl\tmethod\treq\t1\ts\tnone:mono\nPARAM_CLASS\tfx\t7\tStringIO\t1\n"
Tempfile.create(['run_a', '.txt']) do |a|
  Tempfile.create(['run_b', '.txt']) do |b|
    a.write(run_a)
    a.flush
    b.write(run_b)
    b.flush
    merged = TraceTypes::Candidates.render(TraceTypes::Candidates.candidates(*TraceTypes::Candidates.read_dumps([a.path, b.path])))
    check.call('two runs of one method merge into a union', merged.include?('def read: (File | StringIO) -> untyped'))
  end
end

if failures.empty?
  puts 'trace types check: PASS'
else
  warn "trace types check: FAIL\n  #{failures.join("\n  ")}"
  exit 1
end
