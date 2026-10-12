#!/usr/bin/env ruby
# frozen_string_literal: true

# JOIN_DOMINANCE (docs/adr/0261): a backward register walk takes the textually
# nearest writer, which a join can skip. `x = h[k] || []` reads the literal
# while the register may hold h[k]. Every walk whose answer feeds an
# unguarded consumer must therefore prove that the write it found is the only
# value the register can hold at the read.
#
# 1. Host only (no mrbc): BytecodeIR::Program#write_dominates?, its
#    ivar_assigned_before_exposure? sibling, IrepScans#walk_dominating_writers
#    and IvarLayout.trace_type on hand-built instruction lists.
# 2. With MRBC: the generated code for fixtures. The joins the walks used to
#    miss no longer give an inlined loop, an exact-class direct call or a typed
#    slot; the straight-line shapes keep all three.
# 3. With MRBC, BC2CPP_MRUBY_FULL and g++: the fixtures run against real mruby,
#    interpreted and compiled, and must answer alike.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/join_dominance_check.rb

require 'set'
require 'tmpdir'

# Exercise guarded join hints separately from exhaustive user receiver unions.
ENV['BC2CPP_USER_RECEIVER_UNIONS'] = '0'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/ivar_layout'
require_relative '../../tools/bc2cpp/irep_scans'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list, handlers = [])
  Irep.new(label: "t#{list.hash}", instructions: list, catch_handlers: handlers)
end

puts '-- write_dominates? (host)'
# x = h[k] || <lit>; use x  -- GETIDX writes R3, JMPIF skips the literal.
or_literal = irep_of([
  insn(0, 'MOVE', "R3\tR1"), insn(3, 'GETIDX', "R3\t(R4)"), insn(5, 'JMPIF', "R3\t12"),
  insn(9, 'ARRAY', "R3\t0"), insn(12, 'SETIV', "@x\tR3")
])
check.call('the literal of `x = h[k] || []` does not dominate the read after the join',
           !BytecodeIR.write_dominates?(or_literal, 3, 4, '3'))
check.call('the GETIDX before the branch does dominate the branch', BytecodeIR.write_dominates?(or_literal, 1, 2, '3'))
check.call('a write directly before its read dominates it', BytecodeIR.write_dominates?(or_literal, 3, 4, '3') == false &&
                                                             BytecodeIR.write_dominates?(or_literal, 0, 1, '3'))

# A multi-write op between the write and the read can overwrite the register on its fallback or callee frame
# (vm.c L_SEND_SYM writes nil above R(a); a SEND's frame starts at R(a)): the write then does not supply the
# value. The origin walk's rule (origin_effect) refuses these; write_dominates? must refuse them too.
clobber = irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(1, 'ADD', "R0\t(R1)"), insn(2, 'MOVE', "R3\tR2"),
                   insn(3, 'RETURN', 'R3')])
check.call('ADD R0 falls back to a send that writes R2: the LOADI before it does not dominate the read of R2',
           !BytecodeIR.write_dominates?(clobber, 0, 2, '2'))
check.call('ADD R5 writes only R5..R7 on its fallback: the LOADI of R2 still dominates (negative)',
           BytecodeIR.write_dominates?(irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(1, 'ADD', "R5\t(R6)"),
                                                 insn(2, 'MOVE', "R3\tR2"), insn(3, 'RETURN', 'R3')]), 0, 2, '2'))
check.call('GETIDX0 R0 writes R1 on its fallback: a LOADI of R1 does not dominate its read',
           !BytecodeIR.write_dominates?(irep_of([insn(0, 'LOADI_5', "R1\t(5)"), insn(1, 'GETIDX0', "R0\tR9[0]"),
                                                 insn(2, 'MOVE', "R3\tR1"), insn(3, 'RETURN', 'R3')]), 0, 2, '1'))
check.call('a SEND on R1 starts its callee frame at R1: it clobbers R3 (the LOADI does not dominate)',
           !BytecodeIR.write_dominates?(irep_of([insn(0, 'LOADI_5', "R3\t(5)"), insn(1, 'SEND0', "R1\t:f"),
                                                 insn(2, 'MOVE', "R4\tR3"), insn(3, 'RETURN', 'R4')]), 0, 2, '3'))
