#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Array writes and the Integer arms the optcarrot frame loop hits, compiled without a call into libmruby's slow path:
#
#   generated code (needs a host mrbc)
#     - ARY_WRITE_INLINE: `ary << v`, `ary[i] = v` and `ary[i, n] = rpl` call the same-TU bc2cpp_ary_push / _set /
#       _splice fast paths (tools/bc2cpp/codegen_emit.rb), which fall back to mrb_ary_push / _set / _splice;
#     - NATIVE_CORE_DIRECT rotate!: an exact-Array arm calls the audited ary_rotate_bang mirror, the owner call
#       stays the else;
#     - NEQ_OP_EQ: `a != b` compares two Integers in place before mrb_equal, as BasicObject#!= (`!(self == other)`
#       through OP_EQ) does even in a program that reopens Integer#==;
#     - POLY_INTEGER_TAG: a POLY_SMALL_N chain with an Integer arm reads an Integer receiver's class from its tag,
#       and BC2CPP_POLY_INTEGER_TAG=0 keeps the mrb_obj_class read.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, the fallbacks included: frozen and shared receivers, negative
#       and out-of-range indices, splices that resize or take the receiver itself, rotate! counts of every sign,
#       Array subclasses with their own methods, and `!=` across Integer, Float, nil and String.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/array_write_inline_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

SRC = <<~'RUBY'
  class AwBuf
    attr_reader :out, :bg
    def initialize
      @out = []
      @bg = [0] * 16
    end
    def fill(n)
      i = 0
      while i < n
        @out << i * 3
        i += 1
      end
      @out
    end
    def push_to(a, v); a << v; end
    def push_call(a, v); a.push(v); end
    def set_at(a, i, v); a[i] = v; end
    def splice_at(a, at, n, rpl); a[at, n] = rpl; end
    def rotate_by(a, k); a.rotate!(k); end
    def rotate_one(a); a.rotate!; end
    def tile(lut, k)
      @bg.rotate!(8)
      @bg[k, 8] = lut
    end
    def neq(a, b); a != b; end
    def bit(x, n); x[n]; end
  end
  class AwBox
    def [](i); [:box, i]; end
  end
  # The optcarrot probe's Integer#[] shim (tools/optcarrot_probe/shim_integer_aref.rb): a Ruby arm in the `[]` chain.
  class Integer
    def [](i); (self >> i) & 1; end
  end
  class AwList < Array
    def <<(v); super(v * 100); end
    def rotate!(k = 1); [:own_rotate, k]; end
  end
RUBY

OWNERS = %w[AwBuf AwBox AwList Integer].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(env = {}, source: SRC, owners: OWNERS)
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(source, dir, core: true, only_owners: owners) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-array-write-inline')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
check.call('`<<` and push call the inline push, which falls back to mrb_ary_push',
           code_of(code, 'AwBuf_fill').include?('bc2cpp_ary_push(M, ') &&
             code_of(code, 'AwBuf_push_call').include?('bc2cpp_ary_push(M, ') &&
             code.match?(/static inline void bc2cpp_ary_push\(.*?\n\s*mrb_ary_push\(M, ary, elem\);\n\}/m))
check.call('`a[i] = v` calls the inline set, which falls back to mrb_ary_set',
           code.match?(/static inline void bc2cpp_ary_set\(.*?\n\s*mrb_ary_set\(M, ary, n, val\);\n\}/m) &&
             code.include?('bc2cpp_ary_set(M, recv, mrb_integer(idx), val);'))
check.call('`a[i, n] = rpl` calls the inline splice, which falls back to mrb_ary_splice',
           code_of(code, 'AwBuf_splice_at').include?('bc2cpp_ary_splice(M, ') &&
             code.match?(/static inline void bc2cpp_ary_splice\(.*?\n\s*mrb_ary_splice\(M, ary, head, len, rpl\);\n\}/m))
