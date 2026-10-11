#!/usr/bin/env ruby
# frozen_string_literal: true

# Check EXT_PREFIX (docs/adr/0320): the decoder folds EXT1/EXT2/EXT3 into the instruction they widen, so no pass
# meets a prefix between a producer and its consumer and no iseq is refused just for carrying one.
#
# 1. Host decoder (no mrbc): hand-built iseqs for the operand widths, the address of the folded instruction (the
#    prefix byte), the branch targets computed with the prefix byte in the length, and the two malformed shapes.
# 2. mrbc-compiled sources that force each prefix: the folded listing equals the unfolded one minus its prefix lines,
#    instruction by instruction (op, operands, line, handlers), and no prefix is left.
# 3. Generated code (needs MRBC): a method whose registers pass 255 is compiled instead of dropped, the constant
#    pool of a class body with more than 255 symbols is read, and BC2CPP_EXT_PREFIX=0 gives the earlier output.
# 4. Behaviour on real mruby: compiled answers equal interpreted ones, values and exceptions, for the wide methods.
#    Run it on a full-core and a core-only mruby, and, with BC2CPP_MRUBY_FULL32 and BC2CPP_MRBC32 naming a 32-bit
#    mrb_int build and its mrbc, on that build too.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/ext_prefix_check.rb
# BC2CPP_TOOL names another bc2cpp.rb (scripts/bc2cpp/ext_prefix_mutation_check.rb); the host half then loads that copy.

require 'fileutils'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
TOOLS = ENV['BC2CPP_TOOL'] ? File.dirname(ENV['BC2CPP_TOOL']) : File.join(ROOT, 'tools/bc2cpp')
require File.join(TOOLS, 'irep')
require File.join(TOOLS, 'bytecode_ir')
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The decoder reads ENV at each decode, so a block can pick the form it wants.
with_prefix = lambda do |folded, &block|
  saved = ENV.fetch('BC2CPP_EXT_PREFIX', nil)
  folded ? ENV.delete('BC2CPP_EXT_PREFIX') : ENV['BC2CPP_EXT_PREFIX'] = '0'
  begin
    block.call
  ensure
    saved ? ENV['BC2CPP_EXT_PREFIX'] = saved : ENV.delete('BC2CPP_EXT_PREFIX')
  end
end

# -- 1. host decoder --------------------------------------------------------------------

puts '== decoder on hand-built iseqs'
begin
FakeRite = Struct.new(:iseq, :syms, :lv, :pool, :nlocals, :debug_files)
opcode = ->(name) { InsnDecoder::FORMATS.index { |n, _| n == name } }
u16 = ->(n) { [(n >> 8) & 0xff, n & 0xff] }
build = lambda do |*parts|
  bytes = parts.flatten.map { |p| p.is_a?(String) ? opcode.call(p) : p }
  FakeRite.new(bytes.pack('C*'), Array.new(400) { |i| "s#{i}" }, nil, [], 1,
               [RiteBinary::DebugFile.new(0, 'wide.rb', 2, "\x00\x01".b)])
end
decode = ->(folded, *parts) { with_prefix.call(folded) { InsnDecoder.decode(build.call(*parts)).first } }
values = ->(insn) { insn.typed.map(&:value) }

one = decode.call(true, 'EXT1', 'MOVE', u16.call(300), 5, 'RETURN', 1)
check.call('EXT1 widens the first operand: MOVE R300 R5, then the next instruction at 5',
           one.map(&:op) == %w[MOVE RETURN] && values.call(one[0]) == [300, 5] && one[0].addr == 0 && one[1].addr == 5)
two = decode.call(true, 'EXT2', 'MOVE', 1, u16.call(300), 'RETURN', 1)
check.call('EXT2 widens the second operand', values.call(two[0]) == [1, 300] && two[1].addr == 5)
three = decode.call(true, 'EXT3', 'MOVE', u16.call(300), u16.call(301), 'RETURN', 1)
check.call('EXT3 widens both operands', values.call(three[0]) == [300, 301] && three[1].addr == 6)
lone = decode.call(true, 'EXT1', 'LOADSYM', u16.call(300), 7, 'RETURN', 1)
check.call('EXT1 on LOADSYM names the register, not the symbol', values.call(lone[0]) == [300, 's7'])
sym = decode.call(true, 'EXT2', 'LOADSYM', 3, u16.call(300), 'RETURN', 1)
check.call('EXT2 on LOADSYM names the symbol 300', values.call(sym[0]) == [3, 's300'])
check.call('a folded instruction keeps the line of the widened opcode', one[0].lineno == 1 && one[1].lineno == 1)
check.call('the listing text names the instruction, not the prefix',
           one[0].raw.include?('MOVE') && !one[0].raw.include?('EXT') && one[0].args.start_with?('R300'))

