# frozen_string_literal: true

# A Ruby replacement for the fork's `mrbc -g`: Prism tree in, RITE binary out.
#
# Covered: a top-level program whose statements are nil, true, false, self, Integer literals, local reads, local writes
# of those, and method calls on simple operands (a self call or a call with an explicit receiver, with positional
# arguments of those forms, and the binary operators with their own opcodes, + and - with a literal as ADDI and SUBI),
# and if/else with a simple or call predicate and bodies of the forms above, unless, and `class X` or `module X` with a
# plain constant and a body of the forms above (no superclass; the body is a child irep run by EXEC). Milestone 10 adds
# keyword, splat and block-pass arguments, constant paths (read, write, class and module names), regexp literals, lambda
# literals and `&.`. Milestone 11 adds every operator method (folded for integer literals, SEND otherwise), unary minus,
# plus and not, Float, big Integer, Rational and Imaginary literals, operator and setter names in def, alias, undef,
# defined? (not for constants), the special variables, __FILE__ and __LINE__, and exceptions: begin/rescue/else/ensure,
# `rescue Foo, *list => e`, retry, rescue modifiers, def-level and block-level rescue bodies and the irep's catch handler
# table (see the exceptions section below). It also adds hashes with non-leaf elements (calls, nested literals, `**splat`,
# `{a:}`), %i and %I arrays, arrays with splats, index calls with several arguments and index assignment with any operands,
# assignments used as values, ranges and `__ENCODING__`. Anything else raises Unsupported, so a caller can fall back to the
# real mrbc.
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
    SETIDX: 37, INTERN: 90, SYMBOL: 91, RANGE_INC: 100, RANGE_EXC: 101, GETIDX0: 36, GETIV: 25, SETIV: 26, FSTRING: 119,
    ADD: 69, SUB: 71, MUL: 75, DIV: 76, EQ: 77, LT: 78, LE: 79, GT: 80, GE: 81,
    RETSELF: 63, RETNIL: 64, RETTRUE: 65, RETFALSE: 66, RETURN: 61, RETURN_BLK: 62, STOP: 118,
    CLASS: 103, MODULE: 104, EXEC: 105, TDEF: 107, SDEF: 108, SCLASS: 111, ENTER: 57, KEY_P: 58, KEYEND: 59, KARG: 60,
    TCLASS: 112, METHOD: 99, DEF: 106, EXT1: 115, EXT2: 116, EXT3: 117, ALIAS: 109, UNDEF: 110, GETUPVAR: 33, SETUPVAR: 34, SSENDB: 49, SENDB: 52, BLOCK: 98, GETMCNST: 31, SETMCNST: 32, OCLASS: 102, HASHADD: 95, HASHCAT: 96, LAMBDA: 97,
    GETCV: 27, SETCV: 28, MATCHERR: 46,
    EXCEPT: 43, RESCUE: 44, RAISEIF: 45,
    BREAK: 67, BLKPUSH: 68, BLKCALL: 54, SUPER: 55, ARGARY: 56
  }.freeze

  # Binary operators with their own opcode: the receiver is in the result register, the argument in the next one.
  BINARY_OPS = { :+ => :ADD, :- => :SUB, :* => :MUL, :/ => :DIV, :== => :EQ, :< => :LT, :<= => :LE, :> => :GT,
                 :>= => :GE, :[] => :GETIDX }.freeze

  # Statements that may span several lines with the start-line rules of if/unless arms, class and module bodies and def. A
  # multi-line statement of the kinds in MULTILINE_STATEMENTS follows the entered-node rule (Compiler#enter); any other
  # multi-line statement raises Unsupported.
  MULTILINE_OK = [Prism::IfNode, Prism::UnlessNode, Prism::ClassNode, Prism::ModuleNode, Prism::DefNode,
                  Prism::SingletonClassNode, Prism::WhileNode, Prism::UntilNode, Prism::CaseNode, Prism::CaseMatchNode, Prism::BeginNode, Prism::ForNode].freeze

  # Multi-line statements whose line rules are derived below (see Compiler#enter): the fork stamps each instruction with the
  # line of the classic parser node it entered last, and a node's line is the line of the last token the parser had read
  # when it built the node, which is the node's end line. Milestone 11 (multi-line statements) verified these with `mrbc -v`
  # and with a fuzzer that inserts newlines, continuations and comments into statements and compares with the oracle: the
  # exceptions are a node built after later tokens (the key of `label: value`, #label_key_line), a node that waits for the
  # token after it, which a backslash-newline or a leading dot puts on a later line (#continuation_line, #leading_dot), and
  # the nodes whose line is a keyword's (#if_node_line, the loops, #def_line, blocks and lambdas).
  MULTILINE_STATEMENTS = [Prism::LocalVariableWriteNode, Prism::ConstantWriteNode, Prism::GlobalVariableWriteNode,
                          Prism::InstanceVariableWriteNode, Prism::CallNode, Prism::StringNode, Prism::InterpolatedStringNode,
                          Prism::HashNode, Prism::ArrayNode, Prism::OrNode, Prism::AndNode, Prism::ReturnNode, Prism::BreakNode, Prism::NextNode,
                          Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
                          Prism::GlobalVariableOperatorWriteNode, Prism::ConstantOperatorWriteNode,
                          Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode, Prism::GlobalVariableOrWriteNode,
                          Prism::ConstantOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::InstanceVariableAndWriteNode,
                          Prism::GlobalVariableAndWriteNode, Prism::ConstantAndWriteNode, Prism::MultiWriteNode,
                          Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
                          Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode, Prism::LambdaNode,
                          Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode, Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode, Prism::RescueModifierNode, Prism::UndefNode, Prism::ParenthesesNode, Prism::MatchRequiredNode, Prism::MatchPredicateNode].freeze

  # Nodes whose line `enter` sets: every node the fork's codegen enters (a leaf, a call, a write, an array or a hash).
  ENTERED = [Prism::UndefNode, Prism::XStringNode, Prism::InterpolatedXStringNode, Prism::InterpolatedSymbolNode, Prism::IntegerNode, Prism::FloatNode, Prism::SourceFileNode, Prism::SourceLineNode,
             Prism::NumberedReferenceReadNode, Prism::BackReferenceReadNode, Prism::DefinedNode,
             Prism::RationalNode, Prism::ImaginaryNode, Prism::InstanceVariableReadNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
             Prism::LocalVariableReadNode, Prism::StringNode, Prism::ConstantReadNode, Prism::GlobalVariableReadNode, Prism::SelfNode,
             Prism::SymbolNode, Prism::InterpolatedStringNode, Prism::HashNode, Prism::ArrayNode, Prism::CallNode,
             Prism::LocalVariableWriteNode, Prism::ConstantWriteNode, Prism::GlobalVariableWriteNode,
             Prism::InstanceVariableWriteNode, Prism::OrNode, Prism::AndNode, Prism::ClassVariableReadNode,
             Prism::ClassVariableWriteNode, Prism::NumberedReferenceReadNode, Prism::BackReferenceReadNode,
             Prism::FloatNode, Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode, Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode, Prism::LambdaNode, Prism::ConstantPathNode, Prism::ReturnNode,
             Prism::BreakNode, Prism::NextNode, Prism::MultiWriteNode, Prism::SuperNode, Prism::ForwardingSuperNode].freeze

  # The empty heredocs the fork's parser gives the value nil (see Compiler#heredoc_parts), by node identity.
  NIL_HEREDOCS = ObjectSpace::WeakMap.new

  # Conditions the fork folds at compile time (true_always and false_always in codegen.c): no test is emitted for them.
  TRUE_ALWAYS = [Prism::IntegerNode, Prism::FloatNode, Prism::TrueNode, Prism::SourceLineNode].freeze
  FALSE_ALWAYS = [Prism::NilNode, Prism::FalseNode].freeze

  # `(expr)` with one statement is the statement itself: the fork's codegen does not see the parentheses.
  def self.unparen(node)
    while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
      node = node.body.body.first
    end
    node
  end

  # Operands that a call's receiver or argument may be: the forms value_into loads without a call of its own.
  SIMPLE_VALUES = [Prism::IntegerNode, Prism::FloatNode, Prism::SourceFileNode, Prism::SourceLineNode,
                   Prism::NumberedReferenceReadNode, Prism::BackReferenceReadNode, Prism::InstanceVariableReadNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode,
                   Prism::LocalVariableReadNode, Prism::StringNode, Prism::ConstantReadNode, Prism::GlobalVariableReadNode,
                   Prism::SymbolNode, Prism::ClassVariableReadNode, Prism::NumberedReferenceReadNode,
                   Prism::BackReferenceReadNode, Prism::FloatNode].freeze

  # Literals built in the register they are generated in (the fork's cursp): value_into builds these at the destination
  # when it is a temporary, else at the first temporary followed by a MOVE. Allowed where the destination is known.
  BUILT_VALUES = [Prism::XStringNode, Prism::InterpolatedXStringNode, Prism::InterpolatedSymbolNode, Prism::DefinedNode, Prism::RationalNode, Prism::ImaginaryNode, Prism::InterpolatedStringNode, Prism::HashNode, Prism::RegularExpressionNode,
                  Prism::InterpolatedRegularExpressionNode, Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode].freeze

  # Calls with a receiver whose method the fork's codegen treats specially (index, negation and so on): not verified here.
  UNVERIFIED_OPERATORS = [].freeze # every operator is verified (milestone 11)

  # Pool entry tags (include/mruby/irep.h).
  IREP_TT_BIGINT = 7

  RITE_LV_NULL_MARK = 0xffff

  INT32_MIN = -0x8000_0000
  INT32_MAX = 0x7fff_ffff

  # Compiles +source+ as `mrbc -g` compiles a file named +filename+. Returns the RITE binary as a binary String.
  def self.compile(source, filename)
    source = fork_source(source)
    result = Prism.parse(source, filepath: filename)
    raise Error, "parse error: #{result.errors.map(&:message).join('; ')}" unless result.errors.empty?

    # `# frozen_string_literal: true` makes string literals frozen strings (FSTRING), as the fork's parser does.
    frozen = frozen_magic_comment?(source)
    compiler = Compiler.new(filename, frozen_strings: frozen)
    return compiler.compile_empty(empty_program_line(source, result)) if result.value.statements.body.empty?

    compiler.compile(result.value)
  end

  # Source forms the fork reads differently from Prism, rewritten (without moving a line) to the form Prism reads as the fork
  # does:
  # * The fork's lexer ends a statement at a newline after `..` or `...` (an endless range): `(a..\n b)` is `(a..)` and `b`,
  #   where Prism reads the range a..b. A `;` after the operator gives Prism the fork's reading (a newline inside brackets or
  #   arguments is a syntax error for the fork, and the `;` makes it one for Prism too).
  # * `&nil` as a parameter (the fork: no block is accepted, ENTER bit 23, no local; Prism rejects it) is a block parameter
  #   named NIL_BLOCK_NAME, which `parameters` turns into that flag.
  # * `for (a, b), c in x`: the fork's grammar takes the list of targets whose first one is parenthesized, Prism reads the
  #   parentheses as the start of an expression (a syntax error). Parentheses around the whole list are the same list.
  NIL_BLOCK_NAME = '__nil_block__'

  def self.fork_source(source)
    dots = source.match?(/\.\.[ \t]*(#[^\n]*)?\r?\n/)
    fors = source.match?(/\bfor\s*\(/)
    nilblk = source.match?(/&nil\b/) && !Prism.parse(source).errors.empty?
    return source unless dots || fors || nilblk

    tokens = Prism.lex(source).value.map(&:first)
    bytes = source.b
    inserts = []
    if dots
      tokens.each do |t|
        next unless %i[DOT_DOT DOT_DOT_DOT].include?(t.type)

        e = t.location.end_offset
        inserts << [e, ';'] if bytes.byteslice(e..).match?(/\A[ \t]*(#[^\n]*)?\r?\n/n)
      end
    end
    if nilblk
      tokens.each_with_index do |t, i|
        n = tokens[i + 1]
        inserts << [n.location.start_offset, NIL_BLOCK_NAME, 3] if %i[AMPERSAND UAMPERSAND].include?(t.type) && n&.type == :KEYWORD_NIL && n.location.start_offset == t.location.end_offset
      end
    end
    if fors
      tokens.each_with_index do |t, i|
        next unless t.type == :KEYWORD_FOR && tokens[i + 1]&.type == :PARENTHESIS_LEFT

        depth = 0
        close = (i + 1...tokens.size).find do |k|
          depth += 1 if tokens[k].type == :PARENTHESIS_LEFT
          depth -= 1 if tokens[k].type == :PARENTHESIS_RIGHT
          depth.zero?
        end
        next unless close && tokens[close + 1]&.type == :COMMA

        depth = 0
        stop = (close + 1...tokens.size).find do |k|
          depth += 1 if %i[PARENTHESIS_LEFT BRACKET_LEFT BRACE_LEFT].include?(tokens[k].type)
          depth -= 1 if %i[PARENTHESIS_RIGHT BRACKET_RIGHT BRACE_RIGHT].include?(tokens[k].type)
          depth.zero? && tokens[k].type == :KEYWORD_IN
        end
        next unless stop

        inserts << [tokens[i + 1].location.start_offset, '('] << [tokens[stop - 1].location.end_offset, ')']
      end
    end
    return source if inserts.empty?

    out = bytes.dup
    inserts.sort_by { |o, _| -o }.each { |o, text, drop| out[o, drop || 0] = text }
    out.force_encoding(source.encoding)
  end

  # One file of a multi-file program: its name and its top-level statements.
  Unit = Struct.new(:filename, :stmts)

  NON_TOKENS = %i[COMMENT NEWLINE IGNORED_NEWLINE EOF EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END].freeze

  # Compiles +files+ ([[source, filename], ...]) as `mrbc -g` compiles them given on one command line: one program (mrbc.c
  # reads them with mrb_parse_file_continue), so the top-level locals and registers are shared, a file's code is recorded
  # under its own name in the debug section, and the statements are stamped with the file's own line numbers. Rules (checked
  # against `mrbc -g -v`):
  # * The frozen_string_literal comment counts only in the comments before the first token of the whole program, and its
  #   state holds for every file (the parser's flag is read by codegen at the end).
  # * A file ends where the lexer reads the newline after its last token: it reaches the end of the file, the parser switches
  #   to the next file (line 0) and the nodes reduced with that lookahead (a node that is not complete in its last token:
  #   a variable, a string, a call without parentheses, an assignment, an operator ...) have line 0 and the previous file's
  #   index. Line 0 takes the line of the previous byte of code. The next file starts at line 1 plus the comment lines that
  #   directly follow that last statement (they are counted into the same newline token). Unless a blank line follows the
  #   last statement, which ends the lookahead before the file ends.
  # * Codegen switches the file at the first node of the next file: the debug section gets one record per file, the ranges
  #   being the pcs between the switches.
  def self.compile_files(files)
    raise Unsupported, 'no files' if files.empty?

    # `__END__` ends the whole program (the lexer returns the end of the input there): the files after it are never read,
    # not even entered in the filename table, and its own file is the last one.
    stop = files.index { |source, _| source.match?(/^__END__(\r?\n|\z)/) && Prism.parse(source).data_loc }
    files = files[0..stop] if stop
    return compile(*files.first) if files.size == 1

    locals = []
    frozen = false
    token_seen = false
    offset = 0
    units = []
    zero = {}.compare_by_identity
    names = files.map(&:last).uniq
    files.each_with_index do |(source, filename), i|
      raise Unsupported, 'endless range at the end of a file' if i < files.size - 1 && source.match?(/\.\.\.?(?:[ \t\r\n]|#[^\n]*)*\z/)

      source = fork_source(source)
      result = Prism.parse(source, filepath: filename, scopes: [locals.dup], line: 1 + offset)
      raise Error, "parse error: #{result.errors.map(&:message).join('; ')}" unless result.errors.empty?

      stmts = result.value.statements.body
      locals |= result.value.locals
      unless token_seen
        frozen = frozen_magic_comment?(source, frozen)
        token_seen = tokens?(source)
      end
      units << Unit.new(filename, stmts)
      offset = 0
      next if i == files.size - 1

      quirk, offset, word_end = file_tail(source)
      raise Unsupported, 'a file without a newline at the end followed by a leading dot' if !source.end_with?("\n") && joins_previous?(files[i + 1].first)
      # init_var_header: a node built while the parser is at line 0 of the next file (index n) has the index n - 1, or 0
      # (a file named like an earlier one has that one's index).
      tail_zero_nodes(stmts.last, zero, names[[names.index(files[i + 1].last) - 1, 0].max], word_end) if quirk && !stmts.empty?
    end
    raise Unsupported, 'no statements' if units.all? { |u| u.stmts.empty? }

    units.reject! { |u| u.stmts.empty? } # a file without code never switches the file
    Compiler.new(units.first.filename, frozen_strings: frozen).compile_units(units, locals, zero)
  end

  def self.tokens?(source) = Prism.lex(source).value.any? { |t, _| !NON_TOKENS.include?(t.type) }

  # How the lexer leaves +source+ (not the last file): [whether the newline lookahead after its last token reaches the end of
  # the file, the number of lines the next file's numbering is ahead].
  def self.file_tail(source)
    # (heredoc bodies are lexed before the rest of their line: the last token is the one that ends last)
    last = Prism.lex(source).value.map(&:first).reject { |t| NON_TOKENS.include?(t.type) }.each_with_index.max_by { |t, i| [t.location.end_offset, i] }&.first
    return [false, 0] unless last
    raise Unsupported, 'file ending in a heredoc' if last.type == :HEREDOC_START
    heredoc = last.type == :HEREDOC_END
    return [false, 0] if last.type == :SEMICOLON # the state after `;` is the start of an expression: newlines are skipped

    tail = source.b.byteslice(last.location.end_offset..)
    # The heredoc's terminator line ends the token, newline included; the nodes of its statement were built on the line of
    # the `<<`, long before the end of the file: nothing is built at line 0 there.
    tail = "\n".b + tail if heredoc && last.location.slice.end_with?("\n")
    first_line, rest = tail.split("\n".b, 2)
    raise Unsupported, 'text after the last token' unless first_line.to_s.match?(/\A[ \t\f\v\r]*(#.*)?\z/n)

    # The end of the file is read as a newline (nextc returns -2), whether or not there is one, and the file switch happens
    # there. Without a newline a word-like last token (a name, a number, a keyword: its end is known only after the next
    # character) reads the end of the file while it is scanned, so every node completed from it on, its own leaf included,
    # is built at line 0 (+word_end+ is where that token ends). The lookahead after the newline then goes on into the next
    # file (see #joins_previous?).
    word_end = tail.empty? && WORD_TOKENS.include?(last.type) ? last.location.end_offset : nil
    raise Unsupported, 'operator token at the very end of a file' if tail.empty? && !word_end && !CLOSING_TOKENS.include?(last.type)
    lines = rest.to_s.split("\n".b, -1)
    comments = 0
    lines.each_with_index do |l, i|
      if l.match?(/\A[ \t\f\v\r]*#/n) then comments += 1
      elsif l.match?(/\A[ \t\f\v\r]*\z/n) then return i == lines.size - 1 ? [!heredoc, heredoc ? 0 : comments, word_end] : [false, 0, nil]
      else raise Unsupported, 'text after the last statement'
      end
    end
    [!heredoc, heredoc ? 0 : comments, word_end] # the comment lines after a heredoc are not counted into the next file's lines (verified)
  end

  # Tokens that end where they are read (no character after them is needed).
  CLOSING_TOKENS = %i[PARENTHESIS_RIGHT BRACKET_RIGHT BRACE_RIGHT STRING_END LABEL_END SYMBOL_END].freeze

  # Tokens whose scan reads the character after them.
  WORD_TOKENS = %i[IDENTIFIER CONSTANT INTEGER FLOAT INTEGER_IMAGINARY INTEGER_RATIONAL INTEGER_RATIONAL_IMAGINARY FLOAT_IMAGINARY
                   FLOAT_RATIONAL FLOAT_RATIONAL_IMAGINARY INSTANCE_VARIABLE CLASS_VARIABLE GLOBAL_VARIABLE BACK_REFERENCE
                   NUMBERED_REFERENCE METHOD_NAME KEYWORD_END KEYWORD_NIL KEYWORD_TRUE KEYWORD_FALSE KEYWORD_SELF
                   KEYWORD___FILE__ KEYWORD___LINE__ KEYWORD___ENCODING__ KEYWORD_REDO KEYWORD_RETRY KEYWORD_RETURN
                   KEYWORD_BREAK KEYWORD_NEXT KEYWORD_SUPER KEYWORD_YIELD KEYWORD_DEFINED KEYWORD_THEN KEYWORD_DO
                   REGEXP_END KEYWORD_ENSURE KEYWORD_ELSE KEYWORD_BEGIN KEYWORD_ALIAS KEYWORD_UNDEF].freeze

  # Whether the lookahead after a file ends without a newline goes on into +source+, the next file, and joins it to the file
  # before: a leading `.` or `&.` (after blank-free whitespace and comment lines) continues the last statement.
  def self.joins_previous?(source)
    source.b.match?(/\A(?:[ \t\f\v\r]*#[^\n]*\n)*[ \t\f\v\r]*(?:\.(?!\.)|&\.)/n)
  end

  # Marks in +acc+ the nodes the fork's parser builds after reading the newline that follows the last token of +stmt+: those
  # that need that lookahead to be reduced. The tail of the statement is followed down: a node whose last token is the
  # statement's last one. Forms not probed are Unsupported.
  def self.tail_zero_nodes(stmt, acc, name, word_end = nil)
    node = stmt
    loop do
      acc[node] = name if word_end && node.location.end_offset == word_end
      if word_end && node.location.end_offset == word_end
        # Nodes the fork builds at the `end` keyword (the jump back of a loop, the empty clauses of a case or a rescue, the body
        # of a block) are built at line 0 too: verified only for the forms below.
        ended = (node.respond_to?(:end_keyword_loc) && node.end_keyword_loc&.end_offset == word_end) ||
                (node.respond_to?(:closing_loc) && node.closing_loc&.slice == 'end') ||
                (node.respond_to?(:block) && node.block.respond_to?(:closing_loc) && node.block.closing_loc&.slice == 'end')
        ok = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::ForNode, Prism::SingletonClassNode].any? { |k| node.is_a?(k) } ||
             ((node.is_a?(Prism::IfNode) && !node.subsequent.is_a?(Prism::IfNode)) || node.is_a?(Prism::UnlessNode))
        raise Unsupported, 'end keyword at the very end of a file' if ended && !ok
      end
      case node
      when Prism::IntegerNode, Prism::FloatNode, Prism::SourceLineNode, Prism::SourceFileNode
        acc[node] = name if node.location.slice.start_with?('-') # a negative literal is built after the lookahead (tUMINUS_NUM)

        return
      when Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode, Prism::InstanceVariableReadNode,
           Prism::GlobalVariableReadNode, Prism::ClassVariableReadNode, Prism::LambdaNode, Prism::DefNode,
           Prism::ClassNode, Prism::ModuleNode, Prism::AliasMethodNode, Prism::SingletonClassNode
        # An endless def on one line: every instruction of its body is on the def's line, built at line 0 (previous byte) or not.
        raise Unsupported, 'multi-line endless def at the end of a file' if node.is_a?(Prism::DefNode) && node.equal_loc && node.location.start_line != node.location.end_line

        return
      when Prism::SymbolNode
        raise Unsupported, 'symbol form at the end of a file' unless node.opening_loc.nil? || [':', ':"', ":'"].include?(node.opening_loc.slice)

        return
      when Prism::ArrayNode
        return if node.opening_loc # `[...]` and `%w[...]` end in their closing bracket

        # An array without brackets (`x = 1, *a`, `x = *a`) is built after the lookahead, like its last element.
        acc[node] = name
        node = node.elements.last
        node = node.expression if node.is_a?(Prism::SplatNode)
        return unless node
      when Prism::HashNode, Prism::RegularExpressionNode, Prism::MatchLastLineNode, Prism::ParenthesesNode,
           Prism::RationalNode, Prism::ImaginaryNode
        return
      when Prism::InterpolatedStringNode
        raise Unsupported, 'heredoc at the end of a file' if node.opening_loc&.slice&.start_with?('<<')

        acc[node] = name # a string waits for the token after it (adjacent literals are one string)
        return
      when Prism::InterpolatedSymbolNode, Prism::InterpolatedRegularExpressionNode, Prism::XStringNode, Prism::InterpolatedXStringNode
        return
      when Prism::UndefNode
        acc[node] = name
        return
      when Prism::RangeNode, Prism::FlipFlopNode
        raise Unsupported, 'endless range at the end of a file' unless node.right

        acc[node] = name
        node = node.right
      when Prism::DefinedNode
        acc[node] = name unless node.rparen_loc # `defined? x` waits for the token after it
        return
      when Prism::BeginNode, Prism::WhileNode, Prism::UntilNode, Prism::CaseNode, Prism::ForNode
        raise Unsupported, 'modifier form at the end of a file' if (node.is_a?(Prism::WhileNode) || node.is_a?(Prism::UntilNode)) && node.closing_loc.nil?
        raise Unsupported, 'begin form at the end of a file' if node.is_a?(Prism::BeginNode) && node.end_keyword_loc.nil?

        return
      when Prism::IfNode, Prism::UnlessNode
        if node.is_a?(Prism::IfNode) && node.if_keyword_loc.nil? # a ternary
          acc[node] = name
          node = node.subsequent
        elsif node.end_keyword_loc
          return
        else # a modifier: the node and its predicate, the last token
          acc[node] = name
          node = node.predicate
        end
      when Prism::ElseNode # the else branch of a ternary
        node = node.statements.body.last
      when Prism::LocalVariableReadNode, Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::StringNode
        raise Unsupported, 'heredoc at the end of a file' if node.is_a?(Prism::StringNode) && node.opening_loc&.slice&.start_with?('<<')

        acc[node] = name
        return
      when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::GlobalVariableWriteNode,
           Prism::ClassVariableWriteNode, Prism::ConstantWriteNode, Prism::LocalVariableOperatorWriteNode,
           Prism::InstanceVariableOperatorWriteNode, Prism::GlobalVariableOperatorWriteNode,
           Prism::ConstantOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode,
           Prism::GlobalVariableOrWriteNode, Prism::ConstantOrWriteNode, Prism::LocalVariableAndWriteNode,
           Prism::InstanceVariableAndWriteNode, Prism::GlobalVariableAndWriteNode, Prism::ConstantAndWriteNode
        acc[node] = name
        node = node.value
      when Prism::AndNode, Prism::OrNode
        acc[node] = name
        node = node.right
      when Prism::ReturnNode
        acc[node] = name
        args = node.arguments&.arguments
        return if args.nil?

        node = args.last # several values make an array built after the last one: only the last matters
        if node.is_a?(Prism::SplatNode)
          node = node.expression
          return unless node
        end
      when Prism::MultiWriteNode
        acc[node] = name
        node = node.value
      when Prism::CallNode, Prism::SuperNode, Prism::ForwardingSuperNode
        close = node.respond_to?(:closing_loc) ? node.closing_loc : (node.respond_to?(:rparen_loc) ? node.rparen_loc : nil)
        return if node.block.is_a?(Prism::BlockNode) || close&.slice == ')'

        acc[node] = name
        args = node.respond_to?(:arguments) ? node.arguments&.arguments : nil
        if node.block # `&blk`: the last argument, built after the lookahead
          node = node.block.expression
          return unless node
        elsif args && !args.empty?
          node = args.last
          case node
          when Prism::SplatNode
            node = node.expression
            return unless node
          when Prism::KeywordHashNode
            acc[node] = name
            last = node.elements.last
            acc[last.key] = name if last.is_a?(Prism::AssocNode) && last.operator_loc.nil? # `a: v`: the key is built after the value
            node = last.value
            return unless node
          end
        elsif node.respond_to?(:receiver) && node.receiver && %i[! -@ +@ ~].include?(node.name) && node.message_loc && node.message_loc.start_offset < node.receiver.location.start_offset
          node = node.receiver
        else
          return
        end
      else
        raise Unsupported, "#{node.class} at the end of a file"
      end
    end
  end

  # The fork's frozen_string_literal magic comment (frozen_magic_comment in parse.y): every comment line before the first token
  # is searched, the key matching without regard to case and with `-` for `_`, then optional blanks, `:`, blanks and `true` or
  # `false` (any case, not followed by a word character); the last comment that has the key decides. Only the first 255 bytes of
  # a comment line count. `=begin` blocks are skipped.
  def self.frozen_magic_comment?(source, frozen = false)
    text = source.b
    pos = 0
    key = 'frozen_string_literal'.b
    while pos < text.bytesize
      pos += Regexp.last_match(0).bytesize if text.byteslice(pos..).match(/\A[ \t\f\r\v\n]+/n)
      rest = text.byteslice(pos..)
      if rest.start_with?('#')
        line = rest.byteslice(1..).split("\n", 2).first.to_s.byteslice(0, 255)
        pos += 1 + (rest.byteslice(1..).index("\n") || rest.bytesize)
        norm = line.downcase.tr('-', '_')
        if (m = norm.match(/#{key}[ \t]*:[ \t]*/n))
          value = m.post_match
          if value.match?(/\Atrue(?![a-z0-9_])/n) then frozen = true
          elsif value.match?(/\Afalse(?![a-z0-9_])/n) then frozen = false
          end
        end
      elsif (pos.zero? || text.getbyte(pos - 1) == 10) && rest.start_with?('=begin')
        endpos = text.index(/^=end/n, pos) or break
        pos = text.index("\n", endpos) || text.bytesize
      else break
      end
    end
    frozen
  end

  # The line the fork stamps on the code of a program without statements (milestone 13): the line the lexer ended on, which
  # is one plus the newlines before `__END__` (or the end of the file), and one more when a comment runs into the end of the
  # file without its newline.
  def self.empty_program_line(source, result)
    # A program of semicolons only is stamped with the line of the first one (verified with mrbc -v).
    semicolon = Prism.lex(source).value.map(&:first).find { |t| t.type == :SEMICOLON }
    return semicolon.location.start_line if semicolon

    text = source.b
    text = text.byteslice(0, result.data_loc.start_offset) if result.data_loc
    line = 1 + text.count("\n")
    line += 1 if text.split("\n", -1).last.to_s.match?(/\A([ \t]*#|=end)/n)
    line
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
      @line_override = {}.compare_by_identity # node => the line the fork stamps it with when that is not its end line
    end

    def compile(program)
      stmts = program.statements.body
      set_locals(program.locals)
      value_reg = generate(stmts, val: true)
      return_value(value_reg)
      emit(:STOP)
      write_rite
    end

    # The top-level program of several files compiled as one (MrbcRb.compile_files): +units+ are the files in order, each
    # with its statements; +zero_nodes+ are the nodes the fork stamps with line 0.
    def compile_units(units, locals, zero_nodes)
      @unit_starts = {}.compare_by_identity
      units.each { |u| @unit_starts[u.stmts.first] = u unless u.stmts.empty? }
      @zero_nodes = zero_nodes
      @segments = []
      @segment_start = 0
      @segment_name = units.first.filename
      @filename = @segment_name
      set_locals(locals)
      value_reg = generate(units.flat_map(&:stmts), val: true)
      return_value(value_reg)
      emit(:STOP)
      close_segment
      write_rite
    end

    # codegen() noticing a node of another file: the code so far belongs to the file before (mrb_debug_info_append_file
    # skips an empty range and a file named like the previous one).
    def switch_file(unit)
      @unit_name = unit.filename
      switch_to(unit.filename)
    end

    def switch_to(name)
      return if name == @segment_name

      close_segment
      @segment_start = @code.size
      @segment_name = name
      @filename = name
    end

    def close_segment
      return if @segment_start == @code.size
      return if @segments.last && @segments.last[0] == @segment_name

      # mrb_debug_info_append_file copies the lines of its range when it is called: a later rewrite of that code (a folded
      # load) is not seen by the record.
      @segments << [@segment_name, @segment_start, @code.size, @lines[@segment_start...@code.size]]
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

    # A method body (scope_body for def, lambda_body in codegen.c): the parameters are laid out and entered by #parameters (every
    # kind is covered: optional, rest, post-required, keywords, `**rest`, `&block`, `...`, anonymous `*` `**` `&` and
    # destructuring), then the body follows.
    def compile_method(node)
      params = node.parameters
      @in_method = true
      @enter_label = !(params.nil? && node.equal_loc && node.lparen_loc.nil?) # the fork marks a label after ENTER of a method (see merge_strings)
      if params.nil? && node.equal_loc && node.lparen_loc.nil?
        # `def f = expr` has no hidden block slot (verified with mrbc -v: nlocals is 1, unlike `def f() = expr`).
        raise Unsupported, 'endless def without parameters but with locals' unless node.locals.empty?

        set_locals([])
        @nregs = @nlocals + 1
        @line = def_line(node)
        emit(:ENTER, 0)
      else
        parameters(params, node.locals, def_line(node))
      end
      stmts = body_statements(node.body)
      if node.body.is_a?(Prism::BeginNode) && node.body.statements.nil?
        check_empty_gap(node.rparen_loc || params&.location || node.name_loc, first_keyword(node.body))
      end
      value_reg = if stmts.empty?
                    t = temp
                    empty_body_continuation!(node, node.rparen_loc || params&.location || node.name_loc)
                    check_empty_gap(node.rparen_loc || params&.location || node.name_loc, node.body ? node.body.location : node.end_keyword_loc)
                    @line = @zero_end ? 0 : node.end_keyword_loc.start_line # the implicit nil is on the `end` line (verified)
                    emit(:LOADNIL, t)
                    t
                  else
                    generate(stmts, val: true)
                  end
      return_value(value_reg)
      self
    end

    # A literal block's body (lambda_body in codegen.c): laid out and entered as a method body is (#parameters, which also takes
    # numbered parameters and the block-local variables); the variables of the enclosing scopes are upvalues (GETUPVAR and
    # SETUPVAR). +parent+ is the Compiler of the enclosing scope.
    def compile_block(node, parent)
      @parent = parent
      @loops = [BLOCK_LOOP] # the LOOP_BLOCK entry of lambda_body: break, next and return inside a block are its forms
      params = node.parameters
      numbered = 0
      case params
      when nil then nil
      when Prism::BlockParametersNode then params = params.parameters
      when Prism::NumberedParametersNode then numbered = params.maximum; params = nil
      when Prism::ItParametersNode then params = nil # `it` is a plain method call to the fork's parser
      else raise Unsupported, 'block parameters'
      end
      @enter_label = (!node.parameters.nil? && !(node.parameters.is_a?(Prism::BlockParametersNode) && node.parameters.parameters.nil? && node.parameters.locals.empty?)) || node.is_a?(Prism::LambdaNode) # a block without a parameter list has no argument node
      parameters(params, node.locals, node.is_a?(Prism::LambdaNode) ? parent.send(:current_line) : node.opening_loc.start_line, numbered: numbered)
      stmts = body_statements(node.body)
      if node.body.is_a?(Prism::BeginNode) && node.body.statements.nil?
        check_empty_gap(node.parameters ? node.parameters.location : node.opening_loc, first_keyword(node.body))
      end
      value_reg = if stmts.empty?
                    t = temp
                    empty_body_continuation!(node, node.parameters ? node.parameters.location : node.opening_loc)
                    check_empty_gap(node.parameters ? node.parameters.location : node.opening_loc, node.body ? node.body.location : node.closing_loc)
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

    # Keywords (lambda_body, in source order): a required one is KARG into its register; an optional one is KEY_P, a JMPIF over
    # its default (the default is assigned like an optional parameter's, then a JMP past the KARG), then the KARG. Without
    # a `**rest` that takes the leftovers, KEYEND follows, then the hash of the keywords is rebuilt into the "**" slot
    # (register +dict+, the one after the positional parameters) starting at the first temporary.
    def method_keywords(keywords, dict, kwrest)
      keywords.each do |k|
        reg = local_register(k.name)
        if k.is_a?(Prism::OptionalKeywordParameterNode)
          emit(:KEY_P, reg, sym_index(k.name))
          to_key = emit_jump(:JMPIF, reg)
          @line = k.value.location.start_line
          write_local(k, last: false)
          to_end = emit_jump(:JMP)
          dispatch(to_key)
          emit(:KARG, reg, sym_index(k.name))
          dispatch(to_end)
        else
          emit(:KARG, reg, sym_index(k.name))
        end
      end
      return if kwrest

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
      recv = node.receiver && unparen(node.receiver)
      # `self.+(b) { }`: noself needs opt_op == OP_NOP, so an operator name loads self like any receiver (the block
      # disables the operator opcodes, but the receiver test happens first).
      recv = nil if recv.is_a?(Prism::SelfNode) && !OPT_OP_NAMES.include?(node.name)
      raise Unsupported, 'safe navigation without a receiver' if node.safe_navigation? && recv.nil? && !self_receiver?(node)
      args = (node.arguments&.arguments || []).map { |a| unparen(a) }
      raise Unsupported, 'call with a block and a non-operand argument' unless args.all? { |x| operand?(x) || x.is_a?(Prism::KeywordHashNode) || x.is_a?(Prism::SplatNode) }
      raise Unsupported, 'call with a block and a non-simple receiver' if recv && !operand?(recv)

      line = blk.opening_loc.start_line
      # The call node was built before its block: its line is that of the end of its receiver, name and arguments.
      @line = [node.message_loc, node.closing_loc, node.arguments&.location, recv&.location].compact.map(&:end_line).max unless @hold_line
      a = @sp
      @nregs = [@nregs, a + 1].max
      operand_into(recv, a) if recv
      skip = safe_jump(a, need) if node.safe_navigation?
      argc, = gen_args(nil, a, args)
      sp = @sp
      # The block node is stamped with the line of its opening `{` or `do` (the parser records the line right after that
      # token), and it is entered after the receiver and the arguments: BLOCK and SENDB carry that line.
      @line = line
      @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_block(blk, self)
      index = @children.size - 1
      
      emit(:BLOCK, sp, index)
      emit_send(a, recv, node.name, argc, true)
      dispatch(skip)
      @nregs = [@nregs, sp + 1].max
      a
    ensure
      @sp = a if a
    end

    def current_line = @line

    # The line of a def: its name's line, which is the line of `def` as long as the header's words (`def`, the receiver and
    # its dot, the name) share it. Verified with mrbc -v: a break inside the header moves the lines of the def's code and of
    # its ENTER in ways that depend on the token after the name (a parenthesis after a continuation counts, an `=` does not),
    # so those headers are Unsupported.
    def def_line(node)
      lines = [node.def_keyword_loc, node.receiver&.location, node.operator_loc, node.name_loc].compact.map(&:start_line)
      raise Unsupported, 'def header spanning lines' if continuation_count(node.name_loc).positive?
      return lines.first if lines.uniq.size == 1

      # A header broken before the name: the def node is stamped by the last token read when it is reduced, the name (and the
      # token after it, on its line).
      raise Unsupported, 'def header spanning lines' if node.equal_loc || node.receiver # a receiver's header is not verified

      node.name_loc.start_line
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
      recv = unparen(recv.body) if recv.is_a?(Prism::ParenthesesNode) && recv.body && !recv.body.is_a?(Prism::StatementsNode) # `def (expr).m`
      raise Unsupported, 'receiver def on a non-operand receiver' if recv && !simple?(recv) && !operand?(recv)
      raise Unsupported, 'def with a name that is not verified' unless def_name_ok?(node.name)

      # codegen_sdef: the name's symbol comes first, then the method's irep, then the receiver, loaded into the result
      # register, which SDEF takes. A plain def is TDEF on the same register.
      sym = sym_index(node.name)
      child = Compiler.new(@filename, frozen_strings: @frozen_strings)
      child.instance_variable_set(:@zero_end, @zero_nodes&.key?(node)) # the `end` was scanned across the end of the file
      @children << child.compile_method(node)
      index = @children.size - 1

      nregs = @nregs
      @line = def_line(node)
      t = temp
      if index > 0xff # milestone 13: no TDEF/SDEF fusion past 255 child ireps (codegen_def)
        value_into(recv, t) if recv
        emit(recv ? :SCLASS : :TCLASS, t)
        emit(:METHOD, t + 1, index)
        emit(:DEF, t, sym)
      elsif recv
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
      enter(node)

      args = node.arguments&.arguments
      raise Unsupported, 'return with an unverified value' if args && args.size == 1 && !(simple?(args[0]) || call_node?(args[0]) || args[0].is_a?(Prism::SplatNode) || operand?(args[0]) || args[0].is_a?(Prism::BeginNode))

      t = temp
      args ? return_values_into(args, t) : emit(:LOADNIL, t)
      return_value(t, @loops.empty? && @regions.empty? ? :RETURN : :RETURN_BLK) # a return inside a loop or a rescue region is the in-block form
      last ? t : nil
    end

    # Generates the statements of a body. The last one is generated as a value when +val+ is set; its register is returned.
    def generate(stmts, val:)
      value_reg = nil
      stmts.each_with_index do |node, i|
        switch_file(@unit_starts[node]) if @unit_starts&.key?(node)
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
      return true if (node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode)) && node.block.is_a?(Prism::BlockNode)

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
      # A node built after the file switch carries an earlier file index (init_var_header); every other node its own file's.
      # The fork's codegen checks the index of every node it generates, not only of the entered ones.
      if @zero_nodes
        switch_to(@zero_nodes.key?(node) ? @zero_nodes[node] : @unit_name)
        # An operator write reads its variable (a node of its own file) before it generates anything.
        switch_to(@unit_name) if @zero_nodes.key?(node) && node.class.name.end_with?('OperatorWriteNode', 'OrWriteNode', 'AndWriteNode')
      end
      return unless ENTERED.include?(node.class)
      return if node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) # a call with a block has its own rules (call_with_block)
      return if @hold_line

      @line = line_of(node)
      @line = 0 if @zero_nodes&.key?(node)
    end

    # Receivers (and the calls they belong to) that are reduced only once the next token is read: that token is the `.` of a
    # leading-dot continuation, on a later line.
    def line_of(node)
      @line_override.fetch(node) { @leading_dot.fetch(node) { super_head_line(node) || continuation_line(node) } }
    end

    # A super with a literal block is built before its block: its line is that of its keyword, parenthesis or arguments.
    def super_head_line(node)
      return unless (node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode)) && node.block.is_a?(Prism::BlockNode)

      return node.location.start_line if node.is_a?(Prism::ForwardingSuperNode) # a bare `super` is one token

      [node.keyword_loc, node.rparen_loc, node.arguments&.location].compact.map(&:end_line).max
    end

    # A backslash-newline after a node's last token: the lexer skips it as white space (counting the line) when the parser asks
    # for the token after the node. A node the parser can reduce without that token keeps its own end line; one that needs it
    # (a variable, constant or string, a call without a closing parenthesis, an operator, a logic operator, an assignment, a
    # conditional) is built with the line of the token that follows the continuation. Any other node is Unsupported.
    # The number of backslash-newlines right after +loc+ (a Prism::Location).
    def continuation_count(loc)
      m = /\A[ \t]*((?:\\\r?\n[ \t]*)+)/n.match(loc.send(:source).source.byteslice(loc.end_offset, 400).b)
      m ? m[1].count("\n") : 0
    end

    def continuation_line(node)
      line = node.location.end_line
      m = continuation_count(node.location)
      return line if m.zero?

      case node
      when Prism::IntegerNode, Prism::FloatNode
        # A negative literal is built from the minus sign and the number, which needs the token after it.
        node.location.slice.start_with?('-') ? line + m : line
      when Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode, Prism::SymbolNode,
           Prism::InstanceVariableReadNode, Prism::GlobalVariableReadNode, Prism::ArrayNode, Prism::HashNode
        line
      when Prism::CallNode
        raise Unsupported, 'line continuation after a call with a block' if node.block.is_a?(Prism::BlockNode)

        node.closing_loc&.slice == ')' ? line : line + m
      when Prism::LocalVariableReadNode, Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::StringNode,
           Prism::InterpolatedStringNode, Prism::OrNode, Prism::AndNode, Prism::LocalVariableWriteNode, Prism::ReturnNode,
           Prism::BreakNode, Prism::NextNode, Prism::MultiWriteNode,
           Prism::ConstantWriteNode, Prism::GlobalVariableWriteNode, Prism::InstanceVariableWriteNode
        raise Unsupported, 'line continuation after a heredoc' if heredoc_string?(node)

        line + m
      else raise Unsupported, 'line continuation after a node of this kind'
      end
    end

    # The key of `label: value` is a symbol node the fork's parser builds in the action of the whole pair (`assoc: tLABEL
    # arg_value`), after the value: it takes the line the parser is on after the value (verified with mrbc -v: the line of
    # the value's end, so a multi-line value gives the key that later line). `:k => v` and `"k" => v` keys are built before.
    def label_key_line(assoc)
      key = assoc.key
      return unless key.is_a?(Prism::SymbolNode) && key.closing_loc&.slice&.end_with?(':') # `a:`, `"a":`, `'a':`

      value = assoc.value # parentheses included: its end is the closing parenthesis
      # The parser reads the token after the value before it builds the pair, so a continuation counts whatever the value is.
      @line_override[key] = @leading_dot.fetch(value) { value.location.end_line } + continuation_count(value.location)
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
      when Prism::IntegerNode, Prism::FloatNode
        # A negative literal needs the token after it to be built (see #continuation_line).
        @leading_dot[recv] = op.start_line if recv.location.slice.start_with?('-')
      when Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode, Prism::SymbolNode,
           Prism::InstanceVariableReadNode, Prism::GlobalVariableReadNode, Prism::ArrayNode, Prism::HashNode,
           Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode, Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode # built at the closing delimiter, like `)`
        nil
      when Prism::LocalVariableReadNode, Prism::ConstantReadNode, Prism::StringNode
        @leading_dot[recv] = op.start_line
      when Prism::CallNode
        # A call with a block ends in its `}` or `end`: it is built without the next token, like one ending in `)`.
        @leading_dot[recv] = op.start_line unless recv.closing_loc&.slice == ')' || recv.block.is_a?(Prism::BlockNode)
      when Prism::ParenthesesNode
        # Ends in its closing parenthesis: built without the next token. Several lines inside would move the inner nodes.
        nil
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
          nil
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
      end
      enter(node) # the fork enters every node, also one whose value is unused
      case node
      when Prism::LocalVariableWriteNode
        write_local(node, last: last)
      when Prism::ItLocalVariableReadNode
        call(it_call(node), need: last) # `it` is a method call to the fork's parser
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
           Prism::StringNode, Prism::GlobalVariableReadNode, Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode
        last ? value_in_register(node) : nil
      when Prism::FloatNode
        # An unused float still enters the literal pool (new_lit_float runs before gen_load_op2 looks at val); a negative
        # literal is a negation of a literal to the fork, which generates nothing for an unused one.
        float_index(node) unless last || node.location.slice.start_with?('-')
        last ? value_in_register(node) : nil
      when Prism::NumberedReferenceReadNode, Prism::BackReferenceReadNode
        # An unused `$1` or `$&` still enters the symbol table (verified: the symbol count differs, unlike `$~` or `$stdout`).
        sym_index(node.is_a?(Prism::BackReferenceReadNode) ? node.name : :"$#{node.number}") unless last
        last ? value_in_register(node) : nil
      when Prism::ClassVariableWriteNode
        cvar_write(node, last: last)
      when Prism::ArrayNode
        # An unused array generates nothing, not even its elements (codegen_array returns early without a value; verified).
        last ? value_in_register(node) : nil
      when Prism::LambdaNode
        # An unused lambda generates nothing at all, not even its body (codegen_lambda returns early without a value).
        last ? value_in_register(node) : nil
      when Prism::RationalNode, Prism::ImaginaryNode
        t = temp
        numeric_call_at(node, t)
        last ? t : nil
      when Prism::DefinedNode
        # `defined?` never evaluates its argument: nothing is generated when its value is unused.
        last ? value_in_register(node) : nil
      when Prism::SourceFileNode, Prism::SourceLineNode
        last ? value_in_register(node) : nil
      when Prism::SourceEncodingNode
        last ? value_in_register(node) : (source_into(node, temp); nil) # still a call when unused
      when *SPECIAL_READS
        # codegen_nth_ref and codegen_back_ref number the symbol even when the value is unused.
        sym_index(special_variable_name(node))
        last ? value_in_register(node) : nil
      when Prism::AliasMethodNode
        alias_statement(node, last: last)
      when Prism::UndefNode
        undef_statement(node, last: last)
      when Prism::SymbolNode
        # An unused symbol still enters the symbol table (sym_idx runs before gen_load_op2 checks val).
        sym_index(node.unescaped.to_sym)
        last ? value_in_register(node) : nil
      when *BUILT_VALUES
        # Unused hashes generate nothing (codegen_hash returns early); an unused string evaluates its expressions only.
        if last
          value_in_register(node)
        else
          string_unused(node) if node.is_a?(Prism::InterpolatedStringNode)
          regex_unused(node) if node.is_a?(Prism::InterpolatedRegularExpressionNode) || node.is_a?(Prism::InterpolatedMatchLastLineNode)
          small_unused(node)
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
      when Prism::ParenthesesNode
        parentheses_statement(node, last: last)
      when Prism::RescueModifierNode
        rescue_modifier_statement(node, last: last)
      when Prism::RetryNode
        retry_statement(node, last: last)
      when Prism::OrNode, Prism::AndNode
        logic(node, need: last)
      when Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
           Prism::GlobalVariableOperatorWriteNode, Prism::ConstantOperatorWriteNode, Prism::ClassVariableOperatorWriteNode
        operator_write(node, last: last)
      when Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode, Prism::GlobalVariableOrWriteNode,
           Prism::ConstantOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::InstanceVariableAndWriteNode,
           Prism::GlobalVariableAndWriteNode, Prism::ConstantAndWriteNode, Prism::ClassVariableAndWriteNode,
           Prism::ClassVariableOrWriteNode
        logic_write(node, last: last)
      when Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
           Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode
        call_write(node, last: last)
      when Prism::MultiWriteNode
        node.value.is_a?(Prism::RescueModifierNode) && !@masgn_plain.equal?(node) ? masgn_rescue(node, last: last) : multiple_write(node, last: last)
      when Prism::IfNode
        if_statement(node, last: last)
      when Prism::CaseNode
        case_statement(node, last: last)
      when Prism::MatchRequiredNode, Prism::MatchPredicateNode, Prism::CaseMatchNode
        pattern_statement(node, last: last)
      when Prism::UnlessNode
        unless_statement(node, last: last)
      when Prism::WhileNode, Prism::UntilNode
        loop_statement(node, last: last)
      when Prism::BreakNode
        break_statement(node, last: last)
      when Prism::NextNode
        next_statement(node, last: last)
      when Prism::RedoNode
        redo_statement(node, last: last)
      when Prism::YieldNode
        yield_statement(node, last: last)
      when Prism::SuperNode, Prism::ForwardingSuperNode
        super_statement(node, last: last)
      when Prism::DefinedNode
        # An unused defined? generates nothing (verified: no code, no symbols); a used one is a value (value_into).
        return nil unless last

        value_in_register(node)
      when Prism::SingletonClassNode
        sclass_statement(node, last: last)
      when Prism::ForNode
        for_statement(node, last: last)
      when Prism::ClassNode
        class_statement(node, last: last)
      when Prism::ModuleNode
        module_statement(node, last: last)
      when Prism::RangeNode, Prism::FlipFlopNode
        range_statement(node, last: last)
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
      return
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
        empty_line = sub.nil? ? end_line(node) : keyword.start_line
        gap_line = empty_gap_line(node.then_keyword_loc || node.predicate.location, keyword, !node.then_keyword_loc.nil?)
        empty_line = gap_line if gap_line != keyword.start_line # a `;` makes the nil a node of the `;`'s line
      end
      # An empty else-branch is a node on the line of the closing `end`.
      else_line = else_list && else_list.empty? ? end_line(node) : nil
      if else_list&.empty? && sub.is_a?(Prism::ElseNode)
        gap_line = empty_gap_line(sub.else_keyword_loc, node.end_keyword_loc, true)
        else_line = gap_line if gap_line != node.end_keyword_loc.start_line
      end
      gen_if(node.predicate, then_list, else_list, val: last, then_present: true, empty_line: empty_line,
                                                            elsif_node: elsif_node?(node), else_line: else_line,
                                                            line: if_node_line(node))
    end

    # The line of the closing `end` as a node built at it has it: 0 when the `end` was scanned across the end of a file.
    def end_line(node) = @zero_nodes&.key?(node) ? 0 : node.end_keyword_loc.start_line

    # The line of an if or unless node, which the fork enters before its condition: the keyword's line for the block form (the
    # `end`'s for an `elsif`), and for a modifier or a ternary, which the parser builds after the condition (the modifier) or the
    # last branch (the ternary), the line the parser is on then, a continuation after it included.
    def if_node_line(node)
      kw = node.is_a?(Prism::IfNode) ? node.if_keyword_loc : node.keyword_loc
      if kw.nil?
        node.location.end_line + continuation_count(node.location)
      elsif node.statements && node.statements.location.start_offset < kw.start_offset
        pred = node.predicate
        @leading_dot.fetch(pred) { pred.location.end_line } + continuation_count(pred.location)
      elsif elsif_node?(node)
        node.end_keyword_loc.start_line
      else
        kw.start_line
      end
    end

    # `unless` is an if whose then-branch is the else-clause and whose else-branch is the body (the fork's parser swaps
    # them), so the body runs when the predicate is false. Without an else-clause the then-branch is absent.
    def unless_statement(node, last:)
      body = node.statements&.body || []
      else_node = node.else_clause
      # An empty branch is a node on the line of the keyword that follows it (`else` or `end`).
      body_line = body.empty? ? (else_node ? else_node.else_keyword_loc.start_line : end_line(node)) : nil
      if body.empty?
        kw = else_node ? else_node.else_keyword_loc : node.end_keyword_loc
        gap_line = empty_gap_line(node.then_keyword_loc || node.predicate.location, kw, !node.then_keyword_loc.nil?)
        body_line = gap_line if gap_line != kw.start_line
      end
      if else_node
        then_list = else_node.statements&.body || []
        then_line = then_list.empty? ? end_line(node) : nil
        if then_list.empty?
          gap_line = empty_gap_line(else_node.else_keyword_loc, node.end_keyword_loc, true)
          then_line = gap_line if gap_line != node.end_keyword_loc.start_line
        end
        gen_if(node.predicate, then_list, body, val: last, then_present: true, empty_line: then_line,
                                                           else_line: body_line, line: if_node_line(node))
      else
        gen_if(node.predicate, [], body, val: last, then_present: false, else_line: body_line, line: if_node_line(node))
      end
    end

    # codegen_if. +then_list+ and +else_list+ are statement lists (+else_list+ is nil without an else-branch).
    # +then_present+ is whether the fork's then-branch exists (it does for an empty `if` body but not for a bare `unless`).
    def gen_if(pred, then_list, else_list, val:, then_present:, empty_line: nil, elsif_node: false, else_line: nil, line: nil)
      @line = line if line # the if node is entered first; the predicate's nodes are then visited at their own lines
      # The fork folds a literal condition only when it is the condition node itself: `(nil)` is not folded.
      return gen_arm(then_list, val, then_present ? empty_line : nil) if true_always?(pred)
      return gen_arm(else_list || [], val, else_line) if false_always?(pred)

      parenthesized = pred.is_a?(Prism::ParenthesesNode) # `(x.nil?)` is a begin node to the fork: no JMPNIL
      pred = unparen(pred)
      check_condition(pred, elsif_node)
      leading_dot(pred) if pred.is_a?(Prism::CallNode)
      t = temp
      nil_p = !parenthesized && nil_check?(pred)
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
      raise Unsupported, 'singleton class of a non-operand object' unless simple?(obj) || operand?(obj)

      t = temp
      value_into(obj, t)
      emit(:SCLASS, t)
      class_body(node, t, last)
      t
    end

    Loop = Struct.new(:reg, :pc0, :breaks, :pc1)

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

      # The loop node is entered before its condition: its keyword's line, or for a modifier (built after the condition) the
      # line the parser is on then.
      @line = if node.statements && node.statements.location.start_offset < node.keyword_loc.start_offset
                @leading_dot.fetch(pred) { pred.location.end_line } + continuation_count(pred.location)
              else
                node.keyword_loc.start_line
              end

      if never
        emit(:LOADNIL, t) if last
        return last ? t : nil
      end

      pred = unparen(pred)
      check_condition(pred, false) unless forever
      leading_dot(pred) if pred.is_a?(Prism::CallNode)
      lp = Loop.new(last ? t : nil, @code.size, [])
      @labels << lp.pc0
      @loops << lp
      begin
        unless forever
          value_into(pred, t)
          to_exit = cond_jump(until_loop ? :JMPIF : :JMPNOT, t, val: false)
        end
        @labels << @code.size
        lp.pc1 = @code.size
        emit(:NOP)
        # An empty body is a node on the line of the closing `end`, which is visited after the NOP (verified).
        if node.statements.nil? || node.statements.body.empty?
          @line = empty_gap_line(node.do_keyword_loc || node.predicate.location, node.closing_loc, !node.do_keyword_loc.nil?)
        end
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
      raise Unsupported, 'begin/end loop body' unless body.is_a?(Prism::BeginNode)

      # With rescue, else or ensure the begin node itself is the body, a statement with its handler region.
      plain = body.rescue_clause.nil? && body.else_clause.nil? && body.ensure_clause.nil?
      stmts = plain ? (body.statements&.body || []) : [body]
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
        lp.pc1 = @code.size
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
      return block_break(node, last: last) if lp == BLOCK_LOOP

      enter(node)

      args = node.arguments&.arguments
      # milestone 13: with the loop's value unused, several values are a NOVAL array (nothing) and `break *a` the plain value.
      if args && args.size > 1 && lp.reg
        # several values are an array literal built at the loop's value register
        raise Unsupported, 'break value outside the loop statement level' unless @sp == lp.reg
        raise Unsupported, 'break with several values' unless args.size <= 14 && args.all? { |a| operand?(a) && !a.is_a?(Prism::SplatNode) }

        args.each_with_index { |a, i| operand_into(unparen(a), lp.reg + i) }
        @nregs = [@nregs, lp.reg + args.size].max
        emit(:ARRAY, lp.reg, args.size)
        lp.breaks << emit_jump(:JMPUW)
        return last ? temp : nil
      end
      raise Unsupported, 'break with several values' if args && args.size != 1 && lp.reg
      raise Unsupported, 'break with a splat' if args && args.size == 1 && args[0].is_a?(Prism::SplatNode) && (lp.reg || args[0].expression.nil?)

      value = args && args.size == 1 && unparen(args[0].is_a?(Prism::SplatNode) ? args[0].expression : args[0])
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
      return block_next(node, last: last) if lp == BLOCK_LOOP

      enter(node)
      args = node.arguments&.arguments
      # milestone 13: several values are an array literal, which generates nothing unused; `next *a` is the plain value.
      if args && args.size == 1
        v = args[0].is_a?(Prism::SplatNode) ? args[0].expression : args[0]
        raise Unsupported, 'next with an anonymous splat' unless v

        statement(unparen(v), last: false) # codegen(value, NOVAL) before the JMPUW
      end
      jump = emit_jump(:JMPUW)
      patch_jump(jump, lp.pc0)
      last ? temp : nil
    end


    # codegen_class: the outer namespace (nil for a plain constant) goes into the first temporary, the superclass (nil when
    # there is none) into the next, and CLASS takes the first temporary as its result. The body follows (class_body).
    def class_statement(node, last:)
      superclass = node.superclass
      raise Unsupported, 'superclass that is not a simple value' if superclass && !(simple?(superclass) || operand?(superclass))

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

      stmts = body_statements(body)
      if stmts.empty?
        emit(:LOADNIL, t)
      else
        emit(:EXEC, t, child_body(node.locals, stmts, val))
      end
    end

    # scope_body: the index of the child irep, which is the next entry of the parent's reps (a body with no statements
    # creates none).
    def child_body(locals, stmts, val)
      child = Compiler.new(@filename, frozen_strings: @frozen_strings)
      child.instance_variable_set(:@outer_in_method, inside_method?)
      @children << child.compile_body(locals, stmts, val)
      index = @children.size - 1
      
      index
    end

    # ---- case/when and range literals (milestone 11) ----

    # A `*value` element of an array literal whose value is an operand.
    def array_splat?(node)
      node.is_a?(Prism::SplatNode) && node.expression && operand?(node.expression)
    end

    # Assignments whose value is used (`x = (y ||= 1)`, `foo(a = 1)`, `a = b = 2`).
    VALUE_WRITES = [Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::GlobalVariableWriteNode,
                    Prism::ConstantWriteNode, Prism::ClassVariableWriteNode, Prism::ConstantPathWriteNode,
                    Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
                    Prism::GlobalVariableOperatorWriteNode, Prism::ConstantOperatorWriteNode,
                    Prism::ClassVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode,
                    Prism::GlobalVariableOrWriteNode, Prism::ConstantOrWriteNode, Prism::ClassVariableOrWriteNode,
                    Prism::LocalVariableAndWriteNode, Prism::InstanceVariableAndWriteNode, Prism::GlobalVariableAndWriteNode,
                    Prism::ConstantAndWriteNode, Prism::ClassVariableAndWriteNode, Prism::IndexOperatorWriteNode,
                    Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::CallOperatorWriteNode, Prism::CallOrWriteNode,
                    Prism::CallAndWriteNode].freeze

    # A write as a value: the statement's own code with its value used, built at the destination when that is a temporary,
    # else at the first temporary and moved (as for an `if`).
    def write_value_into(node, dst)
      saved = @sp
      base = dst >= @nlocals ? dst : temp
      begin
        @sp = base
        r = statement(node, last: true)
      ensure
        @sp = saved
      end
      gen_move(dst, r, false)
    end

    # The pool entry of a float literal (new_lit_float): the value is read as the fork's mrb_read_float does, and an entry
    # is reused only when its bits are the same (so 0.0 and -0.0 are two entries).
    def float_index(node)
      pool_index([:float, float_bits(node)])
    end

    # src/readfloat.c: the integer part, up to 18 fraction places (the rest are skipped) and the exponent are read with
    # integer arithmetic and combined in double arithmetic, which is not always the correctly rounded value.
    def read_float(text)
      m = /\A(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?\z/.match(text.delete('_'))
      raise Unsupported, 'float literal form' unless m
      raise Unsupported, 'float literal with a long integer part' if m[2].size > 18

      res = m[2].to_i.to_f
      if m[3]
        frac = m[3][0, 18]
        res += frac.to_i.to_f / pow10(frac.size)
      end
      if m[4]
        e = m[4].to_i
        e = 10_000 * (e.negative? ? -1 : 1) if e.abs >= 10_000
        res *= pow10(e)
      end
      res *= m[1].empty? ? 1 : -1
      res
    end

    # mrb_pow10: the table entries are correctly rounded literals; beyond the table the result is infinity or 0.
    def pow10(exp)
      return Float("1e#{exp}") if exp.between?(-323, 308)

      exp.positive? ? Float::INFINITY : 0.0
    end

    # `@@cv = value`: as an instance variable write, with SETCV.
    def cvar_write(node, last:)
      t = temp
      value_into(node.value, t)
      gen_setxv(:SETCV, t, node.name, last)
      last ? t : nil
    end

    # Nodes the fork enters but ENTERED lacks: a single-line one stamps its own line (case_statement sets it).
    # milestone 13: subjects the fork does not enter either (their own parts do): an if, a begin block, parentheses.
    CASE_BLOCKISH = [Prism::IfNode, Prism::UnlessNode, Prism::BeginNode, Prism::ParenthesesNode].freeze
    CASE_UNENTERED = [Prism::ConstantPathNode, Prism::RangeNode, Prism::FlipFlopNode, Prism::RegularExpressionNode,
                      Prism::InterpolatedRegularExpressionNode, Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode].freeze

    # A subject or a `when` value the case code covers: a node the fork enters (so its line is set by value_into), a
    # constant path or a range of such.
    def case_operand?(node)
      node = unparen(node)
      return false unless operand?(node)

      ENTERED.include?(node.class) || CASE_UNENTERED.include?(node.class) || CASE_BLOCKISH.include?(node.class)
    end

    # codegen_case: the subject (when there is one) goes into the first temporary `head`; each `when` value is generated at
    # head+1 and compared with `value === subject` (the subject is copied to head+2 for the SEND: gen_move, then two pushes
    # and a pop leave the SEND at head+1, so the registers head+3 are counted). A `when *list` calls __case_eqq. Without a
    # subject the value itself is tested. The last value of a `when` takes JMPNOT to the next clause, the others JMPIF to the
    # body; the body ends with a JMP to the end of the case (also the last one, and the `else` body). With a value and no
    # `else` the fall-through loads nil; then the result is in head+1 and a MOVE brings it to head (gen_move: that is what a
    # `return` or an assignment then folds).
    def case_statement(node, last:)
      subject = node.predicate && unparen(node.predicate)
      raise Unsupported, 'case subject' if subject && !case_operand?(subject)
      check_multiline(subject) if subject # heredocs, leading dots and multi-line logic have their own line rules

      node.conditions.each do |w|
        raise Unsupported, 'case/in pattern matching' unless w.is_a?(Prism::WhenNode)

        w.conditions.each do |c|
          c = unparen(c)
          c = unparen(c.expression) if c.is_a?(Prism::SplatNode) && c.expression
          raise Unsupported, 'when value' unless case_operand?(c) && !c.is_a?(Prism::SplatNode)

          check_multiline(c)
        end
      end
      saved = @sp
      head = temp
      if subject
        if CASE_UNENTERED.include?(subject.class)
          raise Unsupported, 'multi-line case subject' if subject.location.start_line != subject.location.end_line

          @line = subject.location.start_line
        end
        value_into(subject, head)
      end
      base = subject ? head + 1 : head
      @sp = base
      # An empty body is a node on the line of the keyword that follows it (the next `when`, the `else` or the `end`).
      keywords = node.conditions.map(&:keyword_loc) + [node.else_clause&.else_keyword_loc, node.end_keyword_loc].compact
      clauses = node.conditions.each_with_index.map do |w, i|
        line = keywords[i + 1].start_line
        line = empty_gap_line(w.then_keyword_loc || w.conditions.last.location, keywords[i + 1], !w.then_keyword_loc.nil?) if w.statements.nil? || w.statements.body.empty?
        [w.conditions, w.statements, line]
      end
      if node.else_clause
        line = end_line(node)
        line = empty_gap_line(node.else_clause.else_keyword_loc, node.end_keyword_loc, true) if (node.else_clause.statements.nil? || node.else_clause.statements.body.empty?) && line != 0
        clauses << [[], node.else_clause.statements, line]
      end
      end_jumps = []
      next_jump = nil
      clauses.each do |conds, body, empty_line|
        dispatch(next_jump)
        next_jump = nil
        success = []
        conds.each_with_index do |c, i|
          c = unparen(c)
          splat = c.is_a?(Prism::SplatNode)
          v = splat ? unparen(c.expression) : c
          if CASE_UNENTERED.include?(v.class)
            raise Unsupported, 'multi-line when value' if v.location.start_line != v.location.end_line

            @line = v.location.start_line
          end
          operand_into(v, base)
          if subject
            gen_move(base + 1, head, false)
            @nregs = [@nregs, head + 4].max
            emit(:SEND, base, sym_index(splat ? :__case_eqq : :===), 1)
          end
          if i < conds.size - 1
            success << cond_jump(:JMPIF, base, val: !subject)
          else
            next_jump = cond_jump(:JMPNOT, base, val: !subject)
          end
        end
        success.each { |j| dispatch(j) }
        @line = empty_line if body.nil? || body.body.empty?
        branch(body, base, need: last)
        end_jumps << emit_jump(:JMP)
      end
      if next_jump
        dispatch(next_jump)
        emit(:LOADNIL, base) if last
      end
      end_jumps.each { |j| dispatch(j) }
      return nil unless last

      gen_move(head, base, false) if subject
      head
    ensure
      @sp = saved if saved
    end

    # A case as a value: built at the destination when it is a temporary, else at the first temporary and moved.
    def case_value_into(node, dst)
      saved = @sp
      base = dst >= @nlocals ? dst : temp
      begin
        @sp = base
        r = case_statement(node, last: true)
      ensure
        @sp = saved
      end
      gen_move(dst, r, false)
    end

    # codegen_dot2 and codegen_dot3: both ends are values in consecutive registers (an omitted end is nil) and RANGE_INC or
    # RANGE_EXC builds the range in the first.
    def range_at(node, base)
      raise Unsupported, 'multi-line range' if node.location.start_line != node.location.end_line

      @line = @zero_nodes&.key?(node) ? 0 : node.location.start_line # the node is entered before its ends (an omitted end is a nil on its line)
      [node.left, node.right].each_with_index do |e, i|
        e ? operand_into(unparen(e), base + i) : emit(:LOADNIL, base + i)
      end
      @nregs = [@nregs, base + 2].max
      emit(node.exclude_end? ? :RANGE_EXC : :RANGE_INC, base)
    end

    # A range statement: its value as the last statement; otherwise only the ends are evaluated, for their effects.
    def range_statement(node, last:)
      if last
        value_in_register(node)
      else
        [node.left, node.right].each { |e| statement(e, last: false) if e }
        nil
      end
    end

    def set_jump_line(position, line)
      line = zero_line(position) if line.zero?
      @lines[position] = line
      @lines[position + 1] = line
    end

    # The line of the +count+ bytes just emitted. The fork's emit stamps s->lineno, but a node with line 0 (the tail of a
    # file in a multi-file program, see MrbcRb.compile_files) takes the line of the previous byte instead (emit in codegen.c).
    def record_lines(count)
      count.times { @lines << (@line.zero? ? zero_line(@lines.size) : @line) }
    end

    def zero_line(pc) = pc.zero? ? 0 : @lines[pc - 1]

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
      @code << OP.fetch(:EXT1) if reg && reg > 0xff # genop_2S: a register past 255 takes EXT1
      @code << OP.fetch(name)
      reg && reg > 0xff ? short(reg) : (byte(reg) if reg)
      position = @code.size
      short(0)
      record_lines(@code.size - start)
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
      enter(node)
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
        t = temp
        enter(value)
        case value
        when Prism::LocalVariableReadNode
          # An upvalue read is loaded straight into the local (gen_move's GETUPVAR peephole).
          if value.depth.zero?
            src = local_register(value.name)
            # `x = x`: the value is loaded into the temporary and the move back is skipped (gen_move's swap rule).
            src == local ? emit(:MOVE, @sp, src) : gen_move(local, src, false)
          else
            # ...unless that GETUPVAR is skipped because the SETUPVAR of the same variable just stored its register (getupvar):
            # then the temporary holds the value and the move stays.
            idx, lv = upvar_operands(value.name, value.depth)
            name, operands, = @last
            if name == :SETUPVAR && operands == [t, idx, lv] && !@labels.include?(@code.size)
              emit(:MOVE, local, t)
            else
              value_into(value, local)
            end
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
      when :LOADL then (e = @pool[ops[1]]).is_a?(Array) && e[0] == :int ? e[1] : nil
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
      when Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode
        :cvar
      end
    end

    # The fork enters the variable of an operator, or or and assignment (a node it built when it read the name, so it carries
    # the line of the name and, for a variable or constant, the line after a continuation).
    def enter_target(kind, node)
      return if @hold_line

      loc = node.name_loc
      @line = loc.end_line + (%i[ivar gvar].include?(kind) ? 0 : continuation_count(loc))
    end

    # codegen(lhs, VAL): the variable's value into register +t+.
    def read_target(kind, node, t)
      enter_target(kind, node)
      case kind
      when :local then emit(:MOVE, t, local_register(node.name))
      when :upvar then getupvar(t, node)
      when :ivar then emit(:GETIV, t, sym_index(node.name))
      when :gvar then emit(:GETGV, t, sym_index(node.name))
      when :const then emit(:GETCONST, t, sym_index(node.name))
      when :cvar then emit(:GETCV, t, sym_index(node.name))
      end
    end

    # The read of `recv[idx]` with the receiver and index loaded into +t+ and +t+ + 1 (gen_binop): `local[0]` fuses its two loads
    # into GETIDX0, and a pc that is a jump target gives a plain SEND of `[]`.
    def index_read(t, recv, idx)
      if no_peephole?
        emit(:SEND, t, sym_index(:[]), 1)
      elsif idx.is_a?(Prism::IntegerNode) && idx.value.zero? && recv.is_a?(Prism::LocalVariableReadNode) && recv.depth.zero?
        truncate(@code.size - 5)
        emit(:GETIDX0, t, local_register(recv.name))
      else
        emit(:GETIDX, t)
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
      when :cvar then gen_setxv(:SETCV, t, node.name, val)
      end
    end

    # The values an assignment's right side may be: operands, and `||` and `&&` of operands (value_into builds them).
    def assign_value?(value)
      operand?(value) || value.is_a?(Prism::OrNode) || value.is_a?(Prism::AndNode) || value.is_a?(Prism::RescueModifierNode) ||
        value.is_a?(Prism::BeginNode)
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

      value = unparen(node.value)
      raise Unsupported, 'logic assignment value' unless assign_value?(value)

      t = temp
      if node.is_a?(Prism::ConstantOrWriteNode) || node.is_a?(Prism::ClassVariableOrWriteNode)
        guarded_read(kind, node, t)
      else
        read_target(kind, node, t)
      end
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
      dispatch(to_end)
      last ? t : nil
    end

    # The read of `Const ||= v` and `@@cv ||= v` (codegen_op_asgn): a LOOP_BEGIN label, the read inside a catch handler whose
    # target is EXCEPT then LOADFALSE (an unset constant or class variable counts as false).
    def guarded_read(kind, node, t)
      @labels << @code.size
      entry = new_catch
      from = @code.size
      read_target(kind, node, t)
      to = @code.size
      noexc = emit_jump(:JMP)
      @catches[entry] = [0, from, to, @code.size]
      emit(:EXCEPT, t)
      emit(:LOADFALSE, t)
      dispatch(noexc)
    end

    # `recv[i] op= v`, `recv.name op= v` (and ||=, &&=): the call is read as an ordinary call, then assigned with the
    # fork's codegen_call_assign, which evaluates the receiver and the index again. The value is in the first temporary t;
    # the receiver (and index) go after a result slot at t+1 and the value is copied after them, SETIDX or SEND of the
    # writer then runs on the receiver. Where the value is used it is copied back into t first.
    def call_write(node, last:)
      index = node.is_a?(Prism::IndexOperatorWriteNode) || node.is_a?(Prism::IndexOrWriteNode) ||
              node.is_a?(Prism::IndexAndWriteNode)
      recv = node.receiver && unparen(node.receiver)
      raise Unsupported, 'assignment receiver' unless recv && operand?(recv)
      raise Unsupported, 'safe navigation assignment' if node.safe_navigation? && (index || recv.is_a?(Prism::SelfNode))

      leading_dot(node) unless index
      idxs = []
      reads = nil # the index arguments of the read when they differ from those of the write (a splat among them)
      splat_read = false
      if index
        raw = (node.arguments&.arguments || []).map { |a| unparen(a) }
        raise Unsupported, 'index assignment with a block' if node.block
        # The fork assigns through the splat's value as a plain argument (`o[*a] += 1` reads o[*a] and writes o[a]).
        if raw.any?(Prism::SplatNode)
          raise Unsupported, 'index assignment arguments' if raw.any? { |a| !(a.is_a?(Prism::SplatNode) ? a.expression && operand?(a.expression) : operand?(a)) }

          flat = literal_splat_arguments(raw)
          flat ? reads = flat : splat_read = true
          idxs = raw.map { |a| a.is_a?(Prism::SplatNode) ? unparen(a.expression) : a }
        else
          idxs = raw
        end
        raise Unsupported, 'index assignment arguments' unless idxs.size <= 12 && idxs.all? { |a| operand?(a) } && (reads || idxs).size <= 12
      end
      idx = idxs.first if idxs.size == 1
      ridxs = reads || idxs
      value = unparen(node.value)
      raise Unsupported, 'assignment value' unless assign_value?(value)

      t = temp
      operand_into(recv, t) unless recv.is_a?(Prism::SelfNode) && !index # `self.x op= v` reads x with SSEND0 (no LOADSELF)
      if index && splat_read
        argc, = gen_args(nil, t, raw)
        emit(:SEND, t, sym_index(:[]), argc)
        @sp = t
      elsif index
        ridxs.each_with_index { |a, i| operand_into(a, t + 1 + i) }
        if ridxs.size == 1 then index_read(t, recv, ridxs[0])
        elsif ridxs.empty? then emit(:SEND0, t, sym_index(:[]))
        else emit(:SEND, t, sym_index(:[]), ridxs.size)
        end
      else
        skip = safe_jump(t, true) if node.safe_navigation?
        emit(recv.is_a?(Prism::SelfNode) ? :SSEND0 : :SEND0, t, sym_index(node.read_name))
        dispatch(skip)
      end
      @nregs = [@nregs, t + 2 + (ridxs.size > 1 ? ridxs.size : 0)].max
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
      skip = safe_jump(base, last) if !index && node.safe_navigation?
      if index && idxs.size == 1
        operand_into(idx, base + 1)
        gen_move(base + 2, t, false)
        gen_move(t, base + 2, true) if last
        emit(:SETIDX, base)
        @nregs = [@nregs, base + 4].max
      elsif index
        idxs.each_with_index { |a, i| operand_into(a, base + 1 + i) }
        vreg = base + 1 + idxs.size
        gen_move(vreg, t, false)
        gen_move(t, vreg, true) if last
        emit(:SEND, base, sym_index(:[]=), idxs.size + 1)
        @nregs = [@nregs, vreg + 2].max
      else
        gen_move(base + 1, t, false)
        gen_move(t, base + 1, true) if last
        emit(:SEND, base, sym_index(node.write_name), 1)
        dispatch(skip)
        @nregs = [@nregs, base + 3].max
      end
      dispatch(to_end)
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
      when Prism::ClassVariableTargetNode then gen_setxv(:SETCV, src, target.name, false)
      when Prism::ConstantTargetNode then gen_setxv(:SETCONST, src, target.name, false)
      when Prism::MultiTargetNode
        target.lefts.each_with_index do |l, i|
          emit(:AREF, cursp, src, i)
          assign_target(l, cursp, cursp + 1)
        end
        # milestone 13: a splat or trailing targets in a nested target: APOST on a copy at the stack pointer (codegen_masgn).
        rest = target.rest
        rest = nil if rest.is_a?(Prism::ImplicitRestNode)
        if rest || !target.rights.empty?
          post = target.rights.size
          gen_move(cursp, src, false)
          @nregs = [@nregs, cursp + post + 1].max
          emit(:APOST, cursp, target.lefts.size, post)
          assign_target(rest.expression, cursp, cursp) if rest&.expression
          target.rights.each_with_index { |r, i| assign_target(r, cursp + 1 + i, cursp) }
        end
      when Prism::CallTargetNode, Prism::IndexTargetNode
        index = target.is_a?(Prism::IndexTargetNode)
        recv = unparen(target.receiver)
        raise Unsupported, 'assignment target receiver' unless (simple?(recv) || call_node?(recv)) && !recv.is_a?(Prism::SelfNode)
        raise Unsupported, 'safe navigation assignment' if !index && target.safe_navigation?

        leading_dot(target) unless index
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

      value = unparen(@masgn_plain.equal?(node) ? node.value.expression : node.value)
      fixed = value.is_a?(Prism::ArrayNode) && value.elements.none? { |e| e.is_a?(Prism::SplatNode) }
      if value.is_a?(Prism::ArrayNode)
        raise Unsupported, 'multiple assignment right side element' unless value.elements.all? { |e| operand?(e) || array_splat?(e) }
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
          # The fork loads these without entering the elements: they carry the line of the assignment.
          saved_hold = @hold_line
          @hold_line = true
          lefts.each_with_index { |l, i| value_into(elems[i], local_register(l.name)) }
          @hold_line = saved_hold
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
          raise Unsupported, 'splat target that is not a variable' unless rest.expression.nil? || plain.include?(rest.expression.class)

          post = rights.size
          rn = len < post + n ? 0 : len - post - n
          cursp = t + len
          saved = @nregs
          cursp == t + n ? emit(:ARRAY, cursp, rn) : emit(:ARRAY2, cursp, t + n, rn)
          assign_target(rest.expression, cursp, cursp) if rest.expression # a bare `*` is the fork's NODE_NIL: nothing assigned
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
        assign_target(rest.expression, sp, sp) if rest&.expression
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
    # GETIDX on the receiver and index just generated at +t+ and t+1, as call() emits it: `local[0]` is the fused GETIDX0.
    def getidx_fused(t, recv, idx)
      if no_peephole? # gen_binop does nothing at a jump target or after a rewind: a plain send
        emit(:SEND, t, sym_index(:[]), 1)
      elsif idx.is_a?(Prism::IntegerNode) && idx.value.zero? && recv.is_a?(Prism::LocalVariableReadNode) && recv.depth.zero?
        truncate(@code.size - 5) # the MOVE (3 bytes) and the LOADI_0 (2 bytes) go
        emit(:GETIDX0, t, local_register(recv.name))
      else
        emit(:GETIDX, t)
      end
    end

    # `recv.name = value`: the result (the value) is in the first temporary r; the receiver is in r+1 and the value in r+2,
    # and SEND runs on r+1 with that one argument (verified against mrbc -v: the result is the value, not the send's).
    # Where the value is not needed, the receiver is in the first temporary with the value after it, and SEND runs there.
    def attribute_assign(node, recv, arg, need:)
      r = temp
      if need
        operand_into(recv, r + 1)
        skip = safe_jump(r + 1, true) if node.safe_navigation?
        operand_into(arg, r + 2)
        emit(:MOVE, r, r + 2)
        emit(:SEND, r + 1, sym_index(node.name), 1)
        dispatch(skip)
        @nregs = [@nregs, r + 4].max
        r
      else
        operand_into(recv, r)
        skip = safe_jump(r, false) if node.safe_navigation?
        operand_into(arg, r + 1)
        emit(:SEND, r, sym_index(node.name), 1)
        dispatch(skip)
        @nregs = [@nregs, r + 3].max
        nil
      end
    end

    # `recv[index] = value` (SETIDX, verified): where the value is needed the result register r holds it, the receiver,
    # index and value follow it, and SETIDX runs on the receiver; otherwise the receiver is in the first temporary.
    def index_assign(recv, index, value, need:)
      [recv, index].each do |v|
        raise Unsupported, 'index assignment with a non-simple operand' unless operand?(v)
      end
      raise Unsupported, 'index assignment with a non-simple operand' unless assign_value?(value)
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

    # `recv[i, j] = value`: no SETIDX for several indices, a plain SEND of []= with the indices and the value as its arguments;
    # where the value is needed the result register holds it (copied after the send's arguments are generated).
    def index_assign_many(recv, args, need:)
      raise Unsupported, 'index assignment with a non-simple operand' unless args[0...-1].all? { |v| operand?(v) } && assign_value?(args.last)

      r = temp
      base = need ? r + 1 : r
      operand_into(recv, base)
      args.each_with_index { |v, i| operand_into(v, base + 1 + i) }
      emit(:MOVE, r, base + args.size) if need
      emit(:SEND, base, sym_index(:[]=), args.size)
      @nregs = [@nregs, base + args.size + 2].max
      need ? r : nil
    end

    PLAIN_NAME = /\A[A-Za-z_]\w*[?!]?\z/
    # The names codegen_call maps to an operator opcode (opt_op): a `self` receiver is a real operand for them.
    OPT_OP_NAMES = %i[+ - * / < <= > >= == [] []=].freeze

    # Whether a call's arguments are more than positional operands: keyword arguments, splats or a block argument.
    def complex_arguments?(node)
      # `a[*x] = v`: the fork generates the splat node as its plain value, so the call has simple arguments (verified).
      return false if index_splat_assign?(node)

      (node.arguments&.arguments || []).any? { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::SplatNode) || a.is_a?(Prism::ForwardingArgumentsNode) } ||
        node.block.is_a?(Prism::BlockArgumentNode) || ((node.arguments&.arguments || []).size > 14 && (node.name.to_s.match?(PLAIN_NAME) || (node.name == :[] && node.receiver)))
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
      # `self[*a]` and `self.+(b, &blk)` load self like any receiver (opt_op is set); other names are sent to self.
      recv = node.receiver && unparen(node.receiver)
      recv = nil if recv.is_a?(Prism::SelfNode) && !OPT_OP_NAMES.include?(node.name)
      raise Unsupported, 'safe navigation without a receiver' if node.safe_navigation? && recv.nil? && !self_receiver?(node)
      raise Unsupported, 'call with a non-simple receiver' if recv && !operand?(recv)

      enter(node) # instructions before the first operand (the splat's array) carry the call's line
      a = @sp
      @nregs = [@nregs, a + 1].max
      operand_into(recv, a) if recv
      skip = safe_jump(a, need) if node.safe_navigation?
      args, block = forwarding_arguments(node)
      argc, blk = gen_args(block, a, args, node.closing_loc&.start_line)
      emit_send(a, recv, node.name, argc, blk)
      dispatch(skip)
      a
    ensure
      @sp = a if a
    end

    # The send instruction: with a receiver SEND (SEND0 when there is nothing to pass), without one SSEND (SSEND0).
    def emit_send(a, recv, name, argc, blk)
      if recv && operator_opcode?(name, argc)
        return emit(:SETIDX, a) if name == :[]=
        # keywords after the one positional argument: the last instruction is the last keyword's value, which gen_addsub folds
        return if !blk && argc != (argc & 0xf) && binary_folded(name, a)

        return emit(BINARY_OPS.fetch(name), a)
      end

      sym = sym_index(name)
      if blk
        emit(recv ? :SENDB : :SSENDB, a, sym, argc)
      elsif argc.zero?
        emit(recv ? :SEND0 : :SSEND0, a, sym)
      else
        emit(recv ? :SEND : :SSEND, a, sym, argc)
      end
    end

    # codegen_call picks the operator opcode from the method name before it looks at the arguments or the block: `+ - * / < <= >
    # >= ==` with one positional argument and `[]=` with two are ADD ... EQ and SETIDX even when a block or a block argument
    # follows (the block register is loaded and then ignored). With keywords the last keyword's value is the last instruction, so
    # `a.+(1, k: 2)` is ADDI (emit_send).
    def operator_opcode?(name, argc)
      return false unless (BINARY_OPS.key?(name) && name != :[]) || name == :[]=

      n = argc & 0xf
      return false unless n == (name == :[]= ? 2 : 1)

      true
    end

    # gen_values, gen_hash and the block argument of codegen_call: the arguments of the call whose result register is +a+
    # are generated from register a+1. Returns the argc byte (n | nk << 4) and whether a block argument was generated.
    # Positional operands are loaded in order; a splat flushes what came before into an array (LOADNIL or ARRAY, then
    # ARYPUSH) and ARYCATs the splatted value, so the count becomes 15 and the array is one register. Keywords stay as key and
    # value registers (nk is their count) unless a ** is present: then a HASH is built and extended with HASHADD/HASHCAT
    # (nk = 15). The block argument is loaded in the register after all of these. The stack pointer is left at the register
    # after the arguments, which the send's own result push then counts.
    def gen_args(blk, a, args, close_line = nil)
      regular = args.reject { |x| x.is_a?(Prism::KeywordHashNode) }
      kw = args.find { |x| x.is_a?(Prism::KeywordHashNode) }
      sp = a + 1
      slimit = sp >= 99 ? Float::INFINITY : 99
      n = 0
      variable = false
      regular.each do |arg|
        arg = unparen(arg)
        if arg.is_a?(Prism::SplatNode)
          v = arg.expression ? unparen(arg.expression) : anonymous_local(:*, arg)

          if v.is_a?(Prism::ArrayNode) && v.elements.none?(Prism::SplatNode) && v.opening_loc&.slice == '['
            # Literal arrays are inlined (empty ones vanish).
            raise Unsupported, 'splat of an array of non-leaf values' unless v.elements.all? { |e| operand?(e) }

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

          if sp >= slimit # gen_values flushes what it has when the stack reaches GEN_VAL_STACK_MAX
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
          end
          operand_into(arg, sp)
          sp += 1
          n += 1
        end
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
        # gen_values packs more than 14 positional arguments into one array, which makes the count variable
        sp -= n
        emit(:ARRAY, sp, n)
        sp += 1
        n = 15
      end
      nk = 0
      if kw
        nk, sp = gen_keywords(kw, sp, close_line)
      end
      @sp = sp
      @nregs = [@nregs, sp + 1].max
      if blk
        raise Unsupported, 'block argument nil beside a &nil parameter' if blk.expression.respond_to?(:name) && blk.expression.name == NIL_BLOCK_NAME.to_sym

        operand_into(blk.expression ? unparen(blk.expression) : anonymous_local(:&, blk), sp)
      end
      [n | (nk << 4), !blk.nil?]
    end

    # gen_hash with val: pairs stay as key and value registers; a ** starts (or extends) a HASH built from the pairs before it
    # and merges the splatted value with HASHCAT; pairs after it are added with HASHADD. Returns [nk, the next register].
    def gen_keywords(kw, sp, close_line = nil)
      len = 0
      update = false
      first = true
      slimit = sp >= 64 ? Float::INFINITY : 99
      kw.elements.each do |e|
        label_key_line(e) if e.is_a?(Prism::AssocNode)
        case e
        when Prism::AssocSplatNode
          v = e.value ? unparen(e.value) : anonymous_local(:**, e)
          raise Unsupported, 'keyword splat of a non-operand' unless operand?(v)

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
          assoc_key_line(e, e.equal?(kw.elements.last) ? close_line : nil)
          v = e.value.is_a?(Prism::ImplicitNode) ? e.value.value : e.value
          raise Unsupported, 'keyword pair' unless operand?(e.key) && operand?(v)

          operand_into(unparen(e.key), sp)
          operand_into(unparen(v), sp + 1)
          sp += 2
          len += 1
        else raise Unsupported, 'keyword argument element'
        end
        if sp >= slimit # milestone 13: gen_hash flushes the pairs built so far when the stack reaches GEN_VAL_STACK_MAX
          sp -= len * 2
          if update
            sp -= 1
          end
          emit(update ? :HASHADD : :HASH, sp, len)
          sp += 1
          update = true
          len = 0
        end
        first = false
      end
      if len > 14 # gen_hash builds the pairs into a HASH when there are more than its limit
        sp -= len * 2
        emit(:HASH, sp, len)
        return [15, sp + 1]
      end
      return [len, sp] unless update

      if len.positive?
        sp -= len * 2 + 1
        emit(:HASHADD, sp, len)
        sp += 1
      end
      [15, sp]
    end

    def call(node, need: true)
      leading_dot(node)
      return call_with_block(node, need: need) if node.block.is_a?(Prism::BlockNode)

      node = flatten_literal_splats(node)
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
        elsif n_args == 1 && node.call_operator_loc && name.to_s.match?(/\A[A-Za-z_]\w*=\z/)
          nil # `self.x = v` loads self like any receiver (verified: LOADSELF, value, SEND)
        elsif name == :-@ && node.call_operator_loc.nil?
          nil # `-self` is a NODE_NEGATE: self is generated like any operand
        elsif SELF_SEND_OPS.include?(name)
          recv = nil # an operator with no opcode of its own is sent to self like a named method
        elsif !((BINARY_OPS.key?(name) && n_args == 1) || (name == :[]= && n_args >= 2))
          raise Unsupported, "operator method #{name} on self"
        end
      end
      args = (node.arguments&.arguments || []).map { |a| unparen(a) }
      args = args.map { |a| a.is_a?(Prism::SplatNode) && a.expression ? unparen(a.expression) : a } if index_splat_assign?(node)
      setter = recv && (name == :[]= || name.to_s.match?(/\A[A-Za-z_]\w*=\z/)) # an assigned value may also be a begin block or a rescue modifier
      raise Unsupported, 'call with a block or keywords' if args.any? { |a| !(operand?(a) || (setter && assign_value?(a))) }
      raise Unsupported, 'call with many arguments' if args.size > 14 # gen_values packs more than 14 into an array
      raise Unsupported, 'call with a non-simple receiver' if recv && !operand?(recv)
      raise Unsupported, 'safe navigation' if node.safe_navigation? && !recv && !self_receiver?(node) # `self&.m` has no self load (verified)
      return safe_index_assign(node, recv, args, need: need) if node.safe_navigation? && name == :[]= && args.size == 2 && assign_value?(args[1]) && operand?(args[0])
      raise Unsupported, 'safe navigation with an index assignment call' if node.safe_navigation? && name == :[]=
      raise Unsupported, "operator method #{name}" if recv && UNVERIFIED_OPERATORS.include?(name)
      raise Unsupported, 'unary operator with arguments' if UNARY_OPS.include?(name) && !args.empty?

      if recv && node.call_operator_loc && name.to_s.match?(/\A[A-Za-z_]\w*=\z/) && args.size == 1
        raise Unsupported, 'attribute assignment receiver' unless operand?(recv)
        raise Unsupported, 'safe navigation attribute assignment on self' if node.safe_navigation? && recv.is_a?(Prism::SelfNode)

        return attribute_assign(node, recv, args[0], need: need)
      end

      a = @sp
      @nregs = [@nregs, a + 1].max
      return unary_call(node, recv, a, need) if recv && UNARY_OPS.include?(name) && args.empty?

      # `recv[index]` is GETIDX and `recv[]` a plain SEND0 (both verified); other index forms are not covered yet.
      # `a.[]=(i, v)` is a plain NODE_CALL of []=: SETIDX with the result in the receiver's register (the []= send's own value,
      # not the assigned one); any other argument count is an ordinary send (milestone 14, verified with mrbc -v).
      if name == :[]= && node.call_operator_loc
        return explicit_setidx(node, recv, args) if recv && args.size == 2 && !node.safe_navigation?
        raise Unsupported, 'explicit []= call' unless recv && !node.safe_navigation?
      elsif name == :[]= && recv && args.size == 2
        return index_assign(recv, args[0], args[1], need: need)
      end
      return index_assign_many(recv, args, need: need) if name == :[]= && recv && args.size != 2 && !node.call_operator_loc
      raise Unsupported, 'index assignment' if name == :[]= && !node.call_operator_loc

      if recv && BINARY_OPS.key?(name) && args.size == 1
        operand_into(recv, a)
        skip = safe_jump(a, need) if node.safe_navigation?
        operand_into(args[0], a + 1)
        if name == :[] && no_peephole? # gen_binop gives up (a plain SEND) when the argument ends at a jump target
          emit(:SEND, a, sym_index(:[]), 1)
          dispatch(skip)
          @nregs = [@nregs, a + 3].max
          return a
        end
        if name == :[] && !skip && args[0].is_a?(Prism::IntegerNode) && args[0].value.zero? && recv.is_a?(Prism::LocalVariableReadNode) &&
           recv.depth.zero?
          # gen_binop's GETIDX0 fusion: MOVE a, local; LOADI_0 a+1 become GETIDX0 a, local (verified with mrbc -v).
          truncate(@code.size - 5) # the MOVE (3 bytes) and the LOADI_0 (2 bytes) go
          emit(:GETIDX0, a, local_register(recv.name))
          @nregs = [@nregs, a + 3].max
          return a
        end
        if binary_folded(name, a)
          dispatch(skip)
          return a
        end

        emit(BINARY_OPS.fetch(name), a)
        dispatch(skip)
        @nregs = [@nregs, a + 3].max
        return a
      end

      # milestone 13: gen_values flushes into ARRAY/ARYPUSH once an argument reaches register 99 (GEN_VAL_STACK_MAX).
      return call_with_args(node, need: need) if args.size >= 2 && a + 1 < 99 && a + args.size >= 99 && node.name.to_s.match?(PLAIN_NAME)

      operand_into(recv, a) if recv
      skip = safe_jump(a, need) if node.safe_navigation?
      args.each_with_index { |arg, i| operand_into(arg, a + 1 + i) }
      # A call on self has no receiver of its own, but the fork's folding peepholes still look at the instructions before it.
      return a if args.size == 1 && binary_folded(name, a)
      return a if args.empty? && UNARY_OPS.include?(name) && unary_folded(name, a)

      sym = sym_index(name)
      n = args.size
      if recv
        n.zero? ? emit(:SEND0, a, sym) : emit(:SEND, a, sym, n)
      else
        n.zero? ? emit(:SSEND0, a, sym) : emit(:SSEND, a, sym, n)
      end
      dispatch(skip)
      @nregs = [@nregs, a + n + 2].max
      a
    ensure
      @sp = a if a
    end

    def explicit_setidx(node, recv, args)
      a = @sp
      @nregs = [@nregs, a + 1].max
      enter(node)
      operand_into(recv, a)
      operand_into(args[0], a + 1)
      operand_into(args[1], a + 2)
      emit(:SETIDX, a)
      @nregs = [@nregs, a + 4].max
      a
    ensure
      @sp = a if a
    end

    # `recv&.[]=(i, v)`: SETIDX behind the nil test of the receiver (verified with mrbc -v): the receiver at the result register a
    # (safe_jump's copy when the value is used), the index and the value after it, and SETIDX on a leaves its result there.
    def safe_index_assign(node, recv, args, need:)
      a = @sp
      @nregs = [@nregs, a + 1].max
      enter(node)
      operand_into(recv, a)
      skip = safe_jump(a, need)
      operand_into(args[0], a + 1)
      operand_into(args[1], a + 2)
      emit(:SETIDX, a)
      dispatch(skip)
      @nregs = [@nregs, a + 4].max
      a
    ensure
      @sp = a if a
    end

    # gen_values inlines the elements of a splatted literal array (`*[a, b]` is `a, b`, `*[]` vanishes) and the call is then an
    # ordinary one, which codegen_call folds as such (`o[*[:k]]` is GETIDX, `a.-(*[1])` SUBI). The arguments of +node+ with
    # those splats replaced, or its arguments flattened by #literal_splat_arguments, or +node+ itself.
    def flatten_literal_splats(node)
      return node if node.name == :[]= || node.block || node.arguments.nil?

      flat = literal_splat_arguments(node.arguments.arguments)
      return node unless flat

      node.copy(arguments: flat.empty? ? nil : node.arguments.copy(arguments: flat))
    end

    # The arguments with each splatted literal array of leaves replaced by its elements, or nil when some argument is a splat
    # of anything else (or a keyword, block or forwarding argument), when no splat is a literal array or when there are more
    # than 14 values.
    def literal_splat_arguments(args)
      return nil if args.any? { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::BlockArgumentNode) || a.is_a?(Prism::ForwardingArgumentsNode) }

      found = false
      flat = []
      args.each do |a|
        a = unparen(a)
        if a.is_a?(Prism::SplatNode)
          v = a.expression && unparen(a.expression)
          return nil unless v.is_a?(Prism::ArrayNode) && v.opening_loc&.slice == '[' && v.elements.none?(Prism::SplatNode) &&
                            v.elements.all? { |e| operand?(e) }

          found = true
          flat.concat(v.elements)
        else
          flat << a
        end
      end
      found && flat.size <= 14 ? flat : nil
    end

    def index_splat_assign?(node)
      node.name == :[]= && node.receiver && node.call_operator_loc.nil? && node.block.nil? &&
        node.arguments&.arguments&.any?(Prism::SplatNode) && node.arguments.arguments.none?(Prism::KeywordHashNode)
    end

    def self_receiver?(node) = node.receiver && unparen(node.receiver).is_a?(Prism::SelfNode)

    # Whether +node+ may be a call's receiver or argument: a leaf, an array of leaves, or a call (checked when generated).
    def operand?(node)
      node = unparen(node)
      SIMPLE_VALUES.include?(node.class) || node.is_a?(Prism::CallNode) || node.is_a?(Prism::ItLocalVariableReadNode) || node.is_a?(Prism::YieldNode) || node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode) || node.is_a?(Prism::ConstantPathNode) || node.is_a?(Prism::LambdaNode) || BUILT_VALUES.include?(node.class) ||
        node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) || node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode) ||
        node.is_a?(Prism::SingletonClassNode) || node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::WhileNode) || node.is_a?(Prism::UntilNode) || node.is_a?(Prism::DefNode) || node.is_a?(Prism::ParenthesesNode) || node.is_a?(Prism::CaseNode) || node.is_a?(Prism::MatchRequiredNode) || node.is_a?(Prism::MatchPredicateNode) || node.is_a?(Prism::CaseMatchNode) || node.is_a?(Prism::BeginNode) || node.is_a?(Prism::RescueModifierNode) || VALUE_WRITES.include?(node.class) || ((node.is_a?(Prism::RangeNode) || node.is_a?(Prism::FlipFlopNode)) && [node.left, node.right].all? { |e| e.nil? || operand?(e) }) ||
        (node.is_a?(Prism::ArrayNode) && (symbol_list?(node) || node.elements.all? { |e| operand?(e) || array_splat?(e) })) || node.is_a?(Prism::SourceEncodingNode)
    end

    # %i[...] and %I[...]: the words are symbols or interpolated symbols, built by symbol_word_into.
    def symbol_list?(node)
      node.opening_loc&.slice&.match?(/\A%[iI]/) &&
        node.elements.all? { |e| e.is_a?(Prism::SymbolNode) || e.is_a?(Prism::InterpolatedSymbolNode) }
    end

    # Generates an operand into register +dst+ with the stack pointer at +dst+ (everything above it is free), as the fork
    # pushes an operand and generates it into the new top of the stack.
    def operand_into(node, dst)
      # The fork stamps each node with its own line, so after a heredoc body's expression an operand on an earlier line goes
      # back to that line; only strings (which set their own line) are covered after one.

      saved = @sp
      @sp = dst
      value_into(node, dst)
    ensure
      @sp = saved
    end

    # Symbols are numbered in order of first use, as the fork's new_sym does.
    def sym_index(name)
      index = @syms.index(name) || (@syms << name).size - 1

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
        enter(node)
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
      when Prism::IntegerNode then integer_into(node, dst)
      when Prism::FloatNode then float_into(node, dst)
      when Prism::SourceFileNode, Prism::SourceLineNode, Prism::SourceEncodingNode then source_into(node, dst)
      when Prism::NumberedReferenceReadNode, Prism::BackReferenceReadNode
        emit(:GETGV, dst, sym_index(special_variable_name(node)))
      when Prism::DefinedNode then built_into(dst) { |base| defined_at(node, base) }
      when Prism::RationalNode, Prism::ImaginaryNode then built_into(dst) { |base| numeric_call_at(node, base) }
      when Prism::LocalVariableReadNode
        node.depth.zero? ? emit(:MOVE, dst, local_register(node.name)) : getupvar(dst, node)
      when Prism::StringNode
        # A heredoc of several lines is a literal per line, concatenated (dstr_into).
        if NIL_HEREDOCS[node] then emit(:LOADNIL, dst)
        elsif node.opening&.start_with?('<<') then dstr_into(node, dst)
        else
          raise Unsupported, 'multibyte character literal' if node.opening == '?' && !node.content.ascii_only? # the fork's lexer reads one byte

          emit(@frozen_strings ? :FSTRING : :STRING, dst, pool_index([:str, node.unescaped.b]))
        end
      when Prism::SymbolNode then emit(:LOADSYM, dst, sym_index(node.unescaped.to_sym))
      when Prism::ConstantReadNode then emit(:GETCONST, dst, sym_index(node.name))
      when Prism::ItLocalVariableReadNode
        result = call(it_call(node))
        emit(:MOVE, dst, result) unless result == dst
      when Prism::GlobalVariableReadNode then emit(:GETGV, dst, sym_index(node.name))
      when Prism::InstanceVariableReadNode then emit(:GETIV, dst, sym_index(node.name))
      when Prism::ClassVariableReadNode then emit(:GETCV, dst, sym_index(node.name))
      when Prism::FloatNode then emit(:LOADL, dst, float_index(node))
      when Prism::NumberedReferenceReadNode then emit(:GETGV, dst, sym_index(:"$#{node.number}"))
      when Prism::BackReferenceReadNode then emit(:GETGV, dst, sym_index(node.name))
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
      when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::ForNode, Prism::WhileNode, Prism::UntilNode
        # A class, module or singleton class body as a value (milestone 12): built at the first temporary like a begin block.
        @line = node.location.start_line if !@hold_line && !node.is_a?(Prism::ForNode) && !node.is_a?(Prism::WhileNode) && !node.is_a?(Prism::UntilNode) # a class node is entered at its keyword line (milestone 14)
        saved = @sp
        base = dst >= @nlocals ? dst : temp
        begin
          @sp = base
          r = statement(node, last: true)
        ensure
          @sp = saved
        end
        gen_move(dst, r, false)
      when Prism::BeginNode, Prism::RescueModifierNode, Prism::ParenthesesNode
        # A begin block as a value: built at the destination when it is a temporary, else at the first temporary and moved.
        saved = @sp
        base = dst >= @nlocals ? dst : temp
        begin
          @sp = base
          r = statement(node, last: true)
          # A local variable read last in a body is read in place (a return folds the MOVE away); as a value the fork emits
          # the MOVE into the temporary (gen_lvar, no peephole), which later moves must not fold.
          if r && r < @nlocals
            emit(:MOVE, base, r)
            r = base
          end
        ensure
          @sp = saved
        end
        gen_move(dst, r, false)
      when Prism::ArrayNode then array_into(node, dst)
      when Prism::InterpolatedStringNode then dstr_into(node, dst)
      when Prism::XStringNode, Prism::InterpolatedXStringNode, Prism::InterpolatedSymbolNode then built_into(dst) { |base| small_node_at(node, base) }
      when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode, Prism::MatchLastLineNode, Prism::InterpolatedMatchLastLineNode then built_into(dst) { |base| regex_at(node, base) }
      when Prism::HashNode then built_into(dst) { |base| hash_at(node, base) }
      when Prism::SourceEncodingNode then built_into(dst) { |base| source_into(node, base) }
      when Prism::CallNode
        result = call(node)
        emit(:MOVE, dst, result) unless result == dst
      when Prism::ConstantPathNode
        result = colon_path(node)
        emit(:MOVE, dst, result) unless result == dst
      when Prism::CaseNode then case_value_into(node, dst)
      when Prism::DefNode
        result = def_statement(node, last: true)
        emit(:MOVE, dst, result) unless result == dst
      when Prism::MatchRequiredNode, Prism::MatchPredicateNode, Prism::CaseMatchNode then pattern_value_into(node, dst)
      when *VALUE_WRITES then write_value_into(node, dst)
      when Prism::RangeNode, Prism::FlipFlopNode then built_into(dst) { |base| range_at(node, base) }
      when Prism::LambdaNode
        # LAMBDA takes the child irep like BLOCK does; gen_move folds it straight into a local's register.
        @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_block(node, self)
        index = @children.size - 1
        
        @nregs = [@nregs, @sp + 1].max
        emit(:LAMBDA, dst, index)
      when Prism::DefinedNode
        built_into(dst) { |base| defined_yield(node, base) }
      when Prism::YieldNode
        result = yield_statement(node, last: true)
        emit(:MOVE, dst, result) unless result == dst
      when Prism::SuperNode, Prism::ForwardingSuperNode
        result = super_statement(node, last: true)
        emit(:MOVE, dst, result) unless result == dst
      when Prism::BreakNode, Prism::NextNode, Prism::ReturnNode, Prism::RedoNode
        # A jump as a value (`x || next`): the fork pushes its (never used) value in the register the jump was generated at.
        raise Unsupported, 'jump as a value away from its register' unless statement(node, last: true) == dst
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
      when Prism::StringNode, Prism::XStringNode
        # The fork's lexer reads one byte after `?` (a multibyte character is a syntax error there).
        raise Unsupported, 'multibyte character literal' if node.opening == '?' && !node.content.ascii_only?

        [[:lit, node.unescaped.b]]
      when Prism::InterpolatedStringNode, Prism::InterpolatedXStringNode, Prism::InterpolatedSymbolNode
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

    # A `<<A` heredoc with no body: the fork's parser gives it a nil value, not an empty string (the generated code differs).
    def empty_heredoc?(node)
      node = node && unparen(node)
      return false unless (node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode)) && node.opening_loc&.slice&.start_with?('<<')

      node.is_a?(Prism::StringNode) ? node.content.empty? : node.parts.empty?
    end

    # A heredoc body, as the fork's parser splits it (heredoc_string_interp): one literal per source line, the text of a line
    # before an interpolation as a literal of its own (empty when the line starts with it), and the rest of the line, newline
    # included, after it. Prism joins the lines between two interpolations, so they are split again at the newlines of the
    # text (heredoc_chunks, which also decodes the escapes: a line is one literal, an escaped newline does not end it).
    def heredoc_parts(node)
      pieces = node.is_a?(Prism::StringNode) ? [node] : node.parts
      raw = node.opening.include?("'")
      squiggly = node.opening.start_with?('<<~')
      # Prism leaves a backslash-newline between two pieces out of both: a gap means a continuation.
      continued = lambda do |list|
        heredoc_gap(list.last, node.closing_loc).include?("\\\n") ||
          list.any? { |x| x.content_loc.slice.end_with?("\\\n") } ||
          list.each_cons(2).any? { |a, b| heredoc_gap(a, b).include?("\\\n") }
      end
      return squiggly_continued_parts(pieces, raw) if squiggly && pieces.all?(Prism::StringNode) && continued.call(pieces)

      parts = []
      acc = [] # [text, closed] per line so far; a line is open until its source newline (an escaped one does not close it)
      add = lambda do |chunks|
        chunks.each do |c, closed|
          if acc.last && !acc.last[1]
            acc.last[0] << c
            acc.last[1] = closed
          else acc << [c.dup, closed]
          end
        end
      end
      flush = lambda do |before_expr|
        acc << [''.b, true] if before_expr && (acc.empty? || acc.last[1])
        acc.each { |l, _| parts << [:lit, l] }
        acc = []
      end
      prev = nil
      nested_line = nil # the line of the last interpolation that holds a heredoc
      pieces.each do |part|
        # A gap before a piece is a nested heredoc's body, or a continuation after an interpolation (indentation not covered).
        if squiggly && prev && heredoc_gap(prev, part).include?("\\\n") && !(prev.is_a?(Prism::EmbeddedStatementsNode) && nested_heredoc_ends_at([prev]))
          raise Unsupported, 'continuation after an interpolation in a squiggly heredoc'
        end

        prev = part
        case part
        when Prism::StringNode then add.call(heredoc_chunks(part, raw, squiggly))
        when Prism::EmbeddedVariableNode then add.call([[part.location.slice.b, false]])
        when Prism::EmbeddedStatementsNode
          body = part.statements&.body || []
          raise Unsupported, 'interpolation with several statements' if body.size > 1
          flush.call(true)
          e = body[0] && unparen(body[0])
          # An empty heredoc in a heredoc body has the value nil in the fork's parser, but only the first heredoc of a line: the
          # ones after it on the same line are empty strings (verified with mrbc -v).
          nested_heredocs(e).each do |h|
            NIL_HEREDOCS[h] = true if empty_heredoc?(h) && nested_line != h.location.start_line
            nested_line = h.location.start_line
          end
          parts << [:expr, e]
        else raise Unsupported, "interpolated part #{part.class.name.split('::').last}"
        end
      end
      flush.call(false)
      parts << [:lit, ''.b] if parts.empty?
      # A heredoc interpolated on the last line of a heredoc leaves one more, empty, literal (verified with mrbc -v).
      parts << [:lit, ''.b] if nested_heredoc_ends_at(pieces) == node.closing_loc&.start_offset
      parts
    end

    # A squiggly heredoc with a backslash before a newline: the fork's lexer reads the lines joined by it as one literal. It
    # counts and removes indentation (heredoc_count_indent and heredoc_remove_indent: a tab counts 8, the smallest indentation
    # of the non-blank lines is removed from every line, a blank one included, as far as it goes) at the logical lines' heads
    # only in a raw heredoc, and at each physical line otherwise. Prism dedents every physical line (and counts the joined
    # ones in a raw heredoc), so the text is cut here from the source.
    def squiggly_continued_parts(pieces, raw)
      first = pieces.first.content_loc.start_offset
      body = pieces.first.content_loc.send(:source).source.b.byteslice(first, pieces.last.content_loc.end_offset - first)
      chunks = body.scan(/(?:\\.|[^\\\n])*\n|(?:\\.|[^\\\n])+/mn)
      raise Unsupported, 'heredoc ending in a continuation' if chunks.last.end_with?("\n") && !real_newline?(chunks.last)

      segments = chunks.map { |c| raw ? [c] : c.scan(/(?:\\[^\n]|[^\\\n])*(?:\\\n|\n|\z)/mn).reject(&:empty?) }
      width = lambda do |seg|
        total = 0
        seg.each_byte do |b|
          break unless [0x20, 0x09, 0x0b, 0x0c, 0x0d].include?(b)

          total += b == 0x09 ? 8 : 1
        end
        total
      end
      counted = segments.reject { |segs| segs.last.match?(/\A[ \t\v\f\r]*\n?\z/n) }.flatten
      indent = counted.map(&width).min || 0
      segments.map do |segs|
        text = segs.map do |seg|
          limit = [width.call(seg), indent].min
          used = 0
          cut = 0
          seg.each_byte do |b|
            break unless [0x20, 0x09, 0x0b, 0x0c, 0x0d].include?(b)

            size = b == 0x09 ? 8 : 1
            break if used + size > limit

            used += size
            cut += 1
          end
          seg.byteslice(cut..)
        end.join
        [:lit, heredoc_decode(text, raw)]
      end
    end

    # The source text between two consecutive pieces of a heredoc (the indentation Prism dedents, a backslash-newline, or a
    # nested heredoc's body).
    def heredoc_gap(first, second)
      loc = ->(x) { x.respond_to?(:content_loc) && x.content_loc ? x.content_loc : (x.respond_to?(:location) ? x.location : x) }
      from = loc.call(first).end_offset
      loc.call(first).send(:source).source.b.byteslice(from, [loc.call(second).start_offset - from, 0].max)
    end

    # The heredoc literals in +node+ (an interpolated expression), in source order.
    def nested_heredocs(node)
      return [] unless node

      found = heredoc_string?(node) ? [node] : []
      node.compact_child_nodes.each { |c| found.concat(nested_heredocs(c)) }
      found.sort_by { |h| h.location.start_offset }
    end

    # The end offset of the last nested heredoc terminator inside the interpolations of +pieces+, or nil.
    def nested_heredoc_ends_at(pieces)
      ends = []
      walk = lambda do |n|
        ends << n.closing_loc.end_offset if heredoc_string?(n) && n.closing_loc
        n.compact_child_nodes.each(&walk)
      end
      pieces.each { |p| walk.call(p) if p.is_a?(Prism::EmbeddedStatementsNode) }
      ends.max
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

      # Every node the fork generates stamps the line it was parsed on, so the code of an expression in a heredoc body is on
      # that body's line, and so is the rest of the string and of the statement after it. In a quoted string the expression's
      # own nodes set their lines as they are entered.
      if node && @in_heredoc
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
      heredoc = heredoc_string?(node)

      string_parts(node).each do |kind, v|
        next unless kind == :expr && v

        raise Unsupported, 'interpolation operand' unless interpolation_operand?(v)

        if heredoc
          @line_moved = true if @line != v.location.start_line
          @line = v.location.start_line
        end
        statement(v, last: false)
      end
    end

    # An unused interpolated regexp (codegen_regx without a value): only the embedded expressions are evaluated, in order.
    def regex_unused(node)
      node.parts.each do |part|
        next unless part.is_a?(Prism::EmbeddedStatementsNode)

        body = part.statements&.body || []
        raise Unsupported, 'interpolation with several statements' if body.size > 1
        next if body.empty?

        v = unparen(body[0])
        raise Unsupported, 'interpolation operand' unless interpolation_operand?(v)

        statement(v, last: false)
      end
    end

    def heredoc_string?(node) = node.respond_to?(:opening) && node.opening&.start_with?('<<')

    # gen_string with a value: the first part is loaded into the base register, each further part into the next one and
    # STRCATed onto the base. Under `# frozen_string_literal: true` a string of literals only is one FSTRING of the
    # concatenated bytes (gen_frozen_string).
    def dstr_into(node, dst)
      heredoc = heredoc_string?(node)

      parts = string_parts(node)
      # The node's own line, as every node the fork generates: the line it ends on (a quoted string spanning lines, or
      # adjacent literals, is built when the parser reaches the end), for a heredoc the `<<` line.
      line = heredoc ? node.location.start_line : line_of(node)
      @line_moved = true if heredoc && @line != line
      @line = @zero_nodes&.key?(node) ? 0 : line
      if @frozen_strings && parts.all? { |kind, _| kind == :lit }
        return emit(:FSTRING, dst, pool_index([:str, parts.map(&:last).join.b]))
      end

      # A single literal is a plain string load, folded into a local like any other (gen_move).
      return emit(:STRING, dst, pool_index([:str, parts[0][1]])) if parts.size == 1

      saved = @in_heredoc
      @in_heredoc = heredoc
      begin
        built_into(dst) { |base| dstr_at(parts, base) }
      ensure
        @in_heredoc = saved
      end
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

    # ---- milestone 12 (small nodes): backtick strings and interpolated symbols ----

    # `cmd` and `a#{x}` are a string built as a quoted one is (gen_string) and sent to self as `Kernel.` (SSEND with the string
    # as the only argument, the result in the string's base minus one); :"a#{x}" is such a string INTERNed. Unused, a backtick
    # string is still sent (its string and call are generated), an interpolated symbol generates nothing but its operands.
    def small_node_at(node, base)
      raise Unsupported, 'heredoc backtick string' if heredoc_string?(node)
      raise Unsupported, 'symbol without delimiters' if node.is_a?(Prism::InterpolatedSymbolNode) && node.opening_loc.nil?

      parts = string_parts(node)
      @line = line_of(node)
      if node.is_a?(Prism::InterpolatedSymbolNode)
        # no literal after a last expression, except in a `"a#{x}": v` label (the parser builds that one as a string)
        parts.pop if parts.size > 1 && parts.last[0] == :lit && parts.last[1].empty? && node.closing_loc&.slice != '":'
        parts.size == 1 ? emit(:STRING, base, pool_index([:str, parts[0][1]])) : dstr_at(parts, base)
        return emit(:INTERN, base)
      end
      reach(base + 3)
      if parts.size == 1
        emit(:STRING, base + 1, pool_index([:str, parts[0][1]]))
      else
        dstr_at(parts, base + 1)
      end
      emit(:SSEND, base, sym_index(:`), 1)
    end

    def small_unused(node)
      case node
      when Prism::XStringNode, Prism::InterpolatedXStringNode then small_node_at(node, temp)
      when Prism::InterpolatedSymbolNode then string_unused(node)
      end
    end

    # ---- milestone 12: for loops (codegen_for) ----

    # `for v in obj; body; end` is `obj.each` with a block whose scope has no locals of its own: the loop variable and every
    # local of the body live in the enclosing scope and are reached as upvalues. The block takes one parameter (ENTER 0x40000,
    # register 1), which is stored in the variable (SETUPVAR) before a NOP (the redo target) and the body. Only a single
    # local variable as the loop variable, a one-line header and a body without redo/retry are covered.
    def for_statement(node, last:)
      var = node.index
      raise Unsupported, 'for with a loop variable other than a local' unless for_variable_ok?(var)

      coll = unparen(node.collection)
      raise Unsupported, 'for over a non-operand' unless operand?(coll)
      raise Unsupported, 'multi-line for header' if node.collection.location.end_line != node.location.start_line || var.location.start_line != node.location.start_line

      for_check_body(node.statements)
      t = temp
      @line = node.location.start_line
      operand_into(coll, t)
      child = Compiler.new(@filename, frozen_strings: @frozen_strings)
      child.instance_variable_set(:@zero_end, @zero_nodes&.key?(node))
      @children << child.send(:compile_for, node, self)
      index = @children.size - 1
      
      reach(t + 2)
      emit(:BLOCK, t + 1, index)
      emit(:SENDB, t, sym_index(:each), 0)
      last ? t : nil
    end

    # The loop variables covered: a local, an instance or a global variable, and a list of locals (the fork destructures it like
    # a block's `|a, b|`: AREF and SETUPVAR per variable; a rest or post-required target is not covered).
    def for_variable_ok?(var)
      case var
      when Prism::LocalVariableTargetNode, Prism::InstanceVariableTargetNode, Prism::GlobalVariableTargetNode then true
      when Prism::SplatNode then var.expression.nil? || (!var.expression.is_a?(Prism::MultiTargetNode) && for_variable_ok?(var.expression))
      when Prism::MultiTargetNode
        rest = var.rest.is_a?(Prism::ImplicitRestNode) ? nil : var.rest
        (var.lefts + var.rights).all? { |t| for_variable_ok?(t) } && (rest.nil? || for_variable_ok?(rest))
      else false
      end
    end

    # The loop variable as the fork's grammar reads it: redundant parentheses (`for ((a, *b)) in`) are the same list, and a
    # list of one target with a trailing comma (`for a, in`) is that target.
    def for_normalize(var)
      loop do
        return var unless var.is_a?(Prism::MultiTargetNode)

        rest = var.rest.is_a?(Prism::ImplicitRestNode) ? nil : var.rest
        return var unless var.lefts.size == 1 && rest.nil? && var.rights.empty?

        var = var.lefts[0]
      end
    end

    # Every local target of the loop variable lives one scope further out (see FOR_SHIFT).
    def for_shift_targets(var)
      case var
      when Prism::LocalVariableTargetNode then FOR_SHIFT.call(var)
      when Prism::SplatNode then for_shift_targets(var.expression) if var.expression
      when Prism::MultiTargetNode
        (var.lefts + [var.rest] + var.rights).each { |t| for_shift_targets(t) if t && !t.is_a?(Prism::ImplicitRestNode) }
      end
    end

    def compile_for(node, parent)
      @parent = parent
      @loops = [BLOCK_LOOP] # LOOP_FOR: break, next and return act as in a block
      set_locals([])
      @sp += 1 # the block parameter
      @nregs = [@nregs, @sp].max
      @line = node.location.start_line
      emit(:ENTER, 0x40000)
      var = for_normalize(node.index)
      FOR_DEPTH.call(node.statements, 0) if node.statements
      case var
      when Prism::InstanceVariableTargetNode then emit(:SETIV, 1, sym_index(var.name))
      when Prism::GlobalVariableTargetNode then emit(:SETGV, 1, sym_index(var.name))
      when Prism::MultiTargetNode, Prism::SplatNode
        # gen_massignment(var, 1, VAL): AREF for each leading target, then APOST on a copy of the argument for the splat and the
        # trailing targets, and a final MOVE of the argument (the statement's value) after a splat. Redundant parentheses
        # (`for ((a, *b)) in`) are the same list, and `for a, in` is `for a in`.
        for_shift_targets(var)
        lefts, rest, rights = var.is_a?(Prism::SplatNode) ? [[], var, []] : [var.lefts, var.rest, var.rights]
        rest = nil if rest.is_a?(Prism::ImplicitRestNode)
        lefts.each_with_index do |t, i|
          @nregs = [@nregs, @sp + 1].max
          emit(:AREF, @sp, 1, i)
          assign_target(t, @sp, @sp + 1)
        end
        if rest || !rights.empty?
          gen_move(@sp, 1, true)
          @nregs = [@nregs, @sp + rights.size + 1].max
          emit(:APOST, @sp, lefts.size, rights.size)
          assign_target(rest.expression, @sp, @sp) if rest&.expression
          rights.each_with_index { |r, i| assign_target(r, @sp + 1 + i, @sp) }
          gen_move(@sp, 1, false)
        end
      else
        FOR_SHIFT.call(var)
        idx, lv = upvar_operands(var.name, var.depth)
        emit(:SETUPVAR, 1, idx, lv)
      end
      emit(:NOP)
      stmts = body_statements(node.statements)
      if stmts.empty?
        # An empty body is RETNIL on the line of the closing `end` (milestone 14, verified); a `;` before it is not covered.
        check_empty_gap(node.do_keyword_loc || node.collection.location, node.end_keyword_loc)
        @line = @zero_end ? 0 : node.end_keyword_loc.start_line
        @nregs = [@nregs, @sp + 1].max
        emit(:RETNIL)
        return self
      end

      return_value(generate(stmts, val: true))
      self
    end

    # The locals the body reads and writes belong to the scopes outside the for, one level further out than Prism counts them
    # (it does not see the for as a scope): a variable +level+ blocks deep is shifted when its depth reaches outside the for.
    FOR_SHIFT = lambda do |node|
      depth = node.depth + 1 # a nested for shifts the same node again
      node.singleton_class.send(:remove_method, :depth) if node.singleton_methods.include?(:depth)
      node.define_singleton_method(:depth) { depth }
    end

    FOR_DEPTH = lambda do |node, level|
      case node
      when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        raise Unsupported, 'definition inside a for body'
      when Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode,
           Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
        FOR_SHIFT.call(node) if node.depth >= level
      when Prism::ItLocalVariableReadNode, Prism::NumberedParametersNode, Prism::ItParametersNode
        raise Unsupported, 'implicit block parameter inside a for body' if level.zero?
      end
      inner = node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode) ? level + 1 : level
      node.compact_child_nodes.each { |c| FOR_DEPTH.call(c, inner) }
    end

    def for_check_body(stmts)
      return unless stmts

      walk = lambda do |n|
        case n
        when Prism::RedoNode, Prism::RetryNode
          raise Unsupported, 'redo or retry inside a for body'
        end
        n.compact_child_nodes.each(&walk)
      end
      walk.call(stmts)
    end

    # An interpolated regexp's pattern (the pre-gen_string interpolation path, kept for regexps): the first literal part is a STRING, and each interpolated value is loaded into the
    # next register and STRCATed, followed by the literal part after it (empty when another interpolation or the end
    # follows: the fork always appends it).
    def regex_dstr_at(node, base, regex: true)
      segments = [''.b]
      values = []
      node.parts.each do |part|
        case part
        when Prism::StringNode
          segments.last << (regex ? regex_text(part.content, node) : part.unescaped.b)
        when Prism::EmbeddedVariableNode then segments.last << part.location.slice.b # `#@a` is plain text to the fork
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
          raise Unsupported, 'regexp escape' if nxt.nil?

          if nxt == '/' && slash
            out << '/'
          elsif !slash && (nxt == node.opening_loc.slice[-1] || nxt == node.closing_loc.slice[0])
            out << nxt # an escaped delimiter loses its backslash (milestone 12)
          elsif nxt == "\n" # a continuation inside a regexp is dropped (verified with mrbc -v)
            nil
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
      # A regexp is built when the parser reaches its closing slash and flags, so the node carries its end line; a pattern
      # with interpolations has the lines of its expressions to follow (not covered).
      raise Unsupported, 'regexp encoding' if node.euc_jp? || node.windows_31j?

      @line = (@zero_nodes&.key?(node) ? 0 : line_of(node)) unless @hold_line # the literal is a node of its own (verified: `a\n  .scan(/y/)` stamps line 3)

      sym = sym_index(:Regexp)
      emit(:OCLASS, base)
      emit(:GETMCNST, base, sym)
      if node.is_a?(Prism::RegularExpressionNode) || node.is_a?(Prism::MatchLastLineNode)
        emit(:STRING, base + 1, pool_index([:str, regex_text(node.content, node)]))
      elsif node.parts.none?(Prism::EmbeddedStatementsNode) # only `#@a` and the like: plain text to the fork
        text = node.parts.map { |part| part.is_a?(Prism::StringNode) ? regex_text(part.content, node) : part.location.slice.b }.join.b
        emit(:STRING, base + 1, pool_index([:str, text]))
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
      hash_elements_at(node.elements, base, node.closing_loc.start_line)
    end

    # codegen_hash (value used): key and value registers are pushed pair by pair; a `**splat` flushes the pairs before it into
    # a HASH (or HASHADD onto the hash built so far), generates the splatted value and HASHCATs it. The pairs left over at the
    # end are a HASH, or a HASHADD when a splat came before. The register stack is walked here as the fork's pushes and pops do.
    def hash_elements_at(elements, base, close_line)
      sp = base
      regular = 0
      update = false
      first = true
      elements.each do |e|
        case e
        when Prism::AssocSplatNode
          raise Unsupported, 'anonymous keyword splat' unless e.value

          if first
            emit(:HASH, sp, 0)
            sp += 1
            update = true
          elsif regular.positive?
            sp -= regular * 2
            if update
              sp -= 1
              emit(:HASHADD, sp, regular)
            else
              emit(:HASH, sp, regular)
            end
            sp += 1
          end
          hash_operand(e.value, sp)
          sp += 1
          if regular.positive? || update
            sp -= 2
            emit(:HASHCAT, sp)
            sp += 1
          end
          update = true
          regular = 0
        when Prism::AssocNode
          assoc_key_line(e, e.equal?(elements.last) ? close_line : nil)
          hash_operand(e.key, sp)
          hash_operand(e.value, sp + 1)
          sp += 2
          regular += 1
        else raise Unsupported, 'hash element'
        end
        first = false
      end
      if elements.empty?
        emit(:HASH, base, 0)
      elsif regular.positive?
        sp -= regular * 2
        if update
          sp -= 1
          emit(:HASHADD, sp, regular)
        else
          emit(:HASH, sp, regular)
        end
      end
    end

    # The line of a pair's key: for `label: value` the parser builds the key symbol after the value (assoc: tIDENTIFIER
    # tLABEL_TAG arg), so it carries the line the parser had reached then, the value's end line (verified with mrbc -v: in
    # `{\n  a: 1,\n  b: {\n    c: 2,\n  },\n}` the :b is on line 5). A `key => value` pair's key is built first and keeps its own
    # line, provided the `=>` follows it on that line. A `a:` with no value is built at the lookahead token, which must be on its line.
    def assoc_key_line(pair, last_close_line = nil)
      key = pair.key
      if pair.operator_loc # `key => value`
        raise Unsupported, 'hash pair split over lines' if pair.operator_loc.start_line != key.location.end_line
      elsif pair.value.is_a?(Prism::ImplicitNode)
        # The lookahead is the comma after it (same line), or for the last pair the token after the pair, which may be a
        # trailing comma or the closing bracket on a later line: only the one-line case is covered.
        if last_close_line && last_close_line != key.location.end_line
          raise Unsupported, 'last hash pair without a value ending a line'
        end
      else
        @leading_dot[key] = pair.value.location.end_line
      end
    end

    # One key or value of a hash literal, generated at register +reg+ (the fork pushes it there). `{a:}` has an implicit value:
    # the local or method named by the key.
    def hash_operand(node, reg)
      node = node.value if node.is_a?(Prism::ImplicitNode)
      raise Unsupported, 'hash element' unless operand?(node)

      operand_into(unparen(node), reg)
      @nregs = [@nregs, reg + 1].max
    end

    # An array literal of leaf values: the elements are loaded from the first temporary on. ARRAY takes that register as
    # its destination; otherwise ARRAY2 takes the destination and the register of the first element (codegen.c, NODE_ARRAY).
    def array_into(node, dst)
      elems = node.elements
      return array_splat_into(node, dst) if elems.any?(Prism::SplatNode)

      symbols = node.opening_loc&.slice&.match?(/\A%[iI]/) # %i and %I: symbols built from pool strings (symbol_word_into)
      raise Unsupported, 'array element' unless symbols || elems.all? { |e| operand?(e) }
      a = temp
      # codegen_array flushes the elements built so far (ARRAY, then ARYPUSH) when the stack reaches 64, or 99 above 64.
      if elems.size > 1 && a + elems.size - 1 >= (a >= 64 ? 99 : 64)
        return array_literal_chunked(node, dst, symbols) if node.opening_loc&.slice&.start_with?('%')

        return array_splat_into(node, dst)
      end
      # The elements of %w and %i are strings and symbols the fork does not enter (gen_literal_array): the line stays that of
      # the array node.
      literal_words = node.opening_loc&.slice&.start_with?('%')
      saved_hold = @hold_line
      @hold_line = true if literal_words
      elems.each_with_index { |e, i| word_into(e, a + i, node, symbols) }
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

    # gen_literal_array of a %w, %W, %i or %I list too long for one register window: the same flushing as codegen_array.
    def array_literal_chunked(node, dst, symbols)
      a = temp
      saved_hold = @hold_line
      @hold_line = true
      sp = a
      count = 0
      first = true
      slimit = a >= 64 ? 99 : 64
      node.elements.each do |e|
        if sp >= slimit && count.positive?
          sp -= count
          if first
            emit(:ARRAY, sp, count)
            first = false
          else
            sp -= 1
            emit(:ARYPUSH, sp, count)
          end
          sp += 1
          count = 0
        end

        word_into(e, sp, node, symbols)
        @nregs = [@nregs, sp + 1].max
        sp += 1
        count += 1
      end
      @hold_line = saved_hold
      if first
        emit(:ARRAY, a, count)
      elsif count.positive?
        emit(:ARYPUSH, a, count)
      end
      gen_move(dst, a, false)
    end

    # codegen_array with a splat: the elements before the first splat are an ARRAY (an empty one, built with a LOADNIL before it,
    # when the splat is first), each splatted value is ARYCATed on, and the elements after a splat are ARYPUSHed. The result is
    # in the first temporary. An empty literal `*[]` is skipped; the stack walks as the fork's pushes and pops do.
    def array_splat_into(node, dst)
      elems = node.elements
      raise Unsupported, 'splat in a %w array' if node.opening_loc&.slice&.start_with?('%')

      base = dst >= @nlocals ? dst : temp
      sp = base
      regular = 0
      first = true
      slimit = base >= 64 ? 99 : 64 # codegen_array's GEN_LIT_ARY_MAX, raised once when it starts above it
      elems.each do |e|
        splat = e.is_a?(Prism::SplatNode)
        v = splat ? e.expression : e
        raise Unsupported, 'anonymous splat' unless v

        v = unparen(v)
        next if splat && v.is_a?(Prism::ArrayNode) && v.elements.empty? && v.opening_loc&.slice == '['

        raise Unsupported, 'array element' unless operand?(v)

        if !splat && sp >= slimit && regular.positive? # flush the accumulated elements
          sp -= regular
          if first
            emit(:ARRAY, sp, regular)
            first = false
          else
            sp -= 1
            emit(:ARYPUSH, sp, regular)
          end
          sp += 1
          regular = 0
        end
        if splat
          if regular.positive?
            sp -= regular
            if first
              emit(:ARRAY, sp, regular)
              first = false
            else
              sp -= 1
              emit(:ARYPUSH, sp, regular)
            end
            sp += 1
            regular = 0
          elsif first
            emit(:LOADNIL, sp)
            emit(:ARRAY, sp, 0)
            sp += 1
            first = false
          end
        end

        operand_into(v, sp)
        sp += 1
        if splat
          sp -= 2
          emit(:ARYCAT, sp)
          sp += 1
        else
          regular += 1
        end
      end
      if first
        sp -= regular
        emit(:ARRAY, sp, regular)
      elsif regular.positive?
        sp -= regular + 1
        emit(:ARYPUSH, sp, regular)
      end
      gen_move(dst, base, false)
    end

    # An element of %i or %I (gen_literal_array with sym, gen_string and gen_intern): a plain word is a STRING that gen_intern
    # rewrites to SYMBOL; a word with interpolation is built as a string is and then INTERNed. The pieces are those of a
    # quoted string (a leading literal, then an expression and a literal after it), except that the literal after a last
    # expression is dropped when a space, not the closing bracket, ends the word (verified with mrbc -v on %I[a#{1} b] and
    # %I[a#{1}]).
    def symbol_word_into(elem, reg, array, intern: true)
      case elem
      when Prism::SymbolNode
        emit(:SYMBOL, reg, pool_index([:str, elem.unescaped.b]))
      when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
        parts = [[:lit, ''.b]]
        elem.parts.each do |part|
          case part
          when Prism::StringNode then parts.last[1] << part.unescaped.b
          when Prism::EmbeddedVariableNode then parts.last[1] << part.location.slice.b # `#@a` is plain text to the fork
          when Prism::EmbeddedStatementsNode
            body = part.statements&.body || []
            raise Unsupported, 'interpolation with several statements' if body.size > 1
            parts << [:expr, body[0] && unparen(body[0])] << [:lit, ''.b]
          else raise Unsupported, "symbol list part #{part.class.name.split('::').last}"
          end
        end
        parts.pop if parts.last[0] == :lit && parts.last[1].empty? && parts.size > 1 && parts[-2][0] == :expr &&
                     elem.location.end_offset != array.closing_loc.start_offset
        if parts.size == 1 && intern # only `#@a` texts: a plain word
          emit(:SYMBOL, reg, pool_index([:str, parts[0][1]]))
          return
        end
        word_dstr_at(parts, reg)
        emit(:INTERN, reg) if intern
      else raise Unsupported, "symbol list element #{elem.class.name.split('::').last}"
      end
    end

    # Pool entries are deduplicated in order of first use, as the fork's new_lit_int does.
    def pool_index(i)
      index = @pool.index(i) || (@pool << i).size - 1

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
      wide = wide_operands(name, operands)
      @code << OP.fetch(name)
      case name
      when :ENTER then byte((operands[0] >> 16) & 0xff); short(operands[0] & 0xffff)
      when :LOADI16 then wide ? short(operands[0]) : byte(operands[0]); short(operands[1])
      when :LOADI32 then wide ? short(operands[0]) : byte(operands[0]); short(operands[1] >> 16); short(operands[1] & 0xffff)
      when :BLKPUSH, :ARGARY then wide ? short(operands[0]) : byte(operands[0]); short(operands[1])
      else operands.each_with_index { |v, i| wide && i < 2 && v > 0xff ? short(v) : byte(v) }
      end
      track(operands.first) unless %i[STOP ENTER ALIAS UNDEF].include?(name) # ENTER's operand is an argument spec; ALIAS and UNDEF take symbols
      track(operands[1]) if name == :MOVE
      record_lines(@code.size - start)
    end

    # milestone 13 (wide operands): genop_1/genop_2 prefix EXT1, EXT2 or EXT3 when the first and/or second operand of a B, BB
    # or BBB instruction exceeds 0xff (the operand is then a big-endian short). Returns whether any operand is wide.
    def wide_operands(name, operands)
      return false if %i[ENTER STOP].include?(name)

      a = operands[0].is_a?(Integer) && operands[0] > 0xff
      b = operands[1].is_a?(Integer) && operands[1] > 0xff && !%i[LOADI16 LOADI32 BLKPUSH ARGARY].include?(name) # their second operand is an S/SS one
      return false unless a || b

      @code << OP.fetch(a && b ? :EXT3 : (b ? :EXT2 : :EXT1))
      true
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

    # ---- parameters (milestone 11): def, block and lambda ----

    # lambda_body's argument processing for a def, a block or a lambda. The registers are self, then the required parameters
    # (a destructuring one is an unnamed slot), the optional ones, the rest (`*` when anonymous), the post-required ones, the
    # keyword dictionary slot (the `**rest`'s name, `**` when anonymous or when there are only keywords), the hidden block
    # slot (no name), the block parameter (`&` when anonymous), the keywords (the required ones first, then the optional ones),
    # the variables of destructuring parameters (marg_names), and the body's own locals in the parser's order. `...` is `*`,
    # `**` and `&`; a numbered parameter block takes +numbered+ required parameters. ENTER takes the aspec in its 24 bits:
    # req << 18 | opt << 13 | rest << 12 | post << 7 | keywords << 2 | kwrest << 1 | block (ops.h, MRB_ARGS_*), then the
    # optional parameters' jump table, the keywords, the copy of the block slot into the block parameter's register and the
    # destructuring (AREF) of the required and then the post-required parameters.
    def parameters(params, node_locals, line, numbered: 0)
      requireds = numbered.zero? && params ? params.requireds : []
      optionals = params ? params.optionals : []
      posts = params ? params.posts : []
      keywords = params ? params.keywords : []
      rest = params&.rest
      rest = nil if rest.is_a?(Prism::ImplicitRestNode) # `|a,|` adds nothing
      keyword_rest = params&.keyword_rest
      block = params&.block
      forwarding = keyword_rest.is_a?(Prism::ForwardingParameterNode)
      raise Unsupported, 'rest parameter' unless rest.nil? || rest.is_a?(Prism::RestParameterNode)
      raise Unsupported, 'keyword rest parameter' unless keyword_rest.nil? || forwarding ||
                                                          keyword_rest.is_a?(Prism::KeywordRestParameterNode)
      raise Unsupported, 'destructuring parameter' unless (requireds + posts).all? { |r| plain_or_marg?(r) }
      raise Unsupported, 'parameter kind' unless optionals.all?(Prism::OptionalParameterNode) &&
                                                  keywords.all? { |k| k.is_a?(Prism::RequiredKeywordParameterNode) || k.is_a?(Prism::OptionalKeywordParameterNode) }
      raise Unsupported, 'too many parameters' if [requireds, optionals, posts, keywords].any? { |l| l.size > 0x1f } || numbered > 0x1f

      rest_name = forwarding ? :* : (rest && (rest.name || :*))
      kwrest_name = forwarding ? :** : (keyword_rest && (keyword_rest.name || :**))
      nil_block = block.is_a?(Prism::BlockParameterNode) && block.name == NIL_BLOCK_NAME.to_sym
      block_name = forwarding ? :& : (block && !nil_block ? (block.name || :&) : nil)
      required_names = numbered.positive? ? (1..numbered).map { |i| :"_#{i}" } : requireds.map { |r| r.is_a?(Prism::MultiTargetNode) ? nil : r.name }
      pre = required_names + optionals.map(&:name)
      pre << rest_name if rest_name
      pre += posts.map { |r| r.is_a?(Prism::MultiTargetNode) ? nil : r.name }
      pre << (kwrest_name || :**) if kwrest_name || !keywords.empty?
      kw_names = (keywords.grep(Prism::RequiredKeywordParameterNode) + keywords.grep(Prism::OptionalKeywordParameterNode)).map(&:name)
      # The fork's parser declares the keywords only after the whole list: a default that names one reads a method call.
      keywords = keywords.map { |k| k.is_a?(Prism::OptionalKeywordParameterNode) ? kw_default_vcalls(k, kw_names) : k }
      margs = (requireds + posts).grep(Prism::MultiTargetNode)
      marg_vars = margs.flat_map { |m| marg_names(m) }
      named = pre + [block_name] + kw_names + marg_vars
      # The required keywords are declared as they are read, an optional one once its default is parsed: the locals that default
      # assigns come first (verified: `d: (u = 1), e:` declares e, u, d).
      required_kw = keywords.grep(Prism::RequiredKeywordParameterNode).map(&:name)
      optional_kw = keywords.grep(Prism::OptionalKeywordParameterNode).flat_map { |k| (assigned_locals(k.value) & node_locals) + [k.name] }
      default_locals = (optional_kw - kw_names).uniq - named
      set_locals(pre + [nil] + [block_name].compact + required_kw + optional_kw.uniq + marg_vars +
                 (node_locals - named - default_locals - (nil_block ? [block.name] : [])))
      @nregs = @nlocals + 1
      @line = line
      aspec = ((numbered.positive? ? numbered : requireds.size) << 18) | (optionals.size << 13) | ((rest_name ? 1 : 0) << 12) |
              (posts.size << 7) | (keywords.size << 2) | ((kwrest_name ? 1 : 0) << 1) | (block_name ? 1 : 0) | (nil_block ? 1 << 23 : 0)
      emit(:ENTER, aspec)
      @ainfo = method_ainfo(requireds.size + optionals.size, rest_name, posts.size, keywords.empty? && !kwrest_name ? [] : [nil], block_name)
      method_optionals(optionals) unless optionals.empty?
      method_keywords(keywords, pre.size, kwrest_name) unless keywords.empty?
      emit(:MOVE, local_register(block_name), pre.size + 1) if block_name
      requireds.each_with_index { |r, i| destructure_parameter(r, i + 1) if r.is_a?(Prism::MultiTargetNode) }
      first_post = requireds.size + optionals.size + (rest_name ? 1 : 0) + 1
      posts.each_with_index { |r, i| destructure_parameter(r, first_post + i) if r.is_a?(Prism::MultiTargetNode) }
    end

    # milestone 13 (keyword defaults): the fork's parser declares the keyword parameters only after the whole list, so a
    # default that names one (`def m(a: 1, b: a)`) reads a method call on self, where Prism has a local variable read. The
    # reads of this scope's keywords are rebuilt as calls; a write, a read inside a nested scope, or a name an enclosing scope
    # has as a local (the parser would read that one) is Unsupported.
    def kw_default_vcalls(param, names)
      return param unless reads_local?(param.value, names)

      value = vcall_rewrite(param.value, names)
      raise Unsupported, 'keyword default that reads a keyword parameter' if reads_local?(value, names)
      raise Unsupported, 'keyword default that reads a keyword parameter' if (scope = @parent) && names.any? { |n| scope_has_local?(scope, n) }

      param.copy(value: value)
    end

    def scope_has_local?(scope, name)
      while scope
        return true if scope.locals.include?(name)

        scope = scope.parent
      end
      false
    end

    def vcall_rewrite(node, names)
      return node unless node.is_a?(Prism::Node)

      case node
      when Prism::LocalVariableReadNode
        return node unless node.depth.zero? && names.include?(node.name)

        return Prism::CallNode.new(node.send(:source), -1, node.location, 0, nil, nil, node.name, node.location, nil, nil, nil, nil, nil)
      when Prism::BlockNode, Prism::LambdaNode, Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        return node
      end
      changes = {}
      node.deconstruct_keys(nil).each do |key, v|
        case v
        when Prism::Node
          nv = vcall_rewrite(v, names)
          changes[key] = nv unless nv.equal?(v)
        when Array
          nv = v.map { |e| vcall_rewrite(e, names) }
          changes[key] = nv unless nv.zip(v).all? { |a, b| a.equal?(b) }
        end
      end
      changes.empty? ? node : node.copy(**changes)
    end

    # The names of the locals of this scope that +node+ assigns (a nested scope's are its own).
    def assigned_locals(node)
      return [] if node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::DefNode)

      own = node.class.name.match?(/\APrism::LocalVariable(Write|Target|OperatorWrite|OrWrite|AndWrite)Node\z/) && node.depth.zero? ? [node.name] : []
      own + node.compact_child_nodes.flat_map { |c| assigned_locals(c) }
    end

    # Whether +node+ holds a read or write of a local variable named in +names+.
    def reads_local?(node, names)
      return true if node.class.name.start_with?('Prism::LocalVariable') && node.respond_to?(:name) && names.include?(node.name)

      node.compact_child_nodes.any? { |c| reads_local?(c, names) }
    end

    # A required parameter, or a destructuring one whose targets are names or nested destructuring, with a rest (named or
    # anonymous) and post-required targets (the fork generates no code for those at the top level and APOST below it).
    def plain_or_marg?(node)
      case node
      when Prism::RequiredParameterNode then true
      when Prism::MultiTargetNode
        return false unless node.rest.nil? || (node.rest.is_a?(Prism::SplatNode) &&
                                               (node.rest.expression.nil? || node.rest.expression.is_a?(Prism::RequiredParameterNode)))

        (node.lefts + node.rights).all? { |t| plain_or_marg?(t) }
      else false
      end
    end

    # The names the parser gives a destructuring parameter's variables (level by level: the level's targets in order, an
    # unnamed placeholder for a nested destructuring, then each nested one's own names; an anonymous `*` is named `*`).
    def marg_names(marg)
      level = marg.lefts.dup
      level << marg.rest if marg.rest
      level += marg.rights
      names = level.map do |t|
        case t
        when Prism::MultiTargetNode then nil
        when Prism::SplatNode then t.expression ? t.expression.name : :*
        else t.name
        end
      end
      names + level.grep(Prism::MultiTargetNode).flat_map { |m| marg_names(m) }
    end

    # The destructuring of a required parameter held in register +src+ (lambda_body): each leading target is read with AREF
    # into the first temporary and assigned (gen_assignment, which folds the AREF into the variable's register); a nested
    # destructuring is read the same way and destructured from that temporary (codegen_masgn). The top level generates nothing
    # for a rest or post-required target; a nested one copies the array to the next register and splits it with APOST (leading
    # count, post count): a named rest and the post targets are then assigned from there (an anonymous rest is not assigned,
    # and without a named rest or post targets there is no APOST).
    def destructure_parameter(marg, src, top: true)
      marg.lefts.each_with_index do |t, i|
        sp = @sp
        @nregs = [@nregs, sp + 1].max
        emit(:AREF, sp, src, i)
        if t.is_a?(Prism::MultiTargetNode)
          saved = @sp
          @sp = sp + 1
          begin
            destructure_parameter(t, sp, top: false)
          ensure
            @sp = saved
          end
        else
          gen_move(local_register(t.name), sp, false)
        end
      end
      return if top

      named = marg.rest.is_a?(Prism::SplatNode) && marg.rest.expression
      return unless named || !marg.rights.empty?

      dst = @sp
      post = marg.rights.size
      gen_move(dst, src, false)
      @nregs = [@nregs, dst + post + 1].max
      emit(:APOST, dst, marg.lefts.size, post)
      gen_move(local_register(marg.rest.expression.name), dst, false) if named
      marg.rights.each_with_index do |t, i|
        if t.is_a?(Prism::MultiTargetNode)
          destructure_parameter(t, dst + 1 + i, top: false)
        else
          gen_move(local_register(t.name), dst + 1 + i, false)
        end
      end
    end

    # `foo(*)`, `foo(**)` and `foo(&)` read the enclosing method's anonymous parameters, which the parser names `*`, `**` and
    # `&`: a read of that local, an upvalue from inside a block. The node is built here with the position of the argument.
    def anonymous_local(name, at)
      anonymous_line!(at)
      depth = 0
      scope = self
      until scope.locals.include?(name)
        scope = scope.parent or raise Unsupported, "no anonymous #{name} parameter"
        depth += 1
      end
      Prism::LocalVariableReadNode.new(at.send(:source), -1, at.location, 0, name, depth)
    end

    # The parser builds the read of an anonymous parameter at the token after the `*`, `**`, `&` or `...`: its line is that
    # token's, so an anonymous argument that ends its line is not covered.
    def anonymous_line!(at)
      rest = at.send(:source).source.byteslice(at.location.end_offset..) || ''
      raise Unsupported, 'anonymous argument at the end of a line' if rest.match?(/\A[ \t]*(\n|#|\z)/)
    end

    # `foo(a, ...)` passes `*`, `**` and `&` of the enclosing method on, as `foo(a, *, **, &)` does. Returns the arguments with
    # those in place of the `...`, and the block argument.
    def forwarding_arguments(node)
      args = node.arguments&.arguments || []
      fwd = args.last
      return [args, node.block] unless fwd.is_a?(Prism::ForwardingArgumentsNode)
      raise Unsupported, 'forwarding after keywords' if args.any?(Prism::KeywordHashNode)

      anonymous_line!(fwd)
      src = fwd.send(:source)
      loc = fwd.location
      splat = Prism::SplatNode.new(src, -1, loc, 0, loc, nil)
      keywords = Prism::KeywordHashNode.new(src, -1, loc, 0, [Prism::AssocSplatNode.new(src, -1, loc, 0, nil, loc)])
      [args[0...-1] + [splat, keywords], Prism::BlockArgumentNode.new(src, -1, loc, 0, nil, loc)]
    end

    # `it` in a block is a call of the method `it` (no implicit parameter in the fork's parser).
    def it_call(node)
      Prism::CallNode.new(node.send(:source), -1, node.location, 0, nil, nil, :it, node.location, nil, nil, nil, nil, nil)
    end

    # ---- milestone 11: operators, float literals and special defs ----

    UNARY_OPS = %i[-@ +@ ~].freeze
    SELF_SEND_OPS = %i[!= % << >> ** & | ^ <=> =~ !~ === ~ ! +@ -@].freeze
    FOLD_OPS = %i[+ - * / % << >> & | ^].freeze
    INT64_MIN = -0x8000_0000_0000_0000
    INT64_MAX = 0x7fff_ffff_ffff_ffff

    # mrb_num_shift (numeric.c) on 64-bit integers: the shifted value, or nil when the fork does not fold it.
    def num_shift(val, width)
      if width.negative?
        -width >= 63 ? (val.negative? ? -1 : 0) : val >> -width
      elsif val.positive?
        return nil if width > 63 || val > (INT64_MAX >> width)

        val << width
      else
        return nil if width > 63 || val < (INT64_MIN >> width)

        width == 63 ? INT64_MIN : val * (1 << width)
      end
    end

    def int64(v) = v.between?(INT64_MIN, INT64_MAX) ? v : nil

    # The value of a two-literal operation as the fork folds it (gen_addsub, gen_muldiv, gen_binop), or nil.
    def fold_value(name, n0, n)
      case name
      when :+ then int64(n0 + n)
      when :- then int64(n0 - n)
      when :* then int64(n0 * n)
      when :/ then n.zero? ? nil : int64(n0.div(n))
      when :% then n.zero? ? nil : n0 % n
      when :<< then num_shift(n0, n)
      when :>> then num_shift(n0, -n)
      when :& then n0 & n
      when :| then n0 | n
      when :^ then n0 ^ n
      end
    end

    # gen_int of a folded value, in place of the instructions starting at +start+.
    def fold_load(start, n, dst)
      truncate(start)
      gen_int(n, dst)
    end

    # The fork's gen_int: the shortest load of +i+; a value beyond 32 bits is a pool entry (new_lit_int).
    def gen_int(i, dst)
      if i.negative?
        if i == -1 then emit(:LOADI__1, dst)
        elsif i >= -0xff then emit(:LOADINEG, dst, -i)
        elsif i >= -0x8000 then emit(:LOADI16, dst, i & 0xffff)
        elsif i >= INT32_MIN then emit(:LOADI32, dst, i & 0xffff_ffff)
        else emit(:LOADL, dst, pool_index([:int, i]))
        end
      elsif i <= INT32_MAX
        load_int(i, dst)
      else
        emit(:LOADL, dst, pool_index([:int, i]))
      end
    end

    # An integer literal: a value of 32 bits is a load; a larger one is a big integer pool entry of its digits (as the lexer
    # kept them, without sign, prefix or underscores) and base, the base negated for a negative literal (codegen NODE_BIGINT
    # and codegen_negate).
    def integer_into(node, dst)
      v = node.value
      return load_int(v, dst) if v.between?(INT32_MIN + 1, INT32_MAX) || (v == INT32_MIN && !node.location.slice.match?(/\A-?0[xXbBoOdD_0-9]/)) # -0x8000_0000 keeps its base

      text = node.location.slice.delete('_')
      neg = text.start_with?('-')
      text = text.sub(/\A[-+]/, '')
      base = 10
      if (m = /\A0([xXbBoOdD])(.*)\z/.match(text))
        base = { 'x' => 16, 'b' => 2, 'o' => 8, 'd' => 10 }.fetch(m[1].downcase)
        text = m[2]
      elsif text.size > 1 && text.start_with?('0')
        base = 8
        text = text[1..]
      end
      text = text.downcase # the lexer keeps hexadecimal letters in lower case
      raise Unsupported, 'integer literal too big' if text.size > 255

      emit(:LOADL, dst, pool_index([:bigint, text, neg ? -base : base]))
    end

    # The operation of a binary call whose operands are generated into +a+ and +a+ + 1, when the fork's peepholes handle it
    # (true: nothing more to emit): two integer loads in a row are folded (gen_addsub, gen_muldiv, gen_binop), and + and -
    # with an integer load last become ADDI and SUBI (gen_addsub).
    def binary_folded(name, a)
      return false unless FOLD_OPS.include?(name)

      if !no_peephole? && @insns.size >= 2 && !@labels.include?(@insns[-1][2]) && (n = int_operand(@insns[-1])) &&
         (n0 = int_operand(@insns[-2]))
        r = fold_value(name, n0, n)
        if r
          fold_load(@insns[-2][2], r, a)
          @nregs = [@nregs, a + 3].max
          return true
        end
      end
      return false unless name == :+ || name == :-

      # Two string literals are merged by `+` (merge_op_string), unless the first one is a label: the start of the code or the pc after ENTER (lastlabel starts at 0 and the parameter code marks one there).
      if name == :+ && !no_peephole? && @insns.size >= 2 && @insns[-1][0] == :STRING && @insns[-2][0] == :STRING &&
         !@labels.include?(@insns[-1][2]) && !@labels.include?(@insns[-2][2]) && @insns[-2][2] != 0 && !(@enter_label && @insns[-3] && @insns[-3][0] == :ENTER)
        merge_strings(a)
        @nregs = [@nregs, a + 3].max
        return true
      end

      add_sub(name, a)
      @nregs = [@nregs, a + 3].max
      true
    end

    # gen_uniop: when the last instruction is an integer load, the operator is applied to it at compile time (whatever
    # register it loads: a call on self has no receiver of its own, and the fork folds the load before it).
    def unary_folded(name, a)
      return false if no_peephole? || !(n = int_operand(@insns.last))

      raise Unsupported, 'negated INT64_MIN' if name == :-@ && n == INT64_MIN

      n = { :-@ => -n, :+@ => n, :~ => ~n }.fetch(name)
      fold_load(@insns.last[2], n, a)
      @nregs = [@nregs, a + 2].max
      true
    end

    # `-x`, `+x`, `~x` and their method-call forms. A `-x` without a dot is the fork's NODE_NEGATE (codegen_negate): a numeric
    # literal operand is negated at compile time (and nothing at all is generated when the value is unused); anything else is
    # generated, folded when it ended in an integer load (gen_uniop) and sent with a plain SEND of no arguments. `+x`, `~x`
    # and `x.-@` are ordinary calls, with SEND0.
    def unary_call(node, recv, a, need)
      name = node.name
      negate = name == :-@ && node.call_operator_loc.nil?
      if negate && !node.receiver.is_a?(Prism::ParenthesesNode) && !recv.location.slice.start_with?('-') &&
         (recv.is_a?(Prism::IntegerNode) || recv.is_a?(Prism::FloatNode) || recv.is_a?(Prism::SourceLineNode))
        return a unless need

        if recv.is_a?(Prism::FloatNode)
          emit(:LOADL, a, pool_index([:float, float_bits(recv, negate: true)]))
        else
          v = recv.is_a?(Prism::SourceLineNode) ? recv.location.start_line : recv.value # __LINE__ is an integer literal
          raise Unsupported, 'negated integer literal beyond 32 bits' unless v.abs < INT32_MAX

          load_int(-v, a)
        end
        return a
      end
      operand_into(recv, a)
      if node.safe_navigation? # `a&.-@`: the send is skipped for nil and never folded (verified)
        skip = safe_jump(a, need)
        emit(:SEND0, a, sym_index(name))
        dispatch(skip)
        @nregs = [@nregs, a + 2].max
        return a
      end
      return a if unary_folded(name, a)

      sym = sym_index(name)
      negate ? emit(:SEND, a, sym, 0) : emit(:SEND0, a, sym)
      @nregs = [@nregs, a + 2].max
      a
    end

    # ---- float literals: read_float (above) is mrb_read_float; the pool entry is IREP_TT_FLOAT, 8 bytes little endian ----

    # The 8 bytes of a float literal's pool entry (the value negated for a negative literal, which the fork negates).
    def float_bits(node, negate: false)
      text = node.location.slice
      neg = text.start_with?('-')
      f = read_float(text.sub(/\A[-+]/, ''))
      f = -f if neg != negate
      [f].pack('E')
    end

    def float_into(node, dst)
      emit(:LOADL, dst, pool_index([:float, float_bits(node)]))
    end

    # The names a `def` may have: plain names, predicates and bangs, setters and the operators.
    DEF_OPERATORS = %i[== != === =~ !~ [] []= + - * / % ** << >> & | ^ ~ ! < <= > >= <=> +@ -@ !@ ~@ `].freeze
    def def_name_ok?(name)
      name.to_s.match?(/\A[A-Za-z_]\w*[?!=]?\z/) || DEF_OPERATORS.include?(name)
    end

    # ---- alias, undef, the special variables, __FILE__ and __LINE__, defined? ----

    # gen_load_nil(s, val): the value of alias and undef is nil, loaded only when it is used.
    def nil_value(last)
      return nil unless last

      t = temp
      emit(:LOADNIL, t)
      t
    end

    def static_symbol(node)
      raise Unsupported, 'alias or undef of a dynamic symbol' unless node.is_a?(Prism::SymbolNode)

      node.unescaped.to_sym
    end

    # codegen_alias: both names' symbols are numbered (new first), then ALIAS takes the two indexes.
    def alias_statement(node, last:)
      a = sym_index(static_symbol(node.new_name))
      b = sym_index(static_symbol(node.old_name))
      @line = 0 if @zero_nodes&.key?(node)
      emit(:ALIAS, a, b)
      nil_value(last)
    end

    # codegen_undef: one UNDEF per name.
    def undef_statement(node, last:)
      node.names.each { |n| emit(:UNDEF, sym_index(static_symbol(n))) }
      nil_value(last)
    end

    # `$1`, `$&` and the like (codegen_nth_ref, codegen_back_ref) are reads of the global of that name.
    def special_variable_name(node)
      node.is_a?(Prism::NumberedReferenceReadNode) ? :"$#{node.number}" : node.name
    end

    SPECIAL_READS = [Prism::NumberedReferenceReadNode, Prism::BackReferenceReadNode].freeze

    # codegen_str of the file name, and the line number as an integer load.
    def source_into(node, dst)
      if node.is_a?(Prism::SourceFileNode)
        emit(@frozen_strings ? :FSTRING : :STRING, dst, pool_index([:str, @filename.b]))
      elsif node.is_a?(Prism::SourceEncodingNode)
        @line = node.location.end_line unless @hold_line
        emit(:SSEND0, dst, sym_index(:__ENCODING__)) # a call of that name on self
        @nregs = [@nregs, dst + 2].max
      else
        load_int(node.location.start_line, dst)
      end
    end

    # The pushes of the fork's helpers for `defined?`: nregs counts the highest stack pointer they reach.
    def reach(sp)
      @nregs = [@nregs, sp].max
    end

    # codegen_defined_push_str.
    def defined_str(r, str)
      emit(:STRING, r, pool_index([:str, str.b]))
    end

    # codegen_defined_bool_to_str: the boolean in +r+ becomes +str+ or nil.
    def defined_bool_to_str(r, str)
      skip = emit_jump(:JMPNOT, r)
      defined_str(r, str)
      done = emit_jump(:JMP)
      dispatch(skip)
      emit(:LOADNIL, r)
      dispatch(done)
    end

    DEFINED_STRINGS = { Prism::NilNode => 'nil', Prism::TrueNode => 'true', Prism::FalseNode => 'false',
                        Prism::SelfNode => 'self', Prism::LocalVariableReadNode => 'local-variable' }.freeze
    DEFINED_ASSIGNMENTS = [Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::GlobalVariableWriteNode,
                           Prism::ConstantWriteNode, Prism::ClassVariableWriteNode,
                           Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
                           Prism::GlobalVariableOperatorWriteNode, Prism::ConstantOperatorWriteNode,
                           Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode,
                           Prism::GlobalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
                           Prism::InstanceVariableAndWriteNode, Prism::GlobalVariableAndWriteNode, Prism::MultiWriteNode,
                           Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
                           Prism::ClassVariableOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
                           Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode,
                           Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode].freeze
    DEFINED_EXPRESSIONS = [Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode,
                           Prism::RegularExpressionNode, Prism::AndNode, Prism::OrNode, Prism::SourceFileNode,
                           Prism::SourceLineNode, Prism::ArrayNode, Prism::HashNode, Prism::ParenthesesNode,
                           Prism::IfNode, Prism::UnlessNode, Prism::InterpolatedStringNode, Prism::RangeNode,
                           Prism::LambdaNode, Prism::InterpolatedRegularExpressionNode, Prism::BeginNode,
                           Prism::WhileNode, Prism::CaseNode, Prism::ReturnNode, Prism::NumberedReferenceReadNode,
                           Prism::BackReferenceReadNode].freeze

    # `defined?(expr)` as a value in register +r+ (codegen_defined): the argument is never evaluated; what the fork answers is
    # decided by the node kind. Constants (a catch handler) and the rest are not covered.
    def defined_at(node, r)
      expr = node.value
      raise Unsupported, 'defined? without an argument' unless expr

      case expr
      when *DEFINED_STRINGS.keys then defined_str(r, DEFINED_STRINGS.fetch(expr.class))
      when *DEFINED_ASSIGNMENTS then defined_str(r, 'assignment')
      when *DEFINED_EXPRESSIONS then defined_str(r, 'expression')
      when Prism::InstanceVariableReadNode
        defined_self_send(r, :instance_variable_defined?, expr.name)
        defined_bool_to_str(r, 'instance-variable')
      when Prism::GlobalVariableReadNode
        defined_gvar(r, expr.name)
        defined_bool_to_str(r, 'global-variable')
      when Prism::ClassVariableReadNode
        defined_cvar(r, expr.name)
        defined_bool_to_str(r, 'class variable')
      when Prism::ConstantReadNode, Prism::ConstantPathNode then defined_const(expr, r)
      when Prism::YieldNode
        reach(r + 2)
        emit(:SSEND0, r, sym_index(:block_given?))
        reach(r + 1)
        defined_bool_to_str(r, 'yield')
      when Prism::SuperNode, Prism::ForwardingSuperNode
        emit(:LOADNIL, r)
      when Prism::CallNode
        # `-x` is a NODE_NEGATE to the fork, which answers like any other expression.
        return defined_str(r, 'expression') if expr.name == :-@ && expr.call_operator_loc.nil?
        # An attribute or index assignment is an assignment node to the fork.
        return defined_str(r, 'assignment') if expr.name.to_s.end_with?('=') && !%i[== === != <= >=].include?(expr.name)

        defined_respond_to(expr, r)
        defined_bool_to_str(r, 'method')
      else raise Unsupported, "defined? of #{expr.class.name.split('::').last}"
      end
    end

    # codegen_defined_const: the constant read, run inside a catch handler (rescue with no filtering); "constant" or nil.
    def defined_const(expr, r)
      entry = new_catch
      from = @code.size
      saved = @sp
      @sp = r
      value_into(expr, r)
      @sp = saved
      to = @code.size
      success = emit_jump(:JMP)
      @catches[entry] = [0, from, to, @code.size]
      emit(:EXCEPT, r)
      emit(:LOADNIL, r)
      done = emit_jump(:JMP)
      dispatch(success)
      defined_str(r, 'constant')
      dispatch(done)
    end

    # codegen_defined_respond_to: `recv.respond_to?(:name, true)` (SSEND without a receiver) is run, never the method.
    def defined_respond_to(call, r)
      recv = call.receiver && unparen(call.receiver)
      noself = recv.nil? || recv.is_a?(Prism::SelfNode)
      raise Unsupported, 'defined? of a call on a non-operand receiver' unless noself || operand?(recv)

      reach(r + 1)
      saved = @sp
      @sp = r
      operand_into(recv, r) unless noself
      @sp = saved
      emit(:LOADSYM, r + 1, sym_index(call.name))
      emit(:LOADTRUE, r + 2)
      reach(r + 4)
      emit(noself ? :SSEND : :SEND, r, sym_index(:respond_to?), 2)
    end

    # codegen_defined_self_send1_sym: `self.method(:sym)` for an instance variable.
    def defined_self_send(r, method, arg)
      emit(:LOADSYM, r + 1, sym_index(arg))
      reach(r + 3)
      emit(:SSEND, r, sym_index(method), 1)
    end

    # codegen_defined_gvar: `global_variables.include?(:$name)`.
    def defined_gvar(r, name)
      reach(r + 2)
      emit(:SSEND0, r, sym_index(:global_variables))
      emit(:LOADSYM, r + 1, sym_index(name))
      reach(r + 3)
      emit(:SEND, r, sym_index(:include?), 1)
    end

    # codegen_defined_cvar: `__defined_cvar_scope.class_variable_defined?(:@@name)`.
    def defined_cvar(r, name)
      reach(r + 2)
      emit(:SSEND0, r, sym_index(:__defined_cvar_scope))
      emit(:LOADSYM, r + 1, sym_index(name))
      reach(r + 3)
      emit(:SEND, r, sym_index(:class_variable_defined?), 1)
    end

    # ---- Rational and Imaginary literals: the fork's parser turns `1r` into `Rational(1)` and `2i` into `Complex(0, 2)` ----

    # The literal inside a suffixed number (the digits of `1.5r` without the `r`), as an integer or a float load into +reg+.
    def numeric_literal_at(node, reg)
      text = node.location.slice
      text = text.delete_prefix('-') # the negation is a -@ send on the whole literal (numeric_call_at)
      text = text.delete_suffix('i') if node.is_a?(Prism::ImaginaryNode)
      text = text.delete_suffix('r')
      if text.match?(/[.eE]/) && !text.match?(/\A0[xX]/)
        raise Unsupported, 'rational literal with an exponent' if text.match?(/[eE]/)

        emit(:LOADL, reg, pool_index([:float, [read_float(text)].pack('E')]))
      else
        v = Integer(text.delete('_'))
        raise Unsupported, 'rational or imaginary literal beyond 32 bits' unless v <= INT32_MAX

        load_int(v, reg)
      end
    end

    # The call of Rational or Complex with its result in +a+ (an SSEND whose arguments follow it).
    def numeric_call_at(node, a, top: true)
      negative = top && node.location.slice.start_with?('-')
      reach(a + 1)
      if node.is_a?(Prism::RationalNode)
        numeric_literal_at(node, a + 1)
        argc = 1
        name = :Rational
      else
        emit(:LOADI_0, a + 1)
        inner = node.numeric
        case inner
        when Prism::RationalNode then numeric_call_at(inner, a + 2, top: false)
        when Prism::IntegerNode, Prism::FloatNode then numeric_literal_at(inner, a + 2)
        else raise Unsupported, 'imaginary literal'
        end
        argc = 2
        name = :Complex
      end
      emit(:SSEND, a, sym_index(name), argc)
      emit(:SEND, a, sym_index(:-@), 0) if negative
      reach(a + argc + 2)
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
    # milestone 13: `(a; b)` and `()`: statements like a begin block's, `()` a nil.
    def parentheses_statement(node, last:)
      stmts = node.body&.body || []
      if stmts.empty?
        return nil unless last

        t = temp
        emit(:LOADNIL, t)
        return t
      end
      generate(stmts, val: last)
    end

    def begin_statement(node, last:)
      rescue_c = node.rescue_clause
      else_c = node.else_clause
      ensure_c = node.ensure_clause
      raise Unsupported, 'else without rescue' if else_c && !rescue_c

      stmts = node.statements&.body || []
      ensure_stmts = ensure_c&.statements&.body || []
      if !rescue_c && ensure_stmts.empty?
        if stmts.empty?
          # An empty `begin; end` is a nil: loaded only where its value is used.
          kw = ensure_c ? ensure_c.ensure_keyword_loc : node.end_keyword_loc
          @line = node.begin_keyword_loc && kw ? empty_gap_line(node.begin_keyword_loc, kw, true) : (kw&.end_line || @line)
          return nil unless last

          t = temp
          emit(:LOADNIL, t)
          return t
        end

        return generate(stmts, val: last)
      end
      r = @sp
      @nregs = [@nregs, r + 1].max
      first_kw = rescue_c ? rescue_c.keyword_loc : (else_c ? else_c.else_keyword_loc : (ensure_c ? ensure_c.ensure_keyword_loc : node.end_keyword_loc))
      if stmts.empty?
        @line = first_kw.start_line # an empty body is a node on the line of the keyword after it
        check_empty_gap(node.begin_keyword_loc, first_kw) if node.begin_keyword_loc
      end
      clauses = []
      clause = rescue_c
      while clause
        # An empty clause body is a node on the line of the keyword after it.
        after = clause.subsequent ? clause.subsequent.keyword_loc : (else_c ? else_c.else_keyword_loc : (ensure_c ? ensure_c.ensure_keyword_loc : node.end_keyword_loc))
        body = clause.statements&.body || []
        check_empty_gap(clause.then_keyword_loc || clause.reference&.location || clause.exceptions.last&.location || clause.keyword_loc, after) if body.empty?
        clauses << RescueClause.new(clause.exceptions, clause.reference, body, after.start_line)
        clause = clause.subsequent
      end
      else_stmts = else_c ? (else_c.statements&.body || []) : nil
      else_end = ensure_c ? ensure_c.ensure_keyword_loc : node.end_keyword_loc
      else_line = else_end.start_line
      check_empty_gap(else_c.else_keyword_loc, else_end) if else_stmts&.empty?
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

    # The first keyword after the body of a begin node (rescue, else or ensure, or the end).
    def first_keyword(node)
      (node.rescue_clause ? node.rescue_clause.keyword_loc : nil) || node.else_clause&.else_keyword_loc ||
        node.ensure_clause&.ensure_keyword_loc || node.end_keyword_loc
    end

    # An empty body is a node the parser stamps with the line of the next keyword, unless a `;` came first: then it is the line
    # of the first `;` (verified: `foo do\n  ;\nend` is line 2). A `;` in a gap that spans lines is not covered (it may
    # also just end the keyword's own line).
    # A multi-line def or block with an empty body is covered when it has no backslash-newline and no `;` up to the end of its
    # header (a `;` after the header is check_empty_gap's: the line of the implicit nil is the `end`'s).
    def empty_body_continuation!(node, header)
      return if node.location.start_line == node.location.end_line

      text = node.location.slice.gsub(/^[ \t]*#[^\n]*/, '')
      head = node.location.copy(start_offset: node.location.start_offset, length: header.end_offset - node.location.start_offset).slice
      raise Unsupported, 'empty body after a continuation' if text.match?(/\\\n/) || head.gsub(/#[^\n]*/, '').include?(';')
    end

    # The line of the nil node of an empty body between +from_loc+ and +to_loc+ (the keyword that ends it): the fork builds it when
    # it reads the first token after the body's opener, a `;` or that keyword (the opener's own terminator, when it is not a
    # keyword, is consumed by the header: `if c` newline or `;`).
    def empty_gap_line(from_loc, to_loc, keyword_opener)
      gap = from_loc.copy(start_offset: from_loc.end_offset, length: to_loc.start_offset - from_loc.end_offset).slice
      gap = gap.gsub(/^=begin\b.*?^=end\b[^\n]*/m) { |m| m.gsub(/[^\n]/, ' ') }.gsub(/#[^\n]*/) { |m| ' ' * m.size }
      return to_loc.start_line unless gap.include?(';')

      i = 0
      unless keyword_opener
        i += 1 while gap[i] =~ /[ \t\r]/
        i += 1 if gap[i] == ';' || gap[i] == "\n"
      end
      i += 1 while gap[i] =~ /[ \t\r\n]/
      return to_loc.start_line unless gap[i] == ';'

      from_loc.end_line + gap[0, i].count("\n")
    end

    def check_empty_gap(from_loc, to_loc)
      return if from_loc.end_line == to_loc.start_line

      gap = from_loc.copy(start_offset: from_loc.end_offset, length: to_loc.start_offset - from_loc.end_offset).slice
      gap = gap.gsub(/^=begin\b.*?^=end\b[^\n]*/m, '').gsub(/#[^\n]*/, '') # a `;` inside a comment is not a token
      raise Unsupported, 'empty body with a semicolon' if gap.include?(';')
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

    # milestone 13: the fork's parser applies `a, b = expr rescue other` to the whole assignment (the targets are assigned inside
    # the rescued region and the rescue value is the statement's value), unlike Prism, which rescues the right side only.
    def masgn_rescue(node, last:)
      r = @sp
      @nregs = [@nregs, r + 1].max
      clauses = [RescueClause.new([], nil, [node.value.rescue_expression], node.location.end_line)]
      @masgn_plain = node
      rescue_region(r, [node], clauses, nil, nil, last)
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

            @line = ex.location.end_line if ex.is_a?(Prism::ConstantPathNode) # a path node is entered like the rest
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

    # ---- Block control flow (milestone 11) ----

    # The read of `recv[idx]` in an index operator assignment, as gen_binop does it: GETIDX0 fuses `MOVE t, local; LOADI_0 t+1`
    # (a local receiver and the index 0), a plain SEND replaces GETIDX when the code is at a jump target.
    # The LOOP_BLOCK entry that lambda_body pushes for a block or lambda body (a marker: it has no registers or jumps).
    BLOCK_LOOP = :block

    # The value of a `break` or `next` (gen_retval): a plain `break`/`next` loads nil; one value goes into the first temporary.
    def jump_value(node, t)
      args = node.arguments&.arguments
      # `next *a` is the plain value to the fork (codegen_next generates the splat node itself, with no ARYSPLAT; verified).
      if node.is_a?(Prism::NextNode) && args&.size == 1 && args[0].is_a?(Prism::SplatNode) && args[0].expression && operand?(args[0].expression)
        return operand_into(unparen(args[0].expression), t)
      end

      raise Unsupported, 'break or next with a value of an unverified form' if args&.size == 1 && !args[0].is_a?(Prism::SplatNode) && !operand?(args[0])

      args ? return_values_into(args, t) : emit(:LOADNIL, t)
    end

    # The value of a `return` (gen_retval): one value as it is, a splat as ARYSPLAT of the value, several values as an array
    # literal of them (single-line only: the fork's node lines for the list are not derived).
    def return_values_into(args, t)
      if args.size == 1 && !args[0].is_a?(Prism::SplatNode)
        value_into(unparen(args[0]), t)
      elsif args.size == 1
        v = args[0].expression
        raise Unsupported, 'anonymous splat' unless v && operand?(v)

        operand_into(unparen(v), t)
        emit(:ARYSPLAT, t)
      elsif args.any?(Prism::SplatNode)
        # milestone 13: several values with a splat are the fork's array literal of them (array_splat_into).
        array_splat_into(Struct.new(:elements, :opening_loc).new(args, nil), t)
      else
        raise Unsupported, 'return values of an unverified form' unless args.all? { |a| operand?(a) && !a.is_a?(Prism::SplatNode) }

        # past the stack limits of codegen_array the values are flushed in chunks (ARRAY, then ARYPUSH): the same code as a literal
        return array_splat_into(Struct.new(:elements, :opening_loc).new(args, nil), t) if args.size > 1 && t + args.size - 1 >= (t >= 64 ? 99 : 64)

        args.each_with_index { |e, i| operand_into(unparen(e), t + i) }
        @nregs = [@nregs, t + args.size].max
        emit(:ARRAY, t, args.size)
      end
    end

    # codegen_break in a block (loop_break, LOOP_BLOCK): the value goes into the first temporary and OP_BREAK returns it
    # from the block to the caller of the method the block was passed to (gen_return folds a MOVE into it).
    def block_break(node, last:)
      t = temp
      jump_value(node, t)
      return_value(t, :BREAK)
      last ? t : nil
    end

    # codegen_next in a block (not LOOP_NORMAL): the value goes into the first temporary and the block returns it; a plain
    # `next` is RETNIL.
    def block_next(node, last:)
      t = temp
      jump_value(node, t)
      return_value(t)
      last ? t : nil
    end

    # codegen_redo: JMPUW to the pc1 of the innermost loop that is not a begin or rescue one: in a block that is the start of
    # its code (lambda_body's label at pc 0), in a while or until the NOP that starts the body.
    def redo_statement(_node, last:)
      lp = @loops.last or raise Unsupported, 'redo outside a loop or block'
      jump = emit_jump(:JMPUW)
      patch_jump(jump, lp == BLOCK_LOOP ? 0 : (lp.pc1 or raise(Unsupported, 'redo in this loop')))
      last ? temp : nil
    end

    # s->ainfo of lambda_body for a method: (required + optional) << 7 | rest << 6 | post << 1 | keywords | block << 13.
    def method_ainfo(req_opt, rest, posts, keywords, block)
      ((req_opt & 0x3f) << 7) | ((rest ? 1 : 0) << 6) | ((posts & 0x1f) << 1) | (keywords.empty? ? 0 : 1) | ((block ? 1 : 0) << 13)
    end

    # The enclosing method scope of this (block) scope and the number of block scopes in between (the `lv` of codegen_yield and
    # codegen_super: the walk up to the first scope with mscope set). Only a def counts as one here: a yield or super outside
    # a method is a compile error in the fork.
    def inside_method?
      @in_method || @outer_in_method || @parent&.send(:inside_method?)
    end

    def method_scope(optional: false)
      scope = self
      lv = 0
      until scope.instance_variable_get(:@in_method)
        raise Unsupported, 'super in a class body inside a method' if scope.instance_variable_get(:@outer_in_method)

        scope = scope.parent
        # A super outside any method is generated with a nil block (codegen_super: no mscope found); a yield there is an error.
        return [nil, lv] if scope.nil? && optional
        raise Unsupported, 'yield outside a method' unless scope

        lv += 1
      end
      raise Unsupported, 'block nesting deeper than 15' if lv > 0xf

      [scope, lv]
    end

    # codegen_yield: the result register is pushed first, the arguments follow it (gen_values, gen_hash), then BLKPUSH loads
    # the method's block into the result register (operand: ainfo << 4 | lv, truncated to 16 bits) and BLKCALL calls it; a
    # splat or keywords use SEND :call with the packed argument count instead (a fast path only for plain positional arguments).
    def yield_statement(node, last:)
      scope, lv = method_scope
      a = @sp
      @nregs = [@nregs, a + 1].max
      args = node.arguments&.arguments || []
      argc, = gen_args(nil, a, args)
      emit(:BLKPUSH, a, ((scope.instance_variable_get(:@ainfo) << 4) | lv) & 0xffff)
      if argc < 15
        emit(:BLKCALL, a, argc)
      else
        emit(:SEND, a, sym_index(:call), argc)
      end
      last ? a : nil
    ensure
      @sp = a if a
    end

    # A literal block whose BLOCK goes into the register at @sp (the child irep is the next of this scope's children).
    def block_literal(blk)
      @children << Compiler.new(@filename, frozen_strings: @frozen_strings).compile_block(blk, self)
      index = @children.size - 1
      
      emit(:BLOCK, @sp, index)
      @nregs = [@nregs, @sp + 1].max
    end

    # gen_blkmove: the method's block slot (R[m1 + r + m2 + kd + 1], decoded from the ainfo bits) into the register at @sp;
    # from a block scope it is read with GETUPVAR (whose level operand is lv, not lv - 1).
    def block_move(ainfo, lv, no_method = false)
      return emit(:LOADNIL, @sp) if no_method # super outside a method: nil in place of the block

      off = ((ainfo >> 7) & 0x3f) + ((ainfo >> 6) & 1) + ((ainfo >> 1) & 0x1f) + (ainfo & 1) + 1
      lv.zero? ? gen_move(@sp, off, false) : emit(:GETUPVAR, @sp, off, lv)
    end

    # codegen_super (`super(a)`, `super a`, `super()`) and codegen_zsuper (bare `super`). Without arguments the method's own
    # parameters are passed: ARGARY builds them (and the block) from the method's ainfo, or, for a method with none, just the
    # block slot is copied; an explicit call generates its arguments as a send does and then the block (the `&blk` argument,
    # or the method's own block slot). SUPER takes the result register and the packed argument count. A literal block goes
    # into the register after the arguments (BLOCK), as in a call with a block.
    def super_statement(node, last:)
      literal = node.block.is_a?(Prism::BlockNode) ? node.block : nil
      scope, lv = method_scope(optional: true)
      ainfo = scope ? scope.instance_variable_get(:@ainfo) : 0
      a = @sp
      @nregs = [@nregs, a + 1].max
      pos = a + 1
      if node.is_a?(Prism::ForwardingSuperNode)
        n = 15
        if ainfo.positive?
          emit(:ARGARY, pos, ((ainfo << 4) | lv) & 0xffff)
          @nregs = [@nregs, pos + 3].max
          if ainfo.odd?
            n |= 15 << 4
            emit(:LOADNIL, pos + 2) if ainfo[13].zero?
          end
          @sp = pos + (ainfo.odd? ? 2 : 1) # push() for the block, whose register follows the keywords' slot
        else
          @sp = pos
          unless literal
            saved = @nregs
            block_move(0, lv, scope.nil?)
            @nregs = saved if scope.nil? # a bare super's LOADNIL pushes nothing
          end
          n = 0
        end
        block_literal(literal) if literal
      else
        blk = node.block
        raise Unsupported, 'anonymous block argument' if blk.is_a?(Prism::BlockArgumentNode) && !blk.expression

        n, = gen_args(nil, a, node.arguments&.arguments || [])
        if literal
          block_literal(literal)
        elsif blk
          operand_into(unparen(blk.expression), @sp)
        else
          block_move(ainfo, lv, scope.nil?)
        end
      end
      @sp = a
      emit(:SUPER, a, n)
      last ? a : nil
    ensure
      @sp = a if a
    end

    # `defined?(yield)` and `defined?(super)` (codegen_defined): block_given? is called on self (with the block-argument slot counted in nregs), JMPNOT
    # skips the string "yield" (STRING, never FSTRING) to a LOADNIL, as an if with a value.
    def defined_yield(node, dst)
      if node.value.is_a?(Prism::SuperNode) || node.value.is_a?(Prism::ForwardingSuperNode)
        # `defined?(super)` is nil: the fork does not determine the method context (codegen_defined, NODE_SUPER).
        @nregs = [@nregs, dst + 1].max
        return emit(:LOADNIL, dst)
      end
      raise Unsupported, 'defined? of something other than yield' unless node.value.is_a?(Prism::YieldNode)
      raise Unsupported, 'defined?(yield) away from its register' unless dst == @sp || dst < @nlocals

      method_scope # a yield outside a method is a compile error
      @nregs = [@nregs, dst + 2].max
      emit(:SSEND0, dst, sym_index(:block_given?))
      to_else = cond_jump(:JMPNOT, dst, val: true)
      emit(:STRING, dst, pool_index([:str, 'yield'.b]))
      to_end = emit_jump(:JMP)
      dispatch(to_else)
      emit(:LOADNIL, dst)
      dispatch(to_end)
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
        in [:int, v]
          # new_lit_int: IREP_TT_INT64 when it does not fit in 32 bits, else IREP_TT_INT32
          v.between?(INT32_MIN, INT32_MAX) ? [1, v & 0xffff_ffff].pack('CN') : [3, (v >> 32) & 0xffff_ffff, v & 0xffff_ffff].pack('CNN')
        in [:float, bits]
          [5].pack('C') + bits # IREP_TT_FLOAT: the double, little endian
        in [:str, bytes]
          # A string: tag 0, its length, its bytes and a NUL (dump.c's default case).
          [0].pack('C') + [bytes.bytesize].pack('n') + bytes + "\0".b
        end
      end
      [@pool.size].pack('n') + entries.join
    end

    # ---- milestone 13: pattern matching (codegen_case_match, codegen_pattern and NODE_MATCH_PAT in codegen.c) ----
    # The fork's parser builds PAT_* nodes (parse.y p_expr) and its codegen generates them directly, with no desugaring. Only
    # the pattern forms the fork's grammar has are covered: values (numbers, symbols, strings, nil, true, false, constants),
    # `x`, `^x`, `a | b`, `pat => x`, arrays with a rest, find patterns and hashes. Anything else is Unsupported.

    def pat_push = push_sp
    def pat_pop = @sp -= 1

    # The register count only grows with the stack pointer (push), not with an instruction's operands: the fork loads into
    # the stack top before pushing, and a register above the highest push (a value loaded for an EQ) is not counted.
    def pe(name, *ops)
      n = @nregs
      emit(name, *ops)
      @nregs = n
    end

    def pgi(i, dst)
      n = @nregs
      gen_int(i, dst)
      @nregs = n
    end

    def pgm(dst, src, nopeep)
      n = @nregs
      gen_move(dst, src, nopeep)
      @nregs = n
    end

    # A pattern as the fork's parser reads it: [:value, node], [:var, name], [:alt, l, r], [:as, pat, name], [:pin, name],
    # [:array, pre, rest, post], [:find, pre, elems, post], [:hash, pairs, rest] (rest nil, :nil, :any or [:var, name]).
    def pat_parse(node)
      case node
      when Prism::IntegerNode, Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::ConstantReadNode
        [:value, node]
      when Prism::StringNode
        # The fork's lexer returns tSTRING_BEG for a double-quoted string, never the tSTRING the grammar wants (a syntax error);
        # a single-quoted one (and %q) is a tSTRING: a plain value.
        raise Unsupported, 'pattern string' unless node.opening_loc && (node.opening_loc.slice == "'" || node.opening_loc.slice.start_with?('%q'))

        [:value, node]      when Prism::ConstantPathNode
        raise Unsupported, 'pattern constant path' unless pat_const_path?(node)

        [:value, node]
      when Prism::SymbolNode
        raise Unsupported, 'pattern symbol' unless (node.opening_loc&.slice == ':' && node.closing_loc.nil?) || [':"', ":'"].include?(node.opening_loc&.slice)

        [:value, node]
      when Prism::LocalVariableTargetNode
        # A variable of an enclosing scope is not a local of this one (lv_idx is 0): the fork binds nothing.
        [:var, node.depth.zero? ? node.name : nil]
      when Prism::PinnedVariableNode
        v = node.variable
        raise Unsupported, 'pin of a non-local' unless v.is_a?(Prism::LocalVariableReadNode) && v.depth.zero?

        [:pin, v.name]
      when Prism::AlternationPatternNode
        [:alt, pat_parse(node.left), pat_parse(node.right)]
      when Prism::CapturePatternNode
        t = node.target
        raise Unsupported, 'capture target' unless t.is_a?(Prism::LocalVariableTargetNode)

        [:as, pat_parse(node.value), t.depth.zero? ? t.name : nil]
      when Prism::ArrayPatternNode
        raise Unsupported, 'constant array pattern' if node.constant

        rest = node.rest
        raise Unsupported, 'implicit rest pattern' if rest.is_a?(Prism::ImplicitRestNode)

        raise Unsupported, 'array pattern without rest or elements' if false

        [:array, node.requireds.map { |e| pat_parse(e) }, rest ? pat_rest(rest) : nil, node.posts.map { |e| pat_parse(e) }]
      when Prism::FindPatternNode
        raise Unsupported, 'constant find pattern' if node.constant

        [:find, pat_rest(node.left), node.requireds.map { |e| pat_parse(e) }, pat_rest(node.right)]
      when Prism::HashPatternNode
        raise Unsupported, 'constant hash pattern' if node.constant

        pat_hash_parse(node)
      else
        raise Unsupported, "pattern #{node.class.name.split('::').last}"
      end
    end

    def pat_const_path?(node)
      node = node.parent while node.is_a?(Prism::ConstantPathNode)
      node.nil? || node.is_a?(Prism::ConstantReadNode)
    end

    # A rest in an array or find pattern: :any for `*`, [:var, name] for `*name`.
    def pat_rest(node)
      raise Unsupported, 'pattern rest' unless node.is_a?(Prism::SplatNode)

      e = node.expression
      return :any unless e

      raise Unsupported, 'pattern rest' unless e.is_a?(Prism::LocalVariableTargetNode)

      [:var, e.depth.zero? ? e.name : nil]
    end

    def pat_hash_parse(node)
      pairs = node.elements.map do |a|
        raise Unsupported, 'hash pattern element' unless a.is_a?(Prism::AssocNode) && a.key.is_a?(Prism::SymbolNode)
        raise Unsupported, 'quoted hash pattern key' unless a.key.opening_loc.nil? && a.key.closing_loc&.slice == ':'

        k = a.key.unescaped.to_sym
        v = a.value
        [k, v.is_a?(Prism::ImplicitNode) ? pat_parse(v.value.is_a?(Prism::LocalVariableReadNode) ? Prism::LocalVariableTargetNode.new(v.source, -1, v.location, 0, v.value.name, v.value.depth) : v.value) : pat_parse(v)]
      end
      r = node.rest
      rest = case r
             when nil then nil
             when Prism::NoKeywordsParameterNode then :nil
             when Prism::AssocSplatNode
               e = r.value
               if e.nil? then :any
               elsif e.is_a?(Prism::LocalVariableTargetNode) then [:var, e.depth.zero? ? e.name : nil]
               else raise Unsupported, 'hash pattern rest'
               end
             else raise Unsupported, 'hash pattern rest'
             end
      [:hash, pairs, rest]
    end

    # codegen_pattern: +fails+ collects the positions of the jumps taken when the pattern does not match.
    def pat_gen(pat, target, fails, known = nil)
      case pat[0]
      when :value
        operand_into(pat[1], @sp)
        pat_push
        pat_eqq(target, fails)
      when :var
        pgm(local_register(pat[1]), target, true) if pat[1]
      when :alt
        left_fail = []
        success = []
        pat_gen(pat[1], target, left_fail, known)
        if pat[1][0] != :alt && !left_fail.empty? && left_fail.last + 2 == @code.size && @code[left_fail.last - 2] == OP.fetch(:JMPNOT)
          pos = left_fail.pop
          pat_retag(pos, :JMPIF)
          success << pos
        else
          success << emit_jump(:JMP)
        end
        left_fail.each { |j| dispatch(j) }
        pat_gen(pat[2], target, fails, known)
        success.each { |j| dispatch(j) }
      when :as
        pat_gen(pat[1], target, fails, known)
        pgm(local_register(pat[2]), target, false) if pat[2]
      when :pin
        pgm(@sp, local_register(pat[1]), false)
        pat_push
        pat_eqq(target, fails)
      when :array then pat_array(pat, target, fails, known)
      when :find then pat_find(pat, target, fails)
      when :hash then pat_hash(pat, target, fails)
      end
    end

    # The pattern value is in the register below the stack top: `value === target`, jumping to the failure when false.
    def pat_eqq(target, fails)
      pgm(@sp, target, false)
      pat_push; pat_push; pat_pop; pat_pop; pat_pop
      pe(:SEND, @sp, sym_index(:===), 1)
      fails << cond_jump(:JMPNOT, @sp, val: true)
    end

    # Changes the opcode of the conditional jump whose operand is at +pos+ (the last instruction), keeping its size.
    def pat_retag(pos, name)
      @code[pos - 2] = OP.fetch(name)
      @insns[-1] = [name, @insns[-1][1], @insns[-1][2]]
      @last = @insns[-1]
    end

    # arr[pre_len..-(post_len+1)] bound to the rest variable.
    def pat_bind_rest(var, arr_reg, pre_len, post_len)
      pgm(@sp, arr_reg, false)
      pat_push
      pgi(pre_len, @sp)
      pat_push
      pgi(post_len.positive? ? -(post_len + 1) : -1, @sp)
      pe(:RANGE_INC, @sp - 1)
      pat_pop; pat_pop
      pe(:SEND, @sp, sym_index(:[]), 1)
      pgm(local_register(var[1]), @sp, true) if var[1]
    end

    # +known+ is the length of the array literal the subject is (codegen_case_match and NODE_MATCH_PAT know it): the target is
    # the array itself, with no deconstruct and no size test (a length that cannot match is a plain JMP to the failure), and
    # the elements are read with GETIDX.
    def pat_array_known(pat, target, fails, known)
      _, pre, rest, post = pat
      if rest.nil? ? known != pre.size : known < pre.size + post.size
        fails << emit_jump(:JMP)
        return
      end
      pre.each_with_index { |e, i| pat_elem_known(e, target, i, fails) }
      pat_bind_rest(rest, target, pre.size, post.size) if rest.is_a?(Array)
      post.each_with_index { |e, i| pat_elem_known(e, target, i - post.size, fails) }
    end

    def pat_elem_known(elem, arr_reg, i, fails)
      pgm(@sp, arr_reg, false)
      pat_push
      pgi(i, @sp)
      pe(:GETIDX, @sp - 1)
      pat_gen(elem, @sp - 1, fails)
      pat_pop
    end

    def pat_array(pat, target, fails, known = nil)
      return pat_array_known(pat, target, fails, known) if known

      _, pre, rest, post = pat
      arr_reg = @sp
      pgm(@sp, target, false)
      pat_push
      pe(:SEND, arr_reg, sym_index(:deconstruct), 0)
      if rest.nil?
        pgm(@sp, arr_reg, false)
        pat_push
        pe(:SEND, @sp - 1, sym_index(:size), 0)
        pgi(pre.size, @sp)
        pe(:EQ, @sp - 1)
        fails << cond_jump(:JMPNOT, @sp - 1, val: true)
        pat_pop
      elsif pre.size + post.size > 0
        pgm(@sp, arr_reg, false)
        pat_push
        pe(:SEND, @sp - 1, sym_index(:size), 0)
        pgi(pre.size + post.size, @sp)
        pe(:GE, @sp - 1)
        fails << cond_jump(:JMPNOT, @sp - 1, val: true)
        pat_pop
      end
      pre.each_with_index { |e, i| pat_elem_at(e, arr_reg, i, fails) }
      pat_bind_rest(rest, arr_reg, pre.size, post.size) if rest.is_a?(Array)
      post.each_with_index { |e, i| pat_elem_at(e, arr_reg, i - post.size, fails) }
      pat_pop
    end

    # arr[i] matched against +elem+.
    def pat_elem_at(elem, arr_reg, i, fails)
      pgm(@sp, arr_reg, false)
      pat_push
      pgi(i, @sp)
      pat_push; pat_push; pat_pop; pat_pop; pat_pop
      pe(:SEND, @sp, sym_index(:[]), 1)
      pat_push
      pat_gen(elem, @sp - 1, fails)
      pat_pop
    end

    def pat_find(pat, target, fails)
      _, pre, elems, post = pat
      arr_reg = @sp
      n = elems.size
      pgm(@sp, target, false)
      pat_push
      pe(:SEND, arr_reg, sym_index(:deconstruct), 0)
      pgm(@sp, arr_reg, false)
      pat_push
      pe(:SEND, @sp - 1, sym_index(:size), 0)
      pgi(n, @sp)
      pat_push; pat_push; pat_pop; pat_pop; pat_pop
      pe(:SEND, @sp, sym_index(:>=), 1)
      fails << cond_jump(:JMPNOT, @sp, val: true)
      idx_reg = @sp
      pgi(0, idx_reg)
      pat_push
      loop_start = @code.size
      match_fail = []
      pgm(@sp, arr_reg, false)
      pat_push
      pe(:SEND, @sp - 1, sym_index(:size), 0)
      pgi(n, @sp)
      pat_push; pat_push; pat_pop; pat_pop; pat_pop
      pe(:SEND, @sp, sym_index(:-), 1)
      pgm(@sp + 1, idx_reg, false)
      pat_push
      pat_push; pat_push; pat_pop; pat_pop; pat_pop
      pe(:SEND, @sp, sym_index(:>=), 1)
      fails << cond_jump(:JMPNOT, @sp, val: true)
      elems.each_with_index do |e, offset|
        pgm(@sp, arr_reg, false)
        pat_push
        pgm(@sp, idx_reg, false)
        unless offset.zero?
          pat_push
          pgi(offset, @sp)
          pat_push; pat_push; pat_pop; pat_pop; pat_pop
          pe(:SEND, @sp, sym_index(:+), 1)
        end
        pat_push; pat_push; pat_pop; pat_pop; pat_pop
        pe(:SEND, @sp, sym_index(:[]), 1)
        pat_push
        pat_gen(e, @sp - 1, match_fail)
        pat_pop
      end
      if pre.is_a?(Array)
        pgm(@sp, arr_reg, false)
        pat_push
        pgi(0, @sp)
        pat_push
        pgm(@sp, idx_reg, false)
        pe(:RANGE_EXC, @sp - 1)
        pat_pop; pat_pop
        pe(:SEND, @sp, sym_index(:[]), 1)
        pgm(local_register(pre[1]), @sp, true) if pre[1]
      end
      if post.is_a?(Array)
        pgm(@sp, arr_reg, false)
        pat_push
        pgm(@sp, idx_reg, false)
        pat_push
        pgi(n, @sp)
        pat_push; pat_push; pat_pop; pat_pop; pat_pop
        pe(:SEND, @sp, sym_index(:+), 1)
        pat_push
        pgi(-1, @sp)
        pe(:RANGE_INC, @sp - 1)
        pat_pop; pat_pop
        pe(:SEND, @sp, sym_index(:[]), 1)
        pgm(local_register(post[1]), @sp, true) if post[1]
      end
      loop_end = emit_jump(:JMP)
      match_fail.each { |j| dispatch(j) }
      pgm(@sp, idx_reg, false)
      pat_push
      pgi(1, @sp)
      pat_push; pat_push; pat_pop; pat_pop; pat_pop
      pe(:SEND, @sp, sym_index(:+), 1)
      pgm(idx_reg, @sp, false)
      back = emit_jump(:JMP)
      patch_jump(back, loop_start)
      dispatch(loop_end)
      pat_pop
      pat_pop
    end

    # gen_pat_keys_ary: the keys as an array at the stack top.
    def pat_keys_array(pairs)
      pairs.each do |k, _|
        pe(:LOADSYM, @sp, sym_index(k))
        pat_push
      end
      pe(:ARRAY, @sp - pairs.size, pairs.size)
      (pairs.size - 1).times { pat_pop }
    end

    def pat_hash(pat, target, fails)
      _, pairs, rest = pat
      hash_reg = @sp
      nkeys = pairs.size
      pgm(@sp, target, false)
      pat_push
      if rest.nil? && nkeys.positive?
        pat_keys_array(pairs)
      else
        pe(:LOADNIL, @sp)
        pat_push
      end
      pe(:SEND, hash_reg, sym_index(:deconstruct_keys), 1)
      pat_pop
      if nkeys.positive?
        vals_reg = @sp
        pgm(vals_reg, hash_reg, false)
        pat_push
        pat_keys_array(pairs)
        pe(:SEND, vals_reg, sym_index(:__pat_values), 1)
        pat_pop
        fails << cond_jump(:JMPNOT, vals_reg, val: true)
        pairs.each_with_index do |(_, p), i|
          pgm(@sp, vals_reg, false)
          pat_push
          pgi(i, @sp)
          pat_push; pat_push; pat_pop; pat_pop; pat_pop
          pe(:SEND, @sp, sym_index(:[]), 1)
          pat_push
          pat_gen(p, @sp - 1, fails)
          pat_pop
        end
        pat_pop
      end
      if rest == :nil || (nkeys.zero? && rest.nil?)
        pgm(@sp, hash_reg, false)
        pat_push
        pe(:SEND, @sp - 1, sym_index(:size), 0)
        pgi(nkeys, @sp)
        pe(:EQ, @sp - 1)
        fails << cond_jump(:JMPNOT, @sp - 1, val: true)
        pat_pop
      elsif rest.is_a?(Array)
        recv = @sp
        pgm(recv, hash_reg, false)
        pat_push
        if nkeys.positive?
          pat_keys_array(pairs)
          pe(:SEND, recv, sym_index(:__except), 1)
          pat_pop
        else
          pe(:SEND, recv, sym_index(:dup), 0)
        end
        pgm(local_register(rest[1]), recv, true) if rest[1]
        pat_pop
      end
      pat_pop
    end

    # NODE_MATCH_PAT: `expr => pattern` (raises NoMatchingPatternError) and `expr in pattern` (true or false).
    def match_pattern_statement(node, last:)
      raise_on_fail = node.is_a?(Prism::MatchRequiredNode)
      value = unparen(node.value)
      raise Unsupported, 'pattern subject' unless operand?(value)

      pat = pat_parse(node.pattern)
      check_multiline(value)
      head = temp
      if pat[0] == :var && pat[1].nil?
        # A variable that is not a local of this scope is a wildcard: only the value is evaluated, for its effects.
        statement(value, last: false)
        return pat_result(head, raise_on_fail, last)
      end
      value_into(value, head)
      known = node.value.is_a?(Prism::ArrayNode) ? value.elements.size : nil # parentheses make a statement list: not known
      if pat[0] == :var
        pgm(local_register(pat[1]), head, false)
        return pat_result(head, raise_on_fail, last)
      end
      @sp = head + 1
      @nregs = [@nregs, @sp].max
      fails = []
      if known && pat[0] == :array && pat[2].nil? && pat[3].empty? && known == pat[1].size
        # An array literal against an array pattern of the same length (no rest, no post): the elements are read with GETIDX
        # and the array is popped before the result is built. A pattern that can fail then leaves the stack pointer one
        # register low (the fork pops the array twice), so the result is built at head - 1.
        pat[1].each_with_index do |e, i|
          pgm(@sp, head, false)
          pat_push
          pgi(i, @sp)
          pat_push
          pe(:GETIDX, @sp - 2)
          pat_pop
          pat_gen(e, @sp - 1, fails)
          pat_pop
        end
        pat_pop
      else
        pat_gen(pat, head, fails, known)
      end
      saved = @sp
      return pat_result(head, raise_on_fail, last) if fails.empty?

      head = saved - 1
      @sp = head
      pat_result_values(raise_on_fail, last)
      if fails.size == 1 && fails[0] + 2 == @code.size && @code[fails[0] - 2] == OP.fetch(:JMPNOT)
        pos = fails[0]
        if raise_on_fail
          @code[pos - 2] = OP.fetch(:MATCHERR)
          @code[pos] = OP.fetch(:NOP)
          @code[pos + 1] = OP.fetch(:NOP)
          @insns[-1] = [:MATCHERR, @insns[-1][1], @insns[-1][2]]
          @last = @insns[-1]
          @sp = saved - 1
          pat_push if last
          return last ? head : nil
        end
        pat_retag(pos, :JMPIF)
        match_pos = pos
      else
        match_pos = emit_jump(:JMP)
        fails.each { |j| dispatch(j) }
      end
      @sp = head
      if raise_on_fail
        pe(:LOADFALSE, @sp)
        pe(:MATCHERR, @sp)
      elsif last
        pe(:LOADFALSE, @sp)
        pat_push
      end
      dispatch(match_pos)
      @sp = saved - 1
      pat_push if last
      last ? head : nil
    end

    def pat_result(head, raise_on_fail, last)
      @sp = head
      pat_result_values(raise_on_fail, last)
      last ? head : nil
    end

    # The value of a successful match: nil for `=>`, true for `in`.
    def pat_result_values(raise_on_fail, last)
      return unless last

      pe(raise_on_fail ? :LOADNIL : :LOADTRUE, @sp)
      pat_push
    end

    # codegen_case_match: the subject goes into the first temporary `head`; each `in` clause matches its pattern against it,
    # tests its guard, runs its body and jumps to the end; with no clause left NoMatchingPatternError is raised (MATCHERR),
    # also after an `else` body. The value ends in head.
    def case_match_statement(node, last:)
      subject = unparen(node.predicate)
      raise Unsupported, 'case/in subject' unless subject && operand?(subject)

      known = node.predicate.is_a?(Prism::ArrayNode) ? subject.elements.size : nil # parentheses make a statement list: not known

      check_multiline(subject)
      clauses = node.conditions.map do |c|
        raise Unsupported, 'case/in clause' unless c.is_a?(Prism::InNode)

        pat = c.pattern
        guard = nil
        guard_unless = false
        if pat.is_a?(Prism::IfNode) || pat.is_a?(Prism::UnlessNode)
          guard = pat.predicate
          guard_unless = pat.is_a?(Prism::UnlessNode)
          raise Unsupported, 'guard' unless pat.statements&.body&.size == 1

          pat = pat.statements.body.first
        end
        [pat_parse(pat), guard, guard_unless, c.statements]
      end
      clauses << [nil, nil, false, node.else_clause.statements] if node.else_clause
      # An empty body is a node on the line of the keyword that follows it (the next `in`, the `else` or the `end`).
      keywords = node.conditions.map(&:in_loc) + [node.else_clause&.else_keyword_loc, node.end_keyword_loc].compact
      clauses.each_with_index { |c, i| c << keywords[i + 1].start_line }
      head = temp
      value_into(subject, head)
      @sp = head + 1
      @nregs = [@nregs, @sp].max
      end_jumps = []
      clauses.each do |pat, guard, guard_unless, body, empty_line|
        fails = []
        pat_gen(pat, head, fails, known) if pat
        if guard
          g = unparen(guard)
          raise Unsupported, 'guard value' unless operand?(g)

          check_multiline(g)
          t = temp
          operand_into(g, t)
          j = cond_jump(guard_unless ? :JMPIF : :JMPNOT, t, val: false)
          if j
            fails << j
          else
            # A guard folded away returns JMPLINK_START, which the fork stores as the clause's failure chain: the jumps of the
            # pattern are never patched. Each keeps the link it was emitted with: the offset to the previous jump's operand
            # (absolute 0 for the first).
            prev = 0
            fails.each do |pos|
              off = (prev - (pos + 2)) & 0xffff
              @code[pos] = off >> 8
              @code[pos + 1] = off & 0xff
              prev = pos
            end
            fails.clear
          end
        end
        @line = empty_line if body.nil? || body.body.empty?
        branch(body, @sp, need: last)
        end_jumps << emit_jump(:JMP)
        fails.each { |j| dispatch(j) }
      end
      pe(:LOADFALSE, @sp)
      pe(:MATCHERR, @sp)
      end_jumps.each { |j| dispatch(j) }
      if last
        pgm(head, @sp, false)
        @sp = head + 1
        head
      else
        @sp = head
        nil
      end
    end

    # A match or a case/in as a value: built at the destination when it is a temporary, else at the first temporary and moved.
    def pattern_value_into(node, dst)
      saved = @sp
      base = dst >= @nlocals ? dst : temp
      begin
        @sp = base
        r = pattern_statement(node, last: true)
        # An array literal matched by a same-length array pattern that can fail leaves the fork's result one register low
        # (see match_pattern_statement), where a consumer reads it by its stack pointer: only a statement is covered.
        raise Unsupported, 'array literal pattern subject with a failing pattern as a value' if r < base
      ensure
        @sp = saved
      end
      pgm(dst, r, false)
    end

    # A statement leaves the stack pointer where it found it (the value, when there is one, is in the first temporary).
    def pattern_statement(node, last:)
      saved = @sp
      node.is_a?(Prism::CaseMatchNode) ? case_match_statement(node, last: last) : match_pattern_statement(node, last: last)
    ensure
      @sp = saved
    end

    def debug_section
      names = debug_names.uniq
      table = names.map { |n| [n.bytesize].pack('n') + n }.join
      sized('DBG' + "\0", [names.size].pack('n') + table + debug_records(names).join)
    end

    # The file names of this irep and then its children's, in the order the fork meets them (get_filename_table_size).
    def debug_names
      debug_files.map { |f| f[0].b } + @children.flat_map(&:debug_names)
    end
    public :debug_names

    # [name, first pc, end pc] of each file the code of this irep belongs to: a single file but for the top level of a
    # multi-file program.
    def debug_files = @segments || [[@filename, 0, @code.size]]

    # One debug record per irep, this one first and then its children's (write_debug_record in dump.c). Each covers its files,
    # each from its own first pc.
    def debug_records(names)
      [debug_record(names)] + @children.flat_map { |c| c.debug_records(names) }
    end
    public :debug_records # called on each child, from the parent's debug section

    def debug_record(names)
      files = debug_files.map do |name, first, stop, snapshot|
        packed = packed_lines(first, stop, snapshot)
        [first].pack('N') + [names.index(name.b)].pack('n') + [packed.bytesize].pack('N') + [2].pack('C') + packed
      end
      record = [files.size].pack('n') + files.join
      [record.bytesize + 4].pack('N') + record
    end

    # src/debug.c's packed map: (pc delta, line delta) pairs, written only where the line changes.
    def packed_lines(first = 0, stop = @lines.size, snapshot = nil)
      out = ''.b
      prev_line = 0
      prev_pc = 0
      (first...stop).each do |pc|
        line = snapshot ? snapshot[pc - first] : @lines[pc]
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

    # Milestone 13 (string, regexp and heredoc literal forms).

    # The literals a text piece of a heredoc contributes, one per source line (a line the fork's lexer ends at its newline; a
    # backslash before the newline joins the next line to it). A piece without a backslash is its unescaped text split at the
    # newlines. Otherwise the raw lines are decoded with the fork's escape rules (heredoc_decode) and the result is checked
    # against Prism's unescaped text; in a squiggly heredoc, where Prism dedents, a line is taken from Prism's text.
    def heredoc_chunks(part, raw, squiggly)
      text = part.unescaped.b
      source = part.content_loc.slice.b
      return text.scan(/[^\n]*\n|[^\n]+/n).map { |l| [l, l.end_with?("\n")] } unless source.include?('\\')

      chunks = source.scan(/(?:\\.|[^\\\n])*\n|(?:\\.|[^\\\n])+/mn)
      decoded = chunks.map { |c| heredoc_decode(c, raw) }
      if squiggly
        raise Unsupported, 'escape in a squiggly heredoc line' unless chunks.size == 1 && decoded[0].end_with?(text) && !chunks.any? { |c| c.chomp.include?("\n") || (c.end_with?("\n") && !real_newline?(c)) }

        return [[text, real_newline?(source)]]
      end
      raise Unsupported, 'heredoc escape that Prism reads differently' unless raw || decoded.join == text

      decoded.zip(chunks).map { |d, c| [d, real_newline?(c)] }
    end

    # Whether a chunk of heredoc source ends with a newline that no backslash escapes (an even run of backslashes before it).
    def real_newline?(chunk)
      chunk.end_with?("\n") && chunk[0...-1][/\\*\z/].size.even?
    end

    # One heredoc line's escapes as the fork's lexer reads them: a raw (`<<'A'`) heredoc only turns `\\` into one backslash and
    # keeps every other pair; otherwise read_escape's forms.
    def heredoc_decode(source, raw)
      out = ''.b
      i = 0
      while i < source.bytesize
        c = source.getbyte(i)
        if c != 0x5c
          out << c
          i += 1
          next
        end
        nxt = source.byteslice(i + 1, 1)
        if raw
          out << (nxt == '\\' ? '\\' : "\\#{nxt}")
          i += 2
        elsif nxt == "\n"
          i += 2
        else
          bytes, i = read_escape_bytes(source, i + 1)
          out << bytes
        end
      end
      out
    end

    # read_escape in parse.y, for the text after the backslash at +i+: returns the bytes and the index after the escape.
    SIMPLE_ESCAPES = { 'n' => "\n", 't' => "\t", 'r' => "\r", 'f' => "\f", 'v' => "\v", 'a' => "\a", 'e' => "\e", 'b' => "\b",
                       's' => ' ', '\\' => '\\' }.freeze
    def read_escape_bytes(source, i)
      c = source.byteslice(i, 1)
      raise Unsupported, 'incomplete escape' if c.nil? || c.empty?
      return [SIMPLE_ESCAPES[c].b, i + 1] if SIMPLE_ESCAPES.key?(c)

      case c
      when '0'..'7'
        digits = source.byteslice(i, 3)[/\A[0-7]{1,3}/]
        [[digits.to_i(8) & 0xff].pack('C'), i + digits.size]
      when 'x'
        digits = source.byteslice(i + 1, 2)[/\A\h{1,2}/] or raise Unsupported, 'invalid hex escape'
        [[digits.to_i(16)].pack('C'), i + 1 + digits.size]
      when 'u'
        if source.byteslice(i + 1, 1) == '{'
          close = source.index('}', i) or raise Unsupported, 'unterminated unicode escape'
          codes = source.byteslice(i + 2, close - i - 2).split
          raise Unsupported, 'unicode escape' if codes.empty? || codes.any? { |h| !h.match?(/\A\h{1,6}\z/) }

          [codes.map { |h| [h.to_i(16)].pack('U') }.join.b, close + 1]
        else
          digits = source.byteslice(i + 1, 4)
          raise Unsupported, 'unicode escape' unless digits.match?(/\A\h{4}\z/)

          [[digits.to_i(16)].pack('U').b, i + 5]
        end
      when 'M'
        raise Unsupported, 'meta escape' unless source.byteslice(i + 1, 1) == '-'

        byte, j = escape_operand(source, i + 2)
        [[byte | 0x80].pack('C'), j]
      when 'C', 'c'
        if c == 'C'
          raise Unsupported, 'control escape' unless source.byteslice(i + 1, 1) == '-'

          i += 1
        end
        return ["\x7f".b, i + 2] if source.byteslice(i + 1, 1) == '?'

        byte, j = escape_operand(source, i + 1)
        [[byte & 0x9f].pack('C'), j]
      else [c.b, i + 1]
      end
    end

    # dstr_at for a word of a %W or %I list: the literals keep the line of the list (hold_line), but an interpolated
    # expression is a node the fork enters, so it takes its own line, which then stays.
    def word_dstr_at(parts, base)
      saved = @hold_line
      parts.each_with_index do |(kind, v), i|
        reg = i.zero? ? base : base + 1
        if kind == :lit
          emit(:STRING, reg, pool_index([:str, v]))
        else
          @hold_line = false
          interpolation_into(v, reg)
          @hold_line = saved
        end
        emit(:STRCAT, base) unless i.zero?
      end
    end

    # The byte after `\M-` or `\C-`: a plain byte, or a whole escape after a backslash.
    def escape_operand(source, i)
      c = source.getbyte(i) or raise Unsupported, 'incomplete escape'
      return [c, i + 1] unless c == 0x5c

      bytes, j = read_escape_bytes(source, i + 1)
      raise Unsupported, 'escape operand' unless bytes.bytesize == 1

      [bytes.getbyte(0), j]
    end

    # An element of a %w, %W, %i or %I list: a %W word with interpolation is built like a %I one without the INTERN.
    def word_into(elem, reg, array, symbols)
      if symbols then symbol_word_into(elem, reg, array)
      elsif elem.is_a?(Prism::InterpolatedStringNode) && elem.opening_loc.nil? && array.opening_loc.slice.start_with?('%W')
        symbol_word_into(elem, reg, array, intern: false)
      else operand_into(unparen(elem), reg)
      end
    end

    # merge_op_string: `"a" + "b"` loads the two literals and the ADD is replaced by one STRING of the joined text. The pool
    # entries are reused: both free (or only the second referenced) -> the first is extended and the second dropped when it
    # was the last entry; only the first referenced -> the second becomes the joined text; both referenced -> a new entry;
    # an entry that already holds the joined text is used as is (the two literals stay in the pool). A STRING before the first
    # literal is a reference (the fork scans OP_STRING only).
    def merge_strings(dst)
      first = @insns[-2]
      b1 = first[1][1]
      b2 = @insns[-1][1][1]
      used = 0
      @insns[0...-2].each do |name, ops, _|
        next unless name == :STRING

        used |= 1 if ops[1] == b1
        used |= 2 if ops[1] == b2
      end
      joined = @pool[b1][1] + @pool[b2][1]
      off = @pool.index([:str, joined])
      if off.nil?
        case used
        when 0, 2
          off = b1
          @pool[b1] = [:str, joined]
          @pool.pop if b1 != b2 && used.zero? && b2 + 1 == @pool.size
        when 1
          off = b2
          @pool[b2] = [:str, joined]
        else
          @pool << [:str, joined]
          off = @pool.size - 1
        end
      end
      @code.slice!(first[2]..)
      @lines.slice!(first[2]..)
      @insns.pop(2)
      emit(:STRING, dst, off)
    end

    # A program without statements is a nil return (and STOP) on the line the lexer ended on (see empty_program_line).
    public def compile_empty(line)
      set_locals([])
      @line = line
      @nregs = 2 # the fork reserves a register beyond R0 for the return value
      emit(:RETNIL)
      emit(:STOP)
      write_rite
    end
  end
end
