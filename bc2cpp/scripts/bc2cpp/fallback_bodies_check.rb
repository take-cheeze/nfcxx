#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks for the bc2cpp shapes that used to stay on the interpreter:
#
#   JMPUW_RESCUE_SUPPORT   a `break` inside a rescue/ensure region
#   RESCUE_JOIN_RETURN     `begin ... rescue ... end; out` (join RETURN of another register)
#   RESCUE_LIVE_OUT        locals a rescue try body writes reach the handler and the join
#   RESCUE_YIELD_SUPPORT   `yield` inside a protected range
#   LOADL_BIGINT           an integer literal past int32
#   TIMES_NO_PARAM_SUPPORT `n.times { ... }` with no block parameter
#
# Part 1 runs under plain CRuby over hand-built ireps. Part 2 needs a host mrbc
# (MRBC) and, for the compiled-vs-interpreted comparison, a libmruby_core.a with
# include/ (BC2CPP_MRUBY_CORE); it SKIPs what it lacks, like the other bc2cpp
# checks.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/fallback_bodies_check.rb

require 'open3'
require 'rbconfig'
require 'set'
require 'tmpdir'
# The fixture program defines none of the engine's classes, which sig/bc2cpp/declarations.rbs declares, so the
# shipped signatures would all be unusable (TC1003). Checked against no signature world, as block_iterator_direct_check does.
ENV['BC2CPP_SIG_DIRS'] = ''

require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'fixture_runtime'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/closed_world_env'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

# ---------------------------------------------------------------------------
# Part 1: hand-built ireps.
# ---------------------------------------------------------------------------
gen0 = CodeGen.allocate

# JMPUW is a branch for the region recognizers: a `break` leaving a try body is
# a boundary breach, one landing on the exit JMP is not.
inside = Irep.new(label: 'a', instructions: [
                    insn(0, 'LOADNIL', 'R1 (nil)'), insn(1, 'JMPUW', '6'), insn(4, 'LOADNIL', 'R1 (nil)'),
                    insn(5, 'NOP', ''), insn(6, 'JMP', '10'), insn(9, 'NOP', ''), insn(10, 'RETURN', 'R1')
                  ])
check.call('JMPUW to the exit JMP stays inside the region',
           BytecodeIR::Program.new(inside).region_boundary_breaches(0...6, 6).empty?)
leaving = Irep.new(label: 'b', instructions: [
                     insn(0, 'LOADNIL', 'R1 (nil)'), insn(1, 'JMPUW', '10'), insn(4, 'NOP', ''),
                     insn(6, 'JMP', '10'), insn(10, 'RETURN', 'R1')
                   ])
check.call('JMPUW out of the region is a breach',
           BytecodeIR::Program.new(leaving).region_boundary_breaches(0...6, 6).map(&:src) == [1])

# jmpuw_plain_jump_at?: only an ENSURE handler that covers the JMPUW and whose
# range the target leaves can intercept it (vm.c OP_JMPUW).
handler = ->(type, b, e) { CatchHandler.new(type: type, begin_addr: b, end_addr: e, target: e) }
jmp = insn(10, 'JMPUW', '20')
with = lambda do |handlers, ins = jmp|
  irep = Irep.new(label: 'h', instructions: [ins], catch_handlers: handlers)
  gen0.jmpuw_plain_jump_at?(irep, ins)
end
check.call('no handlers: plain', with.call([]))
check.call('a rescue handler never intercepts', with.call([handler.call(:rescue, 0, 30)]))
check.call('an ensure covering the JMPUW with a target inside its range: plain',
           with.call([handler.call(:ensure, 0, 30)]))
check.call('an ensure covering the JMPUW with the target on its end: plain',
           with.call([handler.call(:ensure, 0, 20)]))
check.call('an ensure covering the JMPUW with the target outside its range: unwinds',
           !with.call([handler.call(:ensure, 0, 15)]))
check.call('an ensure that does not cover the JMPUW: plain', with.call([handler.call(:ensure, 12, 15)]))
check.call('a covering ensure that the target leaves wins over a plain rescue',
           !with.call([handler.call(:rescue, 0, 30), handler.call(:ensure, 0, 15)]))

# rescue_insn_written_regs: leading-operand writers, reads-only ops, and an
# unmodelled op (nil, so every local is aliased).
check.call('MOVE writes its destination', gen0.rescue_insn_written_regs(insn(0, 'MOVE', "R3\tR1")) == ['3'])
check.call('JMPIF writes nothing', gen0.rescue_insn_written_regs(insn(0, 'JMPIF', "R3\t9")) == [])
check.call('JMPUW writes nothing', gen0.rescue_insn_written_regs(insn(0, 'JMPUW', '9')) == [])
check.call('RESCUE writes its second operand', gen0.rescue_insn_written_regs(insn(0, 'RESCUE', "R3\tR4")) == ['4'])
check.call('EXCEPT writes its operand', gen0.rescue_insn_written_regs(insn(0, 'EXCEPT', 'R3')) == ['3'])
check.call('an unmodelled op is nil', gen0.rescue_insn_written_regs(insn(0, 'ARGARY', "R3\t1:0:0:0")).nil?)

