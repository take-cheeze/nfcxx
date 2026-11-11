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
  #     ops: { pc => op_record } }             # pc = byte offset of the instruction in this irep (including an EXT prefix)
  #
  #   op_record (every one has op:, line:, file:):
  #     CLASS / MODULE:  kind: :class|:module, name: written last segment, written: source text of the path,
  #                      outer: :lexical (plain `class X`) | :root (`class ::X`, `::A::X`) | :path (`class A::X`) | :dynamic
  #                      (`class expr::X`), path: qualified name String | nil (nil when outer is dynamic or the lexical namespace
  #                      is unknown or the path is relative to a namespace), candidates: [String] | nil (for a relative path
  #                      inside a namespace: the names it can resolve to, innermost namespace first), namespace: the lexical
  #                      namespace path the opener runs in (nil at top level or when unknown), superclass: { kind: :none |
  #                      :const | :other, text: String|nil }, empty_body: true|false, body_irep: Integer | nil
  #     SCLASS:          kind: :sclass, target: :self | :const | :other, target_text:, singleton_of: String | nil,
  #                      path: nil, empty_body:, body_irep:
  #     EXEC:            owner_pc: pc of the opener this EXEC runs the body of, body_irep: Integer
  #     TDEF / SDEF / DEF: name:, owner_kind: :top|:class|:module|:singleton_class|:block|:dynamic, owner_path: String | nil (the
  #                      class the method lands on when statically evident; "Object" at top level), singleton: true|false,
  #                      receiver: nil | :self | source text of `def Recv.m`, visibility: :public|:private|:protected|
  #                      :module_function | nil (nil when not evident: inside a block, a method or a singleton def),
  #                      nested_in_method:, in_block:, lexical_owner_path:, fingerprint: hash of the def's parameters+body
  #                      subtree with locations stripped, body_irep: Integer
  #     ALIAS / UNDEF:   names: [String] (ALIAS: new, old), owner_kind:, owner_path:, in_block:
  #     SETCONST / SETMCNST: name:, scope_path: String|nil (SETCONST: the lexical class the constant is set on; "Object" at top;
  #                      nil when unknown), base: for SETMCNST the written base path text (nil when dynamic), base_rooted:
  #     GETCONST:        name:   (resolves against the irep's cref chain, then the ancestors of the innermost entry, then Object)
  #     GETMCNST:        name:, base: written base path text (nil when dynamic), base_rooted:
  #
  # A table is only meaningful for the irep tree it was built with; Annotations.verify checks the pcs/ops against decoded code.
  module Annotations
    VERSION = 1
    TRACKED = %i[CLASS MODULE SCLASS EXEC TDEF SDEF DEF ALIAS UNDEF SETCONST SETMCNST GETCONST GETMCNST].to_h { |o| [o, true] }.freeze
    VIS_CALLS = %i[private public protected module_function private_class_method public_class_method private_constant].freeze

    # Emitter-side state of one irep being compiled.
    Scope = Struct.new(:kind, :cref, :vis, :in_block, :in_method, :owner_pc, :vis_calls)

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

    def path_text(sp) = sp && "#{'::' if sp[0]}#{sp[1].join('::')}"

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
        @ann_scope ||= Scope.new(:top, [].freeze, :public, false, false, nil, [])
      end

      def ann_ops = (@ann_ops ||= {})

      # Called on a child Compiler right after it is built: +kind+ is :method, :body (class/module/sclass), :block or :for.
      def ann_enter(parent, kind)
        ps = parent.ann_scope
        @ann_scope =
          case kind
          when :body
            opener = parent.instance_variable_get(:@ann_cur_opener)
            Scope.new(opener[:body_kind], (ps.cref + [opener[:cref_entry]]).freeze, :public, false, false, opener[:pc], [])
          when :method then Scope.new(:method, ps.cref, nil, ps.in_block, true, nil, [])
          else Scope.new(kind, ps.cref, nil, true, ps.in_method, nil, [])
          end
        @ann_parent = parent
      end

      # Hook of Compiler#emit: +start+ is the pc (the EXT prefix included), +operands+ the instruction's operands.
      def ann_emit(name, start, operands)
        return unless TRACKED.key?(name)

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
          @ann_cur_opener = { pc: start, body_kind: :"#{name.to_s.downcase}_body", cref_entry: rec.delete(:cref_entry) }
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
        when :SETCONST then rec.merge!(name: @syms[operands[1]].to_s, scope_path: ann_scope_path, in_block: sc.in_block)
        when :SETMCNST then rec.merge!(name: @syms[operands[1]].to_s, base: extra && extra[:base], base_rooted: extra && extra[:base_rooted])
        when :GETCONST then rec[:name] = @syms[operands[1]].to_s
        when :GETMCNST then rec.merge!(name: @syms[operands[1]].to_s, base: extra && extra[:base], base_rooted: extra && extra[:base_rooted])
        end
        ann_ops[start] = rec
      end

      def ann_truncate(start)
        @ann_ops&.delete_if { |pc, _| pc >= start }
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
               elsif entry[:kind] == :sclass then :singleton_class
               else entry[:kind]
               end
        { owner_kind: kind, owner_path: kind == :block || kind == :singleton_class ? nil : ann_scope_path, in_block: sc.in_block }
      end

      def ann_def_record(extra)
        sc = ann_scope
        fields = ann_owner_fields
        recv = extra[:receiver]
        singleton = !recv.nil? || fields[:owner_kind] == :singleton_class
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
                  empty_body: stmts.empty?, in_block: sc.in_block }
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
          empty_body: body_statements(node.body).empty?, in_block: ann_scope.in_block,
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
          { index: i, parent: parent&.instance_variable_get(:@ann_index), kind: sc.kind, cref: sc.cref.map(&:dup),
            owner: opener ? { irep: parent.instance_variable_get(:@ann_index), pc: sc.owner_pc } : nil,
            in_block: sc.in_block, vis_calls: sc.vis_calls, ops: ops.sort.to_h }
        end
        { version: VERSION, ireps: ireps }
      end
    end
  end
end
