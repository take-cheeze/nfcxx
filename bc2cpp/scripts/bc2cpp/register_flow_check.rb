#!/usr/bin/env ruby
# frozen_string_literal: true

# REGISTER_FLOW: copy propagation and dead register-write
# removal over emitted instruction texts. Hand-built ireps with fixed answers
# (what is dropped, what is rewritten, every refusal), then a generated fixture
# whose output must shrink with the pass on and keep its dead lines with the
# kill switch BC2CPP_REGISTER_FLOW=0, and, when a patched mruby core is
# available (BC2CPP_MRUBY_CORE), an interpreted-vs-compiled differential run.
# Without MRBC only the hand-built shapes run (host-only CI job).
# The fixture program defines none of the engine's classes, which sig/bc2cpp/declarations.rbs declares, so the
# shipped signatures would all be unusable (TC1003). Checked against no signature world, as block_iterator_direct_check does.
ENV['BC2CPP_SIG_DIRS'] = ''

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/irep_arity'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/register_flow'
require_relative '../../tools/bc2cpp/codegen_method'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/closed_world_env'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

ENV.delete('BC2CPP_REGISTER_FLOW_WINDOWS')

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def flow(list, texts, handlers: [], captured: Set.new, model: nil)
  irep = Irep.new(label: 't', instructions: list, catch_handlers: handlers)
  RegisterFlow.optimize(irep, texts, captured, handlers: model)
end

def rescue_handler(begin_addr, end_addr, target)
  CatchHandler.new(type: :rescue, begin_addr: begin_addr, end_addr: end_addr, target: target)
end

# The codegen model for one top-level region whose glue sits at begin_addr.
def rescue_model(begin_addr, end_addr, target, reads: [])
  { regions: [{ begin_addr: begin_addr, end_addr: end_addr, except_addr: target }],
    glue_reads: { begin_addr => reads } }
end

puts '-- unused-register declarations'
generator = CodeGen.allocate
prune_before = lambda do |code, declarations|
  uses = code.scan(/\br\d+\b/).tally
  code[declarations] = code[declarations].gsub(/^  mrb_value (r\d+) = mrb_nil_value\(\);\n/) do |declaration|
    uses.fetch(Regexp.last_match(1)) == 1 ? '' : declaration
  end
  code
end
prune_random = Random.new(20261019)
register_names = %w[r0 r1 r01 r00 r3 r7 r63 r255 r10000000000000000000000000000001]
mention_tokens = register_names + %w[ar1 r1x _r1 r1_ r3.r7 &r63] + ['日本語r1', 'r1日本語', '"r1"', '// r3']
prune_cases = Array.new(1000) do
  declarations = register_names.sample(prune_random.rand(1..register_names.size), random: prune_random)
                               .map { |name| "  mrb_value #{name} = mrb_nil_value();\n" }.join
  text = declarations + Array.new(prune_random.rand(0..50)) { mention_tokens.sample(random: prune_random) }.join(' ')
  [text, 0...declarations.size]
end
check.call('streamed counts preserve pruning, word boundaries, leading zeros and unbounded indices',
           prune_cases.all? do |text, declarations|
             generator.drop_unused_nil_registers(text.dup, declarations) == prune_before.call(text.dup, declarations)
           end)

puts '-- register mention masks'
scanner = RegisterFlow.allocate
samples = ['', 'r1 + r1 + r01', 'r0 + r63 + r127 + r255',
           'ar1 r2x _r3 r4_ r5.r6 // r7 "r8"', "r9\nr10\tr11"]