# 0: LOADNIL R1 | 2: EXT1 JMPIF R300 +0 | 8: JMP back to 2 | 11: RETURN R1
jumps = decode.call(true, 'LOADNIL', 1, 'EXT1', 'JMPIF', u16.call(300), u16.call(0), 'JMP', u16.call(0xfff7), 'RETURN', 1)
check.call('a prefixed conditional jump starts at its prefix byte and ends after its widened operand',
           jumps.map(&:addr) == [0, 2, 8, 11] && jumps[1].op == 'JMPIF' && values.call(jumps[1]) == [300, 8])
check.call('a jump back to a prefixed instruction names the prefix byte', jumps[2].branch_target == 2)
program = BytecodeIR::Program.new(Irep.new(label: 'jumps', instructions: jumps))
check.call('BytecodeIR resolves every edge of the folded listing', program.resolved? && program.instruction_at(2).successors == [1])
check.call('the target of a jump onto a prefixed instruction is an instruction start', program.address_to_index.key?(2))

unfolded = decode.call(false, 'LOADNIL', 1, 'EXT1', 'JMPIF', u16.call(300), u16.call(0), 'JMP', u16.call(0xfff7), 'RETURN', 1)
check.call('BC2CPP_EXT_PREFIX=0 keeps the prefix as its own instruction (EXT1 at 2, JMPIF at 3)',
           unfolded.map(&:op) == %w[LOADNIL EXT1 JMPIF JMP RETURN] && unfolded.map(&:addr) == [0, 2, 3, 8, 11] &&
           values.call(unfolded[2]) == [300, 8])

raises = lambda do |pattern, *parts|
  decode.call(true, *parts)
  false
rescue RuntimeError => e
  pattern.match?(e.message)
end
check.call('a prefix that ends the iseq is an error', raises.call(/ends the iseq/, 'LOADNIL', 1, 'EXT1'))
check.call('a prefix after a prefix is an error', raises.call(/follows another prefix/, 'EXT1', 'EXT2', 'MOVE', 1, 1, 1))
rescue StandardError => e
  check.call("hand-built decoding raised #{e.class}: #{e.message.lines.first&.strip}", false)
end

# -- 2. mrbc-compiled sources -----------------------------------------------------------

