# frozen_string_literal: true

require 'digest'
require 'prism'

module MrbcRb
  # CLASS-SCOPE ANNOTATIONS: the exact lexical scope facts the Prism AST knows while the emitter compiles, kept as a side
  # table next to the irep tree (MrbcRb::Result#annotations). They never affect the emitted bytes. bc2cpp otherwise re-derives
  # them from the bytecode by dataflow (BytecodeIR.class_body_path and friends); when a table is present it uses this one.
  #
  # The structure is plain data (Hash/Array/Symbol/String/Integer/nil/true/false), Marshal- and inspect-friendly:
  #
  #   { version: 1,
  #     ireps: [ irep_record, ... ] }          # index = depth-first (pre-order) irep index, as in the irep tree / RITE image
  #
  #   irep_record = {
  #     index:  Integer,                       # its own depth-first index
  #     parent: Integer | nil,                 # the irep that holds it (nil for the root)
  #     kind:   :top | :class_body | :module_body | :sclass_body | :method | :block | :for,
  #     cref:   [ { kind: :class|:module|:sclass, path: String|nil, singleton_of: String|nil, outer: :lexical|:root|:path|:dynamic|:sclass }, ... ],
  #                                            # the lexical class scopes in effect in this irep, OUTERMOST first (empty at top
  #                                            # level; a body's own entry is last). `path` is the qualified name ("A::B") or nil
  #                                            # when it is not statically known (`class << self` and anything inside one, a
  #                                            # `class A::B` whose A is looked up lexically inside a namespace, a dynamic outer).
  #                                            # Every GETCONST/GETMCNST/SETCONST/ALIAS/UNDEF of this irep sees this chain.
  #     owner:  { irep: Integer, pc: Integer } | nil,   # for a class/module/sclass body: the opener (CLASS/MODULE/SCLASS)
  #     in_block: true|false,                  # inside a literal block (def/alias/constants there have a dynamic owner)
  #     vis_calls: [ { name:, args: [String]|nil, line:, owner_path: } ],   # `private :a, :b`, `private_class_method ...`
  #     ops: { pc => op_record },              # pc = byte offset of the instruction in this irep (including an EXT prefix)
  #     loops: [ loop_record, ... ],           # its while/until loops, by header_pc
  #     block_sends: { pc => block_send_record } }
  #
  #   op_record (every one has op:, line:, file:):
  #     CLASS / MODULE:  kind: :class|:module, name: written last segment, written: source text of the path,
  #                      outer: :lexical (plain `class X`) | :root (`class ::X`, `::A::X`) | :path (`class A::X`) | :dynamic
  #                      (`class expr::X`), path: qualified name String | nil (nil when outer is dynamic or the lexical namespace
  #                      is unknown or the path is relative to a namespace), candidates: [String] | nil (for a relative path
  #                      inside a namespace: the names it can resolve to, innermost namespace first), namespace: the lexical
  #                      namespace path the opener runs in (nil at top level or when unknown), superclass: { kind: :none |
  #                      :const | :other, text: String|nil }, empty_body: true|false, body_irep: Integer | nil,
  #                      conditional: as SETCONST's, for the opener (its body runs whenever the program loads)
  #     SCLASS:          kind: :sclass, target: :self | :const | :other, target_text:, singleton_of: String | nil,
  #                      path: nil, empty_body:, body_irep:, conditional:
  #     EXEC:            owner_pc: pc of the opener this EXEC runs the body of, body_irep: Integer
  #     TDEF / SDEF / DEF: name:, owner_kind: :top|:class|:module|:sclass|:block|:dynamic, owner_path: String | nil (the
  #                      class the method lands on when statically evident; "Object" at top level), singleton: true|false,
  #                      receiver: nil | :self | source text of `def Recv.m`, visibility: :public|:private|:protected|
  #                      :module_function | nil (nil when not evident: inside a block, a method or a singleton def),
  #                      nested_in_method:, in_block:, lexical_owner_path:, fingerprint: hash of the def's parameters+body
  #                      subtree with locations stripped, body_irep: Integer
  #     ALIAS / UNDEF:   names: [String] (ALIAS: new, old), owner_kind:, owner_path:, in_block:
  #     SETCONST / SETMCNST: name:, scope_path: String|nil (SETCONST: the lexical class the constant is set on; "Object" at top;
  #                      nil when unknown), base: for SETMCNST the written base path text (nil when dynamic), base_rooted:,
  #                      conditional: false only when the write runs whenever the program loads (see straight_nodes)
  #     GETCONST:        name:   (resolves against the irep's cref chain, then the ancestors of the innermost entry, then Object)
  #     GETMCNST:        name:, base: written base path text (nil when dynamic), base_rooted:
  #
  #     SEND / SEND0 / SSEND / SSEND0 / SENDB / SSENDB of a CALL_NAMES method (the mixin and name-taking sends: include, extend,
  #                      send, define_method, alias_method, attr_*, private ... ): call: { name:, recv: :implicit | :self |
  #                      :const | :other, recv_text: String | nil (:const: the written path), safe_nav: true|false,
  #                      block: :none | :literal | :pass, args: [ arg, ... ] } with arg = { kind: :sym|:str, value: String } |
  #                      { kind: :const, text: written path, rooted: true|false } | { kind: :splat } | { kind: :keywords } |
  #                      { kind: :other }. The list is the call as written; other sends carry no record.
  #
  #   loop_record (a while/until of this irep's own code): kind: :while | :until, post_test: true|false (`begin ... end while`),
  #                      line:, header_pc: the condition (the target of the back edge and of `next`), body_pc: the NOP that
  #                      starts the body (the target of `redo`), back_pc: the JMP back to header_pc, exit_pc: the pc after it,
  #                      exits: [ { kind:, pc: } ] with kind :break | :next | :redo | :retry (the JMPUW of the innermost
  #                      loop's own jump) | :return (a RETURN-family op) | :break_block (BREAK) | :raise (an EXIT_CALLS send),
  #                      the last three for every loop they are inside; writes: [String] the names of this irep's locals the
  #                      loop's code assigns, a nested block's assignment of them (an upvar) included, sorted.
  #   block_send_record (every SENDB / SSENDB / SUPER): op:, method: (the name; 'each' for `for`, 'super' for SUPER), line:,
  #                      block: :literal | :for | :sym | :pass (`&expr`) | :forward (`&`) | :implicit (a SUPER without one),
  #                      sym: the Symbol of `&:sym` | nil, block_irep: Integer (:literal / :for) | nil, recv: { kind:
  #                      :implicit | :self | :local | :ivar | :integer | :range | :array | :hash | :call | :const | :other, text: },
  #                      params: [ { kind: :req|:opt|:rest|:post|:key|:keyrest|:block|:numbered|:it, name: } ] | nil (a
  #                      literal block's parameters as written).
  #
  # Versions: 1 = scope records; 2 = adds the `call` record of the sends above; 3 = adds `conditional` to the constant writes
  # and openers; 4 = adds `loops` and `block_sends` (each additive: an older table is still valid, and a reader treats a
  # missing fact as unknown).
  #
  # A table is only meaningful for the irep tree it was built with; Annotations.verify checks the pcs/ops against decoded code.
  module Annotations
    VERSION = 4
    SEND_OPS = %i[SEND SEND0 SSEND SSEND0 SENDB SSENDB].to_h { |o| [o, true] }.freeze
    TRACKED = (%i[CLASS MODULE SCLASS EXEC TDEF SDEF DEF ALIAS UNDEF SETCONST SETMCNST GETCONST GETMCNST] + SEND_OPS.keys).to_h { |o| [o, true] }.freeze
    # The sends that get a `call` record (see above): mixins, name-taking sends and visibility/definition sends.
    # A literal Hash (no block runs over the names) so the closed world can prove they are only looked up.
    CALL_NAMES = { include: true, prepend: true, extend: true, send: true, __send__: true, public_send: true,
                  method: true, instance_method: true, define_method: true, define_singleton_method: true,
                  alias_method: true, attr: true, attr_reader: true, attr_writer: true, attr_accessor: true,
                  'respond_to?': true, private: true, public: true, protected: true, module_function: true,
                  private_class_method: true, public_class_method: true, private_constant: true }.freeze
    VIS_CALLS = %i[private public protected module_function private_class_method public_class_method private_constant].freeze

    # Emitter-side state of one irep being compiled. straight: the irep runs whenever the program loads (the top level, or
    # a body whose opener is one of its parent's straight_nodes).
    Scope = Struct.new(:kind, :cref, :vis, :in_block, :in_method, :owner_pc, :vis_calls, :straight)
    # Calls that leave the statement list without returning to it (raise, throw, exit).
    EXIT_CALLS = { raise: true, fail: true, throw: true, exit: true, exit!: true, abort: true }.freeze


    module_function

    # [rooted, [names]] for a statically written constant path (`A`, `A::B`, `::A::B`), nil when any part is dynamic.
    def static_path(node)
      node = MrbcRb.unparen(node)
      case node
      when Prism::ConstantReadNode then [false, [node.name.to_s]]
      when Prism::ConstantPathNode
        return [true, [node.name.to_s]] if node.parent.nil?

        base = static_path(node.parent)
        base && [base[0], base[1] + [node.name.to_s]]
      end
    end

    # The `call` record of a send node (see the header): the call as written.
    def call_facts(node)
      recv = node.receiver && MrbcRb.unparen(node.receiver)
      sp = recv && static_path(recv)
      kind = if recv.nil? then :implicit elsif recv.is_a?(Prism::SelfNode) then :self else sp ? :const : :other end
      block = if node.block.nil? then :none elsif node.block.is_a?(Prism::BlockArgumentNode) then :pass else :literal end
      { name: node.name.to_s, recv: kind, recv_text: kind == :const ? path_text(sp) : nil, safe_nav: node.safe_navigation?,
        block: block, args: (node.arguments&.arguments || []).map { |a| call_arg(a) } }
    end

    def call_arg(node)
      node = MrbcRb.unparen(node)
      case node
      when Prism::SymbolNode then { kind: :sym, value: node.unescaped.to_s }
      when Prism::StringNode then { kind: :str, value: node.unescaped.to_s }
      when Prism::SplatNode then { kind: :splat }
      when Prism::KeywordHashNode then { kind: :keywords }
      else
        sp = static_path(node)
        sp ? { kind: :const, text: path_text(sp), rooted: sp[0] } : { kind: :other }
      end
    end

    def path_text(sp) = sp && "#{'::' if sp[0]}#{sp[1].join('::')}"

    # The constant writes and class/module/singleton openers of +stmts+ (a top-level or class body) that run whenever the body
    # does: a statement of the list itself (through parentheses and a begin with no rescue, else or ensure), before any
    # statement that can leave the list early (exits?). Anything under a condition, a loop, a rescue, a block or a value is
    # not one. An exception out of a load-time body ends the load, so a statement that raises is no earlier exit.
    def straight_nodes(stmts)
      out = {}.compare_by_identity
      work = stmts.reverse
      until work.empty?
        node = MrbcRb.unparen(work.pop)
        case node
        when Prism::ParenthesesNode
          work.concat((node.body&.body || []).reverse)
          next
        when Prism::BeginNode
          if node.rescue_clause.nil? && node.else_clause.nil? && node.ensure_clause.nil?
            work.concat((node.statements&.body || []).reverse)
            next
          end
        end
        break if exits?(node)

        out[node] = true if STRAIGHT_KINDS.any? { |k| node.is_a?(k) }
        # `A, B = v`: each constant target of the statement itself is one write.
        (node.lefts + node.rights).each { |t| out[t] = true if t.is_a?(Prism::ConstantTargetNode) } if node.is_a?(Prism::MultiWriteNode)
      end
      out
    end

    STRAIGHT_KINDS = [Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ClassNode, Prism::ModuleNode,
                      Prism::SingletonClassNode].freeze
    NESTED_CODE = [Prism::BlockNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze

    # Can +node+ leave the statement list it is in other than by finishing: a `return` (not one of a def or lambda body; a
    # block's returns from the list), or an EXIT_CALLS call of the list's own code (not in a def, block or body: one there
    # raises out of a call, which ends the load). Over-approximate: a hit only makes the writes after it conditional.
    def exits?(node)
      stack = [[node, false]]
      until stack.empty?
        n, nested = stack.pop
        next if n.is_a?(Prism::DefNode) || n.is_a?(Prism::LambdaNode)
        return true if n.is_a?(Prism::ReturnNode)
        return true if !nested && n.is_a?(Prism::CallNode) && n.receiver.nil? && EXIT_CALLS.key?(n.name)

        inner = nested || NESTED_CODE.any? { |k| n.is_a?(k) }
        n.compact_child_nodes.each { |c| stack << [c, inner] }
      end
      false
    end

    LOCAL_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
                    Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode].freeze
    NEW_SCOPE = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze

    # The names of the locals of the enclosing scope written anywhere in +node+ (a nested block's writes of them included,
    # as upvars), sorted.
    def local_writes(node)
      names = {}
      stack = [[node, 0]]
      until stack.empty?
        n, level = stack.pop
        next if NEW_SCOPE.any? { |k| n.is_a?(k) }

        names[n.name.to_s] = true if LOCAL_WRITES.any? { |k| n.is_a?(k) } && n.depth == level
        inner = n.is_a?(Prism::BlockNode) || n.is_a?(Prism::LambdaNode) ? level + 1 : level
        n.compact_child_nodes.each { |c| stack << [c, inner] }
      end
      names.keys.sort
    end

    # The block-send record (see the header) of +node+ (a call, super or for node).
    def block_send_facts(node, block)
      recv = node.respond_to?(:receiver) && node.receiver ? MrbcRb.unparen(node.receiver) : nil
      blk = node.is_a?(Prism::ForNode) ? nil : node.block
      params = blk.is_a?(Prism::BlockNode) ? block_params(blk) : nil
      { method: node.is_a?(Prism::ForNode) ? 'each' : (node.respond_to?(:name) ? node.name.to_s : 'super'),
        recv: recv_kind(node.is_a?(Prism::ForNode) ? MrbcRb.unparen(node.collection) : recv),
        block: block, sym: block == :sym ? blk.expression.unescaped.to_s : nil, params: params,
        line: node.location.start_line }
    end

    def recv_kind(recv)
      kind = case recv
             when nil then :implicit
             when Prism::SelfNode then :self
             when Prism::LocalVariableReadNode then :local
             when Prism::InstanceVariableReadNode then :ivar
             when Prism::IntegerNode then :integer
             when Prism::RangeNode then :range
             when Prism::ArrayNode then :array
             when Prism::HashNode then :hash
             when Prism::CallNode then :call
             else static_path(recv) ? :const : :other
             end
      { kind: kind, text: recv && recv.location.slice[0, 60] }
    end

    # [{ kind: :req|:opt|:rest|:post|:key|:keyrest|:block|:numbered|:it, name: }] of a literal block.
    def block_params(blk)
      p = blk.parameters
      case p
      when nil then []
      when Prism::NumberedParametersNode then [{ kind: :numbered, name: p.maximum.to_s }]
      when Prism::ItParametersNode then [{ kind: :it, name: 'it' }]
      else
        q = p.parameters
        return [] unless q

        out = q.requireds.map { |r| { kind: :req, name: r.respond_to?(:name) ? r.name.to_s : nil } }
        out.concat(q.optionals.map { |r| { kind: :opt, name: r.name.to_s } })
        out << { kind: :rest, name: q.rest.respond_to?(:name) ? q.rest.name.to_s : nil } if q.rest
        out.concat(q.posts.map { |r| { kind: :post, name: r.respond_to?(:name) ? r.name.to_s : nil } })
        out.concat(q.keywords.map { |r| { kind: :key, name: r.name.to_s } })
        out << { kind: :keyrest, name: nil } if q.keyword_rest
        out << { kind: :block, name: q.block.name.to_s } if q.block
        out
      end
    end

    def qualify(namespace, name) = namespace ? "#{namespace}::#{name}" : name

    # Hash of the subtree of +node+ with locations (and anything position-derived) removed.
    def fingerprint(node)
      Digest::SHA256.hexdigest(canonical(node))[0, 16]
    end

    def canonical(value)
      case value
      when Prism::Node
        keys = value.deconstruct_keys(nil).reject { |k, v| v.is_a?(Prism::Location) || k == :location || k.to_s.end_with?('_loc') }
        "(#{value.type}#{keys.map { |k, v| " #{k}=#{canonical(v)}" }.join})"
      when Array then "[#{value.map { |v| canonical(v) }.join(' ')}]"
      when String then value.b.inspect
      when Prism::Location, nil then 'nil'
      else value.inspect
      end
    end

    # Checks that every recorded pc of +ireps+ (annotation records) is an instruction of the recorded op in the decoded code:
    # +code_ops+ is an Array (per irep) of { pc => op Symbol }. Returns an error String or nil.
    def verify(annotations, code_ops)
      return 'size' unless annotations[:ireps].size == code_ops.size

      annotations[:ireps].each_with_index do |rec, i|
        rec[:ops].each do |pc, op|
          real = code_ops[i][pc]
          return "irep #{i} pc #{pc}: #{op[:op]} vs #{real.inspect}" unless real == op[:op]
        end
      end
      nil
    end

    # The names (outermost last) a bare constant read in a cref chain is looked up in, innermost first, ending at the top
    # level (nil entries = a scope whose name is unknown).
    def lookup_chain(cref)
      cref.reverse.map { |e| e[:path] } + [nil]
    end

    # Emitter-side recording, mixed into MrbcRb::Compiler. Everything here only reads the AST and the emitted operands.
    module Recorder
      def ann_scope
        @ann_scope ||= Scope.new(:top, [].freeze, :public, false, false, nil, [], true)
      end

      def ann_ops = (@ann_ops ||= {})

      # Called on a child Compiler right after it is built: +kind+ is :method, :body (class/module/sclass), :block or :for.
      def ann_enter(parent, kind)
        ps = parent.ann_scope
        @ann_scope =
          case kind
          when :body
            opener = parent.instance_variable_get(:@ann_cur_opener)
            Scope.new(opener[:body_kind], (ps.cref + [opener[:cref_entry]]).freeze, :public, false, false, opener[:pc], [],
                      opener[:straight])
          when :method then Scope.new(:method, ps.cref, nil, ps.in_block, true, nil, [], false)
          else Scope.new(kind, ps.cref, nil, true, ps.in_method, nil, [], false)
          end
        @ann_parent = parent
      end

      # Hook of Compiler#emit: +start+ is the pc (the EXT prefix included), +operands+ the instruction's operands.
      def ann_emit(name, start, operands)
        ann_emit_loop_facts(name, start, operands) if @ann_bsend || @ann_open_loops
        return unless TRACKED.key?(name)
        return ann_emit_send(name, start, operands) if SEND_OPS.key?(name)

        extra = nil
        if @ann_extra && @ann_extra[0].include?(name)
          extra = @ann_extra[1]
          @ann_extra = nil
        end
        return if name == :SCLASS && extra.nil? # the SCLASS of a def past 255 child ireps (codegen_def), not an opener
        rec = { op: name, line: @line, file: @filename }
        sc = ann_scope
        case name
        when :CLASS, :MODULE, :SCLASS
          rec.merge!(extra || {})
          @ann_cur_opener = { pc: start, body_kind: :"#{name.to_s.downcase}_body", cref_entry: rec.delete(:cref_entry),
                              straight: rec[:conditional] == false }
          @ann_open_pc = start
        when :EXEC
          rec[:owner_pc] = @ann_open_pc
          rec[:child] = operands[1]
          (opener = ann_ops[@ann_open_pc]) && opener[:child] = operands[1]
        when :TDEF, :SDEF
          rec.merge!(ann_def_record(extra || {}))
          rec[:name] = @syms[operands[1]].to_s
          rec[:child] = operands[2]
        when :DEF
          rec.merge!(ann_def_record(extra || {}))
          rec[:name] = @syms[operands[1]].to_s
          rec[:child] = extra && extra[:child]
        when :ALIAS then rec.merge!(names: [@syms[operands[0]].to_s, @syms[operands[1]].to_s], **ann_owner_fields)
        when :UNDEF then rec.merge!(names: [@syms[operands[0]].to_s], **ann_owner_fields)
        when :SETCONST
          rec.merge!(name: @syms[operands[1]].to_s, scope_path: ann_scope_path, in_block: sc.in_block,
                     conditional: !ann_straight_write?)
        when :SETMCNST
          rec.merge!(name: @syms[operands[1]].to_s, base: extra && extra[:base], base_rooted: extra && extra[:base_rooted],
                     conditional: !ann_straight_write?)
        when :GETCONST then rec[:name] = @syms[operands[1]].to_s
        when :GETMCNST then rec.merge!(name: @syms[operands[1]].to_s, base: extra && extra[:base], base_rooted: extra && extra[:base_rooted])
        end
        ann_ops[start] = rec
      end

      # Hook of Compiler#call around the whole call: +node+ is the CallNode being compiled. The send it ends with is the first SEND
      # of its name emitted while it is the innermost open call (the calls in its arguments close before it).
      def ann_call(node)
        return yield unless CALL_NAMES.key?(node.name)

        (@ann_calls ||= []) << [node, false]
        begin
          yield
        ensure
          @ann_calls.pop
        end
      end

      def ann_emit_send(name, start, operands)
        entry = @ann_calls&.last
        return if entry.nil? || entry[1] || @syms[operands[1]].to_s != entry[0].name.to_s

        entry[1] = true
        ann_ops[start] = { op: name, line: @line, file: @filename, call: Annotations.call_facts(entry[0]) }
      end

      # The statements of the body this compiler generates (Annotations.straight_nodes), set before the first is generated.
      def ann_body(stmts)
        @ann_straight = Annotations.straight_nodes(stmts)
      end

      # Called by a constant write right before its SETCONST/SETMCNST with the write node; ann_straight_write? reads it once.
      def ann_const_write(node) = (@ann_write = node)

      def ann_straight?(node) = ann_scope.straight && !@ann_straight.nil? && @ann_straight.key?(node)

      def ann_straight_write?
        node = @ann_write
        @ann_write = nil
        !node.nil? && ann_straight?(node)
      end

      def ann_truncate(start)
        @ann_ops&.delete_if { |pc, _| pc >= start }
        @ann_block_sends&.delete_if { |pc, _| pc >= start }
        @ann_loops&.reject! { |rec| rec[:header_pc] >= start }
        @ann_open_loops&.each { |rec| rec[:exits].reject! { |e| e[:pc] >= start } }
      end

      # LOOP RECORDS (version 4, see the header). A while/until opens a record before its condition; the exits emitted while it
      # is open are added to it (break/next/redo/retry to the innermost, return and raise to every open one).
      def ann_loop_open(node)
        rec = { kind: node.is_a?(Prism::UntilNode) ? :until : :while, post_test: node.begin_modifier?, line: node.location.start_line,
                exits: [], writes: Annotations.local_writes(node) }
        (@ann_open_loops ||= []) << rec
        rec
      end

      def ann_loop_close(rec, header_pc:, body_pc:, back_pc:, exit_pc:)
        @ann_open_loops.pop
        # +back_pc+ and an exit jump's pc are emit_jump's operand positions; JMP/JMPUW take no register, so the op is a byte before.
        rec.merge!(header_pc: header_pc, body_pc: body_pc, back_pc: back_pc - 1, exit_pc: exit_pc)
        (@ann_loops ||= []) << rec
      end

      def ann_loop_exit(kind, pc)
        rec = @ann_open_loops&.last
        rec[:exits] << { kind: kind, pc: pc - 1 } if rec
      end

      def ann_loops = @ann_loops || []
      def ann_block_sends = @ann_block_sends || {}

      # The facts of the block-carrying send about to be emitted (SENDB/SSENDB/SUPER); the next instruction takes them.
      def ann_block_send(node, block, child = nil)
        @ann_bsend = Annotations.block_send_facts(node, block).merge(child: child)
      end

      def ann_pass_kind(blk)
        e = blk.is_a?(Prism::BlockArgumentNode) ? blk.expression : nil
        e.is_a?(Prism::SymbolNode) ? :sym : (e ? :pass : :forward)
      end

      LOOP_EXIT_OPS = { RETURN: :return, RETURN_BLK: :return, RETSELF: :return, RETNIL: :return, RETTRUE: :return,
                        RETFALSE: :return, BREAK: :break_block }.freeze
      BLOCK_SEND_OPS = { SENDB: true, SSENDB: true, SUPER: true }.freeze

      def ann_emit_loop_facts(name, start, operands)
        if (facts = @ann_bsend)
          @ann_bsend = nil
          (@ann_block_sends ||= {})[start] = facts.merge(op: name) if BLOCK_SEND_OPS.key?(name)
        end
        return if @ann_open_loops.nil? || @ann_open_loops.empty?

        kind = LOOP_EXIT_OPS[name]
        kind ||= :raise if SEND_OPS.key?(name) && EXIT_CALLS.key?(@syms[operands[1]].to_s.to_sym)
        @ann_open_loops.each { |rec| rec[:exits] << { kind: kind, pc: start } } if kind
      end

      # Extra facts about the instruction about to be emitted.
      def ann_extra(ops, facts) = (@ann_extra = [ops, facts])

      # `Base::Name` read/write: the base's written text.
      def ann_const_path(node)
        sp = Annotations.static_path(node.parent) if node.parent
        ann_extra(%i[GETMCNST SETMCNST], { base: sp && Annotations.path_text(sp), base_rooted: node.parent.nil? || (sp ? sp[0] : nil) })
      end

      def ann_namespace_entry = ann_scope.cref.last

      def ann_scope_path
        entry = ann_namespace_entry
        entry ? entry[:path] : 'Object'
      end

      def ann_owner_fields
        sc = ann_scope
        entry = ann_namespace_entry
        kind = if sc.in_block then :block
               elsif entry.nil? then :top
               elsif entry[:kind] == :sclass then :sclass
               else entry[:kind]
               end
        { owner_kind: kind, owner_path: kind == :block || kind == :sclass ? nil : ann_scope_path, in_block: sc.in_block }
      end

      def ann_def_record(extra)
        sc = ann_scope
        fields = ann_owner_fields
        recv = extra[:receiver]
        singleton = !recv.nil? || fields[:owner_kind] == :sclass
        if recv
          fields[:owner_kind] = :dynamic if recv != :self
          fields[:owner_kind] = :dynamic if sc.in_method
          fields[:owner_path] = recv == :self && !sc.in_method && !sc.in_block ? ann_scope_path : nil
        end
        vis = if singleton || sc.in_method || sc.in_block then nil else extra[:vis] || sc.vis end
        fields.merge(singleton: singleton, receiver: recv, visibility: vis, nested_in_method: sc.in_method,
                     lexical_owner_path: ann_scope_path, fingerprint: extra[:fingerprint])
      end

      # The opener facts for class_statement/module_statement (+node+ ClassNode/ModuleNode).
      def ann_class_facts(node)
        sc = ann_scope
        entry = ann_namespace_entry
        ns_known = entry.nil? || !entry[:path].nil?
        namespace = entry && entry[:path]
        pnode = node.constant_path
        sp = Annotations.static_path(pnode)
        name = pnode.name.to_s
        candidates = nil
        if pnode.is_a?(Prism::ConstantReadNode)
          outer = :lexical
          path = ns_known ? Annotations.qualify(namespace, name) : nil
        elsif sp.nil?
          outer = :dynamic
          path = nil
        elsif sp[0]
          outer = :root
          path = sp[1].join('::')
        else
          outer = :path
          if entry.nil?
            path = sp[1].join('::')
          else
            path = nil
            chain = sc.cref.reverse.map { |e| e[:path] }
            candidates = chain.all? ? chain.map { |p| Annotations.qualify(p, sp[1].join('::')) } + [sp[1].join('::')] : nil
          end
        end
        stmts = body_statements(node.body)
        facts = { kind: node.is_a?(Prism::ClassNode) ? :class : :module, name: name, written: Annotations.path_text(sp) || pnode.location.slice,
                  outer: outer, path: path, candidates: candidates, namespace: ns_known ? namespace : nil,
                  empty_body: stmts.empty?, in_block: sc.in_block, conditional: !ann_straight?(node) }
        if node.is_a?(Prism::ClassNode)
          sup = node.superclass && MrbcRb.unparen(node.superclass)
          ssp = sup && Annotations.static_path(sup)
          facts[:superclass] = sup.nil? ? { kind: :none, text: nil } : (ssp ? { kind: :const, text: Annotations.path_text(ssp) } : { kind: :other, text: nil })
        end
        facts[:cref_entry] = { kind: facts[:kind], path: path, singleton_of: nil, outer: outer }
        facts
      end

      def ann_sclass_facts(node)
        entry = ann_namespace_entry
        obj = MrbcRb.unparen(node.expression)
        sp = Annotations.static_path(obj)
        target = obj.is_a?(Prism::SelfNode) ? :self : (sp ? :const : :other)
        of = target == :self ? (!ann_scope.in_method && !ann_scope.in_block && (entry.nil? || entry[:path]) ? ann_scope_path : nil) : nil
        { kind: :sclass, target: target, target_text: Annotations.path_text(sp), singleton_of: of, path: nil,
          empty_body: body_statements(node.body).empty?, in_block: ann_scope.in_block, conditional: !ann_straight?(node),
          cref_entry: { kind: :sclass, path: nil, singleton_of: of, outer: :sclass } }
      end

      # Hook of Compiler#statement: visibility calls of a class/module/singleton body (`private`, `private def x`, `private :a`).
      def ann_statement(node)
        return unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.nil? && VIS_CALLS.include?(node.name)

        sc = ann_scope
        return if sc.in_method || sc.in_block

        args = node.arguments&.arguments
        if args.nil?
          sc.vis = node.name if %i[private public protected module_function].include?(node.name)
        elsif args.size == 1 && args[0].is_a?(Prism::DefNode) && %i[private public protected module_function].include?(node.name)
          (@ann_def_vis ||= {}.compare_by_identity)[args[0]] = node.name
        else
          lits = args.map { |a| a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode) ? a.unescaped.to_s : nil }
          sc.vis_calls << { name: node.name, args: lits.all? ? lits : nil, line: node.location.start_line, owner_path: ann_scope_path }
        end
      end

      def ann_def_node(node, index)
        recv = node.receiver && MrbcRb.unparen(node.receiver)
        r = case recv
            when nil then nil
            when Prism::SelfNode then :self
            else Annotations.path_text(Annotations.static_path(recv)) || recv.location.slice
            end
        ann_extra(%i[TDEF SDEF DEF], { receiver: r, vis: @ann_def_vis&.delete(node), child: index,
                                       fingerprint: Annotations.fingerprint([node.parameters, node.body, node.locals]) })
      end

      # Called on the root Compiler: the annotations of the whole tree.
      def ann_result
        order = []
        walk = lambda do |c, parent|
          c.instance_variable_set(:@ann_index, order.size)
          order << [c, parent]
          c.children.each { |ch| walk.call(ch, c) }
        end
        walk.call(self, nil)
        ireps = order.each_with_index.map do |(c, parent), i|
          sc = c.ann_scope
          ops = c.ann_ops.transform_values do |op|
            op = op.dup
            if (k = op.delete(:child))
              op[:body_irep] = c.children[k]&.instance_variable_get(:@ann_index)
            elsif %i[CLASS MODULE SCLASS EXEC TDEF SDEF DEF].include?(op[:op])
              op[:body_irep] = nil
            end
            op
          end
          opener = sc.owner_pc && parent
          sends = c.ann_block_sends.transform_values do |s|
            s = s.dup
            k = s.delete(:child)
            s[:block_irep] = k && c.children[k]&.instance_variable_get(:@ann_index)
            s
          end
          { index: i, parent: parent&.instance_variable_get(:@ann_index), kind: sc.kind, cref: sc.cref.map(&:dup),
            owner: opener ? { irep: parent.instance_variable_get(:@ann_index), pc: sc.owner_pc } : nil,
            in_block: sc.in_block, vis_calls: sc.vis_calls, ops: ops.sort.to_h,
            loops: c.ann_loops.sort_by { |l| l[:header_pc] }, block_sends: sends.sort.to_h }
        end
        { version: VERSION, ireps: ireps }
      end
    end
  end
end
