#!/usr/bin/env ruby
# frozen_string_literal: true

# Behaviour and placement oracle for the stack tuple arrays (docs/adr/0545): a literal Array of immediates that never
# leaves its frame keeps its elements in a C++ buffer. Three halves:
#
#   1. placement: each method in POSITIVE has its buffer in the generated code (`mrb_value bc2cpp_tup<N>[k]`) and no
#      mruby Array for that literal; every method in NEGATIVE keeps the mruby Array, and the whole generated text of
#      NEGATIVE is byte-identical to the output with BC2CPP_STACK_TUPLES=0 (the kill switch).
#   2. parity, interpreted against compiled: every row (POSITIVE and NEGATIVE) prints the same value on both sides,
#      and each value matches the value written here.
#   3. the kill switch: BC2CPP_STACK_TUPLES=0 generates no `bc2cpp_tup` at all.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/stack_tuples_check.rb
# Without MRBC the check aborts; without a full-core build (fixture_runtime.rb) its runtime half prints SKIP and the
# generation half still runs.

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

# Each method holds one placed literal (the placement count is in PLACED) or refuses for the reason in its comment.
POSITIVE = <<~RUBY
  class TupPos
    def pair_sum
      a = [1, 2]
      a[0] + a[1]
    end

    def set_read
      a = [1, 2, 3]
      a[1] = 40
      a[0] + a[1] + a[2]
    end

    def oob_read
      a = [5]
      a[3]
    end

    def neg_read
      a = [5, 6]
      a[-1]
    end

    def sized
      a = [4, 5, 6]
      a.size + a.length
    end

    def alias_store
      a = [1, 2]
      b = a
      b[0] = 9
      a[0]
    end

    def symbols
      a = [:x, nil, true]
      [a[0] == :x, a[1].nil?, a[2]].inspect
    end

    def store_value
      a = [0, 0]
      r = (a[1] = 7)
      [r, a[1]]
    end

    def big_fixnum
      a = [100_000, 2]
      a[0] + a[1]
    end

    def loop_read
      a = [1, 2]
      i = 0
      s = 0
      while i < 4
        s += a[1]
        i += 1
      end
      s
    end

    def two_arrays
      a = [1, 2]
      b = [3, 4]
      a[0] + b[1]
    end
  end
RUBY

POSITIVE_EXPECTED = {
  'TupPos.new.pair_sum' => '3',
  'TupPos.new.set_read' => '44',
  'TupPos.new.oob_read' => 'nil',
  'TupPos.new.neg_read' => '6',
  'TupPos.new.sized' => '6',
  'TupPos.new.alias_store' => '9',
  'TupPos.new.symbols' => '"[true, true, true]"',
  'TupPos.new.store_value' => '[7, 7]',
  'TupPos.new.big_fixnum' => '100002',
  'TupPos.new.loop_read' => '8',
  'TupPos.new.two_arrays' => '5',
}.freeze
# The methods that place a buffer: every other POSITIVE method must keep its Array.
POSITIVE_PLACED = %w[pair_sum set_read oob_read neg_read sized alias_store symbols store_value big_fixnum loop_read
                     two_arrays].freeze
# The methods whose only ARRAY is the placed literal: their chunk has no mruby Array construction at all.
POSITIVE_ONLY_LITERAL = %w[pair_sum set_read oob_read neg_read sized alias_store big_fixnum loop_read].freeze