random = Random.new(415)
tokens = %w[r0 r1 r01 r63 r127 r255 ar1 r2x _r3 r4_ + ; //]
500.times { samples << Array.new(random.rand(1..30)) { tokens.sample(random: random) }.join(' ') }
check.call('streamed masks preserve duplicate, wide and conservative textual mentions', samples.all? do |text|
  expected = text.scan(RegisterFlow::MENTION).flatten.map(&:to_i).uniq.sum { |reg| 1 << reg }
  scanner.send(:mention_mask, text) == expected
end)

puts '-- hand-built shapes'
# t = a; t = b; return t
list = [insn(0, 'MOVE', "R3\tR1"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')]
texts = ["  r3 = r1;\n", "  r3 = r2;\n", "  return r3;\n"]
check.call('an overwritten MOVE is dropped and the survivor propagated', flow(list, texts) == ['', '', "  return r2;\n"])
wide = [insn(0, 'MOVE', "R3\tR1"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'ADDI', "R4\tR3\t1")]
wide_texts = ["  r3 = r1;\n", "  r3 = r2;\n", "  r4 = bc2cpp_add1(r3);\n"]
check.call('an overwritten MOVE read next by a window op is dropped, the other kept',
           flow(wide, wide_texts) == ['', "  r3 = r2;\n", "  r4 = bc2cpp_add1(r3);\n"])
check.call('a pinned (captured) register keeps its write', flow(list, texts, captured: Set[3]) == texts)
check.call('an address-taken register keeps its write',
           flow(list, ["  r3 = r1;\n", "  r3 = r2;\n", "  return bc2cpp_f(&r3);\n"]) ==
             ["  r3 = r1;\n", "  r3 = r2;\n", "  return bc2cpp_f(&r3);\n"])
check.call('a register redeclared inside a text is pinned',
           flow(list, ["  r3 = r1;\n", "  r3 = r2;\n", "  { mrb_value r3 = r1; return r3; }\n"]).first == "  r3 = r1;\n")
check.call('r0 is never dropped', flow([insn(0, 'LOADSELF', 'R0'), insn(2, 'RETNIL', '')],
                                       ["  r0 = self;\n", "  return mrb_nil_value();\n"]).first == "  r0 = self;\n")

# b = a; return b  -> return a, and the copy is gone
list = [insn(0, 'MOVE', "R3\tR1"), insn(2, 'RETURN', 'R3')]
check.call('a copy read by one RETURN is propagated and dropped',
           flow(list, ["  r3 = r1;\n", "  return r3;\n"]) == ['', "  return r1;\n"])
check.call('a read of the copy by a window consumer keeps the copy',
           flow([insn(0, 'MOVE', "R4\tR1"), insn(2, 'SEND', "R3\t:f\t1"), insn(4, 'RETURN', 'R3')],
                ["  r4 = r1;\n", "  r3 = bc2cpp_send(M, r3, 1, 1, r4);\n", "  return r3;\n"]) ==
             ["  r4 = r1;\n", "  r3 = bc2cpp_send(M, r3, 1, 1, r4);\n", "  return r3;\n"])
check.call('the source overwritten before the read keeps the copy',
           flow([insn(0, 'MOVE', "R3\tR1"), insn(2, 'LOADI_5', 'R1 (5)'), insn(4, 'RETURN', 'R3')],
                ["  r3 = r1;\n", "  r1 = mrb_fixnum_value(5);\n", "  return r3;\n"]) ==
             ["  r3 = r1;\n", '', "  return r3;\n"])
check.call('a source captured by a block is never substituted',
           flow(list, ["  r3 = r1;\n", "  return r3;\n"], captured: Set[1]) == ["  r3 = r1;\n", "  return r3;\n"])

# if c then x = a end; return x   (the copy is not on every path)
join = [insn(0, 'JMPNOT', "R1\t8"), insn(3, 'MOVE', "R3\tR2"), insn(5, 'JMP', '8'), insn(8, 'RETURN', 'R3')]
join_texts = ["  if (!mrb_test(r1)) goto L8;\n", "  r3 = r2;\n", "  goto L8;\n", "  return r3;\n"]
check.call('a copy missing on one path to the read is kept', flow(join, join_texts) == join_texts)
check.call('a write live on one branch survives', flow([insn(0, 'LOADNIL', 'R3'), insn(2, 'JMPNOT', "R1\t8"),
                                                        insn(5, 'LOADI_1', 'R3 (1)'), insn(7, 'NOP', ''),
                                                        insn(8, 'RETURN', 'R3')],
                                                       ["  r3 = mrb_nil_value();\n", "  if (!mrb_test(r1)) goto L8;\n",
                                                        "  r3 = mrb_fixnum_value(1);\n", '', "  return r3;\n"]).first ==
                                                       "  r3 = mrb_nil_value();\n")

# Loop: the write before the loop is read on the next iteration.
loop_list = [insn(0, 'LOADNIL', 'R3'), insn(2, 'MOVE', "R4\tR3"), insn(4, 'LOADI_1', 'R3 (1)'),
             insn(6, 'JMPIF', "R1\t2"), insn(9, 'RETURN', 'R4')]
loop_texts = ["  r3 = mrb_nil_value();\n", "  r4 = r3;\n", "  r3 = mrb_fixnum_value(1);\n",
              "  if (mrb_test(r1)) goto L2;\n", "  return r4;\n"]
loop_out = flow(loop_list, loop_texts)
check.call('a loop-carried value is not dropped', loop_out[0] == loop_texts[0] && loop_out[1] != '')

check.call('a method with a catch handler is untouched',
           flow(list, texts, handlers: [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 4, target: 4)]) == texts)

puts '-- catch handlers (the rescue model, REGISTER_FLOW handler edges)'
# 0 r3 = r1; 2 glue (protects [2, 4)); 4 goto 8; 6 EXCEPT (its text is empty: the glue
# runs the handler); 7 the clause reads r3; 8 returns r4.
rescue_list = [insn(0, 'MOVE', "R3\tR1"), insn(2, 'SEND', "R4\t:try\t0"), insn(4, 'JMP', '8'),
               insn(6, 'EXCEPT', 'R5'), insn(7, 'RETURN', 'R3'), insn(8, 'RETURN', 'R4')]
rescue_texts = ["  r3 = r1;\n", "  r4 = bc2cpp_try(r1);\n", "  goto L8;\n", '', "  return r3;\n", "  return r4;\n"]
rescue_on = flow(rescue_list, rescue_texts, handlers: [rescue_handler(2, 4, 6)], model: rescue_model(2, 4, 6))
check.call('a copy read only by a handler clause is propagated through the handler edge',
           rescue_on == ['', rescue_texts[1], rescue_texts[2], '', "  return r1;\n", "  return r4;\n"])
check.call('the same shape without the handler model is refused', flow(rescue_list, rescue_texts,
                                                                          handlers: [rescue_handler(2, 4, 6)]) == rescue_texts)

# The glue writes r3 on the normal path only: a handler raised before the write
# still reads the old r3, so the write before the glue stays live.
kill_list = [insn(0, 'MOVE', "R3\tR2"), insn(2, 'MOVE', "R3\tR1"), insn(4, 'JMP', '8'),
             insn(6, 'EXCEPT', 'R5'), insn(7, 'RETURN', 'R3'), insn(8, 'RETURN', 'R3')]
kill_texts = ["  r3 = r2;\n", "  r3 = bc2cpp_try(r1);\n", "  goto L8;\n", '', "  return r3;\n", "  return r3;\n"]
kill_model = rescue_model(2, 4, 6)
check.call('a write the glue kills on the normal path stays live for its handler',
           flow(kill_list, kill_texts, handlers: [rescue_handler(2, 4, 6)], model: kill_model) == kill_texts)
dead_texts = kill_texts.dup
dead_texts[4] = "  return r2;\n"
check.call('the same write is dropped when no handler reads it',
           flow(kill_list, dead_texts, handlers: [rescue_handler(2, 4, 6)], model: kill_model) ==
             ['', kill_texts[1], kill_texts[2], '', "  return r2;\n", "  return r3;\n"])

# Each refusal leaves the texts untouched.
refused = lambda do |label, reason, texts, handlers, model|
  before = RegisterFlow::Stats["refused #{reason}"]
  out = flow(rescue_list, texts, handlers: handlers, model: model)
  check.call(label, out == texts && RegisterFlow::Stats["refused #{reason}"] == before + 1)
end
refused.call('a glue that does not name a register its try body reads is refused', 'handlers',
             rescue_texts, [rescue_handler(2, 4, 6)], rescue_model(2, 4, 6, reads: [7]))
refused.call('a handler no codegen region describes is refused', 'handlers',
             rescue_texts, [rescue_handler(2, 4, 6)], { regions: [], glue_reads: {} })
refused.call('a region whose target differs from the handler is refused', 'handlers',
             rescue_texts, [rescue_handler(2, 4, 6)], rescue_model(2, 4, 5))
refused.call('an unresolved handler target is refused', 'handlers',
             rescue_texts, [rescue_handler(2, 4, 99)], rescue_model(2, 4, 99))
goto_texts = rescue_texts.dup
goto_texts[2] = "  goto L6;\n"
refused.call('a goto to an address the normal flow does not reach is still refused', 'goto',
             goto_texts, [rescue_handler(2, 4, 6)], rescue_model(2, 4, 6))
# A non-glue instruction inside the protected range would be a handler edge the
# outer C++ does not run, so the method is refused.
protected_list = [insn(0, 'MOVE', "R3\tR1"), insn(2, 'SEND', "R4\t:try\t0"), insn(4, 'MOVE', "R6\tR1"),
                  insn(6, 'RETURN', 'R4'), insn(7, 'EXCEPT', 'R5'), insn(8, 'RETURN', 'R3')]
protected_texts = ["  r3 = r1;\n", "  r4 = bc2cpp_try(r1);\n", "  r6 = r1;\n", "  return r4;\n", '', "  return r3;\n"]
before = RegisterFlow::Stats['refused handlers']
check.call('a text inside the protected range that is not the glue is refused',
           flow(protected_list, protected_texts, handlers: [rescue_handler(2, 7, 7)], model: rescue_model(2, 7, 7)) ==
             protected_texts && RegisterFlow::Stats['refused handlers'] == before + 1)
check.call('no model passed for a handler method is refused as before',
           flow(rescue_list, rescue_texts, handlers: [rescue_handler(2, 4, 6)]) == rescue_texts)
ENV['BC2CPP_REGISTER_FLOW_HANDLERS'] = '0'
check.call('the handler kill switch refuses the modelled method',
           flow(rescue_list, rescue_texts, handlers: [rescue_handler(2, 4, 6)], model: rescue_model(2, 4, 6)) == rescue_texts)
ENV.delete('BC2CPP_REGISTER_FLOW_HANDLERS')
ENV['BC2CPP_REGISTER_FLOW_WINDOWS'] = '1'
check.call('window mode keeps refusing handler methods (the model widens only the default pass)',
           flow(rescue_list, rescue_texts, handlers: [rescue_handler(2, 4, 6)], model: rescue_model(2, 4, 6)) == rescue_texts)
ENV.delete('BC2CPP_REGISTER_FLOW_WINDOWS')
check.call('an unresolved branch target leaves the texts alone',
           flow([insn(0, 'JMP', '99'), insn(2, 'RETURN', 'R3')], ["  goto L99;\n", "  return r3;\n"]) ==
             ["  goto L99;\n", "  return r3;\n"])
check.call('a goto the IR does not allow refuses the method',
           flow(list, ["  r3 = r1;\n  goto L4;\n", "  r3 = r2;\n", "  return r3;\n"]) ==
             ["  r3 = r1;\n  goto L4;\n", "  r3 = r2;\n", "  return r3;\n"])
check.call('a terminator whose text falls through refuses the method',
           flow(list, ["  r3 = r1;\n", "  r3 = r2;\n", "  (void)r3;\n"]) == ["  r3 = r1;\n", "  r3 = r2;\n", "  (void)r3;\n"])
check.call('a reference alias refuses the method',
           flow(list, ["  r3 = r1;\n", "  mrb_value& r5 = r3;\n", "  return r3;\n"]).first == "  r3 = r1;\n")
skipped = flow([insn(0, 'MOVE', "R3\tR1"), insn(2, 'JMP', '6'), insn(4, 'RETURN', 'R3'), insn(6, 'LOADNIL', 'R3'),
                insn(8, 'RETURN', 'R3')],
               ["  r3 = r1;\n", '', "  return r3;\n", "  r3 = mrb_nil_value();\n", "  return r3;\n"])
check.call('a suppressed JMP does not hide the fall-through into the next text',
           skipped[0] == "  r3 = r1;\n" || skipped[2] == "  return r1;\n")

# def f(a, b = 1) style table: ENTER, the first table JMP is the switch over the
# default-value targets (addrs 3 and 4), the second table JMP is suppressed.
dispatch_list = [insn(0, 'ENTER', "0:1:0:0:0:0:0:0\t(0x0)"), insn(1, 'JMP', '3'), insn(2, 'JMP', '4'),
                 insn(3, 'MOVE', "R3\tR1"), insn(4, 'MOVE', "R3\tR2"), insn(5, 'RETURN', 'R3')]
switch_text = RegisterFlow.dispatch_text([3, 4])
dispatch_texts = ["  // ENTER\n", switch_text, '', "  r3 = r1;\n", "  r3 = r2;\n", "  return r3;\n"]
check.call('the switch text is the one codegen emits',
           switch_text == "  switch (bc2cpp_given_opt) {\n    case 0: goto L3;\n    default: goto L4;\n  }\n")
check.call('an optional-argument switch reaches its default targets: the overwritten write and the copy go',
           flow(dispatch_list, dispatch_texts) == ["  // ENTER\n", switch_text, '', '', '', "  return r2;\n"])
wrong_switch = ["  // ENTER\n", RegisterFlow.dispatch_text([3, 9]), '', "  r3 = r1;\n", "  r3 = r2;\n", "  return r3;\n"]
check.call('a switch naming a target the table does not have refuses the method',
           flow(dispatch_list, wrong_switch) == wrong_switch)
emitting_entry = ["  // ENTER\n", switch_text, "  r5 = r1;\n", "  r3 = r1;\n", "  r3 = r2;\n", "  return r3;\n"]
check.call('a table entry that emitted code refuses the method',
           flow(dispatch_list, emitting_entry) == emitting_entry)
ENV['BC2CPP_REGISTER_FLOW_GOTO'] = '0'
check.call('BC2CPP_REGISTER_FLOW_GOTO=0 refuses the switch method again',
           flow(dispatch_list, dispatch_texts) == dispatch_texts)
ENV.delete('BC2CPP_REGISTER_FLOW_GOTO')
ENV['BC2CPP_REGISTER_FLOW'] = '0'
check.call('the kill switch returns the texts untouched', flow(list, texts).equal?(texts))
ENV.delete('BC2CPP_REGISTER_FLOW')

fixture = <<~'RUBY'
  class RfBox
    def initialize; @v = 0; end

    def copies(x, y)
      z = x
      w = z
      q = y
      t = nil
      t = w + q
      [t, z]
    end

    def overwritten(a)
      b = a
      b = 3
      a ? b : a
    end

    def branchy(a, b)
      r = nil
      if a
        r = b
      else
        r = 7
      end
      c = r
      c
    end

    def looped(n)
      acc = 0
      i = n
      while i > 0
        j = i
        acc = acc + j
        i = i - 1
      end
      acc
    end

    def captured(a)
      z = a
      out = []
      twice { |e| z += e; out << z }
      [z, out]
    end

    def twice
      yield 1
      yield 2
    end

    def swap(a, b)
      t = a
      a = b
      b = t
      [a, b]
    end

    def state(a)
      t = a
      @v = t
      t = 9
      [@v, t]
    end
  end

  class RfResc
    def guarded(a)
      b = a
      begin
        raise 'x' if a
        d = b
      rescue
        return b
      end
      d
    end

    def guarded2(a)
      e = a
      begin
        x = e
        raise ArgumentError, 'z' if e == 2
        raise 'y' if e == 1
      rescue ArgumentError
        x = 3
      end
      x
    end
  end

  class RfRunner
    def line(label)
      "#{label}: #{yield.inspect}"
    rescue Exception => e
      "#{label}: !#{e.class}: #{e.message}"
    end

    def all
      b = RfBox.new
      out = []
      out << line('copies') { b.copies(1, 2) }
      out << line('copies str') { b.copies('a', 'b') }
      out << line('overwritten t') { b.overwritten(true) }
      out << line('overwritten f') { b.overwritten(nil) }
      out << line('branchy t') { b.branchy(true, 5) }
      out << line('branchy f') { b.branchy(false, 5) }
      out << line('looped') { b.looped(4) }
      out << line('captured') { b.captured(10) }
      out << line('swap') { b.swap(1, 2) }
      out << line('state') { b.state(4) }
      out << line('guarded') { RfResc.new.guarded(1) }
      out << line('guarded quiet') { RfResc.new.guarded(nil) }
      out << line('guarded2 caught') { RfResc.new.guarded2(2) }
      out << line('guarded2 passed') { RfResc.new.guarded2(nil) }
      out << line('guarded2 reraised') { RfResc.new.guarded2(1) }
      out.join("\n")
    end
  end
RUBY

puts '-- generated fixture'
MRBC_BIN = ENV['MRBC']
puts '  SKIP generated fixture: set MRBC' if MRBC_BIN.nil?
Dir.mktmpdir do |dir|
  src = File.join(dir, 'rf.rb')
  File.write(src, fixture)
  generate = lambda do |switch, windows = '0'|
    env = { 'MRBC' => MRBC_BIN, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'rf', 'OUT_DIR' => dir,
            'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_REGISTER_FLOW' => switch,
            'BC2CPP_REGISTER_FLOW_WINDOWS' => windows }
    out, err, status = Open3.capture3(bc2cpp_closed_world_probe_env(env), RbConfig.ruby, BC2CPP, '--annotated', src)
    abort "bc2cpp.rb failed:\n#{err[-3000..]}" unless status.success?
    [out, err]
  end
  on, on_err = generate.call('1')
  off, = generate.call('0')
  windows, = generate.call('1', '1')
  body = ->(code, name) { code[/^mrb_value RfBox_#{name}_impl\(mrb_state\* M.*?^\}/m].to_s }
  check.call('the pass shrinks the fixture', on.bytesize < off.bytesize)
  check.call('the experimental window rewrites shrink it further', windows.bytesize < on.bytesize)
  assigns = ->(code, name, rhs) { body.call(code, name).scan(/^  r\d+ = #{rhs};$/).length }
  check.call('the kill switch keeps the dead nil write', assigns.call(off, 'copies', 'mrb_nil_value\(\)') == 1)
  check.call('the dead nil write is gone with the pass on', assigns.call(on, 'copies', 'mrb_nil_value\(\)').zero?)
  check.call('the copy chain is shortened', assigns.call(on, 'copies', 'r\d+') < assigns.call(off, 'copies', 'r\d+'))
  check.call('the overwritten copy is gone', assigns.call(on, 'overwritten', 'r\d+') < assigns.call(off, 'overwritten', 'r\d+'))
  check.call('the branch-local nil write is gone', assigns.call(on, 'branchy', 'mrb_nil_value\(\)') <
                                                  assigns.call(off, 'branchy', 'mrb_nil_value\(\)'))
  check.call('the loop body keeps its accumulator copy', body.call(on, 'looped').include?('r'))
  rescue_body = ->(code, name) { code[/^mrb_value RfResc_#{name}_impl\(mrb_state\* M.*?^\}/m].to_s }
  check.call('a method with rescue regions shrinks with the pass on',
             rescue_body.call(on, 'guarded2').bytesize < rescue_body.call(off, 'guarded2').bytesize)
  check.call('no stderr noise from the pass', !on_err.include?('register_flow'))

  core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |c|
    File.exist?(File.join(c, 'lib/libmruby_core.a')) && File.directory?(File.join(c, 'include'))
  end
  if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
    puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
  else
    puts '-- differential run on real mruby (pass on, pass off, interpreted)'
    entries = on_err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                    .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$})
    registrations = entries.map do |entry, owner, name, _extra|
      klass = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, #{owner.dump})))"
      "    mrb_define_method(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
    end
    check.call('every fixture method has a compiled entry point', registrations.size >= 9)
    runs = { 'on' => on, 'off' => off, 'windows' => windows }.to_h do |label, code|
      File.write(File.join(dir, "rf_#{label}.cpp"), code)
      File.write(File.join(dir, "main_#{label}.cpp"), <<~CPP)
        #include <mruby.h>
        #include "rf_#{label}.cpp"
        #include <mruby/irep.h>
        #include <mruby/string.h>
        #include <cstdio>
        #include <cstring>
        #include <fstream>
        #include <iterator>
        #include <vector>
        extern "C" void mrb_init_mrblib(mrb_state*) {}
        int main(int, char** argv) {
          mrb_state* M = mrb_open_core();
          std::ifstream in(argv[1], std::ios::binary);
          std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
          mrb_load_irep_buf(M, bin.data(), bin.size());
          if (M->exc) { mrb_print_error(M); return 2; }
          if (std::strcmp(argv[2], "compiled") == 0) {
            bc2cpp_set_instance_tts(M);
        #{registrations.join("\n")}
          }
          mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "RfRunner"), 0, nullptr);
          mrb_value text = mrb_funcall(M, runner, "all", 0);
          if (M->exc) { mrb_print_error(M); return 3; }
          std::fwrite(RSTRING_PTR(text), 1, RSTRING_LEN(text), stdout);
          std::fputc('\\n', stdout);
          mrb_close(M);
          return 0;
        }
      CPP
      binary = File.join(dir, "rf_#{label}")
      built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                               "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/include", "-I#{ROOT}/mruby-rgss/src",
                               File.join(dir, "main_#{label}.cpp"), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
      check.call("the #{label} fixture compiles against real mruby", built)
      [label, built ? binary : nil]
    end
    if runs.values.all?
      mrb = File.join(dir, 'rf.mrb')
      interpreted = IO.popen([runs['on'], mrb, 'interpreted'], err: %i[child out], &:read)
      compiled_on = IO.popen([runs['on'], mrb, 'compiled'], err: %i[child out], &:read)
      compiled_off = IO.popen([runs['off'], mrb, 'compiled'], err: %i[child out], &:read)
      check.call('the interpreted run produced a transcript', interpreted.lines.size >= 10)
      puts "interpreted: #{interpreted.inspect}\ncompiled: #{compiled_on.inspect}" unless compiled_on == interpreted
      check.call("the compiled run with the pass agrees on all #{interpreted.lines.size} lines", compiled_on == interpreted)
      check.call('the compiled run without the pass agrees', compiled_off == interpreted)
      compiled_windows = IO.popen([runs['windows'], mrb, 'compiled'], err: %i[child out], &:read)
      check.call('the compiled run with the experimental window rewrites agrees', compiled_windows == interpreted)
    end
  end
end if MRBC_BIN

if failures.empty?
  puts 'bc2cpp register flow check: PASS'
else
  warn "bc2cpp register flow check: #{failures.size} failure(s)"
  exit 1
end
