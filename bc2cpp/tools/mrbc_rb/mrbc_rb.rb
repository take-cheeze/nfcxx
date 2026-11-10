# frozen_string_literal: true

# A Ruby replacement for the fork's `mrbc -g`: Prism tree in, RITE binary out.
#
# Covered: a top-level program whose statements are nil, true, false, self, Integer literals, local reads, local writes
# of those, and method calls on simple operands (a self call or a call with an explicit receiver, with positional
# arguments of those forms, and the binary operators with their own opcodes, + and - with a literal as ADDI and SUBI),
# and if/else with a simple or call predicate and bodies of the forms above, unless, and `class X` or `module X` with a
# plain constant and a body of the forms above (no superclass; the body is a child irep run by EXEC). Milestone 10 adds
# keyword, splat and block-pass arguments, constant paths (read, write, class and module names), regexp literals, lambda
# literals and `&.`. Anything else raises Unsupported, so a
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
    LOADI16: 14, LOADI32: 15, LOADSYM: 16, LOADNIL: 17, LOADSELF: 18, LOADTRUE: 19, LOADFALSE: 20,
    SSEND: 47, SSEND0: 48, SEND: 50, SEND0: 51, ADDI: 70, SUBI: 72, JMP: 38, JMPIF: 39, JMPNOT: 40, JMPNIL: 41, JMPUW: 42, ADDILV: 73, SUBILV: 74, AREF: 87, ASET: 88, APOST: 89, ARYCAT: 84, ARYPUSH: 85, ARYSPLAT: 86,
    ARRAY: 82, ARRAY2: 83, STRING: 92, STRCAT: 93, HASH: 94, GETCONST: 29, SETCONST: 30, GETGV: 21, SETGV: 22, GETIDX: 35,
    SETIDX: 37, GETIDX0: 36, GETIV: 25, SETIV: 26, FSTRING: 119,
    ADD: 69, SUB: 71, MUL: 75, DIV: 76, EQ: 77, LT: 78, LE: 79, GT: 80, GE: 81,
    RETSELF: 63, RETNIL: 64, RETTRUE: 65, RETFALSE: 66, RETURN: 61, RETURN_BLK: 62, STOP: 118,
    CLASS: 103, MODULE: 104, EXEC: 105, TDEF: 107, SDEF: 108, SCLASS: 111, ENTER: 57, KEYEND: 59, KARG: 60,
    GETUPVAR: 33, SETUPVAR: 34, SSENDB: 49, SENDB: 52, BLOCK: 98, GETMCNST: 31, SETMCNST: 32, OCLASS: 102, HASHADD: 95, HASHCAT: 96, LAMBDA: 97,
    EXCEPT: 43, RESCUE: 44, RAISEIF: 45
  }.freeze

  # Binary operators with their own opcode: the receiver is in the result register, the argument in the next one.
  BINARY_OPS = { :+ => :ADD, :- => :SUB, :* => :MUL, :/ => :DIV, :== => :EQ, :< => :LT, :<= => :LE, :> => :GT,
                 :>= => :GE, :[] => :GETIDX }.freeze

  # Statements that may span several lines with the start-line rules of if/unless arms, class and module bodies and def. A
  # multi-line statement of the kinds in MULTILINE_STATEMENTS follows the entered-node rule (Compiler#enter); any other
  # multi-line statement raises Unsupported.
  MULTILINE_OK = [Prism::IfNode, Prism::UnlessNode, Prism::ClassNode, Prism::ModuleNode, Prism::DefNode,
                  Prism::SingletonClassNode, Prism::WhileNode, Prism::UntilNode, Prism::BeginNode].freeze

  # Multi-line statements whose line rules are derived below (see Compiler#enter): the fork stamps each instruction with the
  # line of the classic parser node it entered last, and a node's line is the line of the last token the parser had read
  # when it built the node, which is the node's end line.
  MULTILINE_STATEMENTS = [Prism::LocalVariableWriteNode, Prism::ConstantWriteNode, Prism::GlobalVariableWriteNode,
                          Prism::InstanceVariableWriteNode, Prism::CallNode, Prism::StringNode, Prism::InterpolatedStringNode,
                          Prism::HashNode, Prism::ArrayNode].freeze

  # Nodes whose line `enter` sets: every node the fork's codegen enters (a leaf, a call, a write, an array or a hash).
  ENTERED = [Prism::IntegerNode, Prism::InstanceVariableReadNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
             Prism::LocalVariableReadNode, Prism::StringNode, Prism::ConstantReadNode, Prism::GlobalVariableReadNode, Prism::SelfNode,
             Prism::SymbolNode, Prism::InterpolatedStringNode, Prism::HashNode, Prism::ArrayNode, Prism::CallNode,
             Prism::LocalVariableWriteNode, Prism::ConstantWriteNode, Prism::GlobalVariableWriteNode,
             Prism::InstanceVariableWriteNode, Prism::OrNode, Prism::AndNode].freeze

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
  BUILT_VALUES = [Prism::InterpolatedStringNode, Prism::HashNode, Prism::RegularExpressionNode,
                  Prism::InterpolatedRegularExpressionNode].freeze

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
      @insns = [] # every emitted instruction as [name, operands, start], for the peepholes that look two back (gen_move)
      @rewound = false # the pc was rewound to the last instruction (the fork's pc == lastpc): no peephole until the next emit
      @leading_dot = {}.compare_by_identity # receiver node => line of the next token, for `recv\n  .name` (see #line_of)
      @catches = [] # the catch handler table [type, begin, end, target] (RITE_CATCH), in the order the fork allocates them
      @regions = [] # the begin/rescue regions being generated (the fork's LOOP_BEGIN and LOOP_RESCUE loopinfos)
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
      if params.nil? && node.equal_loc && node.lparen_loc.nil?
        # `def f = expr` has no hidden block slot (verified with mrbc -v: nlocals is 1, unlike `def f() = expr`).
        raise Unsupported, 'endless def without parameters but with locals' unless node.locals.empty?

        set_locals([])
      else
        set_locals(pre + [nil] + block_names + kw_names + (node.locals - pre - block_names - kw_names))
      end
      @nregs = @nlocals + 1
      @line = node.location.start_line
      aspec = (requireds.size << 18) | (optionals.size << 13) | ((rest ? 1 : 0) << 12) | (posts.size << 7) |
              (keywords.size << 2) | (block ? 1 : 0)
      emit(:ENTER, aspec)
      @in_method = true
      method_optionals(optionals) unless optionals.empty?
      method_keywords(keywords, pre.size) unless keywords.empty?
      emit(:MOVE, local_register(block.name), pre.size + 1) if block
      stmts = body_statements(node.body)
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

      param_names = requireds.map(&:name)
      set_locals(param_names + [nil] + (node.locals - param_names))
      @nregs = @nlocals + 1
      @line = node.is_a?(Prism::LambdaNode) ? node.closing_loc.start_line : node.opening_loc.start_line # a lambda is stamped at its end
      emit(:ENTER, requireds.size << 18)
      stmts = body_statements(node.body)
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
      body = [@nlocals, @nregs, @children.size].pack('nnn') + [@catches.size, @code.size].pack('nN') + @code.pack('C*') +
             catch_table_block + pool_block + syms_block
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
      raise Unsupported, 'call with a block and a non-plain method name' unless node.name.to_s.match?(PLAIN_NAME)

      recv = node.receiver && unparen(node.receiver)
      recv = nil if recv.is_a?(Prism::SelfNode)
      raise Unsupported, 'safe navigation without a receiver' if node.safe_navigation? && recv.nil?
      args = (node.arguments&.arguments || []).map { |a| unparen(a) }
      raise Unsupported, 'call with a block and a non-operand argument' unless args.all? { |x| operand?(x) || x.is_a?(Prism::KeywordHashNode) || x.is_a?(Prism::SplatNode) }
      raise Unsupported, 'call with a block and a non-simple receiver' if recv && !operand?(recv)

      line = blk.opening_loc.start_line
      parts = [*(recv ? [recv.location] : []), *args.map(&:location)]
      unless @line == line && node.location.start_line == line && parts.all? { |l| l.start_line == line && l.end_line == line }
        raise Unsupported, 'call with a block spanning lines'
      end

      a = @sp
      @nregs = [@nregs, a + 1].max
      operand_into(recv, a) if recv
      skip = safe_jump(a, need) if node.safe_navigation?
      argc, = gen_args(nil, a, args)
      sp = @sp
      @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_block(blk, self)
      index = @children.size - 1
      raise Unsupported, 'more than 255 child ireps' if index > 0xff

      emit(:BLOCK, sp, index)
      emit(recv ? :SENDB : :SSENDB, a, sym_index(node.name), argc)
      patch_jump(skip, @code.size) if skip
      @nregs = [@nregs, sp + 1].max
      a
    ensure
      @sp = a if a
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
      return_value(t, @loops.empty? && @regions.empty? ? :RETURN : :RETURN_BLK) # a return inside a loop or a rescue region is the in-block form
      last ? t : nil
    end

    # Generates the statements of a body. The last one is generated as a value when +val+ is set; its register is returned.
    def generate(stmts, val:)
      value_reg = nil
      stmts.each_with_index do |node, i|
        @line = node.location.start_line
        @line_moved = false
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

    # The fork's codegen() sets the line of each instruction from the node it entered last (s->lineno = node->lineno, never
    # restored on exit), and the classic parser stamps a node with p->lineno when it builds it: the line of the last token
    # it has read. For a node that is complete without a lookahead token that is its end line; the newline that follows
    # does not advance the line (the parser adds it later), so only a leading-dot continuation (`recv\n  .name`) moves it,
    # for the receiver nodes that need a lookahead token to be reduced (see #line_of). Verified against `mrbc -v`'s node
    # dump: the line column of every node there is this rule. Entering a node sets @line; the instructions the fork emits
    # after its children (SEND, ARRAY, HASH, STRCAT, MOVE) carry the line of the last node entered. Nodes the fork does not
    # enter (the lhs of an assignment, `self` as a receiver, the elements of %w and %i) never call this.
    def enter(node)
      node = unparen(node)
      return unless ENTERED.include?(node.class)
      return if node.is_a?(Prism::CallNode) && node.block # a call with a block has its own rules (call_with_block)
      return if @hold_line

      @line = line_of(node)
    end

    # Receivers (and the calls they belong to) that are reduced only once the next token is read: that token is the `.` of a
    # leading-dot continuation, on a later line.
    def line_of(node)
      @leading_dot.fetch(node, node.location.end_line)
    end

    # A call whose `.` is on a later line than its receiver's end: the parser reads the `.` (skipping the newline) before it
    # can reduce a receiver that is not complete in itself, so that receiver takes the line of the `.`. Verified with the
    # node dump: a local, a constant, a string, `a::B`, and a call without parentheses (`foo`, `x.y`, `x[1]`) take the line of
    # the dot; an integer, nil, true, false, self, a symbol, an instance or global variable, an array, a hash and a call
    # ending in `)` keep their own line. Other receivers are Unsupported.
    def leading_dot(call)
      recv = call.receiver
      op = call.call_operator_loc
      return unless recv && op && op.start_line > recv.location.end_line

      case recv
      when Prism::IntegerNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode, Prism::SymbolNode,
           Prism::InstanceVariableReadNode, Prism::GlobalVariableReadNode, Prism::ArrayNode, Prism::HashNode
        nil
      when Prism::LocalVariableReadNode, Prism::ConstantReadNode, Prism::StringNode
        @leading_dot[recv] = op.start_line
      when Prism::CallNode
        raise Unsupported, 'leading-dot receiver' if recv.block || recv.safe_navigation?

        @leading_dot[recv] = op.start_line unless recv.closing_loc&.slice == ')'
      else raise Unsupported, 'leading-dot receiver'
      end
    end

    # Rejects the shapes whose line rules are not verified: heredocs, and operators `||` `&&` over several lines.
    def check_multiline(node)
      stack = [node]
      until stack.empty?
        n = stack.pop
        case n
        when Prism::OrNode, Prism::AndNode, Prism::ParenthesesNode
          raise Unsupported, 'multi-line logic or parentheses' if n.location.start_line != n.location.end_line
        when Prism::StringNode, Prism::InterpolatedStringNode
          raise Unsupported, 'heredoc' if n.opening_loc&.slice&.start_with?('<<')
        when Prism::CallNode
          leading_dot(n)
        end
        stack.concat(n.compact_child_nodes)
      end
    end

    def statement(node, last:)
      node = unparen(node)
      if node.location.start_line != node.location.end_line && !MULTILINE_OK.include?(node.class) && !block_statement?(node)
        raise Unsupported, 'multi-line statement' unless MULTILINE_STATEMENTS.include?(node.class)

        check_multiline(node)
        enter(node)
      end
      case node
      when Prism::LocalVariableWriteNode
        write_local(node, last: last)
      when Prism::ConstantReadNode
        # A constant read is generated even when unused: the lookup can autoload or raise (verified: `C` then `1` has GETCONST).
        # An unused one pushes nothing (codegen_const), so its register does not count toward nregs.
        if last
          value_in_register(node)
        else
          nregs = @nregs
          value_into(node, @sp)
          @nregs = nregs
          nil
        end
      when Prism::LocalVariableReadNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode, Prism::IntegerNode,
           Prism::StringNode, Prism::GlobalVariableReadNode, Prism::InstanceVariableReadNode
        last ? value_in_register(node) : nil
      when Prism::ArrayNode
        # Only as a value: an unused array evaluates its elements with no value (NOVAL), which is not reproduced.
        raise Unsupported, 'unused array' unless last

        value_in_register(node)
      when Prism::LambdaNode
        # An unused lambda generates nothing at all, not even its body (codegen_lambda returns early without a value).
        last ? value_in_register(node) : nil
      when Prism::SymbolNode
        # An unused symbol still enters the symbol table (sym_idx runs before gen_load_op2 checks val).
        sym_index(node.unescaped.to_sym)
        last ? value_in_register(node) : nil
      when *BUILT_VALUES
        raise Unsupported, 'unused interpolated regexp' if !last && node.is_a?(Prism::InterpolatedRegularExpressionNode)

        # Unused hashes generate nothing (codegen_hash returns early); an unused string evaluates its expressions only.
        if last
          value_in_register(node)
        else
          string_unused(node) if node.is_a?(Prism::InterpolatedStringNode)
          nil
        end
      when Prism::CallNode
        call(node, need: last)
      when Prism::ConstantWriteNode
        const_write(node, last: last)
      when Prism::ConstantPathNode
        # codegen_colon2/3 emit the lookup even when the value is unused.
        t = temp
        colon_path(node)
        last ? t : nil
      when Prism::ConstantPathWriteNode
        const_path_write(node, last: last)
      when Prism::GlobalVariableWriteNode
        global_write(node, last: last)
      when Prism::InstanceVariableWriteNode
        ivar_write(node, last: last)
      when Prism::DefNode
        def_statement(node, last: last)
      when Prism::ReturnNode
        return_statement(node, last: last)
      when Prism::BeginNode
        begin_statement(node, last: last)
      when Prism::RescueModifierNode
        rescue_modifier_statement(node, last: last)
      when Prism::RetryNode
        retry_statement(node, last: last)
      when Prism::OrNode, Prism::AndNode
        logic(node, need: last)
      when Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
           Prism::GlobalVariableOperatorWriteNode, Prism::ConstantOperatorWriteNode
        operator_write(node, last: last)
      when Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode, Prism::GlobalVariableOrWriteNode,
           Prism::ConstantOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::InstanceVariableAndWriteNode,
           Prism::GlobalVariableAndWriteNode, Prism::ConstantAndWriteNode
        logic_write(node, last: last)
      when Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
           Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
        call_write(node, last: last)
      when Prism::MultiWriteNode
        multiple_write(node, last: last)
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
      return next_in_region(node, last: last) if @regions.last && @regions.last.loops == @loops.size

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
      raise Unsupported, 'superclass that is not a simple value' if superclass && !(simple?(superclass) || unparen(superclass).is_a?(Prism::ConstantPathNode))

      t = temp
      name = namespace_into(node.constant_path, t)
      # The superclass, when there is one, goes into the register after the namespace (codegen_class).
      superclass ? operand_into(superclass, t + 1) : emit(:LOADNIL, t + 1)
      emit(:CLASS, t, sym_index(name))
      class_body(node, t, last)
      t
    end

    # codegen_module: the outer namespace goes into the temporary, which MODULE takes as its result.
    def module_statement(node, last:)
      t = temp
      name = namespace_into(node.constant_path, t)
      emit(:MODULE, t, sym_index(name))
      class_body(node, t, last)
      t
    end

    # gen_namespace: the outer namespace goes into +t+ (nil for a plain constant, OCLASS for `::Name`, else the base of the
    # path generated there). Returns the class's own name.
    def namespace_into(path, t)
      case path
      when Prism::ConstantReadNode
        emit(:LOADNIL, t)
        path.name
      when Prism::ConstantPathNode
        parent = path.parent && unparen(path.parent)
        if parent.nil?
          emit(:OCLASS, t)
        elsif parent.is_a?(Prism::ConstantPathNode) || (operand?(parent) && !BUILT_VALUES.include?(parent.class))
          operand_into(parent, t)
        else
          raise Unsupported, 'class or module path base'
        end
        path.name
      else raise Unsupported, 'class or module path'
      end
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
      @last = [name, [reg].compact, start]
      @insns << @last
      @rewound = false
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

    # genjmp2: a conditional jump on +reg+. When the value is not needed (+val+ false) and the jump is not a jump target, the
    # fork folds it with the instruction before it: a MOVE into a temporary is dropped and its source tested (only for a
    # temporary above the locals), and a constant load makes the jump unconditional or removes it. Returns the jump's
    # operand position, or nil when the jump was removed.
    def cond_jump(name, reg, val:)
      unless val || no_peephole?
        last, operands, start = @insns.last
        case last
        when :MOVE
          if operands[0] == reg && operands[0] > @nlocals
            truncate(start)
            reg = operands[1]
          end
        when :LOADNIL, :LOADFALSE
          if operands[0] == reg || operands[0] > @nlocals
            truncate(start)
            return name == :JMPNOT || (name == :JMPNIL && last == :LOADNIL) ? emit_jump(:JMP) : nil
          end
        when :LOADTRUE, :LOADI8, :LOADINEG, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4, :LOADI_5,
             :LOADI_6, :LOADI_7
          if operands[0] == reg || operands[0] > @nlocals
            truncate(start)
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
      raise Unsupported, 'multi-line logic operator' if node.location.start_line != node.location.end_line

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
      gen_setxv(:SETIV, t, node.name, last) # drops a MOVE just before when the value is unused
      last ? t : nil
    end

    def global_write(node, last:)
      t = temp
      value_into(node.value, t)
      gen_setxv(:SETGV, t, node.name, last) # drops a MOVE just before when the value is unused
      last ? t : nil
    end

    # `X = value`: the value goes to the first temporary, SETCONST stores it, and the last statement returns it.
    def const_write(node, last:)
      t = temp
      value_into(node.value, t)
      gen_setxv(:SETCONST, t, node.name, last) # drops a MOVE just before when the value is unused
      last ? t : nil
    end

    # `Base::Name` and `::Name` (codegen_colon2, codegen_colon3): the name's symbol is numbered first, then the base is
    # generated at the stack pointer (a constant, another path or an operand) and GETMCNST reads the name from it; a leading
    # `::` is OCLASS in its place. The result is in the register the path started at.
    def colon_path(node)
      a = @sp
      sym = sym_index(node.name)
      parent = node.parent && unparen(node.parent)
      if parent.nil?
        emit(:OCLASS, a)
      elsif parent.is_a?(Prism::ConstantPathNode)
        colon_path(parent)
      else
        raise Unsupported, 'constant path base' unless operand?(parent) && !BUILT_VALUES.include?(parent.class)

        operand_into(parent, a)
      end
      emit(:GETMCNST, a, sym)
      a
    end

    # `Base::Name = value` (gen_colon2_assign, gen_colon_assign_common): the result register t holds the value, the base is
    # in t+1 and the value is generated at t+2 and moved into t (the move folds into a load of a leaf value, as gen_move does).
    # SETMCNST stores t into the constant of the base in t+1.
    def const_path_write(node, last:)
      target = node.target
      value = unparen(node.value)
      raise Unsupported, 'constant path value' unless simple?(value) || call_node?(value) || value.is_a?(Prism::ConstantPathNode)

      t = temp
      saved = @sp
      @sp = t + 1
      parent = target.parent && unparen(target.parent)
      if parent.nil?
        emit(:OCLASS, t + 1)
      elsif parent.is_a?(Prism::ConstantPathNode)
        colon_path(parent)
      else
        raise Unsupported, 'constant path base' unless operand?(parent) && !BUILT_VALUES.include?(parent.class)

        operand_into(parent, t + 1)
      end
      sym = sym_index(target.name) # numbered after the base here, unlike a read
      @sp = t + 2
      @nregs = [@nregs, t + 3].max
      if simple?(value)
        value_into(value, t)
      else
        r = value.is_a?(Prism::CallNode) ? call(value) : colon_path(value)
        emit(:MOVE, t, r)
      end
      @sp = saved
      emit(:SETMCNST, t, sym)
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
        enter(value)
        case value
        when Prism::LocalVariableReadNode
          # An upvalue read is loaded straight into the local (gen_move's GETUPVAR peephole).
          if value.depth.zero?
            src = local_register(value.name)
            # `x = x`: the value is loaded into the temporary and the move back is skipped (gen_move's swap rule).
            src == local ? emit(:MOVE, @sp, src) : gen_move(local, src, false)
          else
            value_into(value, local)
          end
        when Prism::CallNode
          # A call or operator result stays in its temporary, and the move into the local is kept (gen_move's peephole
          # only removes a move after a load).
          gen_move(local, call(value), false)
        else
          value_into(value, local)
        end
        nil
      end
    end

    # ---- operator, or and and assignment (milestone 10) ----

    # no_peephole in codegen.c: the pc is a jump target, the start of the code, or the last instruction's own pc.
    def no_peephole?
      @code.empty? || @rewound || @labels.include?(@code.size)
    end

    # get_int_operand: the integer an integer load puts in its register, or nil.
    def int_operand(insn)
      name, ops, = insn
      case name
      when :LOADI__1 then -1
      when :LOADINEG then -ops[1]
      when :LOADI8 then ops[1]
      when :LOADI16 then ops[1] >= 0x8000 ? ops[1] - 0x10000 : ops[1]
      when :LOADI32 then ops[1] >= 0x8000_0000 ? ops[1] - 0x1_0000_0000 : ops[1]
      else
        name.to_s =~ /\ALOADI_(\d)\z/ ? Regexp.last_match(1).to_i : nil
      end
    end

    # The fork's gen_move: R[dst] = R[src], folding the instruction that produced the value into the destination. With
    # +nopeep+ (the value is used afterwards) the move is always emitted.
    def gen_move(dst, src, nopeep)
      return if dst == src

      unless nopeep || no_peephole?
        name, ops, start = @insns.last
        case name
        when :MOVE
          a, b = ops
          if a == src
            return if b == dst # a swapping MOVE

            unless a < @nlocals
              truncate(start)
              @rewound = false # lastpc is the instruction before: the peepholes go on
              gen_move(dst, b, false)
              return
            end
          elsif dst == a # an overwritten MOVE
            truncate(start)
            @rewound = false
            gen_move(dst, src, false)
            return
          end
        when :LOADNIL, :LOADSELF, :LOADTRUE, :LOADFALSE, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4,
             :LOADI_5, :LOADI_6, :LOADI_7
          if ops[0] == src && ops[0] >= @nlocals
            truncate(start)
            emit(name, dst)
            return
          end
        when :LOADI8, :LOADINEG, :LOADL, :LOADSYM, :GETGV, :GETIV, :GETCONST, :STRING, :FSTRING, :LOADI16, :LOADI32, :HASH
          if ops[0] == src && ops[0] >= @nlocals && (name != :HASH || ops[1].zero?)
            truncate(start)
            emit(name, dst, ops[1])
            return
          end
        when :ARRAY
          if ops[0] == src && ops[0] >= @nlocals && ops[0] >= dst
            truncate(start)
            ops[1].zero? ? emit(:ARRAY, dst, 0) : emit(:ARRAY2, dst, ops[0], ops[1])
            return
          end
        when :ARRAY2, :GETUPVAR, :AREF
          if ops[0] == src && ops[0] >= @nlocals && (name != :ARRAY2 || ops[0] >= dst)
            truncate(start)
            emit(name, dst, ops[1], ops[2])
            return
          end
        when :ADDI, :SUBI
          if ops[0] == src && ops[0] >= @nlocals && !@labels.include?(start) && @insns.size >= 2
            data0 = @insns[-2]
            if data0[0] == :MOVE && data0[1][0] == ops[0] && data0[1][1] == dst
              folded = nil
              unless @labels.include?(data0[2])
                raise Unsupported, 'move peephole at the start of the code' if @insns.size < 3

                n = int_operand(@insns[-3])
                if n && @insns[-3][1][0] == dst
                  n = name == :ADDI ? n + ops[1] : n - ops[1]
                  folded = n if n.between?(INT32_MIN, INT32_MAX)
                end
              end
              if folded
                first = @insns[-3][2]
                truncate(first)
                load_int(folded, dst)
              else
                truncate(data0[2])
                emit(name == :ADDI ? :ADDILV : :SUBILV, dst, ops[0], ops[1])
              end
              return
            end
          end
        end
      end
      emit(:MOVE, dst, src)
    end

    # gen_setxv: SETGV, SETIV and SETCONST of R[dst]; when the value is not used, the source of a MOVE just before is stored.
    def gen_setxv(op, dst, sym, val)
      sym_index(sym)
      if !val && !no_peephole?
        name, ops, start = @insns.last
        if name == :MOVE && ops[0] == dst
          dst = ops[1]
          truncate(start)
        end
      end
      emit(op, dst, sym_index(sym))
    end

    # The variable of an operator, or and and write: [kind, name]. Upvalues and the other variable kinds are not covered.
    def write_target(node)
      case node
      when Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
        node.depth.positive? ? :upvar : :local
      when Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode
        :ivar
      when Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode
        :gvar
      when Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
        :const
      end
    end

    # codegen(lhs, VAL): the variable's value into register +t+.
    def read_target(kind, node, t)
      case kind
      when :local then emit(:MOVE, t, local_register(node.name))
      when :upvar then getupvar(t, node)
      when :ivar then emit(:GETIV, t, sym_index(node.name))
      when :gvar then emit(:GETGV, t, sym_index(node.name))
      when :const then emit(:GETCONST, t, sym_index(node.name))
      end
    end

    # gen_assignment(lhs, NULL, t, val): store R[t] into the variable.
    def write_target_from(kind, node, t, val)
      case kind
      when :local then gen_move(local_register(node.name), t, val)
      when :upvar
        # gen_setupvar: a MOVE just before is dropped whether or not the value is used.
        idx, lv = upvar_operands(node.name, node.depth)
        name, ops, start = @insns.last
        if !no_peephole? && name == :MOVE && ops[0] == t
          truncate(start)
          t = ops[1]
        end
        emit(:SETUPVAR, t, idx, lv)
      when :ivar then gen_setxv(:SETIV, t, node.name, val)
      when :gvar then gen_setxv(:SETGV, t, node.name, val)
      when :const then gen_setxv(:SETCONST, t, node.name, val)
      end
    end

    # The values an assignment's right side may be: operands, and `||` and `&&` of operands (value_into builds them).
    def assign_value?(value)
      operand?(value) || value.is_a?(Prism::OrNode) || value.is_a?(Prism::AndNode)
    end

    # `x += v` is `x = x + v` (codegen_op_asgn): the variable goes to the first temporary, the value to the next, the operator
    # runs on the first one (ADDI and SUBI take a literal from -255 to 255 off gen_addsub's last instruction), and the result is
    # assigned back; the assignment keeps its MOVE where the value is used and folds into the load or the ADDILV otherwise.
    def operator_write(node, last:)
      kind = write_target(node)
      value = unparen(node.value)
      raise Unsupported, 'operator assignment value' unless assign_value?(value)

      t = temp
      read_target(kind, node, t)
      operand_into(value, t + 1)
      @nregs = [@nregs, t + 3].max
      op = node.binary_operator
      case op
      when :+, :-
        add_sub(op, t)
      when :*, :/, :<, :<=, :>, :>=
        emit({ :* => :MUL, :/ => :DIV, :< => :LT, :<= => :LE, :> => :GT, :>= => :GE }.fetch(op), t)
      else
        emit(:SEND, t, sym_index(op), 1)
      end
      write_target_from(kind, node, t, last)
      last ? t : nil
    end

    # gen_addsub: a literal operand from -255 to 255 makes ADDI or SUBI (the load is dropped; 0 drops the operation).
    def add_sub(op, t)
      start = @insns.last&.last
      n = no_peephole? ? nil : int_operand(@insns.last)
      if n.nil?
        emit(op == :+ ? :ADD : :SUB, t)
        return
      end
      raise Unsupported, 'folded operator assignment' if @insns.size >= 2 && !@labels.include?(start) && int_operand(@insns[-2])

      if n > 0xff || n < -0xff
        emit(op == :+ ? :ADD : :SUB, t)
        return
      end
      truncate(start)
      return if n.zero?

      add = (op == :+) == n.positive?
      emit(add ? :ADDI : :SUBI, t, n.abs)
    end

    # `x ||= v` and `x &&= v` (codegen_op_asgn): the variable goes to the first temporary and JMPIF (or JMPNOT) skips the
    # assignment; the value replaces it and is assigned. Where the value is unused a MOVE just before the jump is dropped
    # (genjmp2, only above the first temporary), and the assignment folds into the load. A constant or class variable `||=`
    # is wrapped in an exception handler and is not covered.
    def logic_write(node, last:)
      kind = write_target(node)
      raise Unsupported, 'constant ||=' if kind == :const && node.is_a?(Prism::ConstantOrWriteNode)

      value = unparen(node.value)
      raise Unsupported, 'logic assignment value' unless assign_value?(value)

      t = temp
      read_target(kind, node, t)
      reg = t
      unless last || no_peephole?
        name, ops, start = @insns.last
        if name == :MOVE && ops[0] == t && t > @nlocals
          truncate(start)
          reg = ops[1]
        end
      end
      to_end = emit_jump(jump_name(node), reg)
      value_into(value, t)
      write_target_from(kind, node, t, last)
      patch_jump(to_end, @code.size)
      last ? t : nil
    end

    # `recv[i] op= v`, `recv.name op= v` (and ||=, &&=): the call is read as an ordinary call, then assigned with the
    # fork's codegen_call_assign, which evaluates the receiver and the index again. The value is in the first temporary t;
    # the receiver (and index) go after a result slot at t+1 and the value is copied after them, SETIDX or SEND of the
    # writer then runs on the receiver. Where the value is used it is copied back into t first.
    def call_write(node, last:)
      index = node.is_a?(Prism::IndexOperatorWriteNode) || node.is_a?(Prism::IndexOrWriteNode) ||
              node.is_a?(Prism::IndexAndWriteNode)
      recv = node.receiver && unparen(node.receiver)
      raise Unsupported, 'assignment receiver' unless recv && (simple?(recv) || call_node?(recv)) && !recv.is_a?(Prism::SelfNode)
      raise Unsupported, 'safe navigation assignment' if !index && node.safe_navigation?

      idx = nil
      if index
        args = node.arguments&.arguments || []
        raise Unsupported, 'index assignment with a block' if node.block
        raise Unsupported, 'index assignment arguments' unless args.size == 1 && (simple?(args[0]) || call_node?(args[0]))

        idx = unparen(args[0])
      end
      value = unparen(node.value)
      raise Unsupported, 'assignment value' unless assign_value?(value)

      t = temp
      operand_into(recv, t)
      if index
        operand_into(idx, t + 1)
        emit(:GETIDX, t)
      else
        emit(:SEND0, t, sym_index(node.read_name))
      end
      @nregs = [@nregs, t + 2].max
      to_end = nil
      case node
      when Prism::IndexOrWriteNode, Prism::CallOrWriteNode, Prism::IndexAndWriteNode, Prism::CallAndWriteNode
        to_end = emit_jump(jump_name(node), t)
        value_into(value, t)
      else
        operand_into(value, t + 1)
        @nregs = [@nregs, t + 3].max
        op = node.binary_operator
        case op
        when :+, :-
          add_sub(op, t)
        when :*, :/, :<, :<=, :>, :>=
          emit({ :* => :MUL, :/ => :DIV, :< => :LT, :<= => :LE, :> => :GT, :>= => :GE }.fetch(op), t)
        else
          emit(:SEND, t, sym_index(op), 1)
        end
      end
      base = t + 1
      operand_into(recv, base)
      if index
        operand_into(idx, base + 1)
        gen_move(base + 2, t, false)
        gen_move(t, base + 2, true) if last
        emit(:SETIDX, base)
        @nregs = [@nregs, base + 4].max
      else
        gen_move(base + 1, t, false)
        gen_move(t, base + 1, true) if last
        emit(:SEND, base, sym_index(node.write_name), 1)
        @nregs = [@nregs, base + 3].max
      end
      patch_jump(to_end, @code.size) if to_end
      last ? t : nil
    end

    # gen_assignment(target, NULL, src, NOVAL): store R[src] into one target of a multiple assignment; +cursp+ is the
    # register stack pointer at that moment (a nested target's AREFs and a call target's receiver start there).
    def assign_target(target, src, cursp)
      case target
      when Prism::LocalVariableTargetNode
        if target.depth.positive?
          idx, lv = upvar_operands(target.name, target.depth)
          name, ops, start = @insns.last
          if !no_peephole? && name == :MOVE && ops[0] == src
            truncate(start)
            src = ops[1]
          end
          emit(:SETUPVAR, src, idx, lv)
        else
          gen_move(local_register(target.name), src, false)
        end
      when Prism::InstanceVariableTargetNode then gen_setxv(:SETIV, src, target.name, false)
      when Prism::GlobalVariableTargetNode then gen_setxv(:SETGV, src, target.name, false)
      when Prism::ConstantTargetNode then gen_setxv(:SETCONST, src, target.name, false)
      when Prism::MultiTargetNode
        raise Unsupported, 'nested multiple assignment with a splat' unless target.rest.nil? && target.rights.empty?

        target.lefts.each_with_index do |l, i|
          emit(:AREF, cursp, src, i)
          assign_target(l, cursp, cursp + 1)
        end
      when Prism::CallTargetNode, Prism::IndexTargetNode
        index = target.is_a?(Prism::IndexTargetNode)
        recv = unparen(target.receiver)
        raise Unsupported, 'assignment target receiver' unless (simple?(recv) || call_node?(recv)) && !recv.is_a?(Prism::SelfNode)
        raise Unsupported, 'safe navigation assignment' if !index && target.safe_navigation?

        callsp = src == cursp ? cursp + 1 : cursp # room for the result when the value is at the stack pointer
        operand_into(recv, callsp)
        if index
          args = target.arguments&.arguments || []
          raise Unsupported, 'index assignment target' unless args.size == 1 && !target.block && (simple?(args[0]) || call_node?(args[0]))

          operand_into(unparen(args[0]), callsp + 1)
          gen_move(callsp + 2, src, false)
          emit(:SETIDX, callsp)
          @nregs = [@nregs, callsp + 4].max
        else
          gen_move(callsp + 1, src, false)
          emit(:SEND, callsp, sym_index(target.name), 1)
          @nregs = [@nregs, callsp + 3].max
        end
      else raise Unsupported, "multiple assignment target #{target.class.name.split('::').last}"
      end
    end

    # `a, b = x, y` (codegen_masgn). With a fixed right side whose value is unused, the values go to consecutive registers
    # from the first temporary and each target takes its own (a literal-only right side for local targets is loaded straight
    # into them). Otherwise the right side is a value (an array, for several) in the first temporary, and AREF reads each
    # leading target out of it (APOST for the splat and the trailing targets); the statement's value is that value.
    def multiple_write(node, last:)
      lefts = node.lefts
      rest = node.rest
      rights = node.rights
      rest = nil if rest.is_a?(Prism::ImplicitRestNode) # a trailing comma adds nothing
      raise Unsupported, 'multiple assignment with a bare splat' if rest && rest.expression.nil?
      raise Unsupported, 'multiple assignment with parentheses' if node.lparen_loc

      value = unparen(node.value)
      fixed = value.is_a?(Prism::ArrayNode) && value.elements.none? { |e| e.is_a?(Prism::SplatNode) }
      if value.is_a?(Prism::ArrayNode)
        raise Unsupported, 'multiple assignment right side with a splat' unless fixed
        raise Unsupported, 'multiple assignment right side element' unless value.elements.all? { |e| operand?(e) }
      else
        raise Unsupported, 'multiple assignment right side' unless operand?(value) || value.is_a?(Prism::OrNode) ||
                                                                      value.is_a?(Prism::AndNode)
      end
      nregs_before = @nregs
      t = temp
      if !last && fixed && !value.elements.empty?
        elems = value.elements.map { |e| unparen(e) }
        simple_literals = [Prism::IntegerNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode]
        if rest.nil? && rights.empty? && !lefts.empty? && lefts.size == elems.size &&
           elems.all? { |e| simple_literals.include?(e.class) } &&
           lefts.all? { |l| l.is_a?(Prism::LocalVariableTargetNode) && l.depth.zero? }
          @nregs = nregs_before # nothing is pushed for loads straight into the locals
          lefts.each_with_index { |l, i| value_into(elems[i], local_register(l.name)) }
          return nil
        end
        len = elems.size
        elems.each_with_index { |e, i| operand_into(e, t + i) }
        @nregs = [@nregs, t + len].max
        n = 0
        # The fork's register stack does not grow for a LOADNIL or the rest's ARRAY (no push), so the register count must not
        # either; only variable targets are covered there (a call target counts its own registers).
        plain = [Prism::LocalVariableTargetNode, Prism::InstanceVariableTargetNode, Prism::GlobalVariableTargetNode,
                 Prism::ConstantTargetNode]
        n = 0
        lefts.each do |l|
          if n < len
            assign_target(l, t + n, t + len)
          else
            raise Unsupported, 'missing value for a non-variable target' unless plain.include?(l.class)

            saved = @nregs
            emit(:LOADNIL, t + n)
            assign_target(l, t + n, t + len)
            @nregs = saved
          end
          n += 1
        end
        if rest
          raise Unsupported, 'splat target that is not a variable' unless plain.include?(rest.expression.class)

          post = rights.size
          rn = len < post + n ? 0 : len - post - n
          cursp = t + len
          saved = @nregs
          cursp == t + n ? emit(:ARRAY, cursp, rn) : emit(:ARRAY2, cursp, t + n, rn)
          assign_target(rest.expression, cursp, cursp)
          @nregs = saved
          n += rn
        end
        rights.each do |r|
          if n < len
            assign_target(r, t + n, t + len)
          else
            raise Unsupported, 'missing value for a non-variable target' unless plain.include?(r.class)

            saved = @nregs
            emit(:LOADNIL, t + len)
            assign_target(r, t + len, t + len)
            @nregs = saved
          end
          n += 1
        end
        return nil
      end

      if fixed
        raise Unsupported, 'empty array on a multiple assignment' if value.elements.empty?

        value.elements.each_with_index { |e, i| operand_into(unparen(e), t + 1 + i - 1) }
        @nregs = [@nregs, t + value.elements.size].max
        emit(:ARRAY, t, value.elements.size)
      else
        operand_into(value, t)
      end
      sp = t + 1
      @nregs = [@nregs, sp].max
      lefts.each_with_index do |l, i|
        emit(:AREF, sp, t, i)
        assign_target(l, sp, sp + 1)
      end
      post = rights.size
      if rest || post.positive?
        gen_move(sp, t, last)
        @nregs = [@nregs, sp + post + 1].max
        emit(:APOST, sp, lefts.size, post)
        assign_target(rest.expression, sp, sp) if rest
        rights.each_with_index { |r, i| assign_target(r, sp + 1 + i, sp) }
      end
      last ? t : nil
    end

    def jump_name(node)
      node.class.name.end_with?('OrWriteNode') ? :JMPIF : :JMPNOT
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
        operand_into(recv, r + 1)
        operand_into(arg, r + 2)
        emit(:MOVE, r, r + 2)
        emit(:SEND, r + 1, sym_index(node.name), 1)
        @nregs = [@nregs, r + 4].max
        r
      else
        operand_into(recv, r)
        operand_into(arg, r + 1)
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
      operand_into(recv, base)
      operand_into(index, base + 1)
      operand_into(value, base + 2)
      emit(:MOVE, r, base + 2) if need
      emit(:SETIDX, base)
      @nregs = [@nregs, base + 4].max
      need ? r : nil
    end

    PLAIN_NAME = /\A[A-Za-z_]\w*[?!]?\z/

    # Whether a call's arguments are more than positional operands: keyword arguments, splats or a block argument.
    def complex_arguments?(node)
      (node.arguments&.arguments || []).any? { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::SplatNode) } ||
        node.block.is_a?(Prism::BlockArgumentNode)
    end

    # `recv&.name`: the receiver's copy goes to the next register and JMPNIL on it skips the send (the move is forced, as
    # gen_move's nopeep). When the value is unused the jump takes the receiver's own register, since genjmp2 rewinds the move.
    # Returns the jump to patch after the send.
    def safe_jump(a, need)
      if need
        emit(:MOVE, a + 1, a)
        emit_jump(:JMPNIL, a + 1)
      else
        emit_jump(:JMPNIL, a)
      end
    end

    # A call with keyword arguments, splats or a block argument (codegen_call with callargs): the arguments are generated by
    # gen_args, the block argument last, and the send is SEND/SENDB (SSEND/SSENDB without a receiver) whose argc byte packs
    # the positional count (15 when a splat made it variable) and the keyword count (15 when a ** made it a hash).
    def call_with_args(node, need:)
      raise Unsupported, 'call with a non-plain method name and complex arguments' unless node.name.to_s.match?(PLAIN_NAME)

      recv = node.receiver && unparen(node.receiver)
      recv = nil if recv.is_a?(Prism::SelfNode)
      raise Unsupported, 'safe navigation without a receiver' if node.safe_navigation? && recv.nil?
      raise Unsupported, 'call with a non-simple receiver' if recv && !operand?(recv)

      a = @sp
      @nregs = [@nregs, a + 1].max
      operand_into(recv, a) if recv
      skip = safe_jump(a, need) if node.safe_navigation?
      argc, blk = gen_args(node.block, a, node.arguments&.arguments || [])
      emit_send(a, recv, node.name, argc, blk)
      patch_jump(skip, @code.size) if skip
      a
    ensure
      @sp = a if a
    end

    # The send instruction: with a receiver SEND (SEND0 when there is nothing to pass), without one SSEND (SSEND0).
    def emit_send(a, recv, name, argc, blk)
      sym = sym_index(name)
      if blk
        emit(recv ? :SENDB : :SSENDB, a, sym, argc)
      elsif argc.zero?
        emit(recv ? :SEND0 : :SSEND0, a, sym)
      else
        emit(recv ? :SEND : :SSEND, a, sym, argc)
      end
    end

    # gen_values, gen_hash and the block argument of codegen_call: the arguments of the call whose result register is +a+
    # are generated from register a+1. Returns the argc byte (n | nk << 4) and whether a block argument was generated.
    # Positional operands are loaded in order; a splat flushes what came before into an array (LOADNIL or ARRAY, then
    # ARYPUSH) and ARYCATs the splatted value, so the count becomes 15 and the array is one register. Keywords stay as key and
    # value registers (nk is their count) unless a ** is present: then a HASH is built and extended with HASHADD/HASHCAT
    # (nk = 15). The block argument is loaded in the register after all of these. The stack pointer is left at the register
    # after the arguments, which the send's own result push then counts.
    def gen_args(blk, a, args)
      regular = args.reject { |x| x.is_a?(Prism::KeywordHashNode) }
      kw = args.find { |x| x.is_a?(Prism::KeywordHashNode) }
      sp = a + 1
      n = 0
      variable = false
      regular.each do |arg|
        arg = unparen(arg)
        if arg.is_a?(Prism::SplatNode)
          v = arg.expression && unparen(arg.expression)
          raise Unsupported, 'anonymous splat' unless v

          if v.is_a?(Prism::ArrayNode) && v.elements.none?(Prism::SplatNode)
            # Literal arrays are inlined (empty ones vanish).
            raise Unsupported, 'splat of an array of non-leaf values' unless v.elements.all? { |e| simple?(e) }

            v.elements.each { |e| operand_into(unparen(e), sp); sp += 1; n += 1 }
            next
          end
          raise Unsupported, 'splat of a non-operand' unless operand?(v)

          sp -= n
          if !variable
            n.zero? ? emit(:LOADNIL, sp) : emit(:ARRAY, sp, n)
            sp += 1
            variable = true
          elsif n.positive?
            sp -= 1
            emit(:ARYPUSH, sp, n)
            sp += 1
          end
          n = 0
          operand_into(v, sp)
          emit(:ARYCAT, sp - 1)
        else
          raise Unsupported, 'argument is not an operand' unless operand?(arg)

          operand_into(arg, sp)
          sp += 1
          n += 1
        end
        raise Unsupported, 'argument stack too deep' if sp > 90
      end
      if variable
        if n.positive?
          sp -= 1 + n
          emit(:ARYPUSH, sp, n)
        else
          sp -= 1
        end
        sp += 1
        n = 15
      elsif n > 14
        raise Unsupported, 'more than 14 positional arguments'
      end
      nk = 0
      if kw
        nk, sp = gen_keywords(kw, sp)
      end
      @sp = sp
      @nregs = [@nregs, sp + 1].max
      if blk
        raise Unsupported, 'anonymous block argument' unless blk.expression

        operand_into(unparen(blk.expression), sp)
      end
      [n | (nk << 4), !blk.nil?]
    end

    # gen_hash with val: pairs stay as key and value registers; a ** starts (or extends) a HASH built from the pairs before it
    # and merges the splatted value with HASHCAT; pairs after it are added with HASHADD. Returns [nk, the next register].
    def gen_keywords(kw, sp)
      len = 0
      update = false
      first = true
      kw.elements.each do |e|
        case e
        when Prism::AssocSplatNode
          v = e.value && unparen(e.value)
          raise Unsupported, 'anonymous keyword splat' unless v && operand?(v)

          if first
            emit(:HASH, sp, 0)
            sp += 1
            update = true
          elsif len.positive?
            sp -= len * 2
            if update
              sp -= 1
              emit(:HASHADD, sp, len)
            else
              emit(:HASH, sp, len)
            end
            sp += 1
          end
          operand_into(v, sp)
          emit(:HASHCAT, sp - 1) if len.positive? || update
          update = true
          len = 0
        when Prism::AssocNode
          raise Unsupported, 'keyword pair' unless operand?(e.key) && operand?(e.value)

          operand_into(unparen(e.key), sp)
          operand_into(unparen(e.value), sp + 1)
          sp += 2
          len += 1
        else raise Unsupported, 'keyword argument element'
        end
        first = false
        raise Unsupported, 'argument stack too deep' if sp > 90
      end
      raise Unsupported, 'more than 14 keyword pairs' if len > 14
      return [len, sp] unless update

      if len.positive?
        sp -= len * 2 + 1
        emit(:HASHADD, sp, len)
        sp += 1
      end
      [15, sp]
    end

    def call(node, need: true)
      return call_with_block(node, need: need) if node.block.is_a?(Prism::BlockNode)
      return call_with_args(node, need: need) if complex_arguments?(node)

      enter(node)
      name = node.name
      # `self.foo` is a call on self, emitted as SSEND with no receiver copy.
      recv = node.receiver && unparen(node.receiver)
      if recv.is_a?(Prism::SelfNode)
        # A named method on self is a send with no receiver (SSEND); an operator or index on self loads self like any receiver
        # (verified: `self[x]` is LOADSELF, MOVE, GETIDX).
        n_args = (node.arguments&.arguments || []).size
        if name.to_s.match?(/\A[A-Za-z_]\w*[?!]?\z/) then recv = nil
        elsif !((BINARY_OPS.key?(name) && n_args == 1) || (name == :[]= && n_args == 2))
          raise Unsupported, "operator method #{name} on self"
        end
      end
      args = (node.arguments&.arguments || []).map { |a| unparen(a) }
      raise Unsupported, 'call with a block or keywords' if args.any? { |a| !operand?(a) }
      raise Unsupported, 'call with many arguments' if args.size > 14 # gen_values packs more than 14 into an array
      raise Unsupported, 'call with a non-simple receiver' if recv && !operand?(recv)
      raise Unsupported, 'safe navigation' if node.safe_navigation? && !(recv && name.to_s.match?(PLAIN_NAME))
      raise Unsupported, "operator method #{name}" if recv && UNVERIFIED_OPERATORS.include?(name)

      if recv && node.call_operator_loc && name.to_s.match?(/\A[A-Za-z_]\w*=\z/) && args.size == 1
        raise Unsupported, 'attribute assignment on self' if recv.is_a?(Prism::SelfNode)
        raise Unsupported, 'attribute assignment receiver' unless simple?(recv)

        return attribute_assign(node, recv, args[0], need: need)
      end

      # The parser folds an operator on two integer literals (1 + 2), which is not reproduced here.
      raise Unsupported, 'operator on two literals' if recv.is_a?(Prism::IntegerNode) && (BINARY_OPS.key?(name) || %i[<< >> % ** & | ^].include?(name)) &&
                                                       args.size == 1 && args[0].is_a?(Prism::IntegerNode)

      a = @sp
      @nregs = [@nregs, a + 1].max
      if recv && %i[+ -].include?(name) && args.size == 1 && args[0].is_a?(Prism::IntegerNode) &&
         (1..0xff).cover?(args[0].value)
        operand_into(recv, a)
        enter(args[0]) # the literal is generated (and entered) before the peephole folds it into ADDI
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
        if name == :[] && args[0].is_a?(Prism::IntegerNode) && args[0].value.zero? && recv.is_a?(Prism::LocalVariableReadNode) &&
           recv.depth.zero?
          # gen_binop's GETIDX0 fusion: MOVE a, local; LOADI_0 a+1 become GETIDX0 a, local (verified with mrbc -v).
          truncate(@code.size - 5) # the MOVE (3 bytes) and the LOADI_0 (2 bytes) go
          emit(:GETIDX0, a, local_register(recv.name))
          @nregs = [@nregs, a + 3].max
          return a
        end
        emit(BINARY_OPS.fetch(name), a)
        @nregs = [@nregs, a + 3].max
        return a
      end

      operand_into(recv, a) if recv
      skip = safe_jump(a, need) if node.safe_navigation?
      args.each_with_index { |arg, i| operand_into(arg, a + 1 + i) }
      sym = sym_index(name)
      n = args.size
      if recv
        n.zero? ? emit(:SEND0, a, sym) : emit(:SEND, a, sym, n)
      else
        n.zero? ? emit(:SSEND0, a, sym) : emit(:SSEND, a, sym, n)
      end
      patch_jump(skip, @code.size) if skip
      @nregs = [@nregs, a + n + 2].max
      a
    ensure
      @sp = a if a
    end

    # Whether +node+ may be a call's receiver or argument: a leaf, an array of leaves, or a call (checked when generated).
    def operand?(node)
      node = unparen(node)
      SIMPLE_VALUES.include?(node.class) || node.is_a?(Prism::CallNode) || node.is_a?(Prism::ConstantPathNode) || node.is_a?(Prism::LambdaNode) || BUILT_VALUES.include?(node.class) ||
        node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) || node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode) ||
        (node.is_a?(Prism::ArrayNode) && node.elements.all? { |e| operand?(e) })
    end

    # Generates an operand into register +dst+ with the stack pointer at +dst+ (everything above it is free), as the fork
    # pushes an operand and generates it into the new top of the stack.
    def operand_into(node, dst)
      # The fork stamps each node with its own line, so after a heredoc body's expression an operand on an earlier line goes
      # back to that line; only strings (which set their own line) are covered after one.
      if @line_moved && node.location.start_line != @line && !node.is_a?(Prism::InterpolatedStringNode)
        raise Unsupported, 'operand after a heredoc interpolation'
      end

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
      # No fold when the return or the instruction it would rewrite is a jump target, or after a rewind (the fork's
      # no_peephole, codegen.c).
      if @rewound || @labels.include?(@code.size)
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
      @code.slice!(start..)
      @lines.slice!(start..)
      @insns.pop while @insns.last && @insns.last[2] >= start
      @rewound = true # rewind_pc: the pc is the last instruction's, so no peephole until something is emitted
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
      enter(node)
      case node
      when Prism::NilNode then emit(:LOADNIL, dst)
      when Prism::TrueNode then emit(:LOADTRUE, dst)
      when Prism::FalseNode then emit(:LOADFALSE, dst)
      when Prism::SelfNode then emit(:LOADSELF, dst)
      when Prism::IntegerNode then load_int(node.value, dst)
      when Prism::LocalVariableReadNode
        node.depth.zero? ? emit(:MOVE, dst, local_register(node.name)) : getupvar(dst, node)
      when Prism::StringNode
        # A heredoc of several lines is a literal per line, concatenated (dstr_into).
        if node.opening&.start_with?('<<') then dstr_into(node, dst)
        else emit(@frozen_strings ? :FSTRING : :STRING, dst, pool_index([:str, node.unescaped.b]))
        end
      when Prism::SymbolNode then emit(:LOADSYM, dst, sym_index(node.unescaped.to_sym))
      when Prism::ConstantReadNode then emit(:GETCONST, dst, sym_index(node.name))
      when Prism::GlobalVariableReadNode then emit(:GETGV, dst, sym_index(node.name))
      when Prism::InstanceVariableReadNode then emit(:GETIV, dst, sym_index(node.name))
      when Prism::OrNode, Prism::AndNode
        r = logic(node, need: true)
        gen_move(dst, r, false)
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
        gen_move(dst, r, false)
      when Prism::BeginNode, Prism::RescueModifierNode
        # A begin block as a value: built at the destination when it is a temporary, else at the first temporary and moved.
        saved = @sp
        base = dst >= @nlocals ? dst : temp
        begin
          @sp = base
          r = statement(node, last: true)
        ensure
          @sp = saved
        end
        gen_move(dst, r, false)
      when Prism::ArrayNode then array_into(node, dst)
      when Prism::InterpolatedStringNode then dstr_into(node, dst)
      when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode then built_into(dst) { |base| regex_at(node, base) }
      when Prism::HashNode then built_into(dst) { |base| hash_at(node, base) }
      when Prism::CallNode
        result = call(node)
        emit(:MOVE, dst, result) unless result == dst
      when Prism::ConstantPathNode
        result = colon_path(node)
        emit(:MOVE, dst, result) unless result == dst
      when Prism::LambdaNode
        # LAMBDA takes the child irep like BLOCK does; gen_move folds it straight into a local's register.
        @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_block(node, self)
        index = @children.size - 1
        raise Unsupported, 'more than 255 child ireps' if index > 0xff

        @nregs = [@nregs, @sp + 1].max
        emit(:LAMBDA, dst, index)
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
      gen_move(dst, base, false) # folds an empty hash into the destination; other built values keep the move
    end

    # The fork's string literal (NODE_STR, gen_string): a list of parts, each a literal or an expression. A quoted literal
    # with interpolation is a literal, then an expression and a literal for each interpolation (the literals may be empty,
    # the fork always has them); a literal without one is a single part; adjacent literals ("a" "b#{x}" 'c') are not merged,
    # each contributes its own parts. `#@ivar`, `#$g` and `#@@cv` are not interpolations in the fork: they stay literal text
    # (the part Prism calls an embedded variable). A heredoc is a list of literals per source line (see heredoc_parts).
    # Returns [[:lit, bytes] | [:expr, node], ...].
    def string_parts(node, top: true)
      heredoc = node.respond_to?(:opening) && node.opening&.start_with?('<<')
      raise Unsupported, 'heredoc in a concatenation' if !top && heredoc
      return heredoc_parts(node) if heredoc

      case node
      when Prism::StringNode
        [[:lit, node.unescaped.b]]
      when Prism::InterpolatedStringNode
        return node.parts.flat_map { |part| string_parts(part, top: false) } if node.opening_loc.nil? # adjacent literals

        parts = [[:lit, ''.b]]
        node.parts.each do |part|
          case part
          when Prism::StringNode then parts.last[1] << part.unescaped.b
          when Prism::EmbeddedVariableNode then parts.last[1] << part.location.slice.b
          when Prism::EmbeddedStatementsNode
            body = part.statements&.body || []
            raise Unsupported, 'interpolation with several statements' if body.size > 1

            parts << [:expr, body[0] && unparen(body[0])] << [:lit, ''.b]
          else raise Unsupported, "interpolated part #{part.class.name.split('::').last}"
          end
        end
        parts
      else raise Unsupported, "string part #{node.class.name.split('::').last}"
      end
    end

    # A heredoc body, as the fork's parser splits it (heredoc_string_interp): one literal per source line, the text of a line
    # before an interpolation as a literal of its own (empty when the line starts with it), and the rest of the line, newline
    # included, after it. Prism joins the lines between two interpolations, so they are split again at the newlines of the
    # text. Escapes stay inside their line's literal (verified: \t, \\, \#, \" and \' in a heredoc, a backslash before another
    # character in a raw `<<'A'` one); a continuation, a doubled backslash in a raw heredoc and other escapes are not covered.
    def heredoc_parts(node)
      pieces = node.is_a?(Prism::StringNode) ? [node] : node.parts
      raw = node.opening.include?("'")
      # The fork reads a raw heredoc like a single-quoted string: `\\` is one backslash (unlike Ruby).
      bad = ->(text) { raw ? text.match?(/\\[\\\n]/) : text.gsub(/\\[t\\#"']/, '').include?('\\') }
      if pieces.any? { |x| x.respond_to?(:content_loc) && bad.call(x.content_loc.slice) }
        raise Unsupported, 'heredoc with an escape other than a tab, backslash, quote or hash'
      end

      parts = []
      run = ''.b
      flush = lambda do |before_expr|
        lits = run.scan(/[^\n]*\n|[^\n]+/n)
        lits << ''.b if before_expr && (lits.empty? || lits.last.end_with?("\n"))
        lits.each { |l| parts << [:lit, l] }
        run = ''.b
      end
      pieces.each do |part|
        case part
        when Prism::StringNode then run << part.unescaped.b
        when Prism::EmbeddedVariableNode then run << part.location.slice.b
        when Prism::EmbeddedStatementsNode
          body = part.statements&.body || []
          raise Unsupported, 'interpolation with several statements' if body.size > 1

          flush.call(true)
          parts << [:expr, body[0] && unparen(body[0])]
        else raise Unsupported, "interpolated part #{part.class.name.split('::').last}"
        end
      end
      flush.call(false)
      parts << [:lit, ''.b] if parts.empty?
      parts
    end

    # Whether a heredoc starts inside +node+ (its body lines are not part of the node's own lines).
    def heredoc_inside?(node)
      return true if node.respond_to?(:opening) && node.opening&.start_with?('<<')

      node.compact_child_nodes.any? { |c| heredoc_inside?(c) }
    end

    # An interpolated expression the register stack covers: the operands of calls, the logic operators and the conditionals
    # (an empty interpolation is nil).
    def interpolation_operand?(node)
      node.nil? || operand?(node) || [Prism::OrNode, Prism::AndNode, Prism::IfNode, Prism::UnlessNode].include?(node.class)
    end

    # The value of an interpolated expression in register +dst+, which is the top of the stack.
    def interpolation_into(node, dst)
      raise Unsupported, 'interpolation operand' unless interpolation_operand?(node)
      raise Unsupported, 'multi-line interpolation' if node && (node.location.start_line != node.location.end_line || heredoc_inside?(node))

      # Every node the fork generates stamps the line it was parsed on, so the code of an expression in a heredoc body is on
      # that body's line, and so is the rest of the string and of the statement after it.
      if node
        @line_moved = true if @line != node.location.start_line
        @line = node.location.start_line
      end
      saved = @sp
      @sp = dst
      if node.nil?
        emit(:LOADNIL, dst)
      elsif node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
        r = statement(node, last: true)
        emit(:MOVE, dst, r) unless r == dst
      else
        value_into(node, dst)
      end
    ensure
      @sp = saved
    end

    # An interpolated or concatenated string whose value is unused: only the expressions are evaluated, in order, for their
    # effects (gen_string with val 0).
    def string_unused(node)
      raise Unsupported, 'multi-line interpolated string' if node.location.start_line != node.location.end_line

      string_parts(node).each do |kind, v|
        next unless kind == :expr && v

        raise Unsupported, 'interpolation operand' unless interpolation_operand?(v)
        raise Unsupported, 'multi-line interpolation' if v.location.start_line != v.location.end_line || heredoc_inside?(v)

        @line_moved = true if @line != v.location.start_line
        @line = v.location.start_line
        statement(v, last: false)
      end
    end

    # gen_string with a value: the first part is loaded into the base register, each further part into the next one and
    # STRCATed onto the base. Under `# frozen_string_literal: true` a string of literals only is one FSTRING of the
    # concatenated bytes (gen_frozen_string).
    def dstr_into(node, dst)
      raise Unsupported, 'multi-line interpolated string' if node.location.start_line != node.location.end_line

      parts = string_parts(node)
      # The node's own line, as every node the fork generates (a heredoc: the `<<` line).
      @line_moved = true if @line != node.location.start_line
      @line = node.location.start_line
      if @frozen_strings && parts.all? { |kind, _| kind == :lit }
        return emit(:FSTRING, dst, pool_index([:str, parts.map(&:last).join.b]))
      end

      # A single literal is a plain string load, folded into a local like any other (gen_move).
      return emit(:STRING, dst, pool_index([:str, parts[0][1]])) if parts.size == 1

      built_into(dst) { |base| dstr_at(parts, base) }
    end

    def dstr_at(parts, base)
      parts.each_with_index do |(kind, v), i|
        reg = i.zero? ? base : base + 1
        if kind == :lit
          emit(:STRING, reg, pool_index([:str, v]))
        else
          interpolation_into(v, reg)
        end
        emit(:STRCAT, base) unless i.zero?
      end
    end

    # An interpolated regexp's pattern (the pre-gen_string interpolation path, kept for regexps): the first literal part is a STRING, and each interpolated value is loaded into the
    # next register and STRCATed, followed by the literal part after it (empty when another interpolation or the end
    # follows: the fork always appends it).
    def regex_dstr_at(node, base, regex: true)
      raise Unsupported, 'multi-line interpolated regexp' if regex && node.location.start_line != node.location.end_line

      segments = [''.b]
      values = []
      node.parts.each do |part|
        case part
        when Prism::StringNode
          segments.last << (regex ? regex_text(part.content, node) : part.unescaped.b)
        when Prism::EmbeddedStatementsNode
          body = part.statements&.body || []
          raise Unsupported, 'interpolation operand' unless body.size == 1 && (SIMPLE_VALUES.include?(body[0].class) ||
                                                                                (regex && operand?(body[0])))

          values << body[0]
          segments << ''.b
        else raise Unsupported, "interpolated part #{part.class.name.split('::').last}"
        end
      end
      raise Unsupported, 'string without interpolation' if values.empty?

      emit(:STRING, base, pool_index([:str, segments[0]]))
      values.each_with_index do |v, i|
        operand_into(unparen(v), base + 1)
        emit(:STRCAT, base)
        emit(:STRING, base + 1, pool_index([:str, segments[i + 1]]))
        emit(:STRCAT, base)
      end
    end

    # The text of a regular expression's pattern as the fork's parser keeps it: the source between the delimiters, with an
    # escaped `/` unescaped and every other backslash sequence kept raw. Anything else escaped by the parser (\u) is not
    # reproduced.
    def regex_text(content, node)
      slash = node.opening_loc.slice == '/'
      out = ''.b
      bytes = content.b
      i = 0
      while i < bytes.bytesize
        c = bytes[i]
        if c == '\\'
          nxt = bytes[i + 1]
          raise Unsupported, 'regexp escape' if nxt.nil? || nxt == 'u'
          raise Unsupported, 'escaped delimiter' if !slash && (nxt == node.opening_loc.slice[-1] || nxt == node.closing_loc.slice[0])

          if nxt == '/' && slash
            out << '/'
          else
            out << c << nxt
          end
          i += 2
        else
          out << c
          i += 1
        end
      end
      out
    end

    # codegen_regx: Regexp is looked up from Object (OCLASS, GETMCNST), then the pattern is a string (built as an interpolated
    # string is when it has parts), then the flags "i", "x", "m" in that order and the encoding "u" or "n", with nil for flags
    # when only an encoding is given; the send is Regexp.compile. Always STRING, even under frozen_string_literal.
    def regex_at(node, base)
      raise Unsupported, 'multi-line regexp' if node.location.start_line != node.location.end_line
      raise Unsupported, 'regexp encoding' if node.euc_jp? || node.windows_31j?

      sym = sym_index(:Regexp)
      emit(:OCLASS, base)
      emit(:GETMCNST, base, sym)
      if node.is_a?(Prism::RegularExpressionNode)
        emit(:STRING, base + 1, pool_index([:str, regex_text(node.content, node)]))
      else
        regex_dstr_at(node, base + 1)
      end
      flags = (node.ignore_case? ? 'i' : '') + (node.extended? ? 'x' : '') + (node.multi_line? ? 'm' : '')
      encoding = node.utf_8? ? 'u' : (node.ascii_8bit? ? 'n' : '')
      argc = 1
      unless flags.empty? && encoding.empty?
        flags.empty? ? emit(:LOADNIL, base + 2) : emit(:STRING, base + 2, pool_index([:str, flags.b]))
        argc += 1
        unless encoding.empty?
          emit(:STRING, base + 3, pool_index([:str, encoding.b]))
          argc += 1
        end
      end
      @nregs = [@nregs, base + argc + 2].max
      emit(:SEND, base, sym_index(:compile), argc)
    end

    # A hash literal of leaf keys and values: key and value pairs are loaded from the base register on, and HASH takes the
    # base register and the pair count (codegen_hash).
    def hash_at(node, base)
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
      raise Unsupported, 'array element' unless elems.all? { |e| operand?(e) }
      # %i builds its symbols with SYMBOL and a pool string (not covered); a long list is built in chunks (gen_values).
      raise Unsupported, '%i array' if node.opening_loc&.slice&.match?(/\A%[iI]/)
      raise Unsupported, 'array with many elements' if elems.size > 50

      a = temp
      # The elements of %w and %i are strings and symbols the fork does not enter (gen_literal_array): the line stays that of
      # the array node.
      literal_words = node.opening_loc&.slice&.start_with?('%')
      saved_hold = @hold_line
      @hold_line = true if literal_words
      elems.each_with_index { |e, i| operand_into(unparen(e), a + i) }
      @hold_line = saved_hold
      @nregs = [@nregs, a + elems.size].max
      if elems.empty?
        # gen_move turns the empty array built in the first temporary and moved on into one built in place.
        emit(:ARRAY, dst, 0)
      elsif dst == a
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
      @last = [name, operands, start]
      @insns << @last
      @rewound = false
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

    # ---- exceptions (milestone 11): begin/rescue/else/ensure and retry ----

    # A begin/rescue region on the fork's loop stack (LOOP_BEGIN, then LOOP_RESCUE once its body is done): +pc0+ is the retry
    # target and +loops+ the number of while/until loops enclosing it (a `next` right inside one is not covered).
    Region = Struct.new(:type, :pc0, :loops)

    # write_iseq_block (dump.c): the catch handlers follow the iseq, each a type byte and the begin, end and target pcs as
    # 32-bit big-endian numbers (struct mrb_irep_catch_handler).
    def catch_table_block
      @catches.map { |type, from, to, target| [type, from, to, target].pack('CNNN') }.join
    end

    def new_catch
      @catches << nil
      @catches.size - 1
    end

    def push_sp(n = 1)
      @sp += n
      @nregs = [@nregs, @sp].max
    end

    # NODE_BEGIN, NODE_RESCUE and NODE_ENSURE (codegen_begin, codegen_rescue, codegen_ensure). The value of the whole is in the
    # register the statement started at. A begin block with neither rescue nor a non-empty ensure is its statements.
    def begin_statement(node, last:)
      rescue_c = node.rescue_clause
      else_c = node.else_clause
      ensure_c = node.ensure_clause
      raise Unsupported, 'else without rescue' if else_c && !rescue_c

      stmts = node.statements&.body || []
      ensure_stmts = ensure_c&.statements&.body || []
      if !rescue_c && ensure_stmts.empty?
        raise Unsupported, 'empty begin block' if stmts.empty?

        return generate(stmts, val: last)
      end
      r = @sp
      @nregs = [@nregs, r + 1].max
      first_kw = rescue_c ? rescue_c.keyword_loc : (else_c ? else_c.else_keyword_loc : (ensure_c ? ensure_c.ensure_keyword_loc : node.end_keyword_loc))
      @line = first_kw.start_line if stmts.empty? # an empty body is a node on the line of the keyword after it
      clauses = []
      clause = rescue_c
      while clause
        # An empty clause body is a node on the line of the keyword after it.
        after = clause.subsequent ? clause.subsequent.keyword_loc : (else_c ? else_c.else_keyword_loc : (ensure_c ? ensure_c.ensure_keyword_loc : node.end_keyword_loc))
        clauses << RescueClause.new(clause.exceptions, clause.reference, clause.statements&.body || [], after.start_line)
        clause = clause.subsequent
      end
      else_stmts = else_c ? (else_c.statements&.body || []) : nil
      else_line = (ensure_c ? ensure_c.ensure_keyword_loc : node.end_keyword_loc).start_line
      if ensure_stmts.empty?
        rescue_region(r, stmts, clauses, else_stmts, else_line, last)
      else
        ensure_region(r, last, ensure_stmts) do
          clauses.empty? ? branch(stmts, r, need: last) : rescue_region(r, stmts, clauses, else_stmts, else_line, last)
        end
      end
      @sp = r
      last ? r : nil
    end

    # `expr rescue other` is a rescue of StandardError with no variable (the same NODE_RESCUE).
    def rescue_modifier_statement(node, last:)
      r = @sp
      @nregs = [@nregs, r + 1].max
      clauses = [RescueClause.new([], nil, [node.rescue_expression], node.location.end_line)]
      rescue_region(r, [node.expression], clauses, nil, nil, last)
      @sp = r
      last ? r : nil
    end

    RescueClause = Struct.new(:exceptions, :reference, :body, :empty_line)

    # codegen_ensure: the body (value in r when +val+), then EXCEPT into the register after it, the ensure clause, RAISEIF.
    # The handler covers the body and its target is the end of the body.
    def ensure_region(r, val, ensure_stmts)
      entry = new_catch
      from = @code.size
      yield
      to = @code.size
      @sp = val ? r + 1 : r
      push_sp
      idx = @sp
      emit(:EXCEPT, idx)
      push_sp
      branch(ensure_stmts, nil, need: false)
      @sp = idx
      emit(:RAISEIF, idx)
      @sp = idx - 1
      @catches[entry] = [1, from, to, to]
    end

    # codegen_rescue: the body goes to r; a JMP skips the handlers when nothing was raised. The handler starts with EXCEPT into
    # r, then each clause tests its classes with RESCUE and JMPIF (StandardError when there are none), assigns the
    # exception to its variable and runs its body; no clause matching re-raises with RAISEIF.
    def rescue_region(r, stmts, clauses, else_stmts, else_line, val)
      region = Region.new(:begin, @code.size, @loops.size)
      @labels << region.pc0
      @regions << region
      entry = new_catch
      from = @code.size
      @sp = r
      branch(stmts, r, need: true)
      region.type = :rescue
      to = @code.size
      noexc = emit_jump(:JMP)
      @catches[entry] = [0, from, to, @code.size]
      exend = []
      pos1 = nil
      @sp = r
      emit(:EXCEPT, r)
      @sp = r + 1
      clauses.each do |clause|
        dispatch(pos1)
        pos2 = []
        if clause.exceptions.empty?
          emit(:GETCONST, r + 1, sym_index(:StandardError))
          emit(:RESCUE, r, r + 1)
          pos2 << emit_jump(:JMPIF, r + 1)
        end
        clause.exceptions.each do |ex|
          ex = unparen(ex)
          if ex.is_a?(Prism::SplatNode)
            # `*list`: the list, then the exception copied after it, and list.__case_eqq(exception) tests it.
            splat = ex.expression && unparen(ex.expression)
            raise Unsupported, 'rescue with a splat of a non-operand' unless splat && operand?(splat)

            operand_into(splat, r + 1)
            gen_move(r + 2, r, false)
            @nregs = [@nregs, r + 4].max
            emit(:SEND, r + 1, sym_index(:__case_eqq), 1)
          else
            raise Unsupported, 'rescue with a non-operand class' unless operand?(ex)

            operand_into(ex, r + 1)
            emit(:RESCUE, r, r + 1)
          end
          pos2 << emit_jump(:JMPIF, r + 1)
        end
        pos1 = emit_jump(:JMP)
        pos2.each { |j| dispatch(j) }
        @sp = r
        assign_target(clause.reference, r, @sp) if clause.reference
        @line = clause.empty_line if clause.body.empty?
        branch(clause.body, r, need: val)
        exend << emit_jump(:JMP)
        @sp = r + 1
      end
      dispatch(pos1)
      emit(:RAISEIF, r)
      @sp = r
      dispatch(noexc)
      if else_stmts
        @line = else_line if else_stmts.empty?
        branch(else_stmts, r, need: val)
      end
      exend.each { |j| dispatch(j) }
      @regions.pop
    end

    # codegen_next: when the innermost loopinfo is a begin/rescue region rather than a while loop, the fork treats `next` as a
    # block's: the value (nil when there is none) is returned with RETURN (verified: a `next` in a rescue clause inside a while
    # is RETNIL, leaving the method).
    def next_in_region(node, last:)
      args = node.arguments&.arguments
      raise Unsupported, 'next with several values' if args && (args.size != 1 || !(simple?(args[0]) || call_node?(args[0])))

      t = temp
      args ? value_into(unparen(args[0]), t) : emit(:LOADNIL, t)
      return_value(t, :RETURN)
      last ? t : nil
    end

    # The statements of a def or block body: a body with rescue, else or ensure is one begin statement.
    def body_statements(body)
      case body
      when nil then []
      when Prism::StatementsNode then body.body
      when Prism::BeginNode then [body]
      else raise Unsupported, "body #{body.class.name.split('::').last}"
      end
    end

    # codegen_retry: JMPUW to the start of the innermost region whose body is done (LOOP_RESCUE).
    def retry_statement(_node, last:)
      region = @regions.reverse.find { |g| g.type == :rescue } or raise Unsupported, 'retry outside a rescue clause'
      jump = emit_jump(:JMPUW)
      patch_jump(jump, region.pc0)
      last ? temp : nil
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