# Each method refuses (an escape, a loop-carried creation, an unknown or out-of-bounds index, a non-immediate element,
# a read the placement does not model). The values must still match the interpreter.
NEGATIVE = <<~RUBY
  class TupSink
    def keep(x); @k = x; nil; end
    def first_of(x); x[0]; end
  end

  class TupNeg
    def escapes
      a = [1, 2]
      a
    end

    def kept
      a = [1, 2]
      TupSink.new.keep(a)
      a[0]
    end

    def loop_made
      i = 0
      s = 0
      while i < 3
        t = [i, 1]
        s += t[0]
        i += 1
      end
      s
    end

    def unknown_index(i)
      a = [1, 2]
      a[i]
    end

    def grow
      a = [1, 2]
      a[5] = 1
      a.size
    end

    def passed
      a = [1, 2]
      TupSink.new.first_of(a)
    end

    def first_call
      a = [1, 2]
      a.first
    end

    def float_element
      a = [1.5, 2]
      a[0]
    end

    def bignum_element
      a = [2**40, 1]
      a[0]
    end

    def string_element
      a = ['s', 1]
      a[0]
    end

    def ivar_element
      @v = 3
      a = [@v, 1]
      a[0]
    end

    # A read in a rescue handler has no reaching definition through the handler edges (the producer query refuses).
    def rescued
      a = [3, 4]
      begin
        raise 'boom' if a.size == 2
      rescue RuntimeError
        a[1]
      end
    end

    def string_store
      a = [1, 2]
      a[0] = 'x'
      a[0]
    end

    def neg_store
      a = [1, 2]
      a[-1] = 5
      a[1]
    end

    def rescue_escape
      a = [1, 2]
      begin
        raise ArgumentError, 'x'
      rescue ArgumentError
        a
      end
    end
  end
RUBY

NEGATIVE_EXPECTED = {
  'TupNeg.new.escapes' => '[1, 2]',
  'TupNeg.new.kept' => '1',
  'TupNeg.new.loop_made' => '3',
  'TupNeg.new.unknown_index(1)' => '2',
  'TupNeg.new.grow' => '6',
  'TupNeg.new.passed' => '1',
  'TupNeg.new.first_call' => '1',
  'TupNeg.new.float_element' => '1.5',
  'TupNeg.new.bignum_element' => '1099511627776',
  'TupNeg.new.string_element' => '"s"',
  'TupNeg.new.ivar_element' => '3',
  'TupNeg.new.rescued' => '4',
  'TupNeg.new.string_store' => '"x"',
  'TupNeg.new.neg_store' => '5',
  'TupNeg.new.rescue_escape' => '[1, 2]',
}.freeze

OWNERS_POS = %w[TupPos].freeze
OWNERS_NEG = %w[TupSink TupNeg].freeze

# A Ruby definition of Array#size reaches every exact Array: no placement anywhere in the program.
REDEFINED = <<~RUBY2
  class Array
    def size
      99
    end
  end

  class TupRedef
    def sized
      a = [4, 5]
      a.size
    end
  end
RUBY2
REDEFINED_EXPECTED = { 'TupRedef.new.sized' => '99' }.freeze
OWNERS_REDEF = %w[Array TupRedef].freeze

