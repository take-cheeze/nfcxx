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
# Control flow (milestone 10), verified against the fork on thousands of generated programs: if/unless/elsif/ternary with
# any predicate built from calls, !, not, &&, || (and, or) and nested ifs; `x.nil?` as JMPNIL; literal conditions folded as
# true_always/false_always do; while/until (and `begin ... end while`) with break and next; `def self.x`, `def Foo.x` and
# `class << obj`. A jump takes the line of the last node generated when it is dispatched (see #dispatch); an `elsif` node
# and an empty branch carry the line of the keyword that closes them.
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
    LOADI16: 14, LOADI32: 15, LOADSYM: 16, LOADNIL: 17, LOADSELF: 18, LOADTRUE: 19, LOADFALSE: 20,
    SSEND: 47, SSEND0: 48, SEND: 50, SEND0: 51, ADDI: 70, SUBI: 72, ADDILV: 73, SUBILV: 74, JMP: 38, JMPIF: 39, JMPNOT: 40, JMPNIL: 41, JMPUW: 42,
    ARRAY: 82, ARRAY2: 83, STRING: 92, STRCAT: 93, HASH: 94, GETCONST: 29, SETCONST: 30, GETGV: 21, SETGV: 22, GETIDX: 35,
    SETIDX: 37, GETIV: 25, SETIV: 26, FSTRING: 119,
    ADD: 69, SUB: 71, MUL: 75, DIV: 76, EQ: 77, LT: 78, LE: 79, GT: 80, GE: 81,
    RETSELF: 63, RETNIL: 64, RETTRUE: 65, RETFALSE: 66, RETURN: 61, RETURN_BLK: 62, STOP: 118,
    CLASS: 103, MODULE: 104, EXEC: 105, TDEF: 107, SDEF: 108, SCLASS: 111, ENTER: 57, KEYEND: 59, KARG: 60,
    GETUPVAR: 33, SETUPVAR: 34, SSENDB: 49, SENDB: 52, BLOCK: 98
  }.freeze

  # Binary operators with their own opcode: the receiver is in the result register, the argument in the next one.
  BINARY_OPS = { :+ => :ADD, :- => :SUB, :* => :MUL, :/ => :DIV, :== => :EQ, :< => :LT, :<= => :LE, :> => :GT,
                 :>= => :GE, :[] => :GETIDX }.freeze

  # Statements that may span several lines because their line rules are verified (if/unless arms, class and module bodies,
  # def); any other multi-line statement raises Unsupported: the fork stamps its code with a line that is not the start
  # line (a %w array over two lines is stamped with its last line), and that rule is not reproduced yet.
  MULTILINE_OK = [Prism::IfNode, Prism::UnlessNode, Prism::ClassNode, Prism::ModuleNode, Prism::DefNode,
                  Prism::SingletonClassNode, Prism::WhileNode, Prism::UntilNode].freeze

  # Conditions the fork folds at compile time (true_always and false_always in codegen.c): no test is emitted for them.
  TRUE_ALWAYS = [Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode].freeze
  FALSE_ALWAYS = [Prism::NilNode, Prism::FalseNode].freeze

  # `(expr)` with one statement is the statement itself: the fork's codegen does not see the parentheses.
  def self.unparen(node)
    while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
      node = node.body.body.first
    end
    node
  end

  # Operands that a call's receiver or argument may be: the forms value_into loads without a call of its own.
  SIMPLE_VALUES = [Prism::IntegerNode, Prism::InstanceVariableReadNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode,
                   Prism::LocalVariableReadNode, Prism::StringNode, Prism::ConstantReadNode, Prism::GlobalVariableReadNode,
                   Prism::SymbolNode].freeze

  # Literals built in the register they are generated in (the fork's cursp): value_into builds these at the destination
  # when it is a temporary, else at the first temporary followed by a MOVE. Allowed where the destination is known.
  BUILT_VALUES = [Prism::InterpolatedStringNode, Prism::HashNode].freeze

  # Calls with a receiver whose method the fork's codegen treats specially (index, negation and so on): not verified here.
  UNVERIFIED_OPERATORS = %i[-@ +@ ~ =~ !~ <=> ** & | ^ >> ===].freeze # `[]`, `[]=`, `!`, `!=`, `%` and `<<` are verified

  # Pool entry tags (include/mruby/irep.h).
  IREP_TT_BIGINT = 7

  RITE_LV_NULL_MARK = 0xffff

  INT32_MIN = -0x8000_0000
  INT32_MAX = 0x7fff_ffff

  # Compiles +source+ as `mrbc -g` compiles a file named +filename+. Returns the RITE binary as a binary String.
  def self.compile(source, filename)
    result = Prism.parse(source, filepath: filename)
    raise Error, "parse error: #{result.errors.map(&:message).join('; ')}" unless result.errors.empty?

    # `# frozen_string_literal: true` makes string literals frozen strings (FSTRING), as the fork's parser does.
    frozen = result.magic_comments.any? { |c| c.key == 'frozen_string_literal' && c.value == 'true' }
    Compiler.new(filename, frozen_strings: frozen).compile(result.value)
  end

  class Compiler
    def unparen(node) = MrbcRb.unparen(node)
    def simple?(node) = SIMPLE_VALUES.include?(unparen(node).class)
    def call_node?(node) = unparen(node).is_a?(Prism::CallNode)

    def initialize(filename, frozen_strings: false)
      @filename = filename
      @frozen_strings = frozen_strings
      @code = []
      @lines = []
      @line = 0
      @nregs = 0
      @sp = 0 # the register stack pointer: the first free register; see #call
      @pool = []
      @syms = []
      @children = [] # child ireps of class and module bodies, in the order EXEC refers to them
      @labels = [] # pcs that a jump lands on: the peepholes do not work across them (no_peephole in codegen.c)
      @last = nil # [name, operands, start] of the last instruction, for the RETURN peephole
      @loops = [] # the enclosing while/until loops of this scope, innermost last
      @history = [] # [name, operands, start] of every instruction emitted and not rewound, in order
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

    # A method body (scope_body for def, lambda_body in codegen.c): self, the parameters in the order required, optional,
    # rest, post-required, then the keyword dictionary slot "**" when there are keywords, the hidden block slot (no name),
    # the named block parameter, the keywords, and the body's own locals in the parser's order. ENTER takes
    # the aspec in its 24 bits: req << 18 | opt << 13 | rest << 12 | post << 7 | keywords << 2 | block (ops.h, MRB_ARGS_*).
    # Optional parameters add a jump table of one OP_JMP per parameter plus one for "all supplied" right after ENTER, then
    # the default expressions, each assigned like a local write whose value is unused. Required keywords are KARG, then
    # KEYEND, then the keyword hash is rebuilt into the "**" slot (LOADSYM, MOVE pairs and HASH); a named block parameter is
    # copied out of the block slot last. Optional keywords, **rest, anonymous & and destructuring are Unsupported.
    def compile_method(node)
      params = node.parameters
      requireds = params ? params.requireds : []
      optionals = params ? params.optionals : []
      posts = params ? params.posts : []
      keywords = params ? params.keywords : []
      rest = params&.rest
      block = params&.block
      if params && (params.keyword_rest || (rest && !rest.is_a?(Prism::RestParameterNode)))
        raise Unsupported, 'keyword rest or forwarding parameter'
      end
      raise Unsupported, 'destructuring parameter' unless (requireds + posts).all? { |r| r.is_a?(Prism::RequiredParameterNode) }
      raise Unsupported, 'optional keyword parameter' unless keywords.all? { |k| k.is_a?(Prism::RequiredKeywordParameterNode) }
      raise Unsupported, 'anonymous block parameter' if block && block.name.nil?
      raise Unsupported, 'too many parameters' if [requireds, optionals, posts, keywords].any? { |l| l.size > 0x1f }

      # Registers, in mrbc's order.
      pre = requireds.map(&:name) + optionals.map(&:name)
      pre << (rest.name || :*) if rest
      pre += posts.map(&:name)
      pre << :** unless keywords.empty?
      kw_names = keywords.map(&:name)
      block_names = [block&.name].compact
      set_locals(pre + [nil] + block_names + kw_names + (node.locals - pre - block_names - kw_names))
      @nregs = @nlocals + 1
      @line = node.location.start_line
      aspec = (requireds.size << 18) | (optionals.size << 13) | ((rest ? 1 : 0) << 12) | (posts.size << 7) |
              (keywords.size << 2) | (block ? 1 : 0)
      emit(:ENTER, aspec)
      @in_method = true
      method_optionals(optionals) unless optionals.empty?
      method_keywords(keywords, pre.size) unless keywords.empty?
      emit(:MOVE, local_register(block.name), pre.size + 1) if block
      raise Unsupported, 'method body with rescue or ensure' unless node.body.nil? || node.body.is_a?(Prism::StatementsNode)

      stmts = node.body ? node.body.body : []
      value_reg = if stmts.empty?
                    t = temp
                    @line = node.end_keyword_loc.start_line # the implicit nil is on the `end` line (verified)
                    emit(:LOADNIL, t)
                    t
                  else
                    generate(stmts, val: true)
                  end
      return_value(value_reg)
      self
    end

    # A literal block's body (lambda_body in codegen.c): as a method body, a scope of self, the required parameters, the
    # hidden block slot and the body's own locals, entered with ENTER; the variables of the enclosing scopes are upvalues
    # (GETUPVAR and SETUPVAR). +parent+ is the Compiler of the enclosing scope.
    def compile_block(node, parent)
      @parent = parent
      params = node.parameters
      case params
      when nil then params = nil
      when Prism::BlockParametersNode
        raise Unsupported, 'block-local variables' unless params.locals.empty?

        params = params.parameters
      else raise Unsupported, 'numbered or it block parameters'
      end
      requireds = params ? params.requireds : []
      other = params && (params.optionals.any? || params.rest || params.posts.any? || params.keywords.any? ||
                         params.keyword_rest || params.block)
      raise Unsupported, 'block parameters other than required ones' if other || !requireds.all? { |r| r.is_a?(Prism::RequiredParameterNode) }
      raise Unsupported, 'block body with rescue or ensure' unless node.body.nil? || node.body.is_a?(Prism::StatementsNode)

      param_names = requireds.map(&:name)
      set_locals(param_names + [nil] + (node.locals - param_names))
      @nregs = @nlocals + 1
      @line = node.opening_loc.start_line
      emit(:ENTER, requireds.size << 18)
      stmts = node.body ? node.body.body : []
      value_reg = if stmts.empty?
                    t = temp
                    @line = node.closing_loc.start_line # the implicit nil is on the closing line (verified)
                    emit(:LOADNIL, t)
                    t
                  else
                    generate(stmts, val: true)
                  end
      return_value(value_reg)
      self
    end


    # The optional parameters' jump table: one JMP per parameter to its default's code, and a last JMP past all defaults
    # (taken when every optional argument was given). Each default is assigned as a local write whose value is unused.
    def method_optionals(optionals)
      jumps = (optionals.size + 1).times.map { emit_jump(:JMP) }
      optionals.each_with_index do |opt, i|
        # A jump's operand bytes take the line current when it is dispatched (emit_S writes s->lineno): the line of the
        # previous default's last node, or the def line for the first.
        patch_jump(jumps[i], @code.size)
        set_jump_line(jumps[i], @line)
        @line = opt.value.location.start_line
        write_local(opt, last: false)
      end
      patch_jump(jumps.last, @code.size)
      set_jump_line(jumps.last, @line)
    end

    # Required keywords: KARG into each keyword's register, KEYEND, then the hash of the keywords is rebuilt into the "**"
    # slot (register +dict+ is the one after the positional parameters) starting at the first temporary.
    def method_keywords(keywords, npre)
      dict = npre # the "**" slot is the last of the leading names, R[npre]
      keywords.each { |k| emit(:KARG, local_register(k.name), sym_index(k.name)) }
      emit(:KEYEND)
      base = temp
      keywords.each_with_index do |k, i|
        emit(:LOADSYM, base + 2 * i, sym_index(k.name))
        emit(:MOVE, base + 2 * i + 1, local_register(k.name))
      end
      emit(:HASH, base, keywords.size)
      emit(:MOVE, dict, base)
    end

    attr_reader :locals, :nlocals, :children, :parent

    # The name of each register from R1: a method's block slot has none (its LVAR entry is the null mark).
    def lv_names
      @locals
    end

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

    # The register in the scope +depth+ levels up of the local +name+, and the level for GETUPVAR/SETUPVAR (depth - 1).
    def upvar_operands(name, depth)
      scope = self
      depth.times { scope = scope.parent or raise Unsupported, 'upvalue without an enclosing scope' }
      [scope.send(:local_register, name), depth - 1]
    end

    # gen_getupvar: a GETUPVAR right after the SETUPVAR of the same variable into the same register is skipped.
    def getupvar(dst, node)
      idx, lv = upvar_operands(node.name, node.depth)
      name, operands, = @last
      return if name == :SETUPVAR && operands == [dst, idx, lv] && !@labels.include?(@code.size)

      emit(:GETUPVAR, dst, idx, lv)
    end

    # `a = value` with +a+ in an enclosing scope: the value goes to the first temporary and SETUPVAR stores it, using the
    # source of a MOVE just before it (gen_setupvar). The statement's value register is the temporary, even when the
    # rewound MOVE left it unloaded (verified: `foo { |x| a = x }` returns R3).
    def write_upvar(node, last:)
      t = temp
      value_into(node.value, t)
      idx, lv = upvar_operands(node.name, node.depth)
      name, operands, start = @last
      src = t
      if name == :MOVE && operands[0] == t && !@labels.include?(@code.size)
        truncate(start)
        src = operands[1]
      end
      emit(:SETUPVAR, src, idx, lv)
      last ? t : nil
    end

    # A call with a literal block (codegen_call with a block argument): the receiver (when there is one), the arguments, then
    # the block in the register after them (BLOCK, whose body is a child irep) and SENDB or SSENDB. The fork then skips the
    # operator opcodes, so only plain method names are covered. Line numbers of a call that spans lines depend on the node
    # each instruction belongs to, so only a call whose parts all start and end on the line of its block are covered.
    def call_with_block(node, need:)
      blk = node.block
      raise Unsupported, 'block argument' unless blk.is_a?(Prism::BlockNode)
      raise Unsupported, 'call with a block and a non-plain method name' unless node.name.to_s.match?(/\A[A-Za-z_]\w*[?!]?\z/)
      raise Unsupported, 'safe navigation with a block' if node.safe_navigation?

      recv = node.receiver && unparen(node.receiver)
      recv = nil if recv.is_a?(Prism::SelfNode)
      args = (node.arguments&.arguments || []).map { |a| unparen(a) }
      raise Unsupported, 'call with a block and keywords or a non-simple argument' if args.any? { |a| !simple?(a) }
      raise Unsupported, 'call with a block and a non-simple receiver' if recv && !(simple?(recv) || call_node?(recv))

      line = blk.opening_loc.start_line
      parts = [*(recv ? [recv.location] : []), *args.map(&:location)]
      unless @line == line && node.location.start_line == line && parts.all? { |l| l.start_line == line && l.end_line == line }
        raise Unsupported, 'call with a block spanning lines'
      end

      a = temp
      value_into(recv, a) if recv
      args.each_with_index { |arg, i| value_into(arg, a + 1 + i) }
      @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_block(blk, self)
      index = @children.size - 1
      raise Unsupported, 'more than 255 child ireps' if index > 0xff

      n = args.size
      emit(:BLOCK, a + n + 1, index)
      emit(recv ? :SENDB : :SSENDB, a, sym_index(node.name), n)
      @nregs = [@nregs, a + n + 2].max
      a
    end

    def set_locals(locals)
      @locals = locals.dup
      @nlocals = @locals.size + 1
      @nregs = @nlocals
      @sp = @nlocals # the register stack starts after the locals
    end

    # A def in a body: TDEF stores the method's symbol in the result register and refers to a child irep.
    def def_statement(node, last:)
      recv = node.receiver && unparen(node.receiver)
      raise Unsupported, 'receiver def on a non-simple receiver' if recv && !simple?(recv)
      raise Unsupported, 'def with a name that is not plain' unless node.name.to_s.match?(/\A[A-Za-z_]\w*[?!]?\z/)

      # codegen_sdef: the name's symbol comes first, then the method's irep, then the receiver, loaded into the result
      # register, which SDEF takes. A plain def is TDEF on the same register.
      sym = sym_index(node.name)
      @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_method(node)
      index = @children.size - 1
      raise Unsupported, 'more than 255 child ireps' if index > 0xff

      nregs = @nregs
      t = temp
      if recv
        value_into(recv, t)
        emit(:SDEF, t, sym, index)
      else
        emit(:TDEF, t, sym, index)
        @nregs = nregs unless last # the result register is only counted when the value is pushed (codegen_def)
      end
      last ? t : nil
    end

    # codegen_return: the value (nil for a plain `return`) goes into the first temporary and gen_return folds a MOVE or a
    # constant load into it. Only inside a method body; a statement's value register is that temporary.
    def return_statement(node, last:)
      raise Unsupported, 'return outside a method body' unless @in_method

      args = node.arguments&.arguments
      raise Unsupported, 'return with several values' if args && (args.size != 1 || !(simple?(args[0]) || call_node?(args[0])))

      t = temp
      args ? value_into(unparen(args[0]), t) : emit(:LOADNIL, t)
      return_value(t, @loops.empty? ? :RETURN : :RETURN_BLK) # a return inside a loop is the in-block form
      last ? t : nil
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
    # A call with a block, or a write of one (`y = foo { ... }`): their line rules are verified (blocks, milestone 9).
    def block_statement?(node)
      node = unparen(node)
      return true if node.is_a?(Prism::CallNode) && node.block

      node.respond_to?(:value) && node.value && block_statement?(node.value)
    end

    def statement(node, last:)
      node = unparen(node)
      if node.location.start_line != node.location.end_line && !MULTILINE_OK.include?(node.class) && !block_statement?(node)
        raise Unsupported, 'multi-line statement'
      end
      case node
      when Prism::LocalVariableWriteNode
        write_local(node, last: last)
      when Prism::ConstantReadNode
        # codegen_const loads the constant (it may raise) even when the value is unused.
        return value_in_register(node) if last

        emit(:GETCONST, temp, sym_index(node.name))
        nil
      when Prism::LocalVariableReadNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode, Prism::IntegerNode,
           Prism::StringNode, Prism::GlobalVariableReadNode, Prism::InstanceVariableReadNode
        last ? value_in_register(node) : nil
      when Prism::SymbolNode
        # An unused symbol still enters the symbol table (sym_idx runs before gen_load_op2 checks val).
        sym_index(node.unescaped.to_sym)
        last ? value_in_register(node) : nil
      when *BUILT_VALUES
        # Unused strings and hashes generate nothing (codegen_hash returns early, gen_string skips its parts).
        last ? value_in_register(node) : nil
      when Prism::CallNode
        call(node, need: last)
      when Prism::ConstantWriteNode
        const_write(node, last: last)
      when Prism::GlobalVariableWriteNode
        global_write(node, last: last)
      when Prism::InstanceVariableWriteNode
        ivar_write(node, last: last)
      when Prism::DefNode
        def_statement(node, last: last)
      when Prism::ReturnNode
        return_statement(node, last: last)
      when Prism::OrNode, Prism::AndNode
        logic(node, need: last)
      when Prism::IfNode
        if_statement(node, last: last)
      when Prism::UnlessNode
        unless_statement(node, last: last)
      when Prism::WhileNode, Prism::UntilNode
        loop_statement(node, last: last)
      when Prism::BreakNode
        break_statement(node, last: last)
      when Prism::NextNode
        next_statement(node, last: last)
      when Prism::SingletonClassNode
        sclass_statement(node, last: last)
      when Prism::ClassNode
        class_statement(node, last: last)
      when Prism::ModuleNode
        module_statement(node, last: last)
      else
        raise Unsupported, "node #{node.class.name.split('::').last}"
      end
    end

    def elsif_node?(node) = node.is_a?(Prism::IfNode) && node.if_keyword_loc&.slice == 'elsif'

    # A negative literal is a negation of a literal to the fork's parser, which codegen does not fold.
    def true_always?(node) = TRUE_ALWAYS.include?(node.class) && !node.location.slice.start_with?('-')
    def false_always?(node) = FALSE_ALWAYS.include?(node.class)

    # A condition (an if/unless/while/until predicate) is generated as a value on one line: the fork stamps each node with
    # its own line, and a statement's @line is the line of its first node.
    def check_condition(pred, elsif_node)
      return if pred.location.start_line == pred.location.end_line && (elsif_node || pred.location.start_line == @line)

      raise Unsupported, 'condition on another line than its statement'
    end

    # `x.nil?` in a condition is tested with JMPNIL on the receiver (codegen_if's nil_p).
    def nil_check?(pred)
      return false unless pred.is_a?(Prism::CallNode) && pred.name == :nil? && pred.block.nil? &&
                          pred.arguments.nil? && !pred.safe_navigation?
      return true unless pred.receiver # a call without a receiver has none in the fork's tree: nil is tested

      recv = unparen(pred.receiver)
      raise Unsupported, 'nil? receiver' unless operand?(recv) && !BUILT_VALUES.include?(recv.class)

      true
    end

    # The fork's NODE_IF (if, elsif, ternary, modifier if): the predicate goes into the first temporary, JMPNOT skips the
    # then-branch to the else-branch (or to the end), and the then-branch ends with a JMP to the end when there is an
    # else-branch or a value is needed. A missing else-branch loads nil when the value is needed. An `elsif` is an if node
    # that is the whole else-branch. Returns the value's register when +last+.
    def if_statement(node, last:)
      sub = node.subsequent
      else_list = case sub
                  when nil then nil
                  when Prism::IfNode then [sub]
                  else
                    sub.statements&.body || []
                  end
      then_list = node.statements&.body || []
      empty_line = nil
      if then_list.empty?
        # An empty then-branch takes the line of the `else`, `elsif` or `end` keyword (verified).
        keyword = case sub
                  when nil then node.end_keyword_loc
                  when Prism::IfNode then sub.if_keyword_loc
                  else sub.else_keyword_loc
                  end
        empty_line = keyword.start_line
      end
      # An empty else-branch is a node on the line of the closing `end`.
      else_line = else_list && else_list.empty? ? node.end_keyword_loc.start_line : nil
      gen_if(node.predicate, then_list, else_list, val: last, then_present: true, empty_line: empty_line,
                                                            elsif_node: elsif_node?(node), else_line: else_line)
    end

    # `unless` is an if whose then-branch is the else-clause and whose else-branch is the body (the fork's parser swaps
    # them), so the body runs when the predicate is false. Without an else-clause the then-branch is absent.
    def unless_statement(node, last:)
      body = node.statements&.body || []
      else_node = node.else_clause
      # An empty branch is a node on the line of the keyword that follows it (`else` or `end`).
      body_line = body.empty? ? (else_node ? else_node.else_keyword_loc : node.end_keyword_loc).start_line : nil
      if else_node
        then_list = else_node.statements&.body || []
        then_line = then_list.empty? ? node.end_keyword_loc.start_line : nil
        gen_if(node.predicate, then_list, body, val: last, then_present: true, empty_line: then_line,
                                                           else_line: body_line)
      else
        gen_if(node.predicate, [], body, val: last, then_present: false, else_line: body_line)
      end
    end

    # codegen_if. +then_list+ and +else_list+ are statement lists (+else_list+ is nil without an else-branch).
    # +then_present+ is whether the fork's then-branch exists (it does for an empty `if` body but not for a bare `unless`).
    def gen_if(pred, then_list, else_list, val:, then_present:, empty_line: nil, elsif_node: false, else_line: nil)
      # The fork folds a literal condition only when it is the condition node itself: `(nil)` is not folded.
      return gen_arm(then_list, val, then_present ? empty_line : nil) if true_always?(pred)
      return gen_arm(else_list || [], val, else_line) if false_always?(pred)

      pred = unparen(pred)
      check_condition(pred, elsif_node)
      @line = pred.location.start_line # the predicate's nodes are visited at their own line
      t = temp
      nil_p = nil_check?(pred)
      if nil_p
        pred.receiver ? operand_into(unparen(pred.receiver), t) : emit(:LOADNIL, t)
      else
        value_into(pred, t)
      end
      if val || then_present
        if nil_p
          to_then = cond_jump(:JMPNIL, t, val: val)
          to_else = emit_jump(:JMP)
          dispatch(to_then)
        else
          to_else = cond_jump(:JMPNOT, t, val: val)
        end
        @line = empty_line if then_list.empty? && empty_line
        branch(then_list, t, need: val)
        if else_list || val
          to_end = emit_jump(:JMP)
          dispatch(to_else)
          @line = else_line if else_line
          branch(else_list || [], t, need: val)
          dispatch(to_end)
        else
          dispatch(to_else)
        end
      elsif else_list
        to_end = cond_jump(nil_p ? :JMPNIL : :JMPIF, t, val: val)
        @line = else_line if else_line
        branch(else_list, t, need: false)
        dispatch(to_end)
      end
      val ? t : nil
    end

    # A branch that is the whole statement because the fork folded the condition away.
    def gen_arm(list, val, empty_line)
      t = temp
      @line = empty_line if list.empty? && empty_line
      branch(list, t, need: val)
      val ? t : nil
    end

    # Marks the jump at +position+ (nil when it was folded away) as landing at the current pc: dispatch in codegen.c. The
    # offset's bytes take the line of the last node generated.
    def dispatch(position)
      return unless position

      patch_jump(position, @code.size)
      set_jump_line(position, @line)
    end

    # codegen_sclass: the object goes into the first temporary, SCLASS opens its singleton class there and the body follows
    # as a class body does (class_body).
    def sclass_statement(node, last:)
      obj = unparen(node.expression)
      raise Unsupported, 'singleton class of a non-simple object' unless simple?(obj)

      t = temp
      value_into(obj, t)
      emit(:SCLASS, t)
      class_body(node, t, last)
      t
    end

    Loop = Struct.new(:reg, :pc0, :breaks)

    # codegen_while and codegen_until: the loop's value register is the first temporary (a loop's value is nil, or the value
    # of a `break`). The condition is generated at pc0 and tested with JMPNOT (JMPIF for until) to the exit; a NOP (the
    # redo target) starts the body, which ends with a JMP back to pc0. A constant condition that is always true (always
    # false for until) skips the test and the exit jump; one that is never true skips the loop entirely. `break` is a JMPUW
    # to the end of the loop, `next` a JMPUW back to pc0.
    def loop_statement(node, last:)
      until_loop = node.is_a?(Prism::UntilNode)
      pred = node.predicate
      forever = until_loop ? false_always?(pred) : true_always?(pred)
      never = until_loop ? true_always?(pred) : false_always?(pred)
      t = temp
      return post_test_loop(node, last: last, until_loop: until_loop, forever: forever, t: t) if node.begin_modifier?

      if never
        emit(:LOADNIL, t) if last
        return last ? t : nil
      end

      pred = unparen(pred)
      check_condition(pred, false) unless forever
      lp = Loop.new(last ? t : nil, @code.size, [])
      @labels << lp.pc0
      @loops << lp
      begin
        unless forever
          value_into(pred, t)
          to_exit = cond_jump(until_loop ? :JMPIF : :JMPNOT, t, val: false)
        end
        @labels << @code.size
        emit(:NOP)
        # An empty body is a node on the line of the closing `end`, which is visited after the NOP (verified).
        @line = node.closing_loc.start_line if node.statements.nil? || node.statements.body.empty?
        branch(node.statements, nil, need: false)
        back = emit_jump(:JMP)
        patch_jump(back, lp.pc0)
        dispatch(to_exit)
        emit(:LOADNIL, t) if last
        lp.breaks.each { |j| dispatch(j) }
      ensure
        @loops.pop
      end
      last ? t : nil
    end

    # `begin ... end while cond` (codegen_while_mod): a JMP at the start skips the test, the first time, to the body; the test is
    # then generated as in a plain loop, ahead of the NOP, and the body follows. A constant condition is not covered.
    def post_test_loop(node, last:, until_loop:, forever:, t:)
      pred = unparen(node.predicate)
      body = node.statements.body.first
      unless body.is_a?(Prism::BeginNode) && body.rescue_clause.nil? && body.else_clause.nil? && body.ensure_clause.nil?
        raise Unsupported, 'begin/end loop body'
      end

      stmts = body.statements&.body || []
      raise Unsupported, 'empty begin/end loop body' if stmts.empty?

      # A condition that never loops runs the body once (the body's value is not covered); one that always does has no test.
      once = (until_loop ? true_always?(node.predicate) : false_always?(node.predicate))
      if once
        raise Unsupported, 'begin/end loop run once as a value' if last

        branch(stmts, nil, need: false)
        return nil
      end
      raise Unsupported, 'multi-line condition' if !forever && pred.location.start_line != pred.location.end_line

      lp = Loop.new(last ? t : nil, nil, [])
      @loops << lp
      begin
        @line = pred.location.start_line # the loop node is stamped with the line of its condition (verified)
        to_body = emit_jump(:JMP)
        lp.pc0 = @code.size
        @labels << lp.pc0
        unless forever
          value_into(pred, t)
          to_exit = cond_jump(until_loop ? :JMPIF : :JMPNOT, t, val: false)
        end
        @labels << @code.size
        emit(:NOP)
        dispatch(to_body)
        branch(stmts, nil, need: false)
        back = emit_jump(:JMP)
        patch_jump(back, lp.pc0)
        dispatch(to_exit)
        emit(:LOADNIL, t) if last
        lp.breaks.each { |j| dispatch(j) }
      ensure
        @loops.pop
      end
      last ? t : nil
    end

    # loop_break: a value goes into the loop's register (when the loop's value is used) and JMPUW leaves the loop; without a
    # value the register is set to nil. Only a break directly in a while or until of this scope is covered.
    def break_statement(node, last:)
      lp = @loops.last or raise Unsupported, 'break outside a while or until loop'
      args = node.arguments&.arguments
      raise Unsupported, 'break with several values' if args && args.size != 1

      value = args && unparen(args[0])
      if value
        if lp.reg
          raise Unsupported, 'break value outside the loop statement level' unless @sp == lp.reg
          raise Unsupported, 'break value' unless simple?(value) || call_node?(value)

          value_into(value, lp.reg)
        else
          statement(value, last: false)
        end
      elsif lp.reg
        emit(:LOADNIL, lp.reg)
      end
      lp.breaks << emit_jump(:JMPUW)
      last ? temp : nil
    end

    def next_statement(node, last:)
      lp = @loops.last or raise Unsupported, 'next outside a while or until loop'
      raise Unsupported, 'next with a value' if node.arguments

      jump = emit_jump(:JMPUW)
      patch_jump(jump, lp.pc0)
      last ? temp : nil
    end

    # codegen_class: the outer namespace (nil for a plain constant) goes into the first temporary, the superclass (nil when
    # there is none) into the next, and CLASS takes the first temporary as its result. The body follows (class_body).
    def class_statement(node, last:)
      superclass = node.superclass
      raise Unsupported, 'superclass that is not a simple value' if superclass && !simple?(superclass)

      name = plain_constant(node.constant_path)
      t = temp
      emit(:LOADNIL, t)
      # The superclass, when there is one, goes into the register after the namespace (codegen_class).
      superclass ? value_into(superclass, t + 1) : emit(:LOADNIL, t + 1)
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
      @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_body(locals, stmts, val)
      index = @children.size - 1
      raise Unsupported, 'more than 255 child ireps' if index > 0xff

      index
    end

    def set_jump_line(position, line)
      @lines[position] = line
      @lines[position + 1] = line
    end

    # One branch of an if or a loop body: its statements in order, the last one's value in +t+ when it is needed. An empty
    # branch loads nil (when needed) at the current line.
    def branch(stmts, t, need:)
      stmts = stmts.body if stmts.respond_to?(:body)
      stmts ||= []
      if stmts.empty?
        emit(:LOADNIL, t) if need
        return
      end
      stmts.each_with_index do |stmt, i|
        # An `elsif` is an if node the fork's parser stamps with the line of the closing `end` (verified).
        @line = elsif_node?(stmt) ? stmt.end_keyword_loc.start_line : stmt.location.start_line
        if need && i == stmts.size - 1
          r = statement(stmt, last: true)
          emit(:MOVE, t, r) unless r == t
        else
          statement(stmt, last: false)
        end
      end
    end

    # A jump whose target is patched later: the operand is the 16-bit absolute pc. Returns the operand's position.
    def emit_jump(name, reg = nil)
      start = @code.size
      @history << [name, [reg].compact, start]
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

    # no_peephole in codegen.c: nothing to combine with at the start of the code, after a rewind, or at a jump target.
    def no_peephole?
      @code.empty? || @last.nil? || @labels.include?(@code.size)
    end

    # gen_move (the part verified here): a load into the temporary +src+ right before is rewritten to load into +dst+, and a
    # MOVE into it becomes a MOVE from its source; otherwise a MOVE.
    FOLDABLE_LOADS = %i[LOADNIL LOADSELF LOADTRUE LOADFALSE LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6
                        LOADI_7 LOADI8 LOADINEG LOADI16 LOADI32 LOADL LOADSYM GETGV GETIV GETCONST STRING FSTRING GETUPVAR].freeze
    def gen_move(dst, src)
      return if dst == src

      unless no_peephole?
        name, operands, start = @last
        if FOLDABLE_LOADS.include?(name) && operands[0] == src && src >= @nlocals
          truncate(start)
          @last = nil
          emit(name, dst, *operands[1..])
          return
        elsif name == :MOVE && operands[0] == src && operands[1] == dst
          return # a swapping MOVE (dst <- src right after src <- dst) is skipped
        elsif name == :MOVE && operands[0] == src && src >= @nlocals
          truncate(start)
          @last = nil
          emit(:MOVE, dst, operands[1])
          return
        elsif name == :MOVE && operands[0] == dst
          truncate(start) # an overwritten MOVE is dropped
          @last = nil
          emit(:MOVE, dst, src)
          return
        elsif %i[ADDI SUBI].include?(name) && operands[0] == src && src >= @nlocals && !@labels.include?(start)
          return if fuse_add_immediate(dst, name, operands)
        end
      end
      emit(:MOVE, dst, src)
    end

    # gen_move's ADDI/SUBI case: `MOVE t, x; ADDI t, n` followed by the move of t back into x. When the instruction before the
    # MOVE loads a constant into x the whole thing is the constant of the sum; otherwise the three are one ADDILV (SUBILV) of
    # x with t as working space. Returns whether it applied.
    def fuse_add_immediate(dst, name, operands)
      return false if @history.size < 2

      move = @history[-2]
      return false unless move[0] == :MOVE && move[1][0] == operands[0] && move[1][1] == dst

      unless @labels.include?(move[2]) || @history.size < 3
        prev = @history[-3]
        n = int_operand(prev) if prev[1][0] == dst
        if n
          n = name == :ADDI ? n + operands[1] : n - operands[1]
          truncate(prev[2])
          @last = nil
          load_int(n, dst)
          return true
        end
      end
      truncate(move[2])
      @last = nil
      emit(name == :ADDI ? :ADDILV : :SUBILV, dst, operands[0], operands[1])
      true
    end

    # get_int_operand: the integer an instruction loads (LOADL of a big integer is not one).
    def int_operand(insn)
      name, operands, = insn
      case name
      when :LOADI__1 then -1
      when :LOADINEG then -operands[1]
      when :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4, :LOADI_5, :LOADI_6, :LOADI_7 then name.to_s[-1].to_i
      when :LOADI8, :LOADI16
        v = operands[1]
        name == :LOADI16 && v >= 0x8000 ? v - 0x10000 : v
      when :LOADI32
        v = operands[1]
        v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
      end
    end

    # genjmp2: a conditional jump on +reg+. When the value is not needed (+val+ false) and the jump is not a jump target, the
    # fork folds it with the instruction before it: a MOVE into a temporary is dropped and its source tested (only for a
    # temporary above the locals), and a constant load makes the jump unconditional or removes it. Returns the jump's
    # operand position, or nil when the jump was removed.
    def cond_jump(name, reg, val:)
      unless val || no_peephole?
        last, operands, start = @last
        case last
        when :MOVE
          if operands[0] == reg && operands[0] > @nlocals
            truncate(start)
            @last = nil
            reg = operands[1]
          end
        when :LOADNIL, :LOADFALSE
          if operands[0] == reg || operands[0] > @nlocals
            truncate(start)
            @last = nil
            return name == :JMPNOT || (name == :JMPNIL && last == :LOADNIL) ? emit_jump(:JMP) : nil
          end
        when :LOADTRUE, :LOADI8, :LOADINEG, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4, :LOADI_5,
             :LOADI_6, :LOADI_7
          if operands[0] == reg || operands[0] > @nlocals
            truncate(start)
            @last = nil
            return name == :JMPIF ? emit_jump(:JMP) : nil
          end
        end
      end
      emit_jump(name, reg)
    end

    # `a || b` and `a && b`: the left value goes to the first temporary, a jump past the right side tests it (JMPIF for ||,
    # JMPNOT for &&), and the right side replaces it. As a statement the right side is evaluated only for its effects. A
    # literal left side is folded away (codegen_and and codegen_or): `true && b` is b, `nil && b` is nil.
    def logic(node, need:)
      left = node.left # a parenthesized literal is not folded
      right = unparen(node.right)
      is_or = node.is_a?(Prism::OrNode)
      if true_always?(left) || false_always?(left)
        pick = true_always?(left) == is_or ? left : right
        if need
          t = temp
          value_into(pick, t)
          return t
        end
        statement(pick, last: false)
        return nil
      end

      left = unparen(left)
      t = temp
      value_into(left, t)
      to_end = cond_jump(is_or ? :JMPIF : :JMPNOT, t, val: need)
      if need
        value_into(right, t)
      else
        statement(right, last: false)
      end
      dispatch(to_end)
      need ? t : nil
    end

    # `$g = value`: as a constant write, with SETGV.
    # `@ivar = value`: as a global write, with SETIV.
    def ivar_write(node, last:)
      t = temp
      value_into(node.value, t)
      setxv(:SETIV, t, node.name, last)
      last ? t : nil
    end

    # gen_setxv: when the value is not needed and a MOVE into the temporary comes right before, the store reads the move's
    # source and the MOVE goes.
    def setxv(op, reg, name, last)
      sym = sym_index(name)
      name_, operands, start = @last
      if !last && !no_peephole? && name_ == :MOVE && operands[0] == reg
        truncate(start)
        @last = nil
        reg = operands[1]
      end
      emit(op, reg, sym)
    end

    def global_write(node, last:)
      t = temp
      value_into(node.value, t)
      setxv(:SETGV, t, node.name, last)
      last ? t : nil
    end

    # `X = value`: the value goes to the first temporary, SETCONST stores it, and the last statement returns it.
    def const_write(node, last:)
      t = temp
      value_into(node.value, t)
      emit(:SETCONST, t, sym_index(node.name))
      last ? t : nil
    end

    def write_local(node, last:)
      return write_upvar(node, last: last) if node.respond_to?(:depth) && node.depth.positive? # a default is no upvalue

      local = local_register(node.name)
      value = unparen(node.value)
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
          # An upvalue read is loaded straight into the local (gen_move's GETUPVAR peephole).
          if value.depth.zero?
            src = local_register(value.name)
            # `x = x`: the value is loaded into the temporary and the move back is skipped (gen_move's swap rule).
            src == local ? emit(:MOVE, @sp, src) : gen_move(local, src)
          else
            value_into(value, local)
          end
        when Prism::CallNode
          # A call or operator result stays in its temporary, and the move into the local is kept (gen_move's peephole
          # only removes a move after a load).
          gen_move(local, call(value))
        else
          value_into(value, local)
        end
        nil
      end
    end

    # A method call, as the fork's codegen emits it. The registers above the locals are a stack (the fork's cursp, here
    # @sp = the first free register): a call's result register is the stack pointer at its start, its receiver is
    # generated into that register, and each argument is generated into the next one with the pointer advanced to it, so a
    # nested call (or an operator on a call) takes the argument's register as its own result register and its result lands
    # in place with no move. The pointer is restored when the call is done; the result stays in the base register, which
    # the caller then owns. A binary + or - with a literal from 1 to 255 is ADDI or SUBI on the receiver's register.
    # Returns the result register.
    # `recv.name = value`: the result (the value) is in the first temporary r; the receiver is in r+1 and the value in r+2,
    # and SEND runs on r+1 with that one argument (verified against mrbc -v: the result is the value, not the send's).
    # Where the value is not needed, the receiver is in the first temporary with the value after it, and SEND runs there.
    def attribute_assign(node, recv, arg, need:)
      r = temp
      if need
        value_into(recv, r + 1)
        value_into(arg, r + 2)
        emit(:MOVE, r, r + 2)
        emit(:SEND, r + 1, sym_index(node.name), 1)
        @nregs = [@nregs, r + 4].max
        r
      else
        value_into(recv, r)
        value_into(arg, r + 1)
        emit(:SEND, r, sym_index(node.name), 1)
        @nregs = [@nregs, r + 3].max
        nil
      end
    end

    # `recv[index] = value` (SETIDX, verified): where the value is needed the result register r holds it, the receiver,
    # index and value follow it, and SETIDX runs on the receiver; otherwise the receiver is in the first temporary.
    def index_assign(recv, index, value, need:)
      [recv, index, value].each do |v|
        raise Unsupported, 'index assignment with a non-simple operand' unless simple?(v)
      end
      r = temp
      base = need ? r + 1 : r
      value_into(recv, base)
      value_into(index, base + 1)
      value_into(value, base + 2)
      emit(:MOVE, r, base + 2) if need
      emit(:SETIDX, base)
      @nregs = [@nregs, base + 4].max
      need ? r : nil
    end

    def call(node, need: true)
      return call_with_block(node, need: need) if node.block

      name = node.name
      # `self.foo` is a call on self, emitted as SSEND with no receiver copy.
      recv = node.receiver && unparen(node.receiver)
      recv = nil if recv.is_a?(Prism::SelfNode)
      args = (node.arguments&.arguments || []).map { |a| unparen(a) }
      raise Unsupported, 'call with a block or keywords' if node.block || args.any? { |a| !operand?(a) }
      raise Unsupported, 'call with a non-simple receiver' if recv && (!operand?(recv) || BUILT_VALUES.include?(recv.class))
      raise Unsupported, 'safe navigation' if node.safe_navigation?
      raise Unsupported, "operator method #{name}" if recv && UNVERIFIED_OPERATORS.include?(name)

      if recv && node.call_operator_loc && name.to_s.match?(/\A[A-Za-z_]\w*=\z/) && args.size == 1
        raise Unsupported, 'attribute assignment on self' if recv.is_a?(Prism::SelfNode)
        raise Unsupported, 'attribute assignment receiver' unless simple?(recv)

        return attribute_assign(node, recv, args[0], need: need)
      end

      # The parser folds an operator on two integer literals (1 + 2), which is not reproduced here.
      raise Unsupported, 'operator on two literals' if recv.is_a?(Prism::IntegerNode) && BINARY_OPS.key?(name) &&
                                                       args.size == 1 && args[0].is_a?(Prism::IntegerNode)

      a = @sp
      @nregs = [@nregs, a + 1].max
      if recv && %i[+ -].include?(name) && args.size == 1 && args[0].is_a?(Prism::IntegerNode) &&
         (1..0xff).cover?(args[0].value)
        operand_into(recv, a)
        emit(name == :+ ? :ADDI : :SUBI, a, args[0].value)
        @nregs = [@nregs, a + 3].max
        return a
      end
      # `recv[index]` is GETIDX and `recv[]` a plain SEND0 (both verified); other index forms are not covered yet.
      raise Unsupported, 'index call with several arguments' if name == :[] && args.size > 1
      if name == :[]= && recv && args.size == 2
        return index_assign(recv, args[0], args[1], need: need)
      end
      raise Unsupported, 'index assignment' if name == :[]=

      if recv && BINARY_OPS.key?(name) && args.size == 1
        operand_into(recv, a)
        operand_into(args[0], a + 1)
        emit(BINARY_OPS.fetch(name), a)
        @nregs = [@nregs, a + 3].max
        return a
      end

      operand_into(recv, a) if recv
      args.each_with_index { |arg, i| operand_into(arg, a + 1 + i) }
      sym = sym_index(name)
      n = args.size
      if recv
        n.zero? ? emit(:SEND0, a, sym) : emit(:SEND, a, sym, n)
      else
        n.zero? ? emit(:SSEND0, a, sym) : emit(:SSEND, a, sym, n)
      end
      @nregs = [@nregs, a + n + 2].max
      a
    ensure
      @sp = a if a
    end

    # Whether +node+ may be a call's receiver or argument: a leaf, an array of leaves, or a call (checked when generated).
    def operand?(node)
      node = unparen(node)
      SIMPLE_VALUES.include?(node.class) || node.is_a?(Prism::CallNode) || BUILT_VALUES.include?(node.class) ||
        node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) || node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode) ||
        (node.is_a?(Prism::ArrayNode) && node.elements.all? { |e| simple?(e) })
    end

    # Generates an operand into register +dst+ with the stack pointer at +dst+ (everything above it is free), as the fork
    # pushes an operand and generates it into the new top of the stack.
    def operand_into(node, dst)
      saved = @sp
      @sp = dst
      value_into(node, dst)
    ensure
      @sp = saved
    end

    # Symbols are numbered in order of first use, as the fork's new_sym does.
    def sym_index(name)
      index = @syms.index(name) || (@syms << name).size - 1
      raise Unsupported, 'more than 255 symbols' if index > 0xff

      index
    end

    # The fork's gen_return: a MOVE or a constant load right before RETURN is folded into the return.
    def return_value(reg, op = :RETURN)
      name, operands, start = @last
      # No fold when the return or the instruction it would rewrite is a jump target (the fork's no_peephole and the
      # label checks on the last instruction, codegen.c).
      if @labels.include?(@code.size)
        emit(op, reg)
      elsif %i[RETURN RETSELF RETNIL RETTRUE RETFALSE].include?(name)
        nil # gen_return emits nothing after a return
      elsif name == :MOVE && operands[0] == reg && operands[0] >= @nlocals # a MOVE into a local is kept (verified with mrbc -v)
        truncate(start)
        emit(op, operands[1])
      elsif op == :RETURN && %i[LOADSELF LOADNIL LOADTRUE LOADFALSE].include?(name) && operands[0] == reg
        truncate(start)
        emit({ LOADSELF: :RETSELF, LOADNIL: :RETNIL, LOADTRUE: :RETTRUE, LOADFALSE: :RETFALSE }.fetch(name))
      else
        emit(op, reg)
      end
    end

    def truncate(start)
      @history.pop while @history.last && @history.last[2] >= start
      @code.slice!(start..)
      @lines.slice!(start..)
    end

    # The register the value of +node+ is in: a local is read in place, anything else is loaded into a temporary.
    def value_in_register(node)
      node = unparen(node)
      if node.is_a?(Prism::LocalVariableReadNode) && node.depth.zero?
        # The register is read in place: the fork's MOVE into a temporary, folded into the RETURN, leaves no instruction
        # behind, so a MOVE of an earlier statement must not be folded.
        @last = nil
        return local_register(node.name)
      end

      t = temp
      value_into(node, t)
      t
    end

    def value_into(node, dst)
      node = unparen(node)
      case node
      when Prism::NilNode then emit(:LOADNIL, dst)
      when Prism::TrueNode then emit(:LOADTRUE, dst)
      when Prism::FalseNode then emit(:LOADFALSE, dst)
      when Prism::SelfNode then emit(:LOADSELF, dst)
      when Prism::IntegerNode then load_int(node.value, dst)
      when Prism::LocalVariableReadNode
        node.depth.zero? ? emit(:MOVE, dst, local_register(node.name)) : getupvar(dst, node)
      when Prism::StringNode then emit(@frozen_strings ? :FSTRING : :STRING, dst, pool_index([:str, node.unescaped.b]))
      when Prism::SymbolNode then emit(:LOADSYM, dst, sym_index(node.unescaped.to_sym))
      when Prism::ConstantReadNode then emit(:GETCONST, dst, sym_index(node.name))
      when Prism::GlobalVariableReadNode then emit(:GETGV, dst, sym_index(node.name))
      when Prism::InstanceVariableReadNode then emit(:GETIV, dst, sym_index(node.name))
      when Prism::OrNode, Prism::AndNode
        r = logic(node, need: true)
        gen_move(dst, r)
      when Prism::IfNode, Prism::UnlessNode
        # An if as a value (a ternary, a nested predicate, an argument): built at the destination when it is a temporary,
        # else at the first temporary and moved.
        saved = @sp
        base = dst >= @nlocals ? dst : temp
        begin
          @sp = base
          r = node.is_a?(Prism::IfNode) ? if_statement(node, last: true) : unless_statement(node, last: true)
        ensure
          @sp = saved
        end
        gen_move(dst, r)
      when Prism::ArrayNode then array_into(node, dst)
      when Prism::InterpolatedStringNode then built_into(dst) { |base| dstr_at(node, base) }
      when Prism::HashNode then built_into(dst) { |base| hash_at(node, base) }
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

    # Runs the block with the register the literal is built in: the destination when it is a temporary, else the first
    # temporary, and the result is then moved into the destination (gen_move keeps that move, it only folds loads).
    def built_into(dst)
      base = dst >= @nlocals ? dst : temp
      yield base
      return if dst == base

      # gen_move folds an empty hash literal (HASH with no pairs) into the destination, as it folds a constant load.
      name, operands, start = @last
      if name == :HASH && operands == [base, 0] && !@labels.include?(@code.size)
        truncate(start)
        emit(:HASH, dst, 0)
      else
        emit(:MOVE, dst, base)
      end
    end

    # The fork's string interpolation: the first literal part is a STRING, and each interpolated value is loaded into the
    # next register and STRCATed, followed by the literal part after it (empty when another interpolation or the end
    # follows: the fork always appends it).
    def dstr_at(node, base)
      raise Unsupported, 'multi-line interpolated string' if node.location.start_line != node.location.end_line

      segments = [''.b]
      values = []
      node.parts.each do |part|
        case part
        when Prism::StringNode
          segments.last << part.unescaped.b
        when Prism::EmbeddedStatementsNode
          body = part.statements&.body || []
          raise Unsupported, 'interpolation operand' unless body.size == 1 && SIMPLE_VALUES.include?(body[0].class)

          values << body[0]
          segments << ''.b
        else raise Unsupported, "interpolated part #{part.class.name.split('::').last}"
        end
      end
      raise Unsupported, 'string without interpolation' if values.empty?

      emit(:STRING, base, pool_index([:str, segments[0]]))
      values.each_with_index do |v, i|
        value_into(v, base + 1)
        emit(:STRCAT, base)
        emit(:STRING, base + 1, pool_index([:str, segments[i + 1]]))
        emit(:STRCAT, base)
      end
    end

    # A hash literal of leaf keys and values: key and value pairs are loaded from the base register on, and HASH takes the
    # base register and the pair count (codegen_hash).
    def hash_at(node, base)
      raise Unsupported, 'multi-line hash' if node.location.start_line != node.location.end_line

      pairs = node.elements
      unless pairs.all? { |e| e.is_a?(Prism::AssocNode) && SIMPLE_VALUES.include?(e.key.class) && SIMPLE_VALUES.include?(e.value.class) }
        raise Unsupported, 'hash element'
      end
      raise Unsupported, 'large hash' if pairs.size > 16

      pairs.each_with_index do |e, i|
        value_into(e.key, base + 2 * i)
        value_into(e.value, base + 2 * i + 1)
      end
      emit(:HASH, base, pairs.size)
    end

    # An array literal of leaf values: the elements are loaded from the first temporary on. ARRAY takes that register as
    # its destination; otherwise ARRAY2 takes the destination and the register of the first element (codegen.c, NODE_ARRAY).
    def array_into(node, dst)
      elems = node.elements
      raise Unsupported, 'array element' unless elems.all? { |e| simple?(e) }

      a = temp
      elems.each_with_index { |e, i| value_into(e, a + i) }
      @nregs = [@nregs, a + elems.size].max
      if dst == a
        emit(:ARRAY, a, elems.size)
      elsif elems.empty?
        emit(:ARRAY, dst, 0) # gen_move rewinds an empty ARRAY into the destination
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

    # The first free register (@sp), which starts after the locals as the fork's codegen starts its stack. Using one raises
    # the register count.
    def temp
      @nregs = [@nregs, @sp + 1].max
      @sp
    end

    # Emits one instruction and records its source line for each of its bytes. Operands follow the formats in ops.h:
    # B is 8 bits, S is 16 bits (big endian), and the 32-bit LOADI32 operand is two 16-bit halves.
    def emit(name, *operands)
      start = @code.size
      @history << [name, operands, start]
      @last = [name, operands, start]
      @code << OP.fetch(name)
      case name
      when :ENTER then byte((operands[0] >> 16) & 0xff); short(operands[0] & 0xffff)
      when :LOADI16 then byte(operands[0]); short(operands[1])
      when :LOADI32 then byte(operands[0]); short(operands[1] >> 16); short(operands[1] & 0xffff)
      else operands.each { |v| byte(v) }
      end
      track(operands.first) unless name == :STOP || name == :ENTER # ENTER's operand is an argument spec
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
      lvar = scopes.any? { |s| !s.lv_names.empty? } ? lvar_section : ''.b
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
    # LVAR: the names of all ireps, once each in depth-first order, then per irep one entry for each register from R1
    # (the index of its name, or the null mark for an unnamed register).
    def lvar_section
      names = scopes.flat_map { |s| s.lv_names.compact.map(&:to_s) }.uniq
      syms = [names.size].pack('N') + names.map { |n| [n.bytesize].pack('n') + n.b }.join
      refs = scopes.flat_map do |s|
        (0...s.nlocals - 1).map { |i| (name = s.lv_names[i]) ? names.index(name.to_s) : RITE_LV_NULL_MARK }
      end
      sized('LVAR', syms + refs.pack('n*'))
    end
  end
end