rotate = code_of(code, 'AwBuf_rotate_by')
check.call('rotate!(k) has an exact-Array arm calling the audited mirror, the owner call as its else',
           rotate.include?('NATIVE_CORE_DIRECT :rotate!') &&
             rotate.match?(/mrb_obj_ptr\(r\d+\)->c == M->array_class && mrb_integer_p\(r\d+\)\) \{\n\s*r\d+ = bc2cpp_ary_rotate_bang\(M, r\d+, mrb_integer\(r\d+\)\);/) &&
             rotate.match?(/\} else \{\n.*(?:bc2cpp_owner_call|mrb_funcall|bc2cpp_send)/m))
check.call('rotate! with no argument rotates by one', code_of(code, 'AwBuf_rotate_one').include?('bc2cpp_ary_rotate_bang(M, r'))
neq = code_of(code, 'AwBuf_neq')
# TAGGED_FIXNUM's Fixnum pair comes first, then any Integer pair.
neq_pair = /NEQ_OP_EQ :!=.*\n\s*if \(BC2CPP_FIXNUM_PAIR_P\((\w+), (\w+)\)\) \{\n\s*r\d+ = mrb_bool_value\(BC2CPP_FIXNUM_WORD\(\1\) != BC2CPP_FIXNUM_WORD\(\2\)\);\n\s*\} else if \(mrb_integer_p\(\1\) && mrb_integer_p\(\2\)\) \{\n\s*r\d+ = mrb_bool_value\(mrb_integer\(\1\) != mrb_integer\(\2\)\);\n.*r\d+ = mrb_bool_value\(!mrb_equal\(M, \1, \2\)\);/m
check.call('`!=` compares two Integers in place before mrb_equal', neq.match?(neq_pair))
reopened, = generate_world(source: "class Integer\n  def ==(other); super; end\nend\n#{SRC}", owners: OWNERS | ['Integer'])
check.call('a program that reopens Integer#== keeps the Integer-pair arm, as OP_EQ ignores Integer#==',
           code_of(reopened, 'AwBuf_neq').match?(neq_pair))
getidx = code[/static mrb_value bc2cpp_getidx_slow\(.*?\n\}\n/m].to_s
check.call('the shared `[]` chain reads an Integer receiver\'s class from its tag, Integer arm first',
           getidx.include?('POLY_INTEGER_TAG :[]') &&
             getidx.include?('struct RClass* bc2cpp_recv_class = mrb_integer_p(recv) ? M->integer_class : mrb_obj_class(M, recv);') &&
             getidx.match?(/if \(bc2cpp_owner_class_\d+\(M\) == bc2cpp_recv_class\) \{\n\s*r0 = Integer_\$5b\$5d_impl/))
off, = generate_world({ 'BC2CPP_POLY_INTEGER_TAG' => '0' })
check.call('BC2CPP_POLY_INTEGER_TAG=0 keeps the mrb_obj_class read', !off.include?('POLY_INTEGER_TAG') &&
           off[/static mrb_value bc2cpp_getidx_slow\(.*?\n\}\n/m].to_s.include?('== mrb_obj_class(M, recv)'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  b = AwBuf.new
  show.call('fill') { [b.fill(40).size, b.out.first(3), b.out.last] }
  show.call('push small') { a = []; 5.times { |i| b.push_to(a, i) }; a }
  show.call('push call') { a = [1]; b.push_call(a, :x); b.push_call(a, nil); a }
  show.call('push frozen') { b.push_to([1, 2].freeze, 3) }
  show.call('push shared') { a = (1..40).to_a; s = a[3, 30]; b.push_to(s, :t); [s.size, s.last, a.size, a[33]] }
  show.call('push subclass') { l = AwList.new; b.push_to(l, 2); b.push_call(l, 3); l.to_a }
  show.call('push gc') do
    GC.stress = true if GC.respond_to?(:stress=)
    a = []
    30.times { |i| b.push_to(a, "s#{i}") }
    GC.stress = false if GC.respond_to?(:stress=)
    [a.size, a[0], a[29]]
  end
  show.call('set') { a = [1, 2, 3]; [b.set_at(a, 1, :y), b.set_at(a, -1, :z), a] }
  show.call('set grow') { a = [1]; b.set_at(a, 4, :g); a }
  show.call('set neg out') { b.set_at([1, 2], -5, 0) }
  show.call('set frozen') { b.set_at([1, 2].freeze, 0, 0) }
  show.call('set shared') { a = (1..40).to_a; s = a[2, 30]; b.set_at(s, 0, :q); [s[0], a[2]] }
  show.call('set big') { b.set_at([1], 1 << 40, 0) }
  show.call('splice same') { a = (0..15).to_a; [b.splice_at(a, 4, 8, (100..107).to_a), a] }
  show.call('splice grow') { a = (0..5).to_a; [b.splice_at(a, 2, 2, [:a, :b, :c]), a] }
  show.call('splice shrink') { a = (0..5).to_a; [b.splice_at(a, 1, 3, [:z]), a] }
  show.call('splice past end') { a = (0..5).to_a; [b.splice_at(a, 4, 8, [:p, :q]), a] }
  show.call('splice append') { a = (0..2).to_a; [b.splice_at(a, 5, 1, [:e]), a] }
  show.call('splice neg') { a = (0..5).to_a; [b.splice_at(a, -2, 2, [:m, :n]), a] }
  show.call('splice self') { a = [1, 2, 3, 4]; [b.splice_at(a, 0, 4, a), a] }
  show.call('splice value') { a = [1, 2, 3]; [b.splice_at(a, 1, 1, :v), a] }
  show.call('splice neg len') { b.splice_at([1, 2], 0, -1, [1]) }
  show.call('splice frozen') { b.splice_at([1, 2, 3].freeze, 0, 2, [7, 8]) }
  show.call('splice shared') { a = (1..40).to_a; s = a[2, 30]; b.splice_at(s, 0, 2, [:a, :b]); [s.first(3), a.first(4)] }
  show.call('rotate') { [2, 0, 1, -1, -3, 8, 17, -17].map { |k| b.rotate_by((1..5).to_a, k) } }
  show.call('rotate one') { b.rotate_one([1, 2, 3]) }
  show.call('rotate empty') { [b.rotate_by([], 3), b.rotate_one([])] }
  show.call('rotate float') { b.rotate_by([1, 2, 3], 1.0) }
  show.call('rotate string') { b.rotate_by([1, 2, 3], '1') }
  show.call('rotate frozen') { b.rotate_by([1, 2].freeze, 1) }
  show.call('rotate frozen empty') { b.rotate_by([].freeze, 1) }
  show.call('rotate shared') { a = (1..40).to_a; s = a[2, 30]; b.rotate_by(s, 2); [s.first(2), a.first(4)] }
  show.call('rotate subclass') { b.rotate_by(AwList.new, 3) }
  show.call('tile') { lut = (1..8).to_a; 4.times { |k| b.tile(lut.map { |x| x * (k + 1) }, k) }; b.bg }
  show.call('neq') do
    [[1, 1], [1, 2], [1, 1.0], [1.5, 1], [nil, nil], [nil, 1], ['a', 'a'], ['a', 'b'], [:s, :s], [:s, :t],
     [1 << 62, 1 << 62], [1 << 64, 1 << 64]].map { |x, y| b.neq(x, y) }
  end
  show.call('bit') { [b.bit(5, 0), b.bit(5, 1), b.bit(-1, 70), b.bit(AwBox.new, 3), b.bit([7, 8], 1), b.bit({ 1 => 2 }, 1)] }
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"AWI(#{DRIVER})AWI";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp array write inline check: PASS'
else
  warn "bc2cpp array write inline check: #{failures.size} failure(s)"
  exit 1
end