check.call('a SEND on R4 leaves R3 alone (negative)',
           BytecodeIR.write_dominates?(irep_of([insn(0, 'LOADI_5', "R3\t(5)"), insn(1, 'SEND0', "R4\t:f"),
                                                 insn(2, 'MOVE', "R5\tR3"), insn(3, 'RETURN', 'R5')]), 0, 2, '3'))
check.call('a side write does not supply the register: GETIDX0 R0 writes R1 only on its fallback',
           !BytecodeIR.write_dominates?(irep_of([insn(0, 'GETIDX0', "R0\tR9[0]"), insn(1, 'MOVE', "R3\tR1"),
                                                 insn(2, 'RETURN', 'R3')]), 0, 1, '1'))
check.call('an intervening write to the register is the value at the read: the first LOADI does not dominate',
           !BytecodeIR.write_dominates?(irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(1, 'LOADI_6', "R2\t(6)"),
                                                 insn(2, 'MOVE', "R3\tR2"), insn(3, 'RETURN', 'R3')]), 0, 2, '2') &&
           BytecodeIR.write_dominates?(irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(1, 'LOADI_6', "R2\t(6)"),
                                                 insn(2, 'MOVE', "R3\tR2"), insn(3, 'RETURN', 'R3')]), 1, 2, '2'))

straight = irep_of([
  insn(0, 'LOADI_5', "R2\t(5)"), insn(2, 'JMPNOT', "R1\t9"), insn(6, 'LOADI_1', "R3\t(1)"),
  insn(8, 'NOP', ''), insn(9, 'MOVE', "R4\tR2"), insn(12, 'RETURN', 'R4')
])
check.call('a jump over an unrelated write leaves the earlier write dominating',
           BytecodeIR.write_dominates?(straight, 0, 4, '2'))

# The entry value survives a branch that never writes the register, but not a
# branch that does.
entry_plain = irep_of([insn(0, 'JMPNOT', "R1\t7"), insn(4, 'LOADI_1', "R3\t(1)"), insn(6, 'NOP', ''),
                       insn(7, 'MOVE', "R4\tR2"), insn(10, 'RETURN', 'R4')])
check.call('the entry value of an untouched register reaches a read behind a branch',
           BytecodeIR.write_dominates?(entry_plain, BytecodeIR::ENTRY, 3, '2'))
loop_back = irep_of([insn(0, 'MOVE', "R4\tR2"), insn(3, 'LOADI_1', "R2\t(1)"), insn(5, 'JMPNOT', "R1\t0"),
                     insn(9, 'RETURN', 'R4')])
check.call('a back edge from after the read refuses the entry value',
           !BytecodeIR.write_dominates?(loop_back, BytecodeIR::ENTRY, 0, '2'))

nested = irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(2, 'MOVE', "R3\tR2"), insn(5, 'RETURN', 'R3')])
check.call('a register a nested block writes is never dominated',
           !BytecodeIR.for(nested).write_dominates?(0, 1, '2', opaque_regs: Set['2']))
check.call('an op outside the audited write list between write and read refuses',
           !BytecodeIR.write_dominates?(irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(2, 'APOST', "R4\t1\t0"),
                                                 insn(6, 'RETURN', 'R2')]), 0, 2, '2'))
handler = irep_of([insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SEND0', "R3\t:f"), insn(4, 'LOADI_2', "R2\t(2)"),
                   insn(6, 'MOVE', "R5\tR2"), insn(9, 'RETURN', 'R5')],
                  [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 6, target: 6)])
check.call('an exception edge from before the write into the read refuses',
           !BytecodeIR.write_dominates?(handler, 2, 3, '2'))

puts '-- walk_dominating_writers (host)'
moves = irep_of([insn(0, 'LOADI_5', "R2\t(5)"), insn(2, 'MOVE', "R3\tR2"), insn(5, 'MOVE', "R4\tR3"), insn(8, 'RETURN', 'R4')])
found = moves.walk_dominating_writers(2, '4', use: 3, follow_moves: true) { |i| i.op }
check.call('MOVE is followed as a hop of its own', found == 'LOADI_5')
found = or_literal.walk_dominating_writers(3, '3', use: 4) { |i| i.op }
check.call('the walk ends with nil at the literal behind a join', found.nil?)

