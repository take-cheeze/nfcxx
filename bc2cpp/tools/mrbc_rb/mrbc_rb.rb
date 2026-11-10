# frozen_string_literal: true

# A Ruby replacement for the fork's `mrbc -g`: Prism tree in, RITE binary out.
#
# Covered: a top-level program whose statements are nil, true, false, self, Integer literals, local reads, local writes
# of those, and method calls on simple operands (a self call or a call with an explicit receiver, with positional
# arguments of those forms, and the binary operators with their own opcodes, + and - with a literal as ADDI and SUBI),
# and if/else with a simple or call predicate and bodies of the forms above, unless, and `class X` or `module X` with a
# plain constant and a body of the forms above (no superclass; the body is a child irep run by EXEC). Anything else
# raises Unsupported, so a
# caller can fall back to the real mrbc.
#
# The bytes are those of the fork's classic compiler (take-cheeze/mruby, pinned by rpg-maker-clone). The rules below
# follow mrbgems/mruby-compiler/core/codegen.c:
# - R0 is self, R1.. are the locals in order of first assignment, and temporaries start at R[nlocals];
# - gen_move turns a load into a temporary followed by a move into a local into one load into the local, but only when
#   the statement's value is unused (every statement but the last);
# - the last statement's value is in a register that RETURN takes, so a local read is returned in place.
# The DBG section stores the lines in the packed form of src/debug.c: (pc delta, line delta) pairs where the line changes.
#
# The opcode numbers are the positions of the OPCODE lines of the fork's ops.h. golden_test.rb checks them against it.

require 'prism'