# LOADL_BIGINT: the pool entry carries the base and digits mruby's OP_LOADL uses.
[["\n4294967296", 10, '4294967296'], ["\xf0100000000".b, -16, '100000000']].each do |bytes, base, digits|
  entry = irep_pool_entry(RiteBinary::PoolEntry.new(:bigint, bytes))
  check.call("bigint pool entry #{base}:#{digits}", entry[:type] == :bigint && entry[:base] == base && entry[:digits] == digits)
end

# ---------------------------------------------------------------------------
# Part 2: compiled fixture (needs mrbc).
# ---------------------------------------------------------------------------
SOURCE = <<~'RUBY'
  class Fb
    def big
      0x1_0000_0000
    end

    def neg
      -0x1_0000_0000
    end

    def masked(x)
      x & 0x000f_ffff_ffff_ffff
    end

    # `break` inside a rescue region, joining on a RETURN of another register.
    def scan(list)
      out = []
      begin
        i = 0
        until i >= list.size
          break if list[i] == 0
          out << list[i]
          i += 1
        end
      rescue StopIteration => e
        e.result
      end
      out
    end

    # The handler reads a local the try body assigned.
    def handler_sees(x)
      name = 'init'
      begin
        name = x.to_s
        raise ArgumentError, 'boom' if x == 1
        name + '!'
      rescue ArgumentError => e
        name + ':' + e.message
      end
    end

    # The code after the region reads a local the try body assigned.
    def after_use(x)
      y = 1
      begin
        y = x.succ
        raise ArgumentError, 'boom' if x == 1
      rescue ArgumentError
        nil
      end
      y + 1
    end

    def guard(default)
      yield
    rescue ArgumentError => e
      default
    end

    def count(n)
      c = 0
      n.times { c += 2 }
      c
    end

    def nested_times(n)
      s = 0
      n.times { n.times { s += 1 } }
      s
    end

    # R1 of a parameterless block is one of its locals: it starts nil each pass.
    def times_local(n)
      s = 0
      n.times do
        t = (t || 0) + 5
        s += t
      end
      s
    end

    def ens_break(n)
      log = []
      i = 0
      begin
        while i < n
          i += 1
          break if i == 3
        end
      ensure
        log << :done
      end
      [i, log]
    end

    # A rescue inside a block body (BLOCK_FALLBACK): the handler reads a block local.
    def block_rescue(list)
      out = []
      list.each do |x|
        begin
          seen = x.to_s
          raise ArgumentError, 'b' if x == 2
          out << seen
        rescue ArgumentError => e
          out << (seen + '?' + e.message)
        end
      end
      out
    end

    # A rescue nested in another one's body: an inner write reaches the outer handler.
    def nested_rescue(x)
      a = 'a'
      begin
        a = 'b'
        begin
          a = x.to_s
          raise ArgumentError, 'inner' if x == 1
        rescue TypeError
          a = 'never'
        end
        a
      rescue ArgumentError => e
        a + e.message
      end
    end

    # `next` leaves the ensure region: the unwind must run the ensure body.
    def ens_out(n)
      r = []
      i = 0
      while i < n
        i += 1
        begin
          next if i == 2
          r << i
        ensure
          r << :e
        end
      end
      r
    end
  end
RUBY