# The text of one method's C++ body, from its `// Owner#name (compiled from ...)` header to the next method's header.
def method_chunk(code, owner, name)
  code.split(%r{^(?=// \S+#\S+ \(compiled from)}).find { |chunk| chunk.start_with?("// #{owner}##{name} (") } || ''
end

# The generated text with BC2CPP_STACK_TUPLES=0 (the kill switch), with the environment restored.
def generate_without_tuples(source, owners)
  saved = ENV.fetch('BC2CPP_STACK_TUPLES', nil)
  ENV['BC2CPP_STACK_TUPLES'] = '0'
  Dir.mktmpdir('stack-tuples-off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(source, dir, only_owners: owners)
    code
  end
ensure
  saved.nil? ? ENV.delete('BC2CPP_STACK_TUPLES') : ENV['BC2CPP_STACK_TUPLES'] = saved
end

harness_rows = lambda do |expected|
  rows = expected.keys
  <<~CPP
    static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
    static int scenario(mrb_state* M) {
      const char* rows[] = {
    #{rows.map { |row| "    #{row.to_s.inspect}," }.join("\n")}
      };
      for (const char* src : rows) {
        mrb_value v = eval(M, src);
        if (M->exc) { show_exc(M, src); continue; }
        show(M, src, v);
      }
      return 0;
    }
  CPP
end

Dir.mktmpdir('stack-tuples') do |dir|
  # 1. placement and generation
  pos_dir = File.join(dir, 'pos')
  Dir.mkdir(pos_dir)
  pos_code, pos_err = runtime.generate(POSITIVE, pos_dir, only_owners: OWNERS_POS)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'stack_tuples_pos.cxx'), pos_code) if ENV['BC2CPP_KEEP_DIR']
  check.call('positive fixture generates', !pos_code.to_s.empty?)
  POSITIVE_PLACED.each do |name|
    chunk = method_chunk(pos_code, 'TupPos', name)
    check.call("TupPos##{name} keeps its literal in a buffer", chunk.match?(/mrb_value bc2cpp_tup\d+\[\d+\];/))
  end
  POSITIVE_ONLY_LITERAL.each do |name|
    chunk = method_chunk(pos_code, 'TupPos', name)
    check.call("TupPos##{name} builds no mruby Array", !chunk.include?('mrb_ary_new_from_values'))
  end

  neg_dir = File.join(dir, 'neg')
  Dir.mkdir(neg_dir)
  neg_code, neg_err = runtime.generate(NEGATIVE, neg_dir, only_owners: OWNERS_NEG)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'stack_tuples_neg.cxx'), neg_code) if ENV['BC2CPP_KEEP_DIR']
  NEGATIVE_EXPECTED.each_key do |row|
    owner, rest = row.split('.', 2)
    name = rest.sub(/\Anew\./, '').sub(/\(.*\z/, '')
    chunk = method_chunk(neg_code, owner, name)
    check.call("#{owner}##{name} refuses (keeps its Array)", !chunk.empty? && !chunk.include?('bc2cpp_tup'))
  end
  check.call('negative fixture has no bc2cpp_tup at all', !neg_code.include?('bc2cpp_tup'))

  off_code = generate_without_tuples(NEGATIVE, OWNERS_NEG)
  check.call('negative fixture is byte-identical with BC2CPP_STACK_TUPLES=0', neg_code == off_code)
  off_pos = generate_without_tuples(POSITIVE, OWNERS_POS)
  check.call('kill switch: positive fixture has no bc2cpp_tup', !off_pos.include?('bc2cpp_tup'))

  redef_dir = File.join(dir, 'redef')
  Dir.mkdir(redef_dir)
  redef_code, redef_err = runtime.generate(REDEFINED, redef_dir, only_owners: OWNERS_REDEF)
  check.call('redefined Array#size: no placement anywhere', !redef_code.include?('bc2cpp_tup'))
  check.call('redefined Array#size: byte-identical with BC2CPP_STACK_TUPLES=0',
             redef_code == generate_without_tuples(REDEFINED, OWNERS_REDEF))

  # 2. parity, interpreted against compiled
  build = runtime.full_or_build
  if build
    [[OWNERS_POS, pos_dir, pos_err, POSITIVE_EXPECTED, 'positive'],
     [OWNERS_NEG, neg_dir, neg_err, NEGATIVE_EXPECTED, 'negative'],
     [OWNERS_REDEF, redef_dir, redef_err, REDEFINED_EXPECTED, 'redefined']].each do |owners, sub, err, expected, label|
      built, output = runtime.run(sub, err, owners, harness_rows.call(expected), build: build, full: true)
      sections = runtime.sections(output)
      check.call("#{label}: built and ran", built)
      check.call("#{label}: runtime parity, interpreted against compiled",
                 !sections['compiled'].to_a.empty? && sections['compiled'] == sections['interpreted'])
      expected.each do |src, value|
        check.call("#{label}: #{src} => #{value}", sections['compiled'].to_a.include?("#{src} => #{value}"))
      end
      warn output unless failures.empty?
    end
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp stack tuple arrays check: PASS'