module MrbcRb
  class Error < StandardError; end
  class Unsupported < Error; end

  OP = {
    NOP: 0, MOVE: 1, LOADL: 2, LOADI8: 3, LOADINEG: 4, LOADI__1: 5,
    LOADI_0: 6, LOADI_1: 7, LOADI_2: 8, LOADI_3: 9, LOADI_4: 10, LOADI_5: 11, LOADI_6: 12, LOADI_7: 13,
    LOADI16: 14, LOADI32: 15, LOADNIL: 17, LOADSELF: 18, LOADTRUE: 19, LOADFALSE: 20,
    SSEND: 47, SSEND0: 48, SEND: 50, SEND0: 51, ADDI: 70, SUBI: 72, JMP: 38, JMPIF: 39, JMPNOT: 40,
    ARRAY: 82, ARRAY2: 83, STRING: 92,
    ADD: 69, SUB: 71, MUL: 75, DIV: 76, EQ: 77, LT: 78, LE: 79, GT: 80, GE: 81,
    RETSELF: 63, RETNIL: 64, RETTRUE: 65, RETFALSE: 66, RETURN: 61, STOP: 118,
    CLASS: 103, MODULE: 104, EXEC: 105
  }.freeze

  # Binary operators with their own opcode: the receiver is in the result register, the argument in the next one.
  BINARY_OPS = { :+ => :ADD, :- => :SUB, :* => :MUL, :/ => :DIV, :== => :EQ, :< => :LT, :<= => :LE, :> => :GT,
                 :>= => :GE }.freeze

  # Operands that a call's receiver or argument may be: the forms value_into loads without a call of its own.
  SIMPLE_VALUES = [Prism::IntegerNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode,
                   Prism::LocalVariableReadNode, Prism::StringNode].freeze

  # Pool entry tags (include/mruby/irep.h).
  IREP_TT_BIGINT = 7

  INT32_MIN = -0x8000_0000
  INT32_MAX = 0x7fff_ffff

  # Compiles +source+ as `mrbc -g` compiles a file named +filename+. Returns the RITE binary as a binary String.
  def self.compile(source, filename)
    result = Prism.parse(source, filepath: filename)
    raise Error, "parse error: #{result.errors.map(&:message).join('; ')}" unless result.errors.empty?

    Compiler.new(filename).compile(result.value)
  end

  class Compiler
    def initialize(filename)
      @filename = filename
      @code = []
      @lines = []
      @line = 0
      @nregs = 0
      @pool = []
      @syms = []
      @children = [] # child ireps of class and module bodies, in the order EXEC refers to them
      @labels = [] # pcs that a jump lands on: the peepholes do not work across them (no_peephole in codegen.c)
      @last = nil # [name, operands, start] of the last instruction, for the RETURN peephole
    end

    def compile(program)
      stmts = program.statements.body
      raise Unsupported, 'empty program' if stmts.empty?

      set_locals(program.locals)
      value_reg = generate(stmts, val: true)
      return_value(value_reg)
      emit(:STOP)
      write_rite
    end

    # A child irep for a class or module body (scope_body in codegen.c): its own locals, registers, code and tables. It
    # is generated as a top-level program is, but without STOP. With +val+ its last statement's value is returned;
    # without it the body returns nil (gen_return with source register 0).
    def compile_body(locals, stmts, val)
      set_locals(locals)
      value_reg = generate(stmts, val: val)
      if val
        return_value(value_reg)
      else
        emit(:RETURN, 0)
      end
      self
    end

    attr_reader :locals, :nlocals, :children

    # This irep and its children, depth first: the order of the irep records, the debug records and the LVAR records.
    def scopes
      [self] + @children.flat_map(&:scopes)
    end

    # The IREP record of this irep: its own block (the record size counts only that), then the records of its children.
    def irep_tree
      body = [@nlocals, @nregs, @children.size].pack('nnn') + [0, @code.size].pack('nN') + @code.pack('C*') +
             pool_block + syms_block
      [body.bytesize + 4].pack('N') + body + @children.map(&:irep_tree).join
    end

    private

    def set_locals(locals)
      @locals = locals.dup
      @nlocals = @locals.size + 1
      @nregs = @nlocals
    end

    # Generates the statements of a body. The last one is generated as a value when +val+ is set; its register is returned.
    def generate(stmts, val:)
      value_reg = nil
      stmts.each_with_index do |node, i|
        @line = node.location.start_line
        value_reg = statement(node, last: val && i == stmts.size - 1)
      end
      value_reg
    end

    # Generates one statement. The last statement returns the register that holds its value.
    def statement(node, last:)
      case node
      when Prism::LocalVariableWriteNode
        write_local(node, last: last)
      when Prism::LocalVariableReadNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode, Prism::IntegerNode
        last ? value_in_register(node) : nil
      when Prism::CallNode
        call(node)
      when Prism::IfNode
        if_statement(node, last: last)
      when Prism::UnlessNode
        unless_statement(node, last: last)
      when Prism::ClassNode
        class_statement(node, last: last)
      when Prism::ModuleNode
        module_statement(node, last: last)
      else
        raise Unsupported, "node #{node.class.name.split('::').last}"
      end
    end

    # The fork's NODE_IF: the predicate goes into the first temporary, JMPNOT skips the then-branch to the else-branch
    # (or to the end), and the then-branch ends with a JMP to the end when there is an else-branch or a value is needed.
    # A missing else-branch loads nil when the value is needed. Returns the value's register when +last+.
    def if_statement(node, last:)
      predicate = node.predicate
      raise Unsupported, 'if predicate' unless SIMPLE_VALUES.include?(predicate.class) || predicate.is_a?(Prism::CallNode)

      else_node = node.subsequent
      raise Unsupported, 'elsif' if else_node.is_a?(Prism::IfNode)

      t = temp
      value_into(predicate, t)
      to_else = emit_jump(:JMPNOT, t)
      # A jump operand's bytes take the line of the branch's last statement (verified with mrbc -g's line table). An empty
      # then-branch takes the line of the `else` or `end` keyword.
      then_stmts = node.statements&.body || []
      if then_stmts.empty?
        keyword = else_node ? else_node.else_keyword_loc : node.end_keyword_loc
        @line = keyword.start_line
        set_jump_line(to_else, keyword.start_line)
        branch(node.statements, t, need: last)
      else
        set_jump_line(to_else, branch(node.statements, t, need: last))
      end
      if else_node
        raise Unsupported, 'empty else-branch' if else_node.statements.nil? || else_node.statements.body.empty?

        to_end = emit_jump(:JMP)
      elsif last
        to_end = emit_jump(:JMP)
      end
      patch_jump(to_else, @code.size)
      if else_node
        set_jump_line(to_end, branch(else_node.statements, t, need: last))
      end
      emit(:LOADNIL, t) if !else_node && last
      patch_jump(to_end, @code.size) if to_end
      last ? t : nil
    end

    # codegen_class: the outer namespace (nil for a plain constant) goes into the first temporary, the superclass (nil when
    # there is none) into the next, and CLASS takes the first temporary as its result. The body follows (class_body).
    def class_statement(node, last:)
      raise Unsupported, 'class with a superclass' if node.superclass

      name = plain_constant(node.constant_path)
      t = temp
      emit(:LOADNIL, t)
      emit(:LOADNIL, t + 1)
      emit(:CLASS, t, sym_index(name))
      class_body(node, t, last)
      t
    end

    # codegen_module: the outer namespace goes into the temporary, which MODULE takes as its result.
    def module_statement(node, last:)
      name = plain_constant(node.constant_path)
      t = temp
      emit(:LOADNIL, t)
      emit(:MODULE, t, sym_index(name))
      class_body(node, t, last)
      t
    end

    def plain_constant(path)
      raise Unsupported, 'class or module path other than a plain constant' unless path.is_a?(Prism::ConstantReadNode)

      path.name
    end

    # gen_class_body: an empty body loads nil into the result register, which the RETURN peephole folds when the class is
    # the last statement. A body with statements is a child irep that EXEC runs on the class in the result register.
    def class_body(node, t, val)
      body = node.body
      raise Unsupported, 'class or module body' unless body.nil? || body.is_a?(Prism::StatementsNode)

      stmts = body ? body.body : []
      if stmts.empty?
        emit(:LOADNIL, t)
      else
        emit(:EXEC, t, child_body(node.locals, stmts, val))
      end
    end

    # scope_body: the index of the child irep, which is the next entry of the parent's reps (a body with no statements
    # creates none).
    def child_body(locals, stmts, val)
      @children << Compiler.new(@filename).compile_body(locals, stmts, val)
      index = @children.size - 1
      raise Unsupported, 'more than 255 child ireps' if index > 0xff

      index
    end

    def set_jump_line(position, line)
      @lines[position] = line
      @lines[position + 1] = line
    end

    # `unless` is an if whose body runs when the predicate is false. With an else-branch, the else-branch is the body that
    # runs when the predicate holds, so it is generated first, exactly as the then-branch of an if/else. Without one, the
    # value form loads nil for the predicate-true case, and the statement form skips the body with JMPIF.
    def unless_statement(node, last:)
      predicate = node.predicate
      raise Unsupported, 'unless predicate' unless SIMPLE_VALUES.include?(predicate.class) || predicate.is_a?(Prism::CallNode)

      body = node.statements&.body || []
      else_node = node.else_clause
      t = temp
      value_into(predicate, t)
      if else_node
        raise Unsupported, 'empty unless or else-branch' if body.empty? || else_node.statements.nil? || else_node.statements.body.empty?

        to_else = emit_jump(:JMPNOT, t)
        set_jump_line(to_else, branch(else_node.statements, t, need: last))
        to_end = emit_jump(:JMP)
        patch_jump(to_else, @code.size)
        set_jump_line(to_end, branch(node.statements, t, need: last))
        patch_jump(to_end, @code.size)
      elsif last
        raise Unsupported, 'empty unless-body' if body.empty?

        to_body = emit_jump(:JMPNOT, t)
        set_jump_line(to_body, node.location.start_line)
        emit(:LOADNIL, t)
        to_end = emit_jump(:JMP)
        patch_jump(to_body, @code.size)
        set_jump_line(to_end, branch(node.statements, t, need: true))
        patch_jump(to_end, @code.size)
      else
        raise Unsupported, 'empty unless-body' if body.empty?

        to_end = emit_jump(:JMPIF, t)
        set_jump_line(to_end, branch(node.statements, t, need: false))
        patch_jump(to_end, @code.size)
      end
      last ? t : nil
    end

    # One branch of an if: its statements in order, the last one's value in +t+ when it is needed. Returns the line of the
    # last statement, which the jump into the branch takes.
    def branch(statements, t, need:)
      stmts = statements ? statements.body : []
      if stmts.empty?
        emit(:LOADNIL, t) if need
        return nil
      end
      stmts.each_with_index do |stmt, i|
        @line = stmt.location.start_line
        if need && i == stmts.size - 1
          r = statement(stmt, last: true)
          emit(:MOVE, t, r) unless r == t
        else
          statement(stmt, last: false)
        end
      end
      stmts.last.location.start_line
    end

    # A jump whose target is patched later: the operand is the 16-bit absolute pc. Returns the operand's position.
    def emit_jump(name, reg = nil)
      start = @code.size
      @last = [name, [reg].compact, start]
      @code << OP.fetch(name)
      byte(reg) if reg
      position = @code.size
      short(0)
      (@code.size - start).times { @lines << @line }
      position
    end

    # The operand is a signed 16-bit offset from the end of the jump (the pc after its last byte), as mrbc stores it;
    # `mrbc -v` prints the absolute target instead.
    def patch_jump(position, target)
      offset = target - (position + 2)
      raise Unsupported, 'jump beyond 16 bits' unless offset.between?(-0x8000, 0x7fff)

      @code[position] = (offset >> 8) & 0xff
      @code[position + 1] = offset & 0xff
      @labels << target
    end

    def write_local(node, last:)
      local = local_register(node.name)
      value = node.value
      if last
        t = temp
        value_into(value, t)
        emit(:MOVE, local, t)
        t
      else
        # The fork loads the value into a temporary first and then removes that move (see gen_move), so the temporary
        # still counts toward nregs.
        temp
        case value
        when Prism::LocalVariableReadNode
          emit(:MOVE, local, local_register(value.name))
        when Prism::CallNode
          # A call or operator result stays in its temporary, and the move into the local is kept (gen_move's peephole
          # only removes a move after a load).
          emit(:MOVE, local, call(value))
        else
          value_into(value, local)
        end
        nil
      end
    end

    # A method call, as the fork's codegen emits it: the result register is the first temporary, the receiver is copied
    # into it, and the arguments follow it. A binary + or - with a literal from 1 to 255 is ADDI or SUBI on the copy.
    # Returns the result register.
    def call(node)
      name = node.name
      # `self.foo` is a call on self, emitted as SSEND with no receiver copy.
      recv = node.receiver unless node.receiver.is_a?(Prism::SelfNode)
      args = node.arguments&.arguments || []
      raise Unsupported, 'call with a block or keywords' if node.block || args.any? { |a| !SIMPLE_VALUES.include?(a.class) }
      raise Unsupported, 'call with a non-simple receiver' if recv && !SIMPLE_VALUES.include?(recv.class)

      a = temp
      if recv && %i[+ -].include?(name) && args.size == 1 && args[0].is_a?(Prism::IntegerNode) &&
         (1..0xff).cover?(args[0].value)
        value_into(recv, a)
        emit(name == :+ ? :ADDI : :SUBI, a, args[0].value)
        @nregs = [@nregs, a + 3].max
        return a
      end
      if recv && BINARY_OPS.key?(name) && args.size == 1
        value_into(recv, a)
        value_into(args[0], a + 1)
        emit(BINARY_OPS.fetch(name), a)
        @nregs = [@nregs, a + 3].max
        return a
      end

      value_into(recv, a) if recv
      args.each_with_index { |arg, i| value_into(arg, a + 1 + i) }
      sym = sym_index(name)
      n = args.size
      if recv
        n.zero? ? emit(:SEND0, a, sym) : emit(:SEND, a, sym, n)
      else
        n.zero? ? emit(:SSEND0, a, sym) : emit(:SSEND, a, sym, n)
      end
      @nregs = [@nregs, a + n + 2].max
      a
    end

    # Symbols are numbered in order of first use, as the fork's new_sym does.
    def sym_index(name)
      index = @syms.index(name) || (@syms << name).size - 1
      raise Unsupported, 'more than 255 symbols' if index > 0xff

      index
    end

    # The fork's gen_return: a MOVE or a constant load right before RETURN is folded into the return.
    def return_value(reg)
      name, operands, start = @last
      if @labels.include?(@code.size)
        emit(:RETURN, reg)
      elsif name == :MOVE && operands[0] == reg
        truncate(start)
        emit(:RETURN, operands[1])
      elsif %i[LOADSELF LOADNIL LOADTRUE LOADFALSE].include?(name) && operands[0] == reg
        truncate(start)
        emit({ LOADSELF: :RETSELF, LOADNIL: :RETNIL, LOADTRUE: :RETTRUE, LOADFALSE: :RETFALSE }.fetch(name))
      else
        emit(:RETURN, reg)
      end
    end

    def truncate(start)
      @code.slice!(start..)
      @lines.slice!(start..)
    end

    # The register the value of +node+ is in: a local is read in place, anything else is loaded into a temporary.
    def value_in_register(node)
      return local_register(node.name) if node.is_a?(Prism::LocalVariableReadNode)

      t = temp
      value_into(node, t)
      t
    end

    def value_into(node, dst)
      case node
      when Prism::NilNode then emit(:LOADNIL, dst)
      when Prism::TrueNode then emit(:LOADTRUE, dst)
      when Prism::FalseNode then emit(:LOADFALSE, dst)
      when Prism::SelfNode then emit(:LOADSELF, dst)
      when Prism::IntegerNode then load_int(node.value, dst)
      when Prism::LocalVariableReadNode then emit(:MOVE, dst, local_register(node.name))
      when Prism::StringNode then emit(:STRING, dst, pool_index([:str, node.unescaped.b]))
      when Prism::ArrayNode then array_into(node, dst)
      when Prism::CallNode
        result = call(node)
        emit(:MOVE, dst, result) unless result == dst
      else raise Unsupported, "value #{node.class.name.split('::').last}"
      end
    end

    # The fork's gen_int: the shortest load of the value. -2147483648 cannot be negated in 32 bits, so the fork's NODE_INT
    # codegen loads it from a big integer entry, "2147483648" in base -10 (codegen.c, NODE_INT). Other values beyond the
    # 32-bit range are not verified yet and raise Unsupported.
    def load_int(i, dst)
      if i == INT32_MIN
        emit(:LOADL, dst, pool_index([:bigint, '2147483648', -10]))
      elsif i.abs > INT32_MAX
        raise Unsupported, 'integer literal beyond 32 bits is not verified yet'
      elsif i.negative?
        if i == -1 then emit(:LOADI__1, dst)
        elsif i >= -0xff then emit(:LOADINEG, dst, -i)
        elsif i >= -0x8000 then emit(:LOADI16, dst, i & 0xffff)
        else emit(:LOADI32, dst, i & 0xffff_ffff)
        end
      elsif i < 8 then emit(:"LOADI_#{i}", dst)
      elsif i <= 0xff then emit(:LOADI8, dst, i)
      elsif i <= 0x7fff then emit(:LOADI16, dst, i)
      else emit(:LOADI32, dst, i)
      end
    end

    # An array literal of leaf values: the elements are loaded from the first temporary on. ARRAY takes that register as
    # its destination; otherwise ARRAY2 takes the destination and the register of the first element (codegen.c, NODE_ARRAY).
    def array_into(node, dst)
      elems = node.elements
      raise Unsupported, 'array element' unless elems.all? { |e| SIMPLE_VALUES.include?(e.class) }

      a = temp
      elems.each_with_index { |e, i| value_into(e, a + i) }
      @nregs = [@nregs, a + elems.size].max
      if dst == a
        emit(:ARRAY, a, elems.size)
      else
        emit(:ARRAY2, dst, a, elems.size)
      end
    end

    # Pool entries are deduplicated in order of first use, as the fork's new_lit_int does.
    def pool_index(i)
      index = @pool.index(i) || (@pool << i).size - 1
      raise Unsupported, 'more than 255 pool entries' if index > 0xff

      index
    end

    def local_register(name)
      index = @locals.index(name)
      raise Error, "unknown local #{name}" unless index

      index + 1
    end

    # The first temporary, as the fork's codegen starts its stack after the locals. Using one raises the register count.
    def temp
      @nregs = [@nregs, @nlocals + 1].max
      @nlocals
    end

    # Emits one instruction and records its source line for each of its bytes. Operands follow the formats in ops.h:
    # B is 8 bits, S is 16 bits (big endian), and the 32-bit LOADI32 operand is two 16-bit halves.
    def emit(name, *operands)
      start = @code.size
      @last = [name, operands, start]
      @code << OP.fetch(name)
      case name
      when :LOADI16 then byte(operands[0]); short(operands[1])
      when :LOADI32 then byte(operands[0]); short(operands[1] >> 16); short(operands[1] & 0xffff)
      else operands.each { |v| byte(v) }
      end
      track(operands.first) unless name == :STOP
      track(operands[1]) if name == :MOVE
      (@code.size - start).times { @lines << @line }
    end

    def byte(v)
      @code << (v & 0xff)
    end

    def short(v)
      @code << ((v >> 8) & 0xff) << (v & 0xff)
    end

    def track(reg)
      return unless reg.is_a?(Integer)

      @nregs = [@nregs, reg + 1].max
    end

    # ---- RITE, as src/dump.c writes it: header, IREP, DBG, LVAR, END ----

    def write_rite
      # The LVAR section exists only when some irep has locals, as the fork omits it otherwise (lv_defined_p in dump.c).
      lvar = scopes.any? { |s| !s.locals.empty? } ? lvar_section : ''.b
      sections = irep_section + debug_section + lvar + sized("END\0", ''.b)
      ['RITE0400', 20 + sections.bytesize].pack('a8N') + 'MATZ0000'.b + sections
    end

    # IREP's body starts with its version, "0400"; the records follow it.
    def irep_section
      sized('IREP', '0400'.b + irep_tree)
    end

    # A section is its ident (4 bytes), its size (counting the 8-byte header), and its body.
    def sized(ident, body)
      [ident.b, body.bytesize + 8].pack('a4N') + body.b
    end

    # write_syms_block: the count, then per symbol its length, its name and a NUL (dump.c).
    def syms_block
      [@syms.size].pack('n') + @syms.map { |s| name = s.to_s.b; [name.bytesize].pack('n') + name + "\0".b }.join
    end

    # write_pool_block: the count, then per entry its tag and data. A big integer is its length, its base (as a byte),
    # and its digits, with no terminating NUL (dump.c writes len + 2 bytes).
    def pool_block
      entries = @pool.map do |entry|
        case entry
        in [:bigint, digits, base]
          [IREP_TT_BIGINT].pack('C') + [digits.bytesize, base & 0xff].pack('CC') + digits.b
        in [:str, bytes]
          # A string: tag 0, its length, its bytes and a NUL (dump.c's default case).
          [0].pack('C') + [bytes.bytesize].pack('n') + bytes + "\0".b
        end
      end
      [@pool.size].pack('n') + entries.join
    end

    def debug_section
      name = @filename.b
      sized('DBG' + "\0", [1].pack('n') + [name.bytesize].pack('n') + name + debug_records.join)
    end

    # One debug record per irep, this one first and then its children's (write_debug_record in dump.c). Each covers one file,
    # from pc 0 of its own code.
    def debug_records
      [debug_record(packed_lines)] + @children.flat_map(&:debug_records)
    end
    public :debug_records # called on each child, from the parent's debug section

    def debug_record(packed)
      file = [0].pack('N') + [0].pack('n') + [packed.bytesize].pack('N') + [2].pack('C') + packed
      record = [1].pack('n') + file
      [record.bytesize + 4].pack('N') + record
    end

    # src/debug.c's packed map: (pc delta, line delta) pairs, written only where the line changes.
    def packed_lines
      out = ''.b
      prev_line = 0
      prev_pc = 0
      @lines.each_with_index do |line, pc|
        next if line == prev_line

        out << pack_int(pc - prev_pc) << pack_int(line - prev_line)
        prev_pc = pc
        prev_line = line
      end
      out
    end

    # mrb_packed_int_encode: 7 bits per byte, least significant first, with bit 7 set while more bytes follow.
    def pack_int(num)
      num &= 0xffff_ffff # a line that goes back is a wrapped 32-bit delta, as src/debug.c stores it
      bytes = ''.b
      loop do
        b = num & 0x7f
        num >>= 7
        b |= 0x80 unless num.zero?
        bytes << b
        break if num.zero?
      end
      bytes
    end

    # The names of all ireps' locals, in order of first appearance over the tree, then one reference per local of each irep
    # (create_lv_sym_table and write_lv_record in dump.c).
    def lvar_section
      names = scopes.flat_map { |s| s.locals.map(&:to_s) }.uniq
      syms = [names.size].pack('N') + names.map { |n| [n.bytesize].pack('n') + n.b }.join
      refs = scopes.flat_map { |s| (1...s.nlocals).map { |reg| names.index(s.locals[reg - 1].to_s) } }
      sized('LVAR', syms + refs.pack('n*'))
    end
  end
end