puts '-- ivar_assigned_before_exposure? (host)'
assigned = ->(list, ivar = 'a', handlers = []) { BytecodeIR.for(irep_of(list, handlers)).ivar_assigned_before_exposure?(ivar) }
check.call('assigned first, then returned', assigned.call([insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@a\tR2"),
                                                            insn(5, 'RETURN', 'R2')]))
check.call('assigned on one branch only', !assigned.call([insn(0, 'JMPNOT', "R1\t8"), insn(4, 'LOADI_1', "R2\t(1)"),
                                                          insn(6, 'SETIV', "@a\tR2"), insn(8, 'RETURN', 'R2')]))
check.call('read before the assignment', !assigned.call([insn(0, 'GETIV', "R2\t@a"), insn(3, 'LOADI_1', "R3\t(1)"),
                                                         insn(5, 'SETIV', "@a\tR3"), insn(8, 'RETURN', 'R3')]))
check.call('an implicit-self call before the assignment', !assigned.call([insn(0, 'SSEND0', "R2\t:foo"),
                                                                          insn(3, 'LOADI_1', "R3\t(1)"), insn(5, 'SETIV', "@a\tR3"),
                                                                          insn(8, 'RETURN', 'R3')]))
check.call('a call on another object before the assignment is harmless',
           assigned.call([insn(0, 'SEND0', "R2\t:foo"), insn(3, 'LOADI_1', "R3\t(1)"), insn(5, 'SETIV', "@a\tR3"),
                          insn(8, 'RETURN', 'R3')]))
check.call('self copied out before the assignment', !assigned.call([insn(0, 'MOVE', "R2\tR0"), insn(3, 'LOADI_1', "R3\t(1)"),
                                                                    insn(5, 'SETIV', "@a\tR3"), insn(8, 'RETURN', 'R3')]))
check.call('a method that never assigns it', !assigned.call([insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'RETURN', 'R2')]))
check.call('another ivar is not this one', !assigned.call([insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'SETIV', "@b\tR2"),
                                                          insn(5, 'RETURN', 'R2')]))
check.call('a rescue path back into the body counts as a path',
           !assigned.call([insn(0, 'SEND0', "R2\t:f"), insn(2, 'LOADI_1', "R3\t(1)"), insn(4, 'SETIV', "@a\tR3"),
                           insn(7, 'RETURN', 'R3')],
                          'a', [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 4, target: 7)]))

puts '-- IvarLayout.trace_type joins (host)'
type_of = lambda do |list, idx, reg|
  IvarLayout.trace_type(irep_of(list), idx, reg, {}, nil, 1)
end
or_zero = [insn(0, 'MOVE', "R3\tR1"), insn(3, 'GETIDX', "R3\t(R4)"), insn(5, 'JMPIF', "R3\t12"),
           insn(9, 'LOADI_0', "R3\t(0)"), insn(12, 'SETIV', "@x\tR3")]
check.call('`@x = h[k] || 0` is not proven Fixnum (h[k] may be anything)', type_of.call(or_zero, 4, '3') == IvarLayout::UNKNOWN)
both = [insn(0, 'JMPNOT', "R1\t9"), insn(4, 'LOADI_1', "R3\t(1)"), insn(6, 'JMP', "12"), insn(9, 'LOADI_2', "R3\t(2)"),
        insn(12, 'SETIV', "@x\tR3")]
check.call('both arms Fixnum is Fixnum', type_of.call(both, 4, '3') == :fixnum)
one_nil = [insn(0, 'JMPNOT', "R1\t9"), insn(4, 'LOADI_1', "R3\t(1)"), insn(6, 'JMP', "11"), insn(9, 'LOADNIL', "R3\t(nil)"),
           insn(11, 'SETIV', "@x\tR3")]
check.call('a Fixnum arm and a nil arm is Integer-or-nil', type_of.call(one_nil, 4, '3') == IvarLayout::FIXNUM_NIL)
counter = [insn(0, 'LOADI_0', "R3\t(0)"), insn(2, 'JMPNOT', "R1\t12"), insn(6, 'ADDI', "R3\t1"), insn(9, 'JMP', '2'),
           insn(12, 'SETIV', "@y\tR3")]
check.call('a loop-carried counter is not Fixnum: `+= 1` can leave the Fixnum range (ADR 0279)',
           type_of.call(counter, 4, '3') == IvarLayout::UNKNOWN)
