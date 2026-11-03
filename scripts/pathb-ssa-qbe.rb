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

    # The type of an operand: a constant's or an expression's own type, or the declared type of a register.
    def switch_operand_type(x)
      return x[1] if x.is_a?(Array) && head(x) == "const"
      return "ptr" if x.is_a?(Array) && head(x) == "null"
      return (CMP_HEADS.include?(head(x)) ? "bool" : x[1]) if expression?(x)

      @types.fetch(x) { raise QbeUnsupported, "operand #{sx(x)} has no declared type" }
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
          raise QbeUnsupported, "float constant #{sx(x)}" if float_type?(x[1])

          Qbe.int_lit(x[2]).to_s
        when "null" then "0"
        when "addr" then op(x[1])
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
      when "eval"
        raise QbeUnsupported, "statement #{sx(item)}" unless head(item[1]) == "call"

        @lines << "  #{call_text(item[1])}"
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
      when "cdiv", "crem" then checked_div_lines(dst, t, rv)
      when "cshl", "cshr" then checked_shift_lines(dst, t, rv)
      when *Qbe::CMP.keys
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::CMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when "iconv" then conv_lines(dst, t, rv[2])
      when "call" then @lines << "  #{dst} =#{c} #{call_text(rv)}"
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

    # The checks of the interpreter (pathb-ssa.rb, Machine#eval_rv; pathb-egraph.rb, CheckedMachine for the shifts).
    # Each check is a call `pathb_check(cond, code)` before the operation: the runtime does not return when cond is
    # nonzero (it traps, or longjmps out in the test driver), so the operation after it is never reached with the
    # bad operands and no block is split. Codes: 1 division by zero, 2 signed overflow, 3 shift count out of range.
    def fresh = "%ck#{@temps += 1}"

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
        else Qbe.cls(CMP_HEADS.include?(head(a)) ? "bool" : a[1])
        end
      else raise QbeUnsupported, "argument #{sx(a)}"
      end
    end

    def float_type?(t) = FLOAT_TYPES.key?(strip_const(t))
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
