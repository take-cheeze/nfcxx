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
  # Float operations: the comparisons are ordered (false on NaN), as the interpreter's < and <= are.
  FBIN = { "fadd" => "add", "fsub" => "sub", "fmul" => "mul", "fdiv" => "div" }.freeze
  FCMP = { "lt.f" => "clt", "le.f" => "cle" }.freeze
  CMP_HEADS = (CMP.keys + FCMP.keys).freeze
  # The access of a bit-field's storage unit, by its size in bytes (pathb-qbe-emit.rb's BF_LOAD and BF_STORE).
  BF_LOAD = { 1 => "loadub", 2 => "loaduh", 4 => "loadw", 8 => "loadl" }.freeze
  BF_STORE = { 1 => "storeb", 2 => "storeh", 4 => "storew", 8 => "storel" }.freeze

  module_function

  def float?(t) = FLOAT_TYPES.key?(strip_const(t))

  # The QBE class of a scalar type: w for 32-bit and narrower integers, l for 64-bit ones and pointers, s and d for
  # float and double.
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
    return size(t[1]) if head(t) == "volatile"
    return 8 if head(t) == "ptr"
    return size(t[1]) * int_lit(t[2]) if head(t) == "array"

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

  # The type of an operator expression: a comparison is bool, an address is a pointer, and any other operator carries its type in its second element.
  def expr_type(x)
    return "bool" if CMP_HEADS.include?(head(x))
    return ["ptr", "void"] if %w[addr index offset].include?(head(x))

    x[1]
  end

  # An integer literal: decimal, or hexadecimal with a 0x prefix (the reader keeps the spelling of a literal).
  def int_lit(s)
    return s if s.is_a?(Integer)
    return Integer(s, 16) if s.match?(/\A0[xX]/)
    return -Integer(s[1..], 16) if s.match?(/\A-0[xX]/)

    Integer(s, 10)
  end

  # A constant of type t, wrapped to its QBE class (w: 32 bits, l: 64 bits), as the target computes it.
  def wrap_lit(v, t)
    bits = cls(t) == "w" ? 32 : 64
    v &= (1 << bits) - 1
    v >= 1 << (bits - 1) ? v - (1 << bits) : v
  end

  # A float literal of type t: the value is rounded to t as the interpreter rounds it, then written as an exact hex float
  # (QBE reads it with scanf). Infinities are written as inf; NaN is not a literal of the subset.
  def float_lit(t, text)
    v = round_float(Float(text.to_s), strip_const(t))
    raise QbeUnsupported, "NaN literal" if v.nan?

    body = v.infinite? ? (v.positive? ? "inf" : "-inf") : format("%a", v)
    "#{cls(t)}_#{body}"
  end

  # The QBE symbol of a quoted SSA name: letters, digits, `_` and `.` stay; any other byte is escaped.
  def symbol(raw) = raw.delete('"').gsub(/[^A-Za-z0-9_.]/) { |c| "_x#{c.ord.to_s(16)}_" }

  # The data of one global (install_module's rules, emitted as QBE data): zero bytes, integer and pointer scalars, and
  # addresses of other module globals. A global with an extern or thread-local storage class, a float, a bitfield or
  # any other initialiser is not emitted; a reference to it raises QbeUnsupported. Returns the data line or nil.
  def global_data(g, by_name, state)
    name = g[1].raw
    if state.key?(name)
      return state[name] == :busy ? nil : state[name]
    end

    state[name] = :busy
    state[name] = build_data(g, by_name, state)
  end

  def build_data(g, by_name, state)
    flags = g.map { |x| x.is_a?(Array) ? head(x) : x }
    return nil if flags.include?("extern") || flags.include?("thread")

    init = g.find { |x| head(x) == "init" } or return nil
    size = int_lit(g[3])
    align = [int_lit(g[4]), 1].max
    items = []
    init[1..].each do |item|
      case head(item)
      when "zero" then next
      when "scalar"
        off, type, v = item[1..]
        return nil if FLOAT_TYPES.key?(strip_const(type))

        bytes = Qbe.size(type)
        letter = { 1 => "b", 2 => "h", 4 => "w", 8 => "l" }.fetch(bytes) { return nil }
        items << [int_lit(off), bytes, "#{letter} #{literal(v, type)}"]
      when "addr"
        off, _type, target, add = item[1..]
        return nil unless target.is_a?(Ref) && target.sigil == "@" && by_name.key?(target.raw)
        # A global may point into itself; a longer cycle of addresses is left out (global_data returns nil for it).
        return nil unless target.raw == g[1].raw || global_data(by_name[target.raw], by_name, state)

        suffix = int_lit(add).zero? ? "" : " + #{int_lit(add)}"
        items << [int_lit(off), 8, "l $#{symbol(target.raw)}#{suffix}"]
      else return nil
      end
    end
    parts = []
    cur = 0
    items.sort_by(&:first).each do |off, bytes, text|
      parts << "z #{off - cur}" if off > cur
      parts << text
      cur = off + bytes
    end
    parts << "z #{size - cur}" if size > cur
    parts = ["z #{size}"] if parts.empty?
    "data $#{symbol(g[1].raw)} = align #{align} { #{parts.join(', ')} }"
  end

  # One function. An SSA register %N is %vN, a parameter %k is %pk, and an object of a slot that was not promoted
  # is %o<i>, allocated on the stack at entry.
  class Fn
    attr_reader :lines

    # globals: the raw names of the module globals that are emitted (a reference to any other global raises).
    def initialize(form, globals = {})
      @form = form
      @globals = globals
      @name = Qbe.symbol(form[1].raw)
      @ret = form.find { |x| head(x) == "ret" }
      @params = form.find { |x| head(x) == "params" }.drop(1).select { |p| head(p) == "param" }
      @slots = form.select { |x| head(x) == "slot" }
      @blocks = form.select { |x| head(x) == "bb" }
      @lines = []
      @temps = 0
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
        # A slot carries its own size and alignment (slot NAME TYPE SIZE ALIGN); a scalar's size is also its type's.
        size = s.size > 4 ? Qbe.int_lit(s[3]) : Qbe.size(s[2])
        align = s.size > 4 ? Qbe.int_lit(s[4]) : size
        a = [16, 8, 4, 2].find { |k| align >= k } || 1
        @lines << "  %o#{i} =l alloc#{a} #{[size, 1].max}"
      end
      @blocks.each { |b| b[2..].each { |it| note_type(it) } }
    end

    def note_type(item)
      @types[item[1]] = item[2] if %w[let phi].include?(head(item))
    end

    def reg(name) = "%v#{name[1..]}"

    def block_label(num) = "b#{num}"

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

    # A phi names its predecessors by block. The label that jumps to a block is known only once the predecessor is
    # emitted (a split block may take the jump), so the phi carries a placeholder, resolved at the end.
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

    # The type of an operand: a constant's or an expression's own type, or the declared type of a register.
    def switch_operand_type(x)
      return x[1] if x.is_a?(Array) && head(x) == "const"
      return "ptr" if x.is_a?(Array) && head(x) == "null"
      return Qbe.expr_type(x) if expression?(x)

      @types.fetch(x) { raise QbeUnsupported, "operand #{sx(x)} has no declared type" }
    end

    # A switch is a chain of tests; the first is in the block where the switch is emitted, each later one in its own
    # block. QBE has no switch, so each test is `jnz` on an equality. Each jump is recorded for the phi of its target.
    def switch_lines(item)
      cases, default = switch_parts(item)
      if cases.empty?
        jump_to(default)
        @lines << "  jmp @#{block_label(default)}"
        return
      end
      opnd = item[1]
      if expression?(opnd)
        # An operator in operand position: computed into a temporary first, in the switch's own block.
        name = "%swop#{@cur}"
        let_lines(name, opnd[1], opnd)
        @types[name] = opnd[1]
        operand = reg(name)
      else
        operand = op(opnd)
      end
      cls = Qbe.cls(switch_operand_type(opnd))
      labels = [@label] + (1...cases.size).map { |k| "#{block_label(@cur)}.s#{k}" }
      cases.each_with_index do |(value, target), k|
        cond = "%sw#{@cur}_#{k}"
        @lines << "  #{cond} =w ceq#{cls} #{operand}, #{Qbe.int_lit(value)}"
        @jumper[[target, @cur]] = labels[k]
        if k + 1 < cases.size
          @lines << "  jnz #{cond}, @#{block_label(target)}, @#{labels[k + 1]}"
          @lines << "@#{labels[k + 1]}"
        else
          @jumper[[default, @cur]] = labels[k]
          @lines << "  jnz #{cond}, @#{block_label(target)}, @#{block_label(default)}"
        end
      end
    end

    # An operand: a register, a parameter, an integer constant, null, or the address of an object.
    def op(x)
      case x
      when Ref
        if x.sigil == "@"
          raise QbeUnsupported, "global #{x.raw}" unless @globals[x.raw]

          return "$#{Qbe.symbol(x.raw)}"
        end
        raise QbeUnsupported, "address #{x.raw}" unless x.sigil == "$"

        @slot.fetch("$#{x.raw}") { raise QbeUnsupported, "slot #{x.raw}" }
      when String
        raise QbeUnsupported, "operand #{x}" unless x.start_with?("%")

        @params_set[x] ? "%p#{x[1..]}" : reg(x)
      when Array
        case head(x)
        when "const"
          return Qbe.float_lit(x[1], x[2]) if float_type?(x[1])

          Qbe.wrap_lit(Qbe.int_lit(x[2]), x[1]).to_s
        when "null" then "0"
        when "addr" then op(x[1])
        when "addr" then op(x[1])
        else
          # A nested expression: computed into a temporary, whose line is appended before the caller's line.
          raise QbeUnsupported, "operand #{sx(x)}" unless expression?(x)

          name = "%ne#{@temps += 1}"
          t = Qbe.expr_type(x)
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
      # A volatile store is emitted as an ordinary store: QBE does not reorder or drop a store, and the statements of a
      # block keep their order.
      when "store", "store.v" then @lines << "  #{Qbe.store_op(item[1])} #{op(item[3])}, #{op(item[2])}"
      # `(copy N DST SRC)`: N bytes from SRC to DST (the interpreter's copy_cells). QBE's blit copies a byte count.
      when "copy"
        # The addresses of a copy are pointers. A register holding a by-value aggregate (a byval parameter) is not one:
        # that ABI case is refused, not emitted.
        [item[2], item[3]].each do |a|
          next unless a.is_a?(String) && a.start_with?("%")

          t = @types[a]
          raise QbeUnsupported, "copy of the by-value aggregate #{a}" unless t.nil? || head(strip_const(t)) == "ptr"
        end
        @lines << "  blit #{op(item[3])}, #{op(item[2])}, #{Qbe.int_lit(item[1])}"
      when "br"
        jump_to(item[1])
        @lines << "  jmp @#{block_label(item[1])}"
      when "switch" then switch_lines(item)
      when "eval"
        raise QbeUnsupported, "statement #{sx(item)}" unless head(item[1]) == "call"

        @lines << "  #{call_text(item[1])}"
      when "condbr"
        cond = op(item[1])
        jump_to(item[2])
        jump_to(item[3])
        @lines << "  jnz #{cond}, @#{block_label(item[2])}, @#{block_label(item[3])}"
      when "ret" then @lines << (item.size > 1 ? "  ret #{op(item[1])}" : "  ret")
      when "unreachable" then @lines << "  hlt"
      when "bfstore", "bfstore.v" then bfstore_lines(item)
      when "nonnull" then nonnull_lines(item[1])
      when "bounds" then bounds_lines(item[1], item[2])
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
      when "cdiv", "crem" then checked_div_lines(dst, t, rv)
      when "cshl", "cshr" then checked_shift_lines(dst, t, rv)
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
      when "call" then @lines << "  #{dst} =#{c} #{call_text(rv)}"
      when "addr" then @lines << "  #{dst} =l copy #{op(rv)}"
      when "bfload", "bfload.v" then bfload_lines(dst, rv)
      when "offset" then @lines << "  #{dst} =l add #{op(rv[1])}, #{Qbe.int_lit(rv[2])}"
      when "index" then index_lines(dst, rv)
      # A volatile load is an ordinary load in the emitted code: the loads of a block keep their order.
      when "load", "load.v" then @lines << "  #{dst} =#{c} #{Qbe.load_op(rv[1])} #{op(rv[2])}"
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
      raise QbeUnsupported, "float to integer by iconv" if float_type?(src)

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

    # The checks of the interpreter (pathb-ssa.rb, Machine#eval_rv; pathb-egraph.rb, CheckedMachine for the shifts).
    # Each check is a call `pathb_check(cond, code)` before the operation: the runtime does not return when cond is
    # nonzero (it traps, or longjmps out in the test driver), so the operation after it is never reached with the
    # bad operands and no block is split. Codes: 1 division by zero, 2 signed overflow, 3 shift count out of range.
    def fresh = "%ck#{@temps += 1}"

    # The class of an operand whose type is known: a constant, a declared register, or an expression's type.
    def operand_type(x) = expression?(x) ? Qbe.expr_type(x) : switch_operand_type(x)

    # `(index BASE I SIZE)`: BASE plus I times SIZE. A 32-bit index is widened (signed or unsigned as its type) first.
    def index_lines(dst, rv)
      base = op(rv[1])
      idx = rv[2]
      signed = Qbe.signed?(operand_type(idx))
      i = op(idx)
      if Qbe.cls(operand_type(idx)) == "w"
        wide = fresh
        @lines << "  #{wide} =l #{signed ? 'extsw' : 'extuw'} #{i}"
        i = wide
      end
      scaled = fresh
      @lines << "  #{scaled} =l mul #{i}, #{Qbe.int_lit(rv[3])}"
      @lines << "  #{dst} =l add #{base}, #{scaled}"
    end

    # Bit-fields, with pathb-qbe-emit.rb's rules: `(bfload T UNIT ADDR BOFF WIDTH)` reads the whole UNIT-byte unit and
    # extracts WIDTH bits from bit BOFF (little-endian bit numbering), sign- or zero-extended to T. The extraction is a
    # shift pair, never an `and` with a low mask. `(bfstore T UNIT ADDR BOFF WIDTH VALUE)` replaces those bits of the
    # unit, leaves the others alone, and stores the whole unit back.
    def bf_args(x, nargs)
      raise QbeUnsupported, "#{head(x)} form" unless x.length == nargs

      unit = Qbe.int_lit(x[2])
      boff = Qbe.int_lit(x[4])
      width = Qbe.int_lit(x[5])
      raise QbeUnsupported, "#{head(x)} of a #{unit}-byte unit" unless Qbe::BF_LOAD.key?(unit)
      raise QbeUnsupported, "#{head(x)}: bits #{boff}+#{width} outside the unit" if width < 1 || boff < 0 || boff + width > unit * 8

      [unit, boff, width]
    end

    def bf_type!(ty)
      raise QbeUnsupported, "bit-field of type #{sx(ty)}" unless Qbe::INT_W.include?(ty) || Qbe::INT_L.include?(ty)
    end

    def bfload_lines(dst, rv)
      ty = rv[1]
      bf_type!(ty)
      unit, boff, width = bf_args(rv, 6)
      uc = unit == 8 ? "l" : "w"
      ub = unit * 8
      t = fresh
      @lines << "  #{t} =#{uc} #{Qbe::BF_LOAD[unit]} #{op(rv[3])}"
      if ub - boff - width > 0
        t2 = fresh
        @lines << "  #{t2} =#{uc} shl #{t}, #{ub - boff - width}"
        t = t2
      end
      signed = Qbe.signed?(ty)
      if ub - width > 0
        t2 = fresh
        @lines << "  #{t2} =#{uc} #{signed ? 'sar' : 'shr'} #{t}, #{ub - width}"
        t = t2
      end
      tc = Qbe.cls(ty)
      if tc != uc
        t2 = fresh
        @lines << (tc == "l" ? "  #{t2} =l #{signed ? 'extsw' : 'extuw'} #{t}" : "  #{t2} =w copy #{t}")
        t = t2
      end
      @lines << "  #{dst} =#{tc} copy #{t}"
    end

    def bfstore_lines(x)
      ty = x[1]
      bf_type!(ty)
      unit, boff, width = bf_args(x, 7)
      uc = unit == 8 ? "l" : "w"
      ub = unit * 8
      tc = Qbe.cls(ty)
      raise QbeUnsupported, "bit-field store of a value of another class" unless Qbe.cls(operand_type(x[6])) == tc

      addr = op(x[3])
      v = op(x[6])
      if tc != uc
        t2 = fresh
        @lines << (uc == "l" ? "  #{t2} =l extuw #{v}" : "  #{t2} =w copy #{v}")
        v = t2
      end
      old = fresh
      @lines << "  #{old} =#{uc} #{Qbe::BF_LOAD[unit]} #{addr}"
      if width < ub
        t2 = fresh
        @lines << "  #{t2} =#{uc} shl #{v}, #{ub - width}"
        v = t2
        if ub - width - boff > 0
          t3 = fresh
          @lines << "  #{t3} =#{uc} shr #{v}, #{ub - width - boff}"
          v = t3
        end
      end
      clear = ((1 << ub) - 1) ^ (((1 << width) - 1) << boff)
      nw = v
      if clear != 0
        keep = fresh
        if boff + width == ub
          # the field is the top of the unit: keep the low bits by a shift pair
          k1 = fresh
          @lines << "  #{k1} =#{uc} shl #{old}, #{ub - boff}"
          @lines << "  #{keep} =#{uc} shr #{k1}, #{ub - boff}"
        elsif boff.zero?
          # the field is the bottom of the unit: keep the high bits by a shift pair
          k1 = fresh
          @lines << "  #{k1} =#{uc} shr #{old}, #{width}"
          @lines << "  #{keep} =#{uc} shl #{k1}, #{width}"
        else
          signed_clear = uc == "w" && clear >= 1 << 31 ? clear - (1 << 32) : clear
          @lines << "  #{keep} =#{uc} and #{old}, #{signed_clear}"
        end
        nw = fresh
        @lines << "  #{nw} =#{uc} or #{keep}, #{v}"
      end
      @lines << "  #{Qbe::BF_STORE[unit]} #{nw}, #{addr}"
    end

    # `(nonnull P)`: a null pointer traps (code 5).
    def nonnull_lines(p)
      cond = fresh
      @lines << "  #{cond} =w ceql #{op(p)}, 0"
      @lines << "  call $pathb_check(w #{cond}, w 5)"
    end

    # `(bounds I N)`: an index outside [0, N) traps (code 6). The unsigned comparison also rejects a negative index.
    def bounds_lines(idx, n)
      c = Qbe.cls(operand_type(idx))
      i = op(idx)
      bad = fresh
      @lines << "  #{bad} =w cuge#{c} #{i}, #{Qbe.int_lit(n)}"
      @lines << "  call $pathb_check(w #{bad}, w 6)"
    end

    def checked_div_lines(dst, t, rv)
      raise QbeUnsupported, "#{head(rv)} of bool" if t == "bool"

      c = Qbe.cls(t)
      w, signed = int_info(t)
      a = op(rv[2])
      b = op(rv[3])
      zero = fresh
      @lines << "  #{zero} =w ceq#{c} #{b}, 0"
      @lines << "  call $pathb_check(w #{zero}, w 1)"
      if signed
        lo = fresh
        minus_one = fresh
        both = fresh
        @lines << "  #{lo} =w ceq#{c} #{a}, #{-(1 << (w - 1))}"
        @lines << "  #{minus_one} =w ceq#{c} #{b}, -1"
        @lines << "  #{both} =w and #{lo}, #{minus_one}"
        @lines << "  call $pathb_check(w #{both}, w 2)"
      end
      name = head(rv) == "cdiv" ? (signed ? "div" : "udiv") : (signed ? "rem" : "urem")
      @lines << "  #{dst} =#{c} #{name} #{a}, #{b}"
    end

    # The count must be in [0, w): an unsigned comparison of the count against w also rejects a negative count.
    def checked_shift_lines(dst, t, rv)
      raise QbeUnsupported, "#{head(rv)} of bool" if t == "bool"

      c = Qbe.cls(t)
      w, signed = int_info(t)
      a = op(rv[2])
      count_cls = Qbe.cls(switch_operand_type(rv[3]))
      n = op(rv[3])
      if count_cls == "l" && c == "w"
        narrowed = fresh
        @lines << "  #{narrowed} =w copy #{n}"
        n = narrowed
      end
      bad = fresh
      @lines << "  #{bad} =w cuge#{count_cls} #{n}, #{w}"
      @lines << "  call $pathb_check(w #{bad}, w 3)"
      if head(rv) == "cshl"
        shifted = fresh
        @lines << "  #{shifted} =#{c} shl #{a}, #{n}"
        canon_lines(dst, t, shifted)
      else
        @lines << "  #{dst} =#{c} #{signed ? 'sar' : 'shr'} #{a}, #{n}"
      end
    end

    # The value of t in its low bits, sign- or zero-extended as the canonical form of t (a cshl wraps to the type).
    def canon_lines(dst, t, src)
      if Qbe::EXT.key?(t)
        @lines << "  #{dst} =w ext#{Qbe::EXT[t]} #{src}"
      else
        @lines << "  #{dst} =#{Qbe.cls(t)} copy #{src}"
      end
    end

    # A call `(call RET &"name" ARG...)`: a direct call of a C symbol. The module's functions are exported under their
    # names, and any other callee is linked as a C function. Each argument is passed with the class of its value.
    def call_text(c)
      f = c[2]
      raise QbeUnsupported, "indirect call #{sx(f)}" unless f.is_a?(Ref) && f.sigil == "&"

      args = c[3..].map { |a| "#{arg_cls(a)} #{op(a)}" }
      "call $#{Qbe.symbol(f.raw)}(#{args.join(', ')})"
    end

    def arg_cls(a)
      case a
      when Ref then "l"
      when String then Qbe.cls(@types.fetch(a) { raise QbeUnsupported, "argument #{a} has no declared type" })
      when Array
        case head(a)
        when "addr", "null" then "l"
        when "const" then Qbe.cls(a[1])
        else Qbe.cls(Qbe.expr_type(a))
        end
      else raise QbeUnsupported, "argument #{sx(a)}"
      end
    end

    def float_type?(t) = Qbe.float?(t)

    # The type of an operand: a literal's own type, or the type of a register or an expression.
    def source_type(x)
      return x[1] if x.is_a?(Array) && head(x) == "const"
      return switch_operand_type(x) if expression?(x) || x.is_a?(Array)

      @types.fetch(x) { raise QbeUnsupported, "untyped operand #{sx(x)}" }
    end

    # An integer to a float: the IEEE conversion of the integer, rounded once to the target (as the interpreter's
    # conversion of an integer up to 2**53 is). The conversion follows the signedness of the source type.
    def int_to_float_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "integer to float of a float" if float_type?(src)

      name = { ["w", true] => "swtof", ["w", false] => "uwtof", ["l", true] => "sltof", ["l", false] => "ultof" }
             .fetch([Qbe.cls(src), Qbe.signed?(src)]) { raise QbeUnsupported, "integer to float of #{sx(src)}" }
      @lines << "  #{dst} =#{Qbe.cls(t)} #{name} #{op(x)}"
    end

    # A float to a float of another precision: a rounding to single (truncd) or an exact widening (exts).
    def float_conv_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "float conversion of an integer" unless float_type?(src)

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
    # (lo - 1, hi + 1), and a float source is first widened to double so that the bounds are exact. The check is a
    # call `pathb_check(cond, 4)` before the conversion, like the integer checks: the runtime does not return when the
    # operand is bad, so no block is split.
    def float_to_int_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "float to integer of #{sx(src)}" unless float_type?(src)
      raise QbeUnsupported, "float to bool" if t == "bool"

      w, signed = int_info(t)
      xv = op(x)
      if src == "float"
        widened = fresh
        @lines << "  #{widened} =d exts #{xv}"
        xv = widened
      end
      lower = if signed && w == 64 then ["cged", -(2**63)]
              elsif signed then ["cgtd", -(2**(w - 1)) - 1]
              else ["cgtd", -1]
              end
      upper = ["cltd", signed ? 2**(w - 1) : 2**w]
      tests = [lower, upper].map do |cmp, bound|
        tmp = fresh
        @lines << "  #{tmp} =w #{cmp} #{xv}, #{Qbe.float_lit('double', bound.to_f.to_s)}"
        tmp
      end
      ok = fresh
      @lines << "  #{ok} =w and #{tests[0]}, #{tests[1]}"
      bad = fresh
      @lines << "  #{bad} =w ceqw #{ok}, 0"
      @lines << "  call $pathb_check(w #{bad}, w 4)"
      @lines << "  #{dst} =#{Qbe.cls(t)} #{signed ? 'dtosi' : 'dtoui'} #{xv}"
    end
  end

  # The data of the module's globals, then the functions. A global the emitter cannot model is left out, and a
  # reference to it raises QbeUnsupported where it is used.
  def module_il(forms)
    gs = forms.select { |g| head(g) == "global" }
    by_name = gs.to_h { |g| [g[1].raw, g] }
    state = {}
    data = gs.filter_map { |g| global_data(g, by_name, state) }
    supported = gs.to_h { |g| [g[1].raw, true] }.select { |name, _| state[name].is_a?(String) }
    fns = forms.select { |f| head(f) == "ssa-function" }.map { |f| Fn.new(f, supported).emit.lines.join("\n") }
    (data + fns).join("\n\n") + "\n"
  end
end

if $PROGRAM_NAME == __FILE__
  file = ARGV.first or abort "usage: pathb-ssa-qbe.rb FILE.ssa"
  print Qbe.module_il(read_forms(File.read(file)))
end