# The bare core has no mrblib: give the interpreted twin the two methods it lacks.
# (A NoMethodError cannot be built there, so no case may reach a missing method.)
DRIVER = <<~'RUBY'
  class Integer
    def times
      i = 0
      while i < self
        yield i
        i += 1
      end
      self
    end

    def succ
      self + 1
    end
  end

  class Array
    def each
      i = 0
      while i < size
        yield self[i]
        i += 1
      end
      self
    end
  end

  def outcome
    [:ok, yield.inspect]
  rescue Exception => e
    [:err, e.class.to_s, e.message]
  end

  bad = []
  cases = [
    [:big, []], [:neg, []], [:masked, [-1]], [:masked, [0x7fff_ffff]],
    [:scan, [[3, 4, 0, 5]]], [:scan, [[]]], [:scan, [[1, 2]]],
    [:handler_sees, [1]], [:handler_sees, [2]],
    [:after_use, [1]], [:after_use, [2]],
    [:count, [0]], [:count, [4]], [:nested_times, [3]], [:times_local, [3]], [:times_local, [0]],
    [:ens_break, [10]], [:ens_break, [2]], [:ens_out, [4]],
    [:block_rescue, [[1, 2, 3]]], [:nested_rescue, [1]], [:nested_rescue, [2]]
  ]
  # The bare core has no Array#each: plain loops only.
  i = 0
  while i < cases.size
    name, args = cases[i]
    got = outcome { Fb.new.__send__(name, *args) }
    want = outcome { FbRef.new.__send__(name, *args) }
    bad << "#{name}#{args.inspect}: compiled #{got.inspect}, interpreted #{want.inspect}" unless got == want
    i += 1
  end
  # No Kernel#proc in the bare core either: the block cases use literal blocks.
  guards = [
    ['value', outcome { Fb.new.guard(7) { 5 } }, outcome { FbRef.new.guard(7) { 5 } }],
    ['rescued', outcome { Fb.new.guard(7) { raise ArgumentError, 'x' } },
     outcome { FbRef.new.guard(7) { raise ArgumentError, 'x' } }],
    ['passes', outcome { Fb.new.guard(7) { raise TypeError, 't' } },
     outcome { FbRef.new.guard(7) { raise TypeError, 't' } }]
  ]
  i = 0
  while i < guards.size
    label, got, want = guards[i]
    bad << "guard(#{label}): compiled #{got.inspect}, interpreted #{want.inspect}" unless got == want
    i += 1
  end
  raise bad.join("\n") unless bad.empty?
RUBY

FIXTURE_METHODS = %w[big neg masked scan handler_sees after_use guard count nested_times times_local ens_break
                     block_rescue nested_rescue].freeze

