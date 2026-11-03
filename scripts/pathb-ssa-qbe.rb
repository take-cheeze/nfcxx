#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SSA to QBE (docs/notes/pathb-ssa-qbe.md). Reads the SSA text of a module (scripts/pathb-ssa.rb, optionally optimised
# by scripts/pathb-egraph.rb) and writes QBE IL, which is SSA with blocks and phi. The subset: integer, pointer and
# float scalars, arithmetic, comparisons, conversions, loads and stores of scalar objects, switch, phi, branches and
# return. A function outside the subset raises QbeUnsupported; nothing is emitted for it.
#
#   scripts/pathb-ssa-qbe.rb FILE.ssa > FILE.qbe      then:  build/qbe/qbe FILE.qbe > FILE.s
#
require_relative "pathb-ssa"

QbeUnsupported = Class.new(StandardError)

module Qbe
  INT_W = %w[bool char signed_char unsigned_char short unsigned_short int unsigned_int].freeze
  INT_L = %w[long long_long unsigned_long unsigned_long_long].freeze
  LOAD = { "bool" => "loadub", "char" => "loadsb", "signed_char" => "loadsb", "unsigned_char" => "loadub",
           "short" => "loadsh", "unsigned_short" => "loaduh", "int" => "loadsw", "unsigned_int" => "loaduw",
           "long" => "loadl", "long_long" => "loadl", "unsigned_long" => "loadl", "unsigned_long_long" => "loadl",
           "float" => "load", "double" => "load" }.freeze
  STORE = { "bool" => "storeb", "char" => "storeb", "signed_char" => "storeb", "unsigned_char" => "storeb",
            "short" => "storeh", "unsigned_short" => "storeh", "int" => "storew", "unsigned_int" => "storew",
            "long" => "storel", "long_long" => "storel", "unsigned_long" => "storel", "unsigned_long_long" => "storel",
            "float" => "stores", "double" => "stored" }.freeze
  SIZE = { "bool" => 1, "char" => 1, "signed_char" => 1, "unsigned_char" => 1, "short" => 2, "unsigned_short" => 2,
           "int" => 4, "unsigned_int" => 4, "long" => 8, "long_long" => 8, "unsigned_long" => 8,
           "unsigned_long_long" => 8, "float" => 4, "double" => 8 }.freeze
  EXT = { "char" => "sb", "signed_char" => "sb", "unsigned_char" => "ub", "short" => "sh", "unsigned_short" => "uh" }.freeze
  BIN = { "wadd" => "add", "wsub" => "sub", "wmul" => "mul", "and" => "and", "or" => "or", "xor" => "xor" }.freeze
  CMP = { "eq" => "ceq", "ne" => "cne", "lt.s" => "cslt", "lt.u" => "cult", "le.s" => "csle", "le.u" => "cule" }.freeze
  # Float operations: ordered comparisons (false on NaN, as the interpreter's < and <= are).
  FBIN = { "fadd" => "add", "fsub" => "sub", "fmul" => "mul", "fdiv" => "div" }.freeze
  FCMP = { "lt.f" => "clt", "le.f" => "cle" }.freeze
  CMP_HEADS = (CMP.keys + FCMP.keys).freeze

  module_function

  def float?(t) = FLOAT_TYPES.key?(strip_const(t))

  # The QBE class of a scalar type: w for 32-bit and narrower integers, l for 64-bit integers and pointers, s and d
  # for float and double.
  def cls(t)
    t = strip_const(t)
    return "l" if head(t) == "ptr"
    return "w" if INT_W.include?(t)
    return "l" if INT_L.include?(t)
    return "s" if t == "float"
    return "d" if t == "double"

    raise QbeUnsupported, "type #{sx(t)}"
  end

  def size(t)
    t = strip_const(t)
    return 8 if head(t) == "ptr"

    SIZE.fetch(t) { raise QbeUnsupported, "object of type #{sx(t)}" }
  end

  def load_op(t)
    t = strip_const(t)
    return "loadl" if head(t) == "ptr"

    LOAD.fetch(t) { raise QbeUnsupported, "load of #{sx(t)}" }
  end

  def store_op(t)
    t = strip_const(t)
    return "storel" if head(t) == "ptr"

    STORE.fetch(t) { raise QbeUnsupported, "store of #{sx(t)}" }
  end

  def signed?(t)
    t = strip_const(t)
    return false if head(t) == "ptr"

    INT_TYPES.fetch(t) { raise QbeUnsupported, "type #{sx(t)}" }[1]
  end

  def int_lit(s) = s.is_a?(Integer) ? s : Integer(s, 10)

  # A float literal of type t: the value is rounded to t as the interpreter rounds it, then written as an exact hex float
  # (QBE reads it with scanf). Infinities are written as inf; NaN is not a literal of the subset.
  def float_lit(t, text)
    v = round_float(Float(text.to_s), strip_const(t))
    raise QbeUnsupported, "NaN literal" if v.nan?

    body = v.infinite? ? (v.positive? ? "inf" : "-inf") : format("%a", v)
    "#{cls(t)}_#{body}"
  end

  # One function. An SSA register %N is %vN, a parameter %k is %pk, and an object of a slot that was not promoted
  # is %o<i>, allocated on the stack at entry.
  class Fn
    attr_reader :lines

    def initialize(form)
      @form = form
      @name = form[1].raw.delete('"')
      @ret = form.find { |x| head(x) == "ret" }
      @params = form.find { |x| head(x) == "params" }.drop(1).select { |p| head(p) == "param" }
      @slots = form.select { |x| head(x) == "slot" }
      @blocks = form.select { |x| head(x) == "bb" }
      @lines = []
      @temps = 0
      @splits = 0
      @trap_used = false
      @types = {}
      @params_set = {}
      @slot = {}
      @jumper = {}     # [target block, source block] => the emitted label whose jump reaches target
      @phi_expr = {}   # [block, pred, phi register] => the temporary of an expression phi operand
    end

    def emit
      header
      allocs
      plan_phis
      @blocks.each do |b|
        @cur = b[1].to_s
        @label = block_label(@cur)
        @lines << "@#{@label}"
        items = b[2..]
        items[0...-1].each { |item| item_lines(item) }
        pending_phi_operands(@cur)
        item_lines(items.last) if items.any?
      end
      @lines << "@ftrap" << "  hlt" if @trap_used
      @lines << "}"
      resolve_phi_predecessors
      self
    end

    private

    def header
      @params.each do |p|
        @types[p[1]] = p[3]
        @params_set[p[1]] = true
      end
      ret = @ret[1] == "void" ? "" : "#{Qbe.cls(@ret[1])} "
      sig = @params.map { |p| "#{Qbe.cls(p[3])} %p#{p[1][1..]}" }.join(", ")
      @lines << "export function #{ret}$#{@name}(#{sig}) {"
      @lines << "@start"
    end

    def allocs
      @slots.each_with_index do |s, i|
        @slot["$#{s[1].raw}"] = "%o#{i}"
        size = Qbe.size(s[2])
        @lines << "  %o#{i} =l alloc#{size >= 8 ? 8 : size} #{size}"
      end
      @blocks.each { |b| b[2..].each { |it| note_type(it) } }
    end

    def note_type(item)
      @types[item[1]] = item[2] if %w[let phi].include?(head(item))
    end

    def reg(name) = "%v#{name[1..]}"

    def block_label(num) = "b#{num}"

    def expression?(v) = v.is_a?(Array) && !%w[const null].include?(head(v))

    # Checks that need no emission: a switch's targets may not repeat where a phi reads them, and a phi operand that is an
    # expression is computed at the end of its predecessor, so the phi reads a temporary.
    def plan_phis
      @phi_blocks = {}
      @blocks.each do |b|
        @phi_blocks[b[1].to_s] = true if b[2..].any? { |it| head(it) == "phi" }
      end
      @blocks.each do |b|
        b[2..].each do |it|
          next unless head(it) == "switch"

          cases, default = switch_parts(it)
          targets = cases.map(&:last) + [default]
          dup = targets.find { |t| targets.count(t) > 1 }
          raise QbeUnsupported, "switch edges to block #{dup} that has phi" if dup && @phi_blocks[dup]
        end
      end
      @pending = Hash.new { |h, k| h[k] = [] }
      @blocks.each do |b|
        b[2..].each do |it|
          next unless head(it) == "phi"

          it[3..].each do |pred, v|
            next unless expression?(v)

            name = "%pe#{it[1][1..]}_#{pred}"
            @pending[pred.to_s] << [name, v]
            @phi_expr[[b[1].to_s, pred.to_s, it[1]]] = name
          end
        end
      end
    end

    def pending_phi_operands(num)
      @pending.fetch(num, []).each do |name, v|
        let_lines(name, v[1], v)
        @types[name] = v[1]
      end
    end

    # A phi names its predecessors by block. The label that jumps to a block is known only once the predecessor is
    # emitted (a split block may have taken its jump), so the phi carries a placeholder, resolved at the end.
    def phi_placeholder(target, pred) = "@@J#{target}_#{pred}@@"

    def resolve_phi_predecessors
      @lines.map! do |l|
        l.gsub(/@@J(\d+)_(\d+)@@/) do
          key = [Regexp.last_match(1), Regexp.last_match(2)]
          "@#{@jumper.fetch(key) { block_label(key[1]) }}"
        end
      end
    end

    # A jump from the current block to target: the phi of target names the label that jumps.
    def jump_to(target)
      @jumper[[target.to_s, @cur]] = @label
    end

    def switch_parts(item)
      cases = item[2..].select { |c| head(c) == "case" }.map { |c| [c[1], c[2].to_s] }
      default = item[2..].find { |c| head(c) == "default" } or raise QbeUnsupported, "switch without a default"
      [cases, default[1].to_s]
    end

    # The class and the value text of a switch operand's comparison.
    def operand_type(x)
      return x[1] if x.is_a?(Array) && head(x) == "const"
      return "ptr" if x.is_a?(Array) && head(x) == "null"

      @types.fetch(x) { raise QbeUnsupported, "operand #{sx(x)} has no declared type" }
    end

    # A switch is a chain of tests; the first is in the block where the switch is emitted, each later one in its own
    # block. QBE has no switch, so each test is `jnz` on an equality.
    def switch_lines(item)
      cases, default = switch_parts(item)
      if cases.empty?
        jump_to(default)
        @lines << "  jmp @#{block_label(default)}"
        return
      end
      opnd = item[1]
      if expression?(opnd)
        name = "%swop#{@cur}"
        let_lines(name, opnd[1], opnd)
        @types[name] = opnd[1]
        operand = reg(name)
      else
        operand = op(opnd)
      end
      cls = Qbe.cls(operand_type(opnd))
      labels = [@label] + (1...cases.size).map { |k| "#{block_label(@cur)}.s#{k}" }
      cases.each_with_index do |(value, target), k|
        cond = "%sw#{@cur}_#{k}"
        @lines << "  #{cond} =w ceq#{cls} #{operand}, #{Qbe.int_lit(value)}"
        jump_to_from(target, labels[k])
        next_label = k + 1 < cases.size ? labels[k + 1] : nil
        jump_to_from(default, labels[k]) if next_label.nil?
        @lines << "  jnz #{cond}, @#{block_label(target)}, @#{next_label || block_label(default)}"
        @lines << "@#{next_label}" if next_label
      end
    end

    # A jump from the test block label to target (the block of a switch test).
    def jump_to_from(target, label)
      @jumper[[target.to_s, @cur]] = label
    end

    # An operand: a register, a parameter, a literal, null, the address of an object, or a nested expression (computed into
    # a temporary whose line is appended before the caller's line).
    def op(x)
      case x
      when Ref
        raise QbeUnsupported, "global #{x.raw}" unless x.sigil == "$"

        @slot.fetch("$#{x.raw}") { raise QbeUnsupported, "slot #{x.raw}" }
      when String
        raise QbeUnsupported, "operand #{x}" unless x.start_with?("%")

        @params_set[x] ? "%p#{x[1..]}" : reg(x)
      when Array
        case head(x)
        when "const"
          return Qbe.float_lit(x[1], x[2]) if Qbe.float?(x[1])

          Qbe.int_lit(x[2]).to_s
        when "null" then "0"
        else
          raise QbeUnsupported, "operand #{sx(x)}" unless expression?(x)

          name = "%ne#{@temps += 1}"
          t = CMP_HEADS.include?(head(x)) ? "bool" : x[1]
          let_lines(name, t, x)
          @types[name] = t
          reg(name)
        end
      else raise QbeUnsupported, "operand #{sx(x)}"
      end
    end

    def item_lines(item)
      case head(item)
      when "phi"
        pairs = item[3..].map do |pred, v|
          text = expression?(v) ? reg(@phi_expr.fetch([@cur, pred.to_s, item[1]])) : op(v)
          "#{phi_placeholder(@cur, pred)} #{text}"
        end.join(", ")
        @lines << "  #{reg(item[1])} =#{Qbe.cls(item[2])} phi #{pairs}"
      when "let" then let_lines(item[1], item[2], item[3])
      when "store" then @lines << "  #{Qbe.store_op(item[1])} #{op(item[3])}, #{op(item[2])}"
      when "br"
        jump_to(item[1])
        @lines << "  jmp @#{block_label(item[1])}"
      when "switch" then switch_lines(item)
      when "condbr"
        cond = op(item[1])
        jump_to(item[2])
        jump_to(item[3])
        @lines << "  jnz #{cond}, @#{block_label(item[2])}, @#{block_label(item[3])}"
      when "ret" then @lines << (item.size > 1 ? "  ret #{op(item[1])}" : "  ret")
      when "unreachable" then @lines << "  hlt"
      else raise QbeUnsupported, "statement #{head(item) || sx(item)}"
      end
    end

    def let_lines(r, t, rv)
      dst = reg(r)
      c = Qbe.cls(t)
      case head(rv)
      when *Qbe::BIN.keys
        @lines << "  #{dst} =#{c} #{Qbe::BIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
      when "wneg" then @lines << "  #{dst} =#{c} sub 0, #{op(rv[2])}"
      when *Qbe::FBIN.keys
        @lines << "  #{dst} =#{c} #{Qbe::FBIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
      when "fneg" then @lines << "  #{dst} =#{c} neg #{op(rv[2])}"
      when *Qbe::CMP.keys
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::CMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when *Qbe::FCMP.keys
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::FCMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when "iconv" then conv_lines(dst, t, rv[2])
      when "i2f", "u2f" then int_to_float_lines(dst, t, rv[2])
      when "fconv" then float_conv_lines(dst, t, rv[2])
      when "cf2i" then float_to_int_lines(dst, t, rv[2])
      when "load" then @lines << "  #{dst} =#{c} #{Qbe.load_op(rv[1])} #{op(rv[2])}"
      when "const", "null", nil
        @lines << "  #{dst} =#{c} copy #{op(rv)}" if rv.is_a?(Array) || rv.is_a?(String)
        raise QbeUnsupported, "let of #{sx(rv)}" unless rv.is_a?(Array) || rv.is_a?(String)
      else raise QbeUnsupported, "operator #{head(rv) || sx(rv)}"
      end
    end

    # The type of an operand: a literal's own type, or the type of a register.
    def source_type(x)
      x.is_a?(Array) && head(x) == "const" ? x[1] : @types.fetch(x) { raise QbeUnsupported, "untyped operand #{sx(x)}" }
    end

    # An integer conversion to type t from the operand x. A widening keeps the value; a conversion to bool compares
    # with zero; a conversion to a narrower type sign- or zero-extends the low bits.
    def conv_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "float to integer by iconv" if Qbe.float?(src)

      dc = Qbe.cls(t)
      sc = Qbe.cls(src)
      if dc == "l" && sc == "w"
        @lines << "  #{dst} =l #{Qbe.signed?(src) ? 'extsw' : 'extuw'} #{op(x)}"
      elsif dc == "w" && sc == "l" && t != "bool" && !Qbe::EXT.key?(t)
        @lines << "  #{dst} =w copy #{op(x)}"
      elsif t == "bool"
        @lines << "  #{dst} =w cne#{sc} #{op(x)}, 0"
      elsif Qbe::EXT.key?(t)
        @lines << "  #{dst} =w ext#{Qbe::EXT[t]} #{op(x)}"
      else
        @lines << "  #{dst} =#{dc} copy #{op(x)}"
      end
    end

    # An integer to a float: the IEEE conversion of the integer, rounded once to the target (as the interpreter's
    # conversion of an integer up to 2**53 is). The conversion follows the signedness of the source type.
    def int_to_float_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "integer to float of a float" if Qbe.float?(src)

      name = { ["w", true] => "swtof", ["w", false] => "uwtof", ["l", true] => "sltof", ["l", false] => "ultof" }
             .fetch([Qbe.cls(src), Qbe.signed?(src)]) { raise QbeUnsupported, "integer to float of #{sx(src)}" }
      @lines << "  #{dst} =#{Qbe.cls(t)} #{name} #{op(x)}"
    end

    # A float to a float of another precision: a rounding to single (truncd) or an exact widening (exts).
    def float_conv_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "float conversion of an integer" unless Qbe.float?(src)

      if t == src
        @lines << "  #{dst} =#{Qbe.cls(t)} copy #{op(x)}"
      elsif t == "float"
        @lines << "  #{dst} =s truncd #{op(x)}"
      else
        @lines << "  #{dst} =d exts #{op(x)}"
      end
    end

    # A float to an integer, truncating toward zero. The interpreter traps on NaN, an infinity, or a value outside the
    # target type. The check is an exact range test: the truncated value is in [lo, hi] exactly when x is in
    # (lo - 1, hi + 1), and a float source is first widened to double so that the bounds are exact. A failed check
    # jumps to a shared `hlt`, which stops the program as the interpreter's trap does.
    def float_to_int_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "float to integer of #{sx(src)}" unless Qbe.float?(src)
      raise QbeUnsupported, "float to bool" if t == "bool"

      w, signed = int_info(t)
      xv = op(x)
      if src == "float"
        widened = "%fx#{@temps += 1}"
        @lines << "  #{reg(widened)} =d exts #{xv}"
        xv = reg(widened)
      end
      if signed
        lo = w == 64 ? -(2**63) : -(2**(w - 1)) - 1
        lower = w == 64 ? ["cged", -(2**63)] : ["cgtd", lo]
      else
        lower = ["cgtd", -1]
      end
      upper = ["cltd", signed ? 2**(w - 1) : 2**w]
      tests = [lower, upper].map do |cmp, bound|
        tmp = "%fc#{@temps += 1}"
        @lines << "  #{tmp} =w #{cmp} #{xv}, #{Qbe.float_lit('double', bound.to_f.to_s)}"
        tmp
      end
      ok = "%fc#{@temps += 1}"
      @lines << "  #{ok} =w and #{tests[0]}, #{tests[1]}"
      @splits += 1
      split = "#{block_label(@cur)}.f#{@splits}"
      @trap_used = true
      @lines << "  jnz #{ok}, @#{split}, @ftrap"
      @lines << "@#{split}"
      @label = split
      @lines << "  #{dst} =#{Qbe.cls(t)} #{signed ? 'dtosi' : 'dtoui'} #{xv}"
    end
  end

  # The QBE IL of every function of the module (its globals and other declarations are not emitted yet).
  def module_il(forms)
    forms.select { |f| head(f) == "ssa-function" }.map { |f| Fn.new(f).emit.lines.join("\n") }.join("\n\n") + "\n"
  end
end

if $PROGRAM_NAME == __FILE__
  file = ARGV.first or abort "usage: pathb-ssa-qbe.rb FILE.ssa"
  print Qbe.module_il(read_forms(File.read(file)))
end
