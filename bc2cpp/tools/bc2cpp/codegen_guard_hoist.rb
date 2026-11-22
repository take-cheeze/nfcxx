# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'bytecode_ir_dataflow'

# GUARD_HOIST: one class test per unchanged value per method. A send whose text is a chain of exact-class tests of its
# receiver, `if (bc2cpp_class_is(M, rA, S1)) {..} else if (bc2cpp_class_is(M, rA, S2)) {..} else { <raise> }`,
# leaves the receiver's value proven one of the classes S1..Sn on its normal successor. A later chain on the same
# value whose arms up to some k cover that set never reaches past arm k, so arm k loses its test and the arms and
# else after it go; with one class and k = 1 only the then-arm is left.
#
# Soundness (enforced here, in GuardHoist::Flow and guard_hoist_site):
#   * bc2cpp_class_is is `slot == mrb_obj_class(v)`; an owner slot is filled once and never cleared, and an
#     object's real class never changes (a singleton class or an extend sits in front of it and mrb_obj_class skips
#     both), so a test repeated on the same value against the same slot gives the same answer. A singleton method
#     gained in between changes nothing: the repeated test would not have seen it either.
#   * the fact needs a raising final else: bc2cpp_nomethod* (bc2cpp_guard_violation is not one, its debugging build
#     dispatches), or a lone arm's owner call over that arm's class when the class is a leaf (LeafOwnerElse's proof);
#   * the arms before k are kept as they are, so two slots naming one class cannot change which arm runs: reaching
#     arm k means every class of the set but arm k's own failed an earlier test;
#   * the fact is a forward must-flow over the normal-flow CFG (BytecodeIR, ENTER's JMP table included): unreached
#     states are optimistic and a join keeps a register's fact only when every incoming path has one (the union of
#     their sets), so a loop keeps it only when no iteration writes the value. A write of a register kills it, a
#     call or frame-starting op kills R(a) and above, an op outside the modelled set kills everything, and a register
#     a nested block writes (SETUPVAR) never carries one;
#   * facts come only from sites already compiled in this pass (index order): a fact a later site would add is
#     missing, never wrong;
#   * no instance anywhere may gain a singleton class (ClosedWorld#exact_instances_singleton_free?);
#   * a method with handlers, prefixes or a resumable body is not touched, and no site inside a glued or guarded-inline
#     range adds or uses a fact (guard_hoist_bypassed): code there may run out of order or be jumped over.
# BC2CPP_GUARD_HOIST=0 turns it off.
class CodeGen
  module GuardHoist
    ENABLED = ENV['BC2CPP_GUARD_HOIST'] != '0'
    RECEIVER_SENDS = %i[SEND SEND0 SENDB].freeze
    # Ops that write nothing in this frame and call nothing that starts a frame on its registers.
    NO_WRITE_OPS = Set[:NOP, :JMP, :JMPIF, :JMPNOT, :JMPNIL, :SETGV, :SETSV, :SETIV, :SETCV, :SETCONST, :SETMCNST,
                       :RETURN, :RETURN_BLK, :RETSELF, :RETNIL, :RETTRUE, :RETFALSE, :BREAK, :DEBUG, :STOP].freeze
    # Ops that write only R(a) and run no Ruby whose frame could start at a register of this one.
    LEAD_ONLY_OPS = Set[:LOADL, :LOADSYM, :LOADNIL, :LOADTRUE, :LOADFALSE, :GETGV, :GETSV, :GETIV, :GETCV,
                        :GETUPVAR, :STRING, :INTERN, :SYMBOL, :LAMBDA, :BLOCK, :METHOD, :ARRAY, :ARRAY2,
                        :HASH, :RANGE_INC, :RANGE_EXC].freeze
    # A chain arm's test of the send's receiver: the first arm opens the text, the others follow a `}`.
    ARM_TEST = /\G(?<likely>mrb_likely\()?bc2cpp_class_is\(M, r(?<reg>\d+), (?<slot>bc2cpp_owner_class_\d+\(M\))\)(?(<likely>)\))\) \{\n/
    GUARD_HEAD = /\A(?<lead>(?:[ \t]*(?:\/\/[^\n]*)?\n)*)(?<indent>[ \t]*)if \(/
    NORETURN_ELSE = %r{\A(?:[ \t]*\n)*[ \t]*(?:BC2CPP_COLD_ARM[ \t]+)?(?:r\d+ = )?bc2cpp_nomethod(?:_raise)?(?:_named)?\([^;\n]*\);(?:[ \t]*/\*[^\n]*?\*/)?[ \t]*\n[ \t]*\z}

    # An owner call over the guard's own class when that class is a leaf (LeafOwnerElse's proof): a receiver the
    # guard refused answers the name only from a class the closed world did not see, which raises too.
    LEAF_OWNER_CALL_ELSE = %r{\A(?:[ \t]*\n)*[ \t]*(?:BC2CPP_COLD_ARM[ \t]+)?r\d+ = bc2cpp_owner_call_named\(M, (?<recv>r\d+), "[^"]+", \d, BC2CPP_OWNERS\("(?<owner>[^"]+)"\), mrb_nil_value\(\), \d+(?:, [^,);]+)*\); /\* CLOSED_WORLD owner-call: \S+ \*/[ \t]*\n[ \t]*\z}

    # Per-method state: the guard facts each compiled site added, and the flow over them.
    class Session
      attr_reader :irep

      def initialize(irep, bypassed)
        @irep = irep
        @bypassed = bypassed || Set.new
        @gens = {}
        @states = nil
      end

      def bypassed?(idx)
        @bypassed.include?(idx)
      end

      def add(idx, reg, slots)
        @gens[idx] = [reg, slots]
        @states = nil
      end

      # The sorted slots one of which +reg+'s class is at the entry of instruction +idx+, or nil.
      def fact(idx, reg)
        return nil if @gens.empty?

        @states ||= Flow.new(@irep, @gens).run
        st = @states && @states[idx]
        st && st[0][reg]
      end
    end

    # The must-flow. A state is [facts, roots]: facts[r] the sorted slots r's class is among (nil: unknown), roots[r]
    # a register known to hold the same value (r itself when none; a root is its own root).
    class Flow
      def initialize(irep, gens)
        @irep = irep
        @gens = gens
        @program = BytecodeIR.for(irep)
        @nregs = irep.nregs.to_i
        @opaque = BytecodeIR.own_upvar_written_regs(irep)
      end

      def run
        return nil unless @program.resolved? && !@program.handlers?

        insns = @program.instructions
        succ = @program.successor_lists
        n = insns.size
        ins = Array.new(n)
        ins[0] = [Array.new(@nregs), Array.new(@nregs) { |r| r }]
        work = [0]
        until work.empty?
          i = work.pop
          out = transfer(i, insns[i].source, ins[i])
          succ[i].each do |s|
            merged = ins[s] ? join(ins[s], out) : out
            next if merged == ins[s]

            ins[s] = merged
            work << s
          end
        end
        ins
      end

      private

      def transfer(idx, insn, state)
        facts = state[0].dup
        roots = state[1].dup
        op = insn.op
        a = insn.reg.to_i if insn.reg
        if op == :MOVE || op == :LOADSELF
          src = op == :MOVE ? insn.regs[1] : 0
          return [kill_all(facts), roots] unless src

          kill(facts, roots, a, a)
          copy(facts, roots, a, src) if src < @nregs
        elsif NO_WRITE_OPS.include?(op)
          # nothing written
        elsif LEAD_ONLY_OPS.include?(op) || BytecodeIR::Ops::LOADI_OPS.include?(op)
          kill(facts, roots, a, a)
        elsif (run = BytecodeIR.written_run(insn))
          kill(facts, roots, run.first, @nregs - 1)
        elsif a && BytecodeIR::WRITES_LEADING_REG_OPS.include?(op)
          gen = RECEIVER_SENDS.include?(op) && @gens[idx]
          same = gen && gen[0] == a ? (0...a).select { |q| roots[q] == roots[a] } : []
          kill(facts, roots, a, @nregs - 1)
          same.each do |q|
            next if @opaque.include?(q)

            narrowed = facts[q] && (facts[q] & gen[1])
            facts[q] = narrowed.nil? || narrowed.empty? ? gen[1] : narrowed
          end
        else
          kill(facts, roots, 0, @nregs - 1)
        end
        [facts, roots]
      end

      # Registers lo..hi get new values: their facts go, and a value one of them represented moves to its next holder.
      def kill(facts, roots, lo, hi)
        return if lo.nil? || lo >= @nregs

        hi = @nregs - 1 if hi >= @nregs
        moved = {}
        (0...@nregs).each do |q|
          next if q.between?(lo, hi)

          r = roots[q]
          roots[q] = (moved[r] ||= q) if r.between?(lo, hi)
        end
        (lo..hi).each do |r|
          facts[r] = nil
          roots[r] = r
        end
      end

      def kill_all(facts)
        facts.fill(nil)
      end

      def copy(facts, roots, dst, src)
        return if @opaque.include?(dst)

        facts[dst] = @opaque.include?(src) ? nil : facts[src]
        roots[dst] = @opaque.include?(src) ? dst : roots[src]
      end

      def join(x, y)
        facts = Array.new(@nregs) do |r|
          fx = x[0][r]
          fy = y[0][r]
          fx && fy ? (fx | fy).sort.freeze : nil
        end
        roots = Array.new(@nregs) { |r| x[1][r] == y[1][r] ? x[1][r] : r }
        # A kept root must still name itself, or the registers that share it no longer share a value.
        roots.each_with_index { |root, r| roots[r] = r unless roots[root] == root }
        [facts, roots]
      end
    end
  end

  # As exact_flow_class, a class fact is used only where no instance may gain a singleton class.
  def guard_hoist_enabled?
    GuardHoist::ENABLED && !@resumable && @closed_world&.exact_instances_singleton_free?
  end

  # Runs the method's instruction loop with a session when the method qualifies (see GuardHoist).
  def guard_hoist_session(irep, eligible, bypassed: nil)
    saved = @guard_hoist
    program = BytecodeIR.for(irep)
    on = guard_hoist_enabled?
    @guard_hoist = on && eligible && program.resolved? && !program.handlers? ? GuardHoist::Session.new(irep, bypassed) : nil
    if on
      reason = if @guard_hoist then :sessions
               elsif !eligible then :skipped_text
               else :skipped_flow
               end
      (@guard_hoist_stats ||= Hash.new(0))[reason] += 1
    end
    yield
  ensure
    @guard_hoist = saved
  end

  # Indices whose text a path may skip or run out of order: from a glue's address through the last suppressed
  # address before the next glue (an inlined loop's glue runs the whole send there and its `break` jumps past it), and
  # from a guarded inline loop's address to its after label (the loop jumps over the send). Their own writes still
  # kill facts in the flow; they only add or use none.
  def guard_hoist_bypassed(irep, suppressed, glue_at, guarded_inline)
    addrs = BytecodeIR.for(irep).instructions.map(&:addr)
    out = Set.new
    starts = glue_at.keys.sort
    starts.each_with_index do |from, k|
      stop = starts[k + 1]
      last = suppressed.select { |addr| addr >= from && (stop.nil? || addr < stop) }.max || from
      addrs.each_with_index { |addr, idx| out << idx if addr >= from && addr <= last }
    end
    afters = guarded_inline[:after].keys.sort
    guarded_inline[:at].each_key do |from|
      after = afters.find { |addr| addr > from }
      addrs.each_with_index { |addr, idx| out << idx if addr >= from && (after.nil? || addr < after) }
    end
    # A suppressed address no glue covers is text nobody emits: keep the whole method out.
    uncovered = suppressed.any? { |addr| addrs.include?(addr) && !out.include?(addrs.index(addr)) }
    uncovered ? Set.new(0...addrs.size) : out
  end

  # The text of the send at +idx+: its chain cut where a fact already decides it, and its own fact recorded.
  def guard_hoist_site(irep, idx, insn, text)
    session = @guard_hoist
    return text unless session && session.irep.equal?(irep) && GuardHoist::RECEIVER_SENDS.include?(insn.op)
    return text if session.bypassed?(idx)

    head = GuardHoist::GUARD_HEAD.match(text)
    chain = head && guard_hoist_chain(text, head.end(0), insn.reg.to_i)
    return text unless chain

    arms, else_arm, rest = chain
    fact = session.fact(idx, insn.reg.to_i)
    if fact
      covered = []
      cut = arms.index { |arm| covered |= [arm[:slot]]; (fact - covered).empty? }
      return guard_hoist_cut(text, head, insn.reg.to_i, arms, cut, rest) if cut
    end
    return text unless else_arm

    body = text[else_arm[0]...else_arm[1]]
    leaf = arms.size == 1 && GuardHoist::LEAF_OWNER_CALL_ELSE.match(body)
    if GuardHoist::NORETURN_ELSE.match?(body) ||
       (leaf && @closed_world && leaf[:recv] == "r#{insn.reg.to_i}" && leaf_owner_class_expr?(arms[0][:slot], leaf[:owner]))
      session.add(idx, insn.reg.to_i, arms.map { |arm| arm[:slot] }.uniq.sort.freeze)
      (@guard_hoist_stats ||= Hash.new(0))[:facts] += 1
    end
    text
  end

  # [arms, else, rest] of the if-chain whose first test starts at +from+, every arm an exact-class test of r+reg:
  # each arm {slot:, test: [from, to) of its test, body: [from, to)}, else the [from, to) of the final else's body
  # or nil, rest the offset after the chain. nil when the text is not such a chain.
  def guard_hoist_chain(text, from, reg)
    arms = []
    pos = from
    loop do
      test = GuardHoist::ARM_TEST.match(text, pos)
      return nil unless test && test.begin(0) == pos && test[:reg].to_i == reg

      close = guard_hoist_block_end(text, test.end(0))
      return nil unless close

      arms << { slot: test[:slot], test: [pos, test.end(0)], body: [test.end(0), close] }
      if text[close + 1, 10] == ' else if ('
        pos = close + 11
      elsif text[close + 1, 8] == " else {\n"
        body_from = close + 9
        last = guard_hoist_block_end(text, body_from)
        return nil unless last

        return [arms, [body_from, last], guard_hoist_line_end(text, last)]
      else
        return [arms, nil, guard_hoist_line_end(text, close)]
      end
    end
  end

  def guard_hoist_line_end(text, close)
    text[close + 1] == "\n" ? close + 2 : close + 1
  end

  # The chain with arm +cut+ as its last, untested, arm.
  def guard_hoist_cut(text, head, reg, arms, cut, rest)
    (@guard_hoist_stats ||= Hash.new(0))[:elided] += 1
    indent = head[:indent]
    note = "#{indent}/* GUARD_HOIST: r#{reg} is one of the classes a dominating guard proved */\n"
    last = arms[cut]
    out = String.new("#{head[:lead]}#{note}")
    if cut.zero?
      out << "#{indent}{\n"
    else
      out << "#{indent}if (" << text[arms[0][:test][0]...arms[cut - 1][:body][1]] << "} else {\n"
    end
    out << text[last[:body][0]...last[:body][1]] << "}\n" << text[rest..]
  end

  # The offset of the `}` closing the block whose body starts at +from+ (just past its `{`), or nil when the text
  # does not scan cleanly (an unterminated literal or comment, an unbalanced brace).
  def guard_hoist_block_end(text, from)
    depth = 1
    i = from
    n = text.size
    while i < n
      c = text[i]
      case c
      when '"', "'"
        i += 1
        i += (text[i] == '\\' ? 2 : 1) while i < n && text[i] != c
        return nil if i >= n
      when '/'
        if text[i + 1] == '/'
          i = text.index("\n", i) || n
        elsif text[i + 1] == '*'
          close = text.index('*/', i + 2)
          return nil unless close

          i = close + 1
        end
      when '{' then depth += 1
      when '}'
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  def guard_hoist_summary
    stats = @guard_hoist_stats || {}
    "== guard hoist (GUARD_HOIST): #{stats[:facts].to_i} guard facts, #{stats[:elided].to_i} chains cut in " \
      "#{stats[:sessions].to_i} method bodies; skipped #{stats[:skipped_text].to_i} with prefixed text, " \
      "#{stats[:skipped_flow].to_i} with handlers or an unresolved CFG (probe compiles included) =="
  end
end