# The fixture is compiled in the block-core world (core: true): the `times` inlining the checks name needs the compiled
# core Integer#times, which a bare fixture CodeGen does not have. A method's helpers (block fallbacks, rescue
# bodies) are emitted before its header, so each top-level C++ block goes to the method its first code line names.
def fixture(source)
  Dir.mktmpdir do |dir|
    code, = Bc2cppFixtureRuntime.generate(source, dir, core: true, only_owners: %w[Fb], skip_unsupported: false)
    names = code.scan(%r{^// Fb#(\S+) \(compiled from irep}).flatten.uniq
    codes = names.to_h { |name| [name, +''] }
    # The symbol table the closed world names symbols by (bc2cpp_sym(M, i) is names[i]).
    symbols = code[/bc2cpp_sym_names\[\d+\] = \{(.*?)\};/m, 1].to_s.scan(/"([^"]*)"/).flatten
    top_level_blocks(code).each do |block|
      first = block.each_line.find { |line| !line.start_with?('//') && !line.strip.empty? }.to_s
      owner = names.select { |name| first.match?(/\bFb_#{Regexp.escape(name)}(?![A-Za-z0-9])/) }.max_by(&:length)
      codes[owner] << block if owner
    end
    yield codes, symbols
  end
end

# The file cut before each column-0 line that starts a new definition at brace depth 0.
def top_level_blocks(code)
  blocks = []
  current = []
  depth = 0
  code.each_line do |line|
    if depth.zero? && line.match?(/\A[^\s\/}]/) && current.any? { |l| l.match?(/\A[^\s\/]/) }
      blocks << current.join
      current = []
    end
    current << line
    depth += line.count('{') - line.count('}')
  end
  blocks << current.join
end

mrbc = ENV['MRBC'] || 'mrbc'
if system(mrbc, '--version', out: File::NULL, err: File::NULL) || system(mrbc, '-h', out: File::NULL, err: File::NULL)
  fixture(SOURCE) do |code, symbols|
    FIXTURE_METHODS.each do |name|
      check.call("#{name} compiles with no #error", !code.fetch(name).include?('#error'))
    end
    check.call('an ensure-leaving JMPUW keeps `#error`', code.fetch('ens_out').include?('#error unhandled opcode JMPUW'))
    check.call('a positive bigint literal is rebuilt from its digits',
               code.fetch('big').include?('mrb_bint_new_str(M, "100000000", 9, 16)') &&
                 code.fetch('big').include?('#ifdef MRB_USE_BIGINT'))
    check.call('a negative bigint literal keeps its sign in the base', code.fetch('neg').include?('"100000000", 9, -16)'))
    range_error = symbols.index('RangeError')
    check.call('the bigint fallback raises the VM RangeError',
               range_error && code.fetch('big').include?("mrb_exc_get_id(M, bc2cpp_sym(M, #{range_error})), \"integer overflow\""))
    check.call('a body writing a local aliases it in the try body',
               code.fetch('after_use').include?('mrb_value& r') && code.fetch('after_use').include?('&r'))
    check.call('the handler-visible local is aliased too', code.fetch('handler_sees').include?('mrb_value& r'))
    check.call('a rescue inside a block body aliases its local', code.fetch('block_rescue').include?('mrb_value& r'))
    check.call('a nested rescue passes the alias down', code.fetch('nested_rescue').include?('_nested'))
    check.call('a rescue join on RETURN of another register is a real region', code.fetch('scan').include?('_rescue_try'))
    check.call('the block reaches the try body of a yielding method', code.fetch('guard').include?('bc2cpp_blk'))
    # GUARDED_BLOCK_INLINE: an Integer receiver runs the inline loop, and the block fallback is only the other-receiver
    # arm, emitted after the inline arm's jump to the guarded end.
    count = code.fetch('count')
    check.call('a parameterless times block is inlined',
               count.include?('Lbc2cpp_times_iter_') &&
               (!count.include?('BLOCK_FALLBACK') || count.index('BLOCK_FALLBACK') > count.index('goto Lbc2cpp_guarded_end')))
    check.call('a parameterless times block binds no counter',
               !code.fetch('count').match?(/= mrb_fixnum_value\(bc2cpp_times_i_/))
  end
  fixture("class Fb\n def t(n); s = 0; n.times { |i| s += i }; s; end\nend\n") do |code|
    check.call('a one-parameter times block still binds the counter',
               code.fetch('t').match?(/= mrb_fixnum_value\(bc2cpp_times_i_/))
  end

  core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |candidate|
    File.exist?(File.join(candidate, 'lib/libmruby_core.a')) && File.directory?(File.join(candidate, 'include'))
  end
  if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
    puts '  SKIP compiled-vs-interpreted comparison: set BC2CPP_MRUBY_CORE to a host mruby core directory'
  else
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'fb.rb')
      ref = File.join(dir, 'fb_ref.rb')
      driver = File.join(dir, 'driver.rb')
      File.write(src, SOURCE)
      File.write(ref, SOURCE.sub('class Fb', 'class FbRef'))
      File.write(driver, DRIVER)
      mrbs = { src => 'fb.mrb', ref => 'fb_ref.mrb', driver => 'driver.mrb' }.map do |from, to|
        out = File.join(dir, to)
        abort "mrbc failed for #{from}" unless system(mrbc, '-o', out, from)
        out
      end

      env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'bc2cpp_fb', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
              'BC2CPP_SELF_REGISTERING' => '1' }
      out, err, status = Open3.capture3(bc2cpp_closed_world_probe_env(env), RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', src,
                                        chdir: ROOT)
      abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?
      File.write(File.join(dir, 'fb_gen.cpp'), out)
      registrations = FIXTURE_METHODS.map do |name|
        %(mrb_define_method(M, cls, "#{name}", Fb_#{name}, MRB_ARGS_ANY());)
      end
      File.write(File.join(dir, 'main.cpp'), <<~CPP)
        #include <mruby.h>
        #include <mruby/irep.h>
        #include <cstdio>
        #include <fstream>
        #include <iterator>
        #include <vector>
        extern "C" void mrb_init_mrblib(mrb_state*) {}
        #include "fb_gen.cpp"

        int main(int argc, char** argv) {
          mrb_state* M = mrb_open_core();
          for (int i = 1; i < argc; ++i) {
            std::ifstream in(argv[i], std::ios::binary);
            std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            if (i == argc - 1) {
              bc2cpp_set_instance_tts(M);
              RClass* cls = mrb_class_get(M, "Fb");
              #{registrations.join("\n      ")}
            }
            mrb_load_irep_buf(M, bin.data(), bin.size());
            if (M->exc) { mrb_print_error(M); return 2; }
          }
          mrb_close(M);
          return 0;
        }
      CPP
      # The bigint arm needs a core built with mruby-bigint (its `-DMRB_USE_BIGINT`).
      bigint = `nm -g #{core}/lib/libmruby_core.a 2>/dev/null`.include?('mrb_bint_new_str')
      binary = File.join(dir, 'fb')
      flags = bigint ? ['-DMRB_USE_BIGINT'] : []
      built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w', *flags,
                     "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", File.join(dir, 'main.cpp'),
                     "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
      check.call('the fixture compiles against real mruby', built)
      if built
        output = IO.popen([binary, *mrbs], err: %i[child out], &:read)
        puts output.lines.map { |l| "    #{l}" }.join
        check.call("compiled bodies match the interpreter (#{bigint ? 'bigint core' : 'no-bigint core: RangeError arm'})",
                   $?.success?)
      end
    end
  end
else
  puts '  SKIP compiled-fixture checks: no mrbc (set MRBC)'
end

if failures.empty?
  puts 'bc2cpp fallback bodies check: PASS'
else
  warn "bc2cpp fallback bodies check: #{failures.size} failure(s)"
  exit 1
end