switch = [insn(0, 'LOADI_0', "R3\t(0)"), insn(2, 'JMPNOT', "R1\t12"), insn(6, 'LOADI_7', "R3\t(7)"), insn(8, 'JMP', '2'),
          insn(12, 'SETIV', "@y\tR3")]
check.call('a loop-carried literal keeps the join: the cycle takes the type the other definition gives it',
           type_of.call(switch, 4, '3') == :fixnum)
opaque = [insn(0, 'LOADI_0', "R3\t(0)"), insn(2, 'JMPNOT', "R1\t10"), insn(6, 'SEND0', "R3\t:next"), insn(8, 'JMP', '2'),
          insn(10, 'SETIV', "@y\tR3")]
check.call('a loop that also writes an opaque call result is not Fixnum', type_of.call(opaque, 4, '3') == IvarLayout::UNKNOWN)
check.call('a write straight before the SETIV is unchanged',
           type_of.call([insn(0, 'LOADI_7', "R3\t(7)"), insn(2, 'SETIV', "@x\tR3")], 1, '3') == :fixnum)

if ENV['MRBC']
  require_relative 'fixture_runtime'
  runtime = Bc2cppFixtureRuntime
  body_of = lambda do |code, fn|
    code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  end

  puts '-- generated code (closed world)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(<<~RUBY, dir)
      class JdFoo
        def bar; 1; end
      end
      class JdBaz
        def bar; 2; end
      end
      class JdProbe
        def orarr(h, k)
          x = h[k] || []
          s = 0
          x.each { |e| s += e }
          s
        end

        def orhash(h, k)
          x = h[k] || {}
          x.each { |kk, vv| kk }
          x
        end

        def straight
          x = []
          s = 0
          x.each { |e| s += e }
          s
        end

        def orfoo(h, k)
          x = h[k] || JdFoo.new
          x.bar
        end

        def reassigned(c)
          x = JdBaz.new
          x = JdFoo.new if c
          x.bar
        end

        def fresh
          x = JdFoo.new
          x.bar
        end
      end
    RUBY
    check.call('`(h[k] || []).each` is not inlined (the receiver may not be an Array)',
               !body_of.call(code, 'JdProbe_orarr').include?('inlined #each') &&
                 body_of.call(code, 'JdProbe_orarr').include?('BLOCK_FALLBACK :each'))
    check.call('`(h[k] || {}).each` is not inlined as a Hash walk', !body_of.call(code, 'JdProbe_orhash').match?(/bc2cpp_each|hash_each/))
    check.call('an array built on the straight path is still inlined',
               body_of.call(code, 'JdProbe_straight').include?('inlined #each'))
    check.call('`x = h[k] || Foo.new; x.bar` is not an unguarded exact-class call',
               !body_of.call(code, 'JdProbe_orfoo').include?('CLOSED_WORLD_EXACT_CLASS'))
    check.call('a class picked on one branch is not an unguarded exact-class call',
               !body_of.call(code, 'JdProbe_reassigned').include?('CLOSED_WORLD_EXACT_CLASS'))
    check.call('a fresh `Foo.new` receiver keeps the unguarded exact-class call',
               body_of.call(code, 'JdProbe_fresh').include?('CLOSED_WORLD_EXACT_CLASS'))
    check.call('the guarded typed call is kept for the join, with its class check',
               body_of.call(code, 'JdProbe_reassigned').match?(/TYPED :bar -> JdFoo#bar.*\n\s+if \(bc2cpp_owner_class_\d+\(M\) == mrb_obj_class\(M, r\d+\)\)/))
  end

  puts '-- embedded ivar types (closed world)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(<<~RUBY, dir)
      class JdHolder
        def initialize(h)
          @jd_a = 1
          @jd_b = h[:b] || 0
          @jd_c = h[:c] ? 1 : nil
        end

        def set_late; @jd_late = 5; end
        def late; @jd_late; end
      end
    RUBY
    fields = code[/struct JdHolder_ivars \{\n(.*?)\n\};/m, 1].to_s
    check.call('a straight-line Fixnum ivar stays typed', fields.include?('mrb_int ivar_jd_a;'))
    check.call('`@jd_b = h[:b] || 0` is not typed (h[:b] may be any class)', fields.include?('mrb_value ivar_jd_b;'))
    check.call('a Fixnum-or-nil join is the nilable type', fields.include?('Bc2cppFixnumOrNil ivar_jd_c;'))
    check.call('an ivar assigned outside #initialize is not typed (an unset read is nil, not 0)',
               fields.include?('mrb_value ivar_jd_late;'))
  end

  full = runtime.full
  if full.nil? || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      source = <<~RUBY
        class JdFoo
          def bar; 1; end
        end
        class JdBaz
          def bar; 2; end
        end
        class JdProbe
          def orarr(h, k)
            x = h[k] || []
            s = 0
            x.each { |e| s += e }
            s
          end

          def reassigned(c)
            x = JdBaz.new
            x = JdFoo.new if c
            x.bar
          end

          def orfoo(h, k)
            x = h[k] || JdFoo.new
            x.bar
          end
        end
        class JdHolder
          def initialize(h)
            @b = h[:b] || 0
          end

          def b; @b; end
          def add_one; @b = @b + 1; end
        end
        class JdLate
          def set_late; @late = 5; end
          def late; @late; end
          def initialize; @a = 1; end
        end
      RUBY
      _code, err = runtime.generate(source, dir, closed: true, only_owners: %w[JdProbe JdHolder JdLate JdFoo JdBaz])
      body = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "JdProbe"), 0, nullptr);
          mrb_value h = mrb_hash_new(M);
          mrb_value list = mrb_ary_new(M);
          mrb_ary_push(M, list, mrb_fixnum_value(1));
          mrb_ary_push(M, list, mrb_fixnum_value(2));
          mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "list")), list);
          mrb_value args[2] = { h, mrb_symbol_value(mrb_intern_lit(M, "list")) };
          call(M, "orarr with an array", probe, "orarr", 2, args);
          args[1] = mrb_symbol_value(mrb_intern_lit(M, "none"));
          call(M, "orarr with a missing key", probe, "orarr", 2, args);
          // A Hash where an Array was assumed: `each` still works there.
          mrb_value hh = mrb_hash_new(M);
          mrb_hash_set(M, hh, mrb_fixnum_value(1), mrb_fixnum_value(2));
          mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "hash")), hh);
          args[1] = mrb_symbol_value(mrb_intern_lit(M, "hash"));
          call(M, "orarr with a Hash value", probe, "orarr", 2, args);
          mrb_value no = mrb_false_value();
          mrb_value yes = mrb_true_value();
          call(M, "reassigned false", probe, "reassigned", 1, &no);
          call(M, "reassigned true", probe, "reassigned", 1, &yes);
          mrb_hash_set(M, h, mrb_symbol_value(mrb_intern_lit(M, "baz")), mrb_obj_new(M, mrb_class_get(M, "JdBaz"), 0, nullptr));
          args[1] = mrb_symbol_value(mrb_intern_lit(M, "baz"));
          call(M, "orfoo with a JdBaz value", probe, "orfoo", 2, args);
          args[1] = mrb_symbol_value(mrb_intern_lit(M, "none"));
          call(M, "orfoo with a missing key", probe, "orfoo", 2, args);

          // A value of another class in a `|| 0` ivar.
          mrb_value opts = mrb_hash_new(M);
          mrb_hash_set(M, opts, mrb_symbol_value(mrb_intern_lit(M, "b")), mrb_float_value(M, 2.5));
          mrb_value holder = mrb_obj_new(M, mrb_class_get(M, "JdHolder"), 1, &opts);
          call(M, "holder b (a Float)", holder, "b");
          mrb_value empty = mrb_hash_new(M);
          mrb_value plain = mrb_obj_new(M, mrb_class_get(M, "JdHolder"), 1, &empty);
          call(M, "holder b (defaulted)", plain, "b");
          call(M, "holder add_one", plain, "add_one");
          // An unset ivar reads nil.
          mrb_value late = mrb_obj_new(M, mrb_class_get(M, "JdLate"), 0, nullptr);
          call(M, "late before set", late, "late");
          call(M, "set_late", late, "set_late");
          call(M, "late after set", late, "late");
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, %w[JdProbe JdHolder JdLate JdFoo JdBaz], body, build: full, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('every join answers what the interpreter answers',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        puts output if ENV["BC2CPP_CHECK_VERBOSE"] || values.call("interpreted") != values.call("compiled")
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp join dominance check: PASS'
else
  warn "bc2cpp join dominance check: #{failures.size} failure(s)"
  exit 1
end
