#!/usr/bin/env ruby
# frozen_string_literal: true

# TUPLE_RETURN_FACTS: `a, b = pair(x)` reads the elements of the Array a call returned.
# When every definition of `pair` ends in a literal `[e0, e1, ...]` of one length, that Array is fresh and
# nobody else holds it, so AREF's result has the class set the flow proved for that position, and a
# guarded arithmetic arm on it loses its by-name else.
#
# 1. Host only (no mrbc): NumericFlow's AREF transfer on hand-built bytecode.
# 2. With MRBC: the generated code of a closed-world fixture. Positive cases (Integer, Float and
#    Integer-or-Float positions, ternary tails, one position unknown while another proves, a nil position
#    narrowed by `||`, a pooled argument feeding the tuple) must lose the send; negative cases (a second
#    definition with another length / a String / a non-literal, an Array stored or mutated before it leaves,
#    a block `return`, a rescue clause, a name a native also defines, an index past the length, a destructure
#    that is not straight after the call, a branch join in front of the destructure, a copy mutated first,
#    a reopened Integer#+, the BC2CPP_TUPLE_RETURNS=0 kill switch) must keep it.
#    TQ_GENERATED_ONLY=1 stops here (what the mutation check runs).
# 3. With BC2CPP_MRUBY_FULL / BC2CPP_MRUBY_CORE (+ g++): the fixture runs on real mruby, interpreted and
#    compiled, and must answer alike -- values, exceptions, Integer overflow -- while the proven methods make
#    no dynamic dispatch. The run repeats on a 32-bit mrb_int build (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32)
#    and a build without mruby-bigint (BC2CPP_MRUBY_NOBIGINT).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir BC2CPP_FULL_BUILD_DIR=dir BC2CPP_MRUBY_FULL32=dir
#         BC2CPP_MRBC32=mrbc32 BC2CPP_MRUBY_NOBIGINT=dir] ruby scripts/bc2cpp/tuple_return_check.rb

# The fixture program defines none of the engine's classes, which sig/bc2cpp/declarations.rbs declares, so the
# shipped signatures would all be unusable (TC1003). Checked against no signature world, as block_iterator_direct_check does.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'set'
require 'tmpdir'
require_relative 'fixture_runtime'

# The mutation check points BC2CPP_TOOL at a mutant copy; the host half loads the same copy.
TOOLS = ENV['BC2CPP_TOOL'] ? File.dirname(ENV['BC2CPP_TOOL']) : File.expand_path('../../tools/bc2cpp', __dir__)
%w[irep bytecode_ir numeric_flow codegen codegen_tuple_returns].each { |file| require File.join(TOOLS, file) }

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

INT = NumericFlow::INT
FLT = NumericFlow::FLT
NIL_ = NumericFlow::NIL
OTHER = NumericFlow::OTHER

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

# An oracle with no facts but the AREF answer a test configures.
class TupleStubOracle
  attr_accessor :aref

  def entry_mask(_irep, _reg) = NumericFlow::OTHER
  def const_mask(_insn) = NumericFlow::OTHER
  def ivar_slots(_irep) = []
  def ivar_entry_mask(_irep, _name) = NumericFlow::OTHER
  def ivar_fact_mask(_irep, _name) = NumericFlow::OTHER
  def send_mask(_irep, _index, _insn, _state) = NumericFlow::OTHER
  def pool_mask(_irep, _insn) = NumericFlow::INT
  def op_native?(_sym) = true
  def nil_raises?(_sym) = true
end

class TupleAnswering < TupleStubOracle
  def aref_mask(_irep, _index, _insn, _state) = @aref
end

