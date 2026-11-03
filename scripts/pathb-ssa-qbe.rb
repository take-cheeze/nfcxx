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
      @types = {}
      @params_set = {}
      @slot = {}
    end

    def emit
      header
      allocs
      @blocks.each do |b|
        @lines << "@b#{b[1]}"
        b[2..].each { |item| item_lines(item) }
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
        else raise QbeUnsupported, "operand #{sx(x)}"
        end
      else raise QbeUnsupported, "operand #{sx(x)}"
      end
    end

    def item_lines(item)
      case head(item)
      when "phi"
        pairs = item[3..].map { |pred, v| "@b#{pred} #{op(v)}" }.join(", ")
        @lines << "  #{reg(item[1])} =#{Qbe.cls(item[2])} phi #{pairs}"
      when "let" then let_lines(item[1], item[2], item[3])
      when "store" then @lines << "  #{Qbe.store_op(item[1])} #{op(item[3])}, #{op(item[2])}"
      when "br" then @lines << "  jmp @b#{item[1]}"
      when "condbr" then @lines << "  jnz #{op(item[1])}, @b#{item[2]}, @b#{item[3]}"
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