# Registers past 255 (EXT1/EXT3 on register operands) and a begin/rescue/ensure, a loop and a long run of
# statements, so handler ranges and branch targets sit on prefixed instructions.
LOCALS = 248
wide_method = <<~RUBY
  class WideM
    def big(a)
      #{(0...LOCALS).map { |i| "v#{i} = #{i}" }.join("\n    ")}
      t = [#{(0...130).map { |i| "v#{i}" }.join(', ')}]
      u = [#{(0...300).map { |i| ":y#{i}" }.join(', ')}]
      i = 0
      s = 0
      while i < 5
        s += t[i] + v200
        i += 1
      end
      s + a + t.size + u.size
    end

    def guarded(a)
      #{(0...LOCALS).map { |i| "v#{i} = #{i}" }.join("\n    ")}
      t = [#{(0...130).map { |i| "v#{i}" }.join(', ')}]
      r = 0
      begin
        raise ArgumentError, 'bad' if a > 10
        r = t.size + a
      rescue ArgumentError
        r = -1
      end
      r + v0
    end

    def boom(a)
      #{(0...LOCALS).map { |i| "v#{i} = #{i}" }.join("\n    ")}
      t = [#{(0...130).map { |i| "v#{i}" }.join(', ')}]
      raise 'boom' if a > v#{LOCALS - 1}
      t.size + a
    end
  end
RUBY

# More than 255 symbols and children in one class body: METHOD/DEF/SETCONST/LOADSYM/GETCONST carry EXT2, and a
# constant table is read by methods defined after the 256th.
wide_class = <<~RUBY
  class WideC
    TABLE = [3, 1, 2]
    #{(0...300).map { |i| "def m#{i}; #{i}; end" }.join("\n  ")}
    K300 = 300
    def table_size; TABLE.size; end
    def table_first; TABLE.first; end
    def self.last_m; K300; end
  end
RUBY
WIDE_OWNERS = %w[WideM WideC].freeze
WIDE_SOURCE = wide_method + wide_class

if ENV['MRBC']
  puts '== folded listing equals the unfolded one without its prefix lines'
  Dir.mktmpdir do |dir|
    src = File.join(dir, 'wide.rb')
    File.write(src, WIDE_SOURCE)
    image = run_mrbc([src], 'wide', dir)
    on = with_prefix.call(true) { load_ireps(image).first }
    off = with_prefix.call(false) { load_ireps(image).first }
    ext = %w[EXT1 EXT2 EXT3]
    prefixes = off.values.sum { |irep| irep.instructions.count { |i| ext.include?(i.op) } }
    kinds = ext.to_h { |op| [op, off.values.sum { |irep| irep.instructions.count { |i| i.op == op } }] }
    check.call("the source forces all three prefixes (#{kinds.inspect})", kinds.values.all?(&:positive?))
    check.call('the folded listing has no prefix left', on.values.none? { |irep| irep.instructions.any? { |i| ext.include?(i.op) } })
    check.call("the same irep tree (#{on.size} ireps, #{prefixes} prefixes folded)", on.keys == off.keys)
    same = on.all? do |label, irep|
      rest = []
      pending = nil
      off.fetch(label).instructions.each do |insn|
        if ext.include?(insn.op)
          pending = insn
        else
          rest << [insn, pending&.addr || insn.addr]
          pending = nil
        end
      end
      irep.instructions.size == rest.size && irep.instructions.zip(rest).all? do |got, (want, addr)|
        got.op == want.op && got.typed == want.typed && got.lineno == want.lineno && got.addr == addr &&
          got.args == want.args
      end
    end
    check.call('every instruction keeps its op, operands, args and line; the address is the prefix byte when there is one', same)
    check.call('the catch handlers are the same bytes', on.all? { |label, irep| irep.catch_handlers == off.fetch(label).catch_handlers })
    handler_ok = on.values.all? do |irep|
      starts = irep.instructions.map(&:addr)
      irep.catch_handlers.all? { |h| [h.begin_addr, h.target].all? { |a| starts.include?(a) } && h.end_addr <= irep.instructions.last.addr + 16 }
    end
    check.call('a handler begins and lands on an instruction start of the folded listing', handler_ok)
    check.call('every branch of the folded listing lands on an instruction start',
               on.values.all? { |irep| BytecodeIR.for(irep).resolved? })
    big = on.values.find { |irep| irep.instructions.any? { |i| %w[JMPNOT JMPIF].include?(i.op) && irep.nregs > 256 } }
    check.call('a branch in a method with registers past 255 is one instruction', !big.nil? && BytecodeIR.for(big).resolved?)
    check.call('registers past 255 appear as operands', on.values.any? { |irep| irep.nregs > 256 })
  end
else
  puts '-- SKIP mrbc-compiled listing: set MRBC'
end

# -- 3. generated code ------------------------------------------------------------------

runtime = Bc2cppFixtureRuntime
generate = lambda do |source, dir, folded: true, **options|
  with_prefix.call(folded) { runtime.generate(source, dir, only_owners: WIDE_OWNERS, **options) }
end
body_of = lambda do |code, owner, fn|
  code.scan(/^(?:static )?mrb_value #{owner}_#{fn}(?:_\w*?)?_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
live_of = ->(code, owner, fn) { body_of.call(code, owner, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join }
# A bare by-name dispatch or class test left in the method.
guarded = lambda do |code, owner, fn|
  body = live_of.call(code, owner, fn)
  !body.empty? && (body.include?('bc2cpp_send(') || body.include?('mrb_funcall(') || body.include?('->c == M->'))
end
unguarded = lambda do |code, owner, fn|
  body = live_of.call(code, owner, fn)
  !body.empty? && !body.include?('bc2cpp_send(') && !body.include?('mrb_funcall(') && !body.include?('->c == M->')
end
entries_of = lambda do |err|
  err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0].scan(/\((\w+(?:::\w+)*)#(\S+?),/).map { |o, n| "#{o}##{n}" }
end

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(WIDE_SOURCE, dir)
    entries = entries_of.call(err)
    %w[WideM#big WideM#guarded WideM#boom WideC#table_size WideC#table_first].each do |name|
      check.call("#{name} is compiled", entries.include?(name))
    end
    puts code.scan(/#error.*$/).uniq.first(5) unless entries.include?('WideM#guarded')
    check.call('WideM#big names a register past 255 in its compiled body', live_of.call(code, 'WideM', 'big').match?(/\br(25[6-9]|2[6-9]\d|[3-9]\d\d)\b/))
    check.call('a method of the class body with more than 255 symbols reads its constant table without a class test',
               unguarded.call(code, 'WideC', 'table_size') && unguarded.call(code, 'WideC', 'table_first'))

    Dir.mktmpdir do |off_dir|
      off_code, off_err = generate.call(WIDE_SOURCE, off_dir, folded: false)
      off_entries = entries_of.call(off_err)
      check.call('BC2CPP_EXT_PREFIX=0: the wide methods are dropped as before (the non-vacuity probe)',
                 %w[WideM#big].none? { |name| off_entries.include?(name) })
      check.call('BC2CPP_EXT_PREFIX=0: the constant table keeps its class test', guarded.call(off_code, 'WideC', 'table_size'))
      check.call('the kill switch changes the generated code', off_code != code)
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 4. behaviour -----------------------------------------------------------------------

# [label, build dir, mrbc, compiler flags]; the 32-bit leg needs its own mrbc, and -no-pie because the fallback glue
# keeps a block function's address in an mrb_int (ADR 0271).
builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['full-core', full, ENV.fetch('MRBC', nil), ''] if full
builds << ['core-only', runtime.core, ENV.fetch('MRBC', nil), ''] if runtime.core
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32 (full-core)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie']
end
builds << ['full-core', runtime.full_or_build, ENV.fetch('MRBC', nil), ''] if builds.empty? && runtime.compiler? && runtime.full_or_build
if ENV['MRBC'] && !builds.empty? && runtime.compiler? && !ENV['EXT_PREFIX_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  scenario = <<~CPP
    // 1 when the method is a compiled C function: the wide instruction really ran in compiled code.
    static void cfunc(mrb_state* M, const char* name, mrb_value obj) {
      RClass* cls = mrb_class(M, obj);
      mrb_method_t m = mrb_method_search_vm(M, &cls, mrb_intern_cstr(M, name));
      std::printf("cfunc %s => %d\\n", name, MRB_METHOD_CFUNC_P(m) ? 1 : 0);
    }
    static int scenario(mrb_state* M) {
      mrb_value wide = mrb_obj_new(M, mrb_class_get(M, "WideM"), 0, nullptr);
      mrb_value tab = mrb_obj_new(M, mrb_class_get(M, "WideC"), 0, nullptr);
      mrb_value five = mrb_fixnum_value(5), big = mrb_fixnum_value(1000), twenty = mrb_fixnum_value(20);
      cfunc(M, "big", wide);
      cfunc(M, "guarded", wide);
      cfunc(M, "table_size", tab);
      call(M, "big", wide, "big", 1, &five);
      call(M, "guarded_ok", wide, "guarded", 1, &five);
      call(M, "guarded_rescued", wide, "guarded", 1, &twenty);
      call(M, "boom_ok", wide, "boom", 1, &five);
      call(M, "boom_raises", wide, "boom", 1, &big);
      call(M, "table_size", tab, "table_size");
      call(M, "table_first", tab, "table_first");
      call(M, "m299", tab, "m299");
      call(M, "m7", tab, "m7");
      call(M, "last_m", mrb_obj_value(mrb_class_get(M, "WideC")), "last_m");
      return 0;
    }
  CPP
builds.each do |build_name, build, mrbc, flags|
  full = File.exist?("#{build}/lib/libmruby.a") && build_name != 'core-only'
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS', 'BC2CPP_BLOCK_DIRECT_ENTRY')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if flags.include?('MRB_INT32')
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
  Dir.mktmpdir do |dir|
      _code, err = generate.call(WIDE_SOURCE, dir)
      built, output = runtime.run(dir, err, WIDE_OWNERS, scenario, build: build, full: full)
      check.call("#{build_name}: the fixture compiles and runs against real mruby", built)
      puts output unless built
      next unless built

      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') || l.start_with?('cfunc ') } }
      puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
      check.call("#{build_name}: every method answers what the interpreter answers (#{values.call('interpreted').size} lines), values and exceptions alike",
                 !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
      compiled = sections.fetch('compiled', [])
      interpreted = sections.fetch('interpreted', [])
      check.call("#{build_name}: the wide methods run as compiled C functions, not the interpreter",
                 %w[big guarded table_size].all? { |m| compiled.include?("cfunc #{m} => 1") && interpreted.include?("cfunc #{m} => 0") })
      raised = ->(lines) { lines.find { |l| l.start_with?('boom_raises =>') }.to_s }
      # A core-only mruby (no mrblib) may report another exception class on both sides; the interpreter's own line decides.
      check.call("#{build_name}: a raise from a method with registers past 255 raises, as the interpreter does",
                 raised.call(compiled) == raised.call(interpreted) && raised.call(compiled).include?('raised'))
      # big(5) = (0 + 1 + 2 + 3 + 4) + 5 * v200 + 5 + 130 + 300
      check.call("#{build_name}: the wide loop answers", compiled.include?('big => 1445'))
      check.call("#{build_name}: the rescued wide method answers", compiled.include?('guarded_ok => 135') &&
                                                                                compiled.include?('guarded_rescued => -1'))
      check.call("#{build_name}: the class body's methods and constant answer", compiled.include?('table_size => 3') &&
                                                                                 compiled.include?('m299 => 299') && compiled.include?('last_m => 300'))
    end
    ensure
      %w[MRBC BC2CPP_CXXFLAGS BC2CPP_BLOCK_DIRECT_ENTRY].zip(saved).each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp ext prefix check: PASS'
else
  warn "bc2cpp ext prefix check: #{failures.size} failure(s)"
  exit 1
end