puts '-- NumericFlow AREF transfer (host)'
list = [insn(0, 'SEND0', "R2\t:pair"), insn(2, 'AREF', "R3\tR2\t1"), insn(6, 'ADDI', "R3\t1"), insn(9, 'RETURN', 'R3')]
irep = Irep.new(label: 'tq0', nregs: 8, instructions: list, catch_handlers: [], reps: [], pool: [])
states = NumericFlow.states(irep, TupleStubOracle.new, Set.new)
check.call('an oracle without aref_mask leaves the AREF result unknown', states[2][3] == OTHER)
answering = TupleAnswering.new.tap { |o| o.aref = INT }
states = NumericFlow.states(irep, answering, Set.new)
check.call('the oracle\'s class set becomes the register\'s', states[2][3] == INT)
check.call('and flows through the arithmetic that follows', states[3][3] == INT)
answering.aref = INT | FLT
check.call('an Integer-or-Float position stays both classes', NumericFlow.states(irep, answering, Set.new)[2][3] == (INT | FLT))
answering.aref = OTHER
check.call('an unproven position is unknown', NumericFlow.states(irep, answering, Set.new)[2][3] == OTHER)

puts '-- tuple shape of one definition (host)'
shape_of = lambda do |list|
  cg = CodeGen.allocate
  cg.instance_variable_set(:@ireps, {})
  cg.tuple_shape(Irep.new(label: "tq#{list.hash}", nregs: 8, instructions: list, catch_handlers: [], reps: [], pool: []))
end
check.call('ARRAY straight into RETURN is a tuple',
           shape_of.call([insn(0, 'ARRAY', "R3\t2"), insn(3, 'RETURN', 'R3')]) == [[0, 2]])
check.call('two arms, each an ARRAY then a jump to the RETURN, are a tuple',
           shape_of.call([insn(0, 'JMPNOT', "R1\t11"), insn(4, 'ARRAY', "R3\t2"), insn(7, 'JMP', '14'),
                          insn(11, 'ARRAY', "R3\t2"), insn(14, 'RETURN', 'R3')]) == [[1, 2], [3, 2]])
check.call('arms of different length are not',
           shape_of.call([insn(0, 'JMPNOT', "R1\t11"), insn(4, 'ARRAY', "R3\t2"), insn(7, 'JMP', '14'),
                          insn(11, 'ARRAY', "R3\t3"), insn(14, 'RETURN', 'R3')]).nil?)
check.call('an instruction that reads the Array before it leaves is not (SETIV)',
           shape_of.call([insn(0, 'ARRAY', "R3\t2"), insn(3, 'SETIV', "@x\tR3"), insn(6, 'RETURN', 'R3')]).nil?)
check.call('nor is a call between the ARRAY and the RETURN',
           shape_of.call([insn(0, 'ARRAY', "R3\t2"), insn(3, 'SEND0', "R4\t:f"), insn(5, 'RETURN', 'R3')]).nil?)
check.call('a returned parameter is not', shape_of.call([insn(0, 'RETURN', 'R1')]).nil?)
check.call('a copy of the Array is not',
           shape_of.call([insn(0, 'ARRAY', "R4\t2"), insn(3, 'MOVE', "R3\tR4"), insn(6, 'RETURN', 'R3')]).nil?)
check.call('a path that returns nil is not',
           shape_of.call([insn(0, 'JMPNOT', "R1\t9"), insn(4, 'ARRAY', "R3\t2"), insn(7, 'RETURN', 'R3'),
                          insn(9, 'RETNIL', '')]).nil?)

