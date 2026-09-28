# frozen_string_literal: true

# INTEGER_CONSTANT_PROOF: constant names that only ever hold an Integer.

# ---------------------------------------------------------------------------
# INTEGER_CONSTANT_PROOF: the bare constant names that can only ever resolve
# to an Integer; FIXNUM_OPERAND_PROOF's fifth proof source (see
# fixnum_proof_source?).
#
# Keyed by BARE name, which is the soundness argument: `GETCONST R4 FOO`
# resolves through lexical nesting and ancestors, which this file does not
# model, so a name is admitted only when EVERY definition of it anywhere is
# integral. Poison sources, all required:
#   1. a SETCONST/SETMCNST whose source is not an integer literal
#      (literal_int_const_source?);
#   2. a CLASS/MODULE naming it (OP_CLASS binds the constant itself);
#   3. a native mrb_define_const / mrb_define_global_const /
#      mrb_define_const_id;
#   4. a definition in a foreign Ruby source sharing the VM
#      (foreign_mrblib_srcs, compiled_gems.rb).
# A name with no integer definition is never admitted, so an unseen constant
# only costs a missed proof.
#
# CONST_ALIAS_CHAINING: `SCREEN_W = RPG2k::WIDTH` records an alias to the bare
# name instead of poisoning; resolve_integral settles the graph (see its
# header for why it must be the greatest fixpoint). ADD/SUB bytecodes may also
# combine proven integer constants; their exact result must fit target Fixnum.
module IntegerConstants
  # `SETCONST NAME R1` / `SETMCNST (R2)::NAME R1` (codedump.c): the name comes
  # first and the source register last, the reverse of GETCONST. print_lv_a may
  # append a `; R1:name` comment, which is stripped before reading the register.
  def self.analyze(ireps, native_paths, foreign_paths)
    # name -> list of one entry per real definition of that bare name:
    # `:literal` (an integer literal), `[:alias, M]` (a read of bare constant
    # name M), or nil (anything else -- an unconditional poison).
    defs = Hash.new { |h, k| h[k] = [] }
    poisoned = Set.new
    ireps.each_value do |irep|
      entries = const_entry_addrs(irep)
      irep.instructions.each_with_index do |insn, i|
        case insn.op
        when 'SETCONST', 'SETMCNST'
          name = insn.op == 'SETCONST' ? insn.args[/\A(\S+)/, 1] : insn.args[/::(\S+)/, 1]
          next unless name

          src = insn.args.sub(/;.*\z/m, '').scan(/R(\d+)/).flatten.last
          defs[name] << (src && const_source_kind(irep, i, src, entries))
        when 'CLASS', 'MODULE'
          nm = insn.args[/:(\S+)/, 1]
          poisoned << nm if nm
        end
      end
    end
    poisoned.merge(native_const_names(native_paths))
    poisoned.merge(foreign_const_names(foreign_paths))
    admitted = resolve_integral(defs, poisoned)
    loop do
      values = analyze_values(ireps, admitted)
      invalid = admitted.select do |name|
        defs[name].any? { |kind| kind.is_a?(Array) && kind[0] == :arithmetic } && values[name].nil?
      end
      break if invalid.empty?

      invalid.each { |name| poisoned << name }
      admitted = resolve_integral(defs, poisoned)
    end
    admitted
  end

  # CONST_ALIAS_CHAINING: the GREATEST fixpoint of "every definition of this bare
  # name assigns an integer literal, another such name, or integer ADD/SUB of
  # such values": start
  # from every classifiable, unpoisoned name and drop names aliasing a dropped
  # one until stable. The least fixpoint would refuse `Scene::Map::TILE =
  # Game::TILE`, which aliases its own bare name.
  #
  # Soundness is an induction on runtime assignment order: each binding of an
  # admitted name N executes a Fixnum literal, reads another admitted name, or
  # applies ADD/SUB to admitted integer values. The arithmetic form is retained
  # only when exact-value analysis proves the result fits the target Fixnum
  # range. An unassigned alias raises NameError before a value is stored. A
  # cycle with no literal (`A = B; B = A`) is admitted but can never execute.
  # Every binding must be classified, which the four poison sources guarantee.
  def self.resolve_integral(defs, poisoned)
    cand = Set.new
    defs.each do |name, kinds|
      next if poisoned.include?(name)
      next if kinds.empty? || kinds.any?(&:nil?)

      cand << name
    end
    loop do
      dropped = cand.reject do |name|
        defs[name].all? { |kind| integral_kind?(kind, cand) }
      end
      break if dropped.empty?

      dropped.each { |n| cand.delete(n) }
    end

    cand
  end

  def self.integral_kind?(kind, candidates)
    return true if kind == :literal
    return false unless kind.is_a?(Array)

    case kind[0]
    when :alias then candidates.include?(kind[1])
    when :arithmetic
      integral_operand?(kind[2], candidates) && integral_operand?(kind[3], candidates)
    else false
    end
  end

  def self.integral_operand?(operand, candidates)
    return true if operand.is_a?(Numeric) || operand == :literal
    return false unless operand.is_a?(Array)

    case operand[0]
    when :literal then true
    when :alias then candidates.include?(operand[1])
    when :arithmetic then integral_kind?(operand, candidates)
    else false
    end
  end

  def self.source_operand_kind?(operand)
    operand.is_a?(Numeric) || operand == :literal ||
      (operand.is_a?(Array) && %i[literal alias arithmetic].include?(operand[0]))
  end

  def self.value_for_kind(kind, visiting, resolve)
    case kind[0]
    when :literal then kind[1]
    when :alias then resolve.call(kind[1], visiting)
    when :arithmetic
      left = value_for_operand(kind[2], visiting, resolve)
      right = value_for_operand(kind[3], visiting, resolve)
      return nil if left.nil? || right.nil?

      value = case kind[1]
              when 'ADD', 'ADDI' then left + right
              when 'SUB', 'SUBI' then left - right
              end
      value if value&.between?(CodeGen::LOADI_FIXNUM_MIN, CodeGen::LOADI_FIXNUM_MAX)
    end
  end

  def self.value_for_operand(operand, visiting, resolve)
    return operand if operand.is_a?(Numeric)
    return nil if operand == :literal

    value_for_kind(operand, visiting, resolve)
  end

  # Every address control can enter other than by falling through: the targets
  # of the five pc-moving JMP* opcodes (as in fixnum_proof_edge_sources) plus
  # every catch handler target.
  def self.const_entry_addrs(irep)
    addrs = Set.new
    irep.instructions.each do |insn|
      case insn.op
      when 'JMP', 'JMPUW'
        addrs << insn.args.strip[/\d+/].to_i
      when 'JMPIF', 'JMPNOT', 'JMPNIL'
        # `"JMPIF\t\tR%d\t%03d"` -- register first, target last.
        t = insn.args.sub(/;.*\z/m, '').strip.split(/\s+/).last
        addrs << t.to_i if t
      end
    end
    (irep.catch_handlers || []).each { |ch| addrs << ch.target }
    addrs
  end

  # How is `reg` written at this point of the class body? Returns :literal,
  # [:alias, NAME], an ADD/SUB expression, or nil (poison), using the same
  # bounded backward walk as proven_fixnum_operand?. Any complication returns nil.
  # The walk must not step over a jump target: `X = cond ? "s" : 1` compiles to
  # JMPNOT/STRING/JMP/LOADI_1/SETCONST, whose nearest backward writer is a LOADI
  # even though the other arm binds a String.
  def self.const_source_kind(irep, idx, reg, entries)
    cur = reg.to_s
    j = idx - 1
    while j >= 0
      insn = irep.instructions[j]
      return nil unless insn
      return nil if entries.include?(insn.addr)

      if insn.args =~ /\AR#{cur}\b/
        return :literal if insn.op.start_with?('LOADI')

        case insn.op
        when 'MOVE'
          # `regs[a] = regs[b]` -- keep looking for whatever wrote the source.
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return nil unless src

          cur = src
        when 'GETCONST'
          # `"GETCONST\tR%d\t%s"` -- register first, bare name second.
          n = insn.args.split(/\s+/)[1]
          return n && [:alias, n]
        when 'GETMCNST'
          # `"GETMCNST\tR%d\t(R%d)::%s"`: only the bare name after `::` is used; the
          # scope register is not modelled, so the proof must hold for every constant
          # of that name.
          n = insn.args[/::(\S+)/, 1]
          return n && [:alias, n]
        when 'ADD', 'SUB', 'ADDI', 'SUBI'
          args = insn.args.sub(/;.*\z/m, '').scan(/R(\d+)/).flatten
          left = const_source_kind(irep, j, cur, entries)
          right = if %w[ADDI SUBI].include?(insn.op)
                    immediate = insn.args.sub(/;.*\z/m, '').split(/\s+/).last
                    return nil unless immediate&.match?(/\A-?\d+\z/)

                    immediate.to_i
                  else
                    return nil unless args[1]

                    const_source_kind(irep, j, args[1], entries)
                  end
          return nil unless source_operand_kind?(left) && source_operand_kind?(right)

          return [:arithmetic, insn.op, left, right]
        else
          return nil
        end
      end
      j -= 1
    end
    nil
  end

  # INTEGER_CONSTANT_VALUE_PROOF: analyze proves a bare name always binds a
  # Fixnum; this proves it always binds the SAME Fixnum, so GETCONST/GETMCNST can
  # be replaced by the literal. Sound by resolve_integral's induction: if every
  # classified definition resolves to one number, every run binds that number.
  # Arithmetic bytecodes use their integer fast arm for these proven operands;
  # out-of-range results are rejected. `admitted` already has poison sources.
  # A literal-less alias cycle resolves to nil by cycle detection, not memoized:
  # a cycle is a property of the path, not the name.
  def self.analyze_values(ireps, admitted)
    return {} if admitted.empty?

    defs = Hash.new { |h, k| h[k] = [] }
    ireps.each_value do |irep|
      entries = const_entry_addrs(irep)
      irep.instructions.each_with_index do |insn, i|
        next unless insn.op == 'SETCONST' || insn.op == 'SETMCNST'

        name = insn.op == 'SETCONST' ? insn.args[/\A(\S+)/, 1] : insn.args[/::(\S+)/, 1]
        next unless name && admitted.include?(name)

        src = insn.args.sub(/;.*\z/m, '').scan(/R(\d+)/).flatten.last
        defs[name] << (src && literal_value_kind(irep, i, src, entries))
      end
    end

    memo = {}
    resolve = lambda do |name, visiting|
      return memo[name] if memo.key?(name)
      return nil if visiting.include?(name)

      kinds = defs[name]
      next nil if kinds.empty? || kinds.any?(&:nil?)

      seen = visiting + [name]
      values = kinds.map { |kind| value_for_kind(kind, seen, resolve) }
      result = values.any?(&:nil?) || values.uniq.size != 1 ? nil : values.first
      memo[name] = result
      result
    end

    admitted.each_with_object({}) do |name, out|
      value = resolve.call(name, Set.new)
      out[name] = value unless value.nil?
    end
  end

  # const_source_kind's walk, returning `[:literal, N]` for LOADI* and exact
  # operand expressions for ADD/SUB. Everything else is refused.
  def self.literal_value_kind(irep, idx, reg, entries)
    cur = reg.to_s
    j = idx - 1
    while j >= 0
      insn = irep.instructions[j]
      return nil unless insn
      return nil if entries.include?(insn.addr)

      if insn.args =~ /\AR#{cur}\b/
        if insn.op.start_with?('LOADI')
          value = loadi_value(insn)
          return value.nil? ? nil : [:literal, value]
        end

        case insn.op
        when 'MOVE'
          src = insn.args.scan(/R(\d+)/).flatten[1]
          return nil unless src

          cur = src
        when 'GETCONST'
          n = insn.args.split(/\s+/)[1]
          return n && [:alias, n]
        when 'GETMCNST'
          n = insn.args[/::(\S+)/, 1]
          return n && [:alias, n]
        when 'ADD', 'SUB', 'ADDI', 'SUBI'
          args = insn.args.sub(/;.*\z/m, '').scan(/R(\d+)/).flatten
          left = literal_value_kind(irep, j, cur, entries)
          right = if %w[ADDI SUBI].include?(insn.op)
                    immediate = insn.args.sub(/;.*\z/m, '').split(/\s+/).last
                    return nil unless immediate&.match?(/\A-?\d+\z/)

                    immediate.to_i
                  else
                    return nil unless args[1]

                    literal_value_kind(irep, j, args[1], entries)
                  end
          return nil unless left && right

          return [:arithmetic, insn.op, left, right]
        else
          return nil
        end
      end
      j -= 1
    end
    nil
  end

  # Duplicate of CodeGen's loadi_literal/loadi_proven_fixnum? (this module has no
  # CodeGen instance). Only LOADI32 can leave the LOADI_FIXNUM_MIN/MAX margin, so
  # it is range-checked and refused (nil) outside it.
  def self.loadi_value(insn)
    tok = insn.args.split(/\s+/)[1]
    return nil unless tok&.match?(/\A-?\d+\z/)

    value = tok.to_i
    return nil if insn.op == 'LOADI32' && !value.between?(CodeGen::LOADI_FIXNUM_MIN, CodeGen::LOADI_FIXNUM_MAX)

    value
  end

  # Poison source 3 -- see the header above for the three real call forms.
  def self.native_const_names(paths)
    names = Set.new
    Array(paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      src.scan(/mrb_define_(?:global_)?const(?:_id)?\s*\(.{0,200}?/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Za-z_][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
    end
    names
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: native constant definitions,
  # with a bounded `[^;]{0,200}` window over the call's arguments. It does not
  # reuse native_const_names, whose lazy `.{0,200}?` matches zero characters (a
  # latent miss left alone because INTEGER_CONSTANT_PROOF depends on it); a missed
  # definition is the unsound direction for a never-defined proof. Reads:
  #   * mrb_define_const / mrb_define_global_const (+ _id);
  #   * mrb_const_set;
  #   * mrb_define_class / mrb_define_module (+ _id/_under): class.c's
  #     mrb_define_class_id does its own const_set.
  # Deliberately over-broad; over-collecting only costs a proof.
  def self.native_defined_const_names(paths)
    names = Set.new
    Array(paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      src.scan(/mrb_define_(?:global_)?const(?:_id)?\s*\([^;]{0,200}/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Z][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
      src.scan(/mrb_const_set\s*\([^;]{0,200}/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Z][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
      src.scan(/mrb_define_(?:class|module)(?:_[a-z_]*)?\s*\([^;]{0,200}/m) do
        seg = Regexp.last_match(0)
        seg.scan(/"([A-Z][A-Za-z_0-9]*)"/) { names << Regexp.last_match(1) }
        seg.scan(/MRB_SYM[A-Z_]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)/) { names << Regexp.last_match(1) }
      end
    end
    names
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: every constant name with a
  # visible definition: SETCONST/SETMCNST/CLASS/MODULE opcodes, native
  # definitions and foreign Ruby sources. What stays invisible (runtime
  # const_set, unscanned gems, eval) is listed at
  # compile_keyword_never_defined_const_send.
  def self.defined_name_universe(ireps, native_paths, foreign_paths)
    names = Set.new
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        case insn.op
        when 'SETCONST'
          names << insn.args[/\A(\S+)/, 1]
        when 'SETMCNST'
          names << insn.args[/::(\S+)/, 1]
        when 'CLASS', 'MODULE'
          names << insn.args[/:(\S+)/, 1]
        end
      end
    end
    names.delete(nil)
    names.merge(native_defined_const_names(native_paths))
    names.merge(foreign_const_names(foreign_paths))
    names
  end

  # Poison source 4: any `NAME =` at line start, whatever the right-hand side.
  # Over-collecting only costs a proof; under-collecting would be wrong.
  def self.foreign_const_names(paths)
    names = Set.new
    Array(paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      src.scan(/^\s*([A-Z][A-Za-z_0-9]*)\s*=[^=~]/) { names << Regexp.last_match(1) }
      # `class Foo` / `module Foo` bind a constant too (poison source 2).
      src.scan(/^\s*(?:class|module)\s+([A-Z][A-Za-z_0-9]*)/) { names << Regexp.last_match(1) }
    end
    names
  end
end
