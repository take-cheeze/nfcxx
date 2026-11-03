#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SSA to QBE (docs/notes/pathb-ssa-qbe.md). Reads the SSA text of a module (scripts/pathb-ssa.rb, optionally optimised
# by scripts/pathb-egraph.rb) and writes QBE IL, which is SSA with blocks and phi. The first subset: integer and pointer
# scalars, arithmetic, comparisons, integer conversions, loads and stores of scalar objects, phi, branches and return.
# A function outside the subset raises QbeUnsupported; nothing is emitted for it.
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
           "long" => "loadl", "long_long" => "loadl", "unsigned_long" => "loadl", "unsigned_long_long" => "loadl" }.freeze
  STORE = { "bool" => "storeb", "char" => "storeb", "signed_char" => "storeb", "unsigned_char" => "storeb",
            "short" => "storeh", "unsigned_short" => "storeh", "int" => "storew", "unsigned_int" => "storew",
            "long" => "storel", "long_long" => "storel", "unsigned_long" => "storel", "unsigned_long_long" => "storel" }.freeze
  SIZE = { "bool" => 1, "char" => 1, "signed_char" => 1, "unsigned_char" => 1, "short" => 2, "unsigned_short" => 2,
           "int" => 4, "unsigned_int" => 4, "long" => 8, "long_long" => 8, "unsigned_long" => 8,
           "unsigned_long_long" => 8 }.freeze
  EXT = { "char" => "sb", "signed_char" => "sb", "unsigned_char" => "ub", "short" => "sh", "unsigned_short" => "uh" }.freeze
  BIN = { "wadd" => "add", "wsub" => "sub", "wmul" => "mul", "and" => "and", "or" => "or", "xor" => "xor" }.freeze
  CMP = { "eq" => "ceq", "ne" => "cne", "lt.s" => "cslt", "lt.u" => "cult", "le.s" => "csle", "le.u" => "cule" }.freeze
  CMP_HEADS = CMP.keys.freeze

  module_function

  # The QBE class of an integer or pointer type: w for 32-bit and narrower integers, l for 64-bit ones and pointers.
  def cls(t)
    t = strip_const(t)
    return "l" if head(t) == "ptr"
    return "w" if INT_W.include?(t)
    return "l" if INT_L.include?(t)

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
      @types = {}
      @params_set = {}
      @slot = {}
    end

    def emit
      header
      allocs
      plan_switches
      @blocks.each do |b|
        @cur = b[1].to_s
        @lines << "@#{block_label(@cur)}"
        items = b[2..]
        items[0...-1].each { |item| item_lines(item) }
        pending_phi_operands(@cur)
        item_lines(items.last) if items.any?
      end
      @lines << "}"
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

    # The label a phi of block @cur uses for its predecessor pred: the test block that jumps to @cur.
    def jumper_label(pred)
      @jumper.fetch([@cur, pred.to_s], block_label(pred))
    end

    # A switch is a chain of tests, one block per case after the first (the first test is in the switch's own block).
    # QBE has no switch, so each test is `jnz` on an equality. A phi names the block that jumps to it, so for each
    # target the label of the test block that jumps there is recorded in @jumper.
    def plan_switches
      @jumper = {}
      @phi_blocks = {}
      @phi_expr = {}
      @blocks.each do |b|
        @phi_blocks[b[1].to_s] = true if b[2..].any? { |it| head(it) == "phi" }
      end
      @blocks.each do |b|
        b[2..].each { |it| plan_switch(b[1].to_s, it) if head(it) == "switch" }
      end
      # A phi operand that is an expression is computed at the end of its predecessor, so the phi reads a temporary.
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

    def expression?(v) = v.is_a?(Array) && !%w[const null].include?(head(v))

    def pending_phi_operands(num)
      @pending.fetch(num, []).each do |name, v|
        let_lines(name, v[1], v)
        @types[name] = v[1]
      end
    end

    def switch_parts(item)
      cases = item[2..].select { |c| head(c) == "case" }.map { |c| [c[1], c[2].to_s] }
      default = item[2..].find { |c| head(c) == "default" } or raise QbeUnsupported, "switch without a default"
      [cases, default[1].to_s]
    end

    # The labels of the test blocks of block num: the first is the block itself.
    def test_labels(num, cases)
      [block_label(num)] + (1...cases.size).map { |k| "#{block_label(num)}.s#{k}" }
    end

    def plan_switch(num, item)
      cases, default = switch_parts(item)
      targets = cases.map(&:last) + [default]
      dup = targets.find { |t| targets.count(t) > 1 }
      if dup && @phi_blocks[dup]
        raise QbeUnsupported, "switch edges to block #{dup} that has phi"
      end

      labels = test_labels(num, cases)
      cases.each_with_index { |(_, t), k| @jumper[[t, num]] = labels[k] }
      @jumper[[default, num]] = labels.last
    end

    # The class and the value text of a switch operand's comparison.
    def switch_operand_type(x)
      return x[1] if x.is_a?(Array) && head(x) == "const"
      return "ptr" if x.is_a?(Array) && head(x) == "null"

      @types.fetch(x) { raise QbeUnsupported, "switch operand #{sx(x)} has no declared type" }
    end

    def switch_lines(num, item)
      cases, default = switch_parts(item)
      labels = test_labels(num, cases)
      if cases.empty?
        @lines << "  jmp @#{block_label(default)}"
        return
      end
      opnd = item[1]
      if opnd.is_a?(Array) && !%w[const null].include?(head(opnd))
        # An operator in operand position: computed into a temporary first, in the switch's own block.
        name = "%swop#{num}"
        let_lines(name, opnd[1], opnd)
        @types[name] = opnd[1]
        operand = reg(name)
      else
        operand = op(opnd)
      end
      cls = Qbe.cls(switch_operand_type(opnd))
      cases.each_with_index do |(value, target), k|
        cond = "%sw#{num}_#{k}"
        @lines << "  #{cond} =w ceq#{cls} #{operand}, #{Qbe.int_lit(value)}"
        next_label = k + 1 < cases.size ? "@#{labels[k + 1]}" : "@#{block_label(default)}"
        @lines << "  jnz #{cond}, @#{block_label(target)}, #{next_label}"
        @lines << "@#{labels[k + 1]}" if k + 1 < cases.size
      end
    end

    # An operand: a register, a parameter, an integer constant, null, or the address of an object.
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
          raise QbeUnsupported, "float constant #{sx(x)}" if float_type?(x[1])

          Qbe.int_lit(x[2]).to_s
        when "null" then "0"
        else
          # A nested expression: computed into a temporary, whose line is appended before the caller's line.
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
          "@#{jumper_label(pred)} #{text}"
        end.join(", ")
        @lines << "  #{reg(item[1])} =#{Qbe.cls(item[2])} phi #{pairs}"
      when "let" then let_lines(item[1], item[2], item[3])
      when "store" then @lines << "  #{Qbe.store_op(item[1])} #{op(item[3])}, #{op(item[2])}"
      when "br" then @lines << "  jmp @#{block_label(item[1])}"
      when "switch" then switch_lines(@cur, item)
      when "condbr" then @lines << "  jnz #{op(item[1])}, @#{block_label(item[2])}, @#{block_label(item[3])}"
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
      when *Qbe::CMP.keys
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::CMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when "iconv" then conv_lines(dst, t, rv[2])
      when "load" then @lines << "  #{dst} =#{c} #{Qbe.load_op(rv[1])} #{op(rv[2])}"
      when "const", "null", nil
        @lines << "  #{dst} =#{c} copy #{op(rv)}" if rv.is_a?(Array) || rv.is_a?(String)
        raise QbeUnsupported, "let of #{sx(rv)}" unless rv.is_a?(Array) || rv.is_a?(String)
      else raise QbeUnsupported, "operator #{head(rv) || sx(rv)}"
      end
    end

    # An integer conversion to type t from the operand x. A widening keeps the value; a conversion to bool compares
    # with zero; a conversion to a narrower type sign- or zero-extends the low bits.
    def conv_lines(dst, t, x)
      src = x.is_a?(Array) && head(x) == "const" ? x[1] : @types[x]
      raise QbeUnsupported, "conversion of an untyped operand #{sx(x)}" unless src

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

    def float_type?(t) = FLOAT_TYPES.key?(strip_const(t))
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