if ENV['MRBC']
  runtime = Bc2cppFixtureRuntime

  FIXTURE = <<~RUBY
    class TqBox
      def initialize
        @tq_n = 3
        @tq_big = 1073741824
        @tq_list = []
      end

      def tq_pair(a)
        [a + 1, a * 2]
      end

      def tq_pair_use
        x, y = tq_pair(@tq_n)
        x + y
      end

      def tq_cond(f)
        f ? [1, 2.5] : [3, 4]
      end

      def tq_cond_use
        p, q = tq_cond(@tq_n > 2)
        p + q
      end

      def tq_flt
        [1.5, @tq_n * 2.0]
      end

      def tq_flt_use
        x, y = tq_flt
        x * y
      end

      def tq_mixed(a)
        [a + 1, "s"]
      end

      def tq_mixed_first
        x, _y = tq_mixed(@tq_n)
        x + 1
      end

      def tq_mixed_second
        _x, y = tq_mixed(@tq_n)
        y + 1
      end

      def tq_nil_pos
        [@tq_n, nil]
      end

      def tq_nil_use
        x, y = tq_nil_pos
        x + (y || 0)
      end

      def tq_beyond
        _x, _y, z = tq_pair(@tq_n)
        z + 1
      end

      def tq_big(a)
        [a * 2, a + 1]
      end

      def tq_big_use
        x, y = tq_big(@tq_big)
        x + y
      end

      def tq_arity(a)
        [a, a]
      end

      def tq_arity_use
        x, y = tq_arity(@tq_n)
        x + y
      end

      def tq_str(a)
        [a, a]
      end

      def tq_str_use
        x, y = tq_str(@tq_n)
        x + y
      end

      def tq_nonlit(a)
        [a, a]
      end

      def tq_nonlit_use
        x, y = tq_nonlit(@tq_n)
        x + y
      end

      def tq_escape(a)
        r = [a, a + 1]
        @tq_list << r
        @tq_list[0][0] = "s"
        r
      end

      def tq_escape_use
        x, y = tq_escape(@tq_n)
        x + y
      end

      def tq_run_blk
        yield
      end

      def tq_blockret(a)
        tq_run_blk { return [a, "s"] }
        [a, a]
      end

      def tq_blockret_use
        _x, y = tq_blockret(@tq_n)
        y + 1
      end

      def tq_rescue(a)
        [a, a]
      rescue
        [a, "s"]
      end

      def tq_rescue_use
        _x, y = tq_rescue(@tq_n)
        y + 1
      end

      def divmod(a, b)
        [a / b, a % b]
      end

      def tq_native_use
        q, r = divmod(7, 2)
        q + r
      end

      def partition(a)
        [a, a]
      end

      def tq_foreign_use
        x, y = partition(@tq_n)
        x + y
      end

      def tq_mutate_use
        t = tq_pair(@tq_n)
        t[0] = "s"
        x, y = t
        x + y
      end

      def tq_text
        ["a", "b"]
      end

      def tq_join_use(f)
        x, y = (f ? tq_text : tq_pair(1))
        x + y
      end
    end

    class TqOther
      def tq_arity(a)
        [a, a, a]
      end

      def tq_str(_a)
        "text"
      end

      def tq_nonlit(a)
        r = [a, a]
        r
      end
    end

    class TqDrv
      def tq_go
        b = TqBox.new
        o = TqOther.new
        [b.tq_pair_use, b.tq_cond_use, b.tq_flt_use, b.tq_arity_use, o.tq_arity(1), o.tq_str(1), o.tq_nonlit(1),
         b.tq_join_use(true), b.tq_join_use(false)]
      end
    end
  RUBY

  FIXTURE_PLUS = <<~RUBY
    class Integer
      def +(other) = 1
    end

    class TqPlus
      def tq_pair(a)
        [a, a]
      end

      def tq_plus_use
        x, y = tq_pair(1)
        x + y
      end
    end
  RUBY

  FIXTURE_MM = <<~RUBY
    class TqMm
      def method_missing(name, *args)
        [name, args]
      end

      def respond_to_missing?(_name, _include_private = false) = true

      def tq_pair(a)
        [a, a]
      end

      def tq_mm_use
        x, y = tq_pair(1)
        x + y
      end
    end
  RUBY

  # The guarded arms tag themselves; an arm that lost its send has neither tag.
  retained_tag = %r{// (?:FIXNUM_ARITHMETIC|FIXNUM_COMPARE|FLOAT_DIV_RECEIVER) :}
  chunk_of = lambda do |code, owner_method|
    code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|^static mrb_value \S+_block_fallback_|\z)/m].to_s
  end
  with_blocks = lambda do |code, owner_method|
    prefix = Regexp.escape(owner_method.tr('#', '_'))
    chunk_of.call(code, owner_method) + code.scan(/^static mrb_value #{prefix}_block_fallback_\d+_impl.*?^\}\n(?=\nstatic mrb_value )/m).join
  end
  generate = lambda do |source, env = {}|
    saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    env.each { |k, v| ENV[k] = v }
    begin
      Dir.mktmpdir { |dir| runtime.generate(source, dir) }
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end

  puts '-- generated code (closed world)'
  code, err = generate.call(FIXTURE)
  proven = lambda do |method|
    chunk = with_blocks.call(code, method)
    !chunk.empty? && !chunk.match?(retained_tag) &&
      (chunk.include?('NUMERIC_OPERAND_PROOF') || chunk.include?('operands proven Fixnum'))
  end
  kept = lambda do |method|
    chunk = with_blocks.call(code, method)
    !chunk.empty? && chunk.match?(retained_tag)
  end

  check.call('Integer positions of a literal pair prove `x + y` after the destructure', proven.call('TqBox#tq_pair_use'))
  check.call('ternary tails with an Integer and an Integer-or-Float position prove', proven.call('TqBox#tq_cond_use'))
  check.call('a Float pair proves `x * y`', proven.call('TqBox#tq_flt_use'))
  check.call('one proven position proves although another position is a String', proven.call('TqBox#tq_mixed_first'))
  check.call('a nil position narrowed by `||` proves', proven.call('TqBox#tq_nil_use'))
  check.call('arithmetic that leaves the fixnum range still proves through the checked tier',
             proven.call('TqBox#tq_big_use'))
  check.call('NEG: the String position keeps its send', kept.call('TqBox#tq_mixed_second'))
  check.call('NEG: an index past the length reads nil and keeps its send', kept.call('TqBox#tq_beyond'))
  check.call('NEG: a second definition with another length keeps the send', kept.call('TqBox#tq_arity_use'))
  check.call('NEG: a second definition returning a String keeps the send', kept.call('TqBox#tq_str_use'))
  check.call('NEG: a second definition returning a non-literal keeps the send', kept.call('TqBox#tq_nonlit_use'))
  check.call('NEG: an Array stored and changed before it leaves keeps the send', kept.call('TqBox#tq_escape_use'))
  check.call('NEG: a `return` from a block keeps the send', kept.call('TqBox#tq_blockret_use'))
  check.call('NEG: a method with a rescue clause keeps the send', kept.call('TqBox#tq_rescue_use'))
  check.call('NEG: a name a native also defines (Integer#divmod) keeps the send', kept.call('TqBox#tq_native_use'))
  check.call('NEG: a name the core Ruby library also defines (Enumerable#partition) keeps the send',
             kept.call('TqBox#tq_foreign_use'))
  check.call('NEG: a copy changed before the destructure keeps the send', kept.call('TqBox#tq_mutate_use'))
  check.call('NEG: a branch join in front of the destructure keeps the send', kept.call('TqBox#tq_join_use'))
  facts = err.lines.grep(/NUMTUPLE /).join
  check.call('the diagnostic lists the proven positions',
             facts.include?('NUMTUPLE tq_pair (INT, INT)') && facts.include?('NUMTUPLE tq_cond (INT, INT|FLT)') &&
               facts.include?('NUMTUPLE tq_mixed (INT, OTHER)') && facts.include?('NUMTUPLE tq_nil_pos (INT, NIL)'))
  check.call('the diagnostic lists no name with a second shape',
             %w[tq_arity tq_str tq_nonlit tq_escape tq_blockret tq_rescue divmod].none? { |n| facts.include?("NUMTUPLE #{n} ") })

  _code, err_off = generate.call(FIXTURE, 'BC2CPP_TUPLE_RETURNS' => '0')
  off_code, = generate.call(FIXTURE, 'BC2CPP_TUPLE_RETURNS' => '0')
  check.call('BC2CPP_TUPLE_RETURNS=0 lists no tuple fact', err_off.lines.grep(/NUMTUPLE /).empty?)
  check.call('BC2CPP_TUPLE_RETURNS=0 puts the send back where the tuple proof removed it',
             with_blocks.call(off_code, 'TqBox#tq_pair_use').match?(retained_tag))

  plus_code, = generate.call(FIXTURE_PLUS)
  plus_chunk = with_blocks.call(plus_code, 'TqPlus#tq_plus_use')
  check.call('NEG: a reopened Integer#+ keeps the dispatch although the position is Integer',
             !plus_chunk.include?('NUMERIC_OPERAND_PROOF') && plus_chunk.include?('bc2cpp_send(M, r'))
  mm_code, mm_err = generate.call(FIXTURE_MM)
  check.call('NEG: a method_missing anywhere in the world disables the fact',
             with_blocks.call(mm_code, 'TqMm#tq_mm_use').match?(retained_tag) && mm_err.lines.grep(/NUMTUPLE /).empty?)

  # Everything above compiles the fixture; the run half needs libmruby and g++.
  if ENV['TQ_GENERATED_ONLY']
    puts '  SKIP run: TQ_GENERATED_ONLY'
  else
    owners = %w[TqBox TqOther TqDrv]
    methods = %w[tq_pair_use tq_cond_use tq_flt_use tq_mixed_first tq_mixed_second tq_nil_use tq_beyond tq_big_use
                 tq_arity_use tq_str_use tq_nonlit_use tq_escape_use tq_blockret_use tq_rescue_use tq_native_use
                 tq_foreign_use tq_mutate_use]
    body = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value box = mrb_obj_new(M, mrb_class_get(M, "TqBox"), 0, nullptr);
      #{methods.map { |m| "  call(M, \"#{m}\", box, \"#{m}\");" }.join("\n")}
        mrb_value t = mrb_true_value();
        mrb_value f = mrb_false_value();
        call(M, "join true", box, "tq_join_use", 1, &t);
        call(M, "join false", box, "tq_join_use", 1, &f);
        call(M, "pair_use again", box, "tq_pair_use");
        call(M, "escape_use again", box, "tq_escape_use");
        mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "TqDrv"), 0, nullptr);
        call(M, "driver", drv, "tq_go");
        return 0;
      }
    CPP
    # [label, build dir, mrbc, extra flags, full (mruby-core gems)?]
    builds = []
    # BC2CPP_MRUBY_FULL, or a full-core mruby built into BC2CPP_FULL_BUILD_DIR (the core-mrbtest shard shares it).
    full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
    core = runtime.core
    builds << ['mrb_int 64, full-core', full, ENV['MRBC'], '', true] if full
    builds << ['mrb_int 64, core only', core, ENV['MRBC'], '', false] if core
    if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
      builds << ['mrb_int 32 (MRB_INT32, 31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
                 '-DMRB_32BIT -DMRB_INT32 -no-pie', true]
    end
    builds << ['no mruby-bigint (32-bit mrb_int, no heap Integers)', ENV['BC2CPP_MRUBY_NOBIGINT'], ENV['MRBC'], '', true] if ENV['BC2CPP_MRUBY_NOBIGINT']
    if builds.empty? || !runtime.compiler?
      puts '  SKIP run: set BC2CPP_MRUBY_FULL / BC2CPP_MRUBY_CORE (libmruby*.a and include/, from the patched 3rd/mruby) and have g++'
    end
    builds.each do |label, build, mrbc, flags, with_gems|
      next unless runtime.compiler?

      puts "-- fixture on real mruby (#{label}), interpreted and compiled"
      saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
      ENV['MRBC'] = mrbc
      ENV['BC2CPP_CXXFLAGS'] = flags
      begin
        Dir.mktmpdir do |dir|
          _c, gen_err = runtime.generate(FIXTURE, dir, only_owners: owners)
          built, output = runtime.run(dir, gen_err, owners, body, build: build, full: with_gems)
          check.call("#{label}: the fixture compiles and runs against real mruby", built)
          puts output unless built
          next unless built

          sections = runtime.sections(output)
          values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
          same = !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled')
          check.call("#{label}: every method answers what the interpreter answers, values and exceptions alike", same)
          puts output if ENV['BC2CPP_CHECK_VERBOSE'] || !same
          dispatches = lambda do |name|
            lines = sections.fetch('compiled', [])
            at = lines.index { |l| l.start_with?("#{name} =>") }
            at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
          end
          %w[tq_pair_use tq_cond_use tq_flt_use tq_mixed_first tq_nil_use].each do |name|
            check.call("#{label}: #{name} makes no dynamic dispatch", dispatches.call(name) == 0)
          end
        end
      ensure
        ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
      end
    end
  end
else
  puts '  SKIP generated code and run: set MRBC'
end

if failures.empty?
  puts 'bc2cpp tuple return check: PASS'
else
  warn "bc2cpp tuple return check: #{failures.size} failure(s)"
  exit 1
end
