# Native return kinds from the clang AST, by flow analysis over one translation unit (the parallel counterpart of
# tools/bc2cpp/native_return_kinds.rb, which matches return text with regexes).
#
#   clang -fsyntax-only -Xclang -ast-dump=json <flags> SOURCE | ruby native_ast_returns.rb SOURCE > result.json
#
# Each function's kind is the join of its ReturnStmt values. A value is:
#   - a call to an mrb_*_value constructor (the same name table as NativeReturnKinds::ENTRIES) -> that kind;
#   - a call to another function defined in this file -> that function's kind (interprocedural, with a cycle guard);
#   - `self` (the receiver parameter) -> 'self';
#   - a local -> the join of its initializer and every assignment to it in the body (flow-insensitive);
#   - a field `x.f` of a struct the file defines -> the join of every value the file stores into f (FieldIndex);
#   - a conditional -> the join of its two arms; casts and parentheses are transparent;
#   - anything else -> nil (unknown). A join of different kinds is nil.
#
# A nil test (mruby's mrb_nil_p, a macro: `mrb_type(x) == MRB_TT_FALSE && !mrb_fixnum(x)`) narrows a field read inside
# the branch where it proves x non-nil: there the stores of a definitely-nil value are not the value read, so they
# drop out of the join. The branch must not store to the field or use its object bare (see unsafe_branch?).
#
# Trust boundary: a record the file defines has a layout only this file knows, so its fields are written only by this
# file's stores. A pointer to it that reaches other code is opaque there; a write through it by a memory operation in
# another file is not seen here. A whole-record copy, a by-value parameter, or a declaration that is not a brace
# initializer makes the record's fields unknown.
require 'json'
require 'set'
require_relative 'native_return_kinds'

module NativeAstReturns
  UNKNOWN = :unknown
  SELF_KIND = 'self'
  # Helpers whose result class is a contract of mruby's source rather than a proof here. class_name_str (class.c:391-401)
  # returns the class path as a String, and builds the "#<Class:...>" String itself when mrb_class_path is nil; the
  # other mrb_class_path branches (mrb_sym_str, mrb_str_dup) are Strings. So Module#to_s is a String.
  CONTRACT_KINDS = { 'class_name_str' => 'String' }.freeze
  # mrb_obj_class returns mrb_class_real(...) (class.c), a real class with no singleton or iclass wrapper, so
  # mrb_obj_value of its result is a Class whatever the receiver is (Kernel#class, kernel.c mrb_obj_class_m).
  REAL_CLASS_FNS = %w[mrb_obj_class].freeze

  module_function

  # The kind of a constructor call by its callee name, or nil.
  def constructor_kind(name)
    NativeReturnKinds.kind_of_call(name)
  end

  # Every node under +node+, the node first.
  def walk_nodes(node, &block)
    return unless node.is_a?(Hash)

    block.call(node)
    (node['inner'] || []).each { |child| walk_nodes(child, &block) }
  end

  # +node+ without the casts and parentheses around it.
  def strip(node)
    node = node['inner'].first while node && %w[ImplicitCastExpr ParenExpr].include?(node['kind']) && node['inner']
    node
  end

  # [target, value] of an assignment: a built-in `=`, or the operator= a C++ class copy becomes; nil otherwise.
  def assignment(node)
    if node['kind'] == 'BinaryOperator' && node['opcode'] == '=' && node['inner']
      [node['inner'].first, node['inner'].last]
    elsif node['kind'] == 'CXXOperatorCallExpr' && node['inner'] && node['inner'].size == 3
      callee = strip(node['inner'].first)
      [node['inner'][1], node['inner'][2]] if callee['kind'] == 'DeclRefExpr' && callee.dig('referencedDecl', 'name') == 'operator='
    end
  end

  # The expression a statement evaluates: C++ wraps one with its temporaries (ExprWithCleanups), and casts sit around it.
  def statement_expr(node)
    node = node['inner'].first while node['kind'] && %w[ExprWithCleanups ImplicitCastExpr ParenExpr].include?(node['kind']) && node['inner']
    node
  end

  # Joins kinds: the one kind every value agrees on, else nil. UNKNOWN (no value yet) is the identity.
  def join(kinds)
    kinds = kinds.reject { |k| k == UNKNOWN }
    return nil if kinds.empty? || kinds.any?(&:nil?)

    kinds.uniq.size == 1 ? kinds.first : nil
  end

  # join, with K and nil joining to `K?`.
  def join_optional(kinds)
    NativeReturnKinds.join_optional(kinds.reject { |k| k == UNKNOWN })
  end

  # One translation unit: the function definitions and the complete record definitions in the file the source names.
  def translation_unit(root, source)
    fns = {}
    records = {}
    current = nil
    # clang prints a location's file only when it differs from the previous location printed, in print order over
    # every node (locations and ranges, including nested ones). The file is tracked the same way: a declaration with
    # no file of its own belongs to the last file named before it.
    track = lambda do |node|
      return unless node.is_a?(Hash)

      [node['loc'], node.dig('range', 'begin'), node.dig('range', 'end')].each do |loc|
        next unless loc.is_a?(Hash)

        current = loc['file'] if loc['file']
        current = loc.dig('spellingLoc', 'file') || current if loc['spellingLoc']
        current = loc.dig('expansionLoc', 'file') || current if loc['expansionLoc']
      end
    end
    visit = lambda do |node, top|
      track.call(node)
      if node['kind'] == 'FunctionDecl' && node['name'] && node['inner']
        body = node['inner'].find { |c| c['kind'] == 'CompoundStmt' }
        fns[node['name']] = { node: node, body: body, file: current } if body && top
      elsif %w[RecordDecl CXXRecordDecl].include?(node['kind']) && node['name'] && node['completeDefinition'] && top
        records[node['id']] = { node: node, file: current }
      end
      (node['inner'] || []).each do |child|
        visit.call(child, top && %w[NamespaceDecl LinkageSpecDecl TranslationUnitDecl].include?(node['kind']))
      end
    end
    visit.call(root, true)
    in_source = ->(entry) { entry[:file] && File.expand_path(entry[:file]) == File.expand_path(source) }
    {
      fns: fns.select { |_, f| in_source.call(f) },
      records: records.values.select { |r| in_source.call(r) }.map { |r| r[:node] }
    }
  end

  # The function definitions in the file the source names, with their bodies.
  def functions_of(root, source)
    translation_unit(root, source)[:fns]
  end

  # The struct fields of the records a translation unit defines, and every value the unit stores into each one. The
  # record's layout is known only to this file, so these stores are all the writes its fields can see (the trust
  # boundary in the header). A whole-record copy, a by-value parameter, a file-scope object, or a declaration that is
  # not a brace initializer makes every field of that record unknown.
  class FieldIndex
    attr_reader :owners

    # records: RecordDecl nodes of the file. fns: { name => { body: } } of the file's functions. root: the TU.
    def initialize(records, fns, root)
      @owners = {} # FieldDecl id => [record node, index]
      @stores = Hash.new { |hash, id| hash[id] = [] } # FieldDecl id => [[value node, enclosing body]]
      @unknown = Set.new
      @by_type = {}
      # Two records of one name cannot be told apart by their type, so neither is indexed.
      # C names a record `struct NAME` in a type; C++ names it `NAME`. Both spellings are indexed.
      records.group_by { |record| record['name'] }.each_value do |group|
        next unless group.size == 1

        @by_type["struct #{group.first['name']}"] = group.first
        @by_type[group.first['name']] = group.first
      end
      @by_type.each_value do |record|
        fields(record).each_with_index { |field, index| @owners[field['id']] = [record, index] }
      end
      (root['inner'] || []).each { |node| file_scope(node) }
      # The whole definition, so a by-value parameter (a ParmVarDecl outside the body) is seen too.
      fns.each_value do |fn|
        NativeAstReturns.walk_nodes(fn[:node]) { |node| store(node, fn[:body]) }
      end
    end

    def stores(field)
      @stores[field]
    end

    def unknown?(field)
      @unknown.include?(field)
    end

    private

    def fields(record)
      (record['inner'] || []).select { |child| child['kind'] == 'FieldDecl' }
    end

    def mark_unknown(record)
      fields(record).each { |field| @unknown << field['id'] }
    end

    def record_of(type)
      @by_type[type && type['qualType']]
    end

    def file_scope(node)
      return unless node['kind'] == 'VarDecl'

      record = record_of(node['type'])
      mark_unknown(record) if record
    end

    def store(node, body)
      target, value = NativeAstReturns.assignment(node)
      if target
        lhs = NativeAstReturns.strip(target)
        if lhs['kind'] == 'MemberExpr' && @owners.key?(lhs['referencedMemberDecl'])
          @stores[lhs['referencedMemberDecl']] << [value, body]
        elsif (record = record_of(lhs['type']))
          mark_unknown(record)
        end
        return
      end

      case node['kind']
      when 'ParmVarDecl'
        record = record_of(node['type'])
        mark_unknown(record) if record
      when 'VarDecl'
        record = record_of(node['type'])
        return unless record

        init = (node['inner'] || []).last
        if init && NativeAstReturns.strip(init)['kind'] == 'InitListExpr'
          elements = NativeAstReturns.strip(init)['inner'] || []
          fields(record).each_with_index do |field, index|
            # A field the brace list leaves out is zero-initialised, which this analysis does not model.
            elements[index] ? @stores[field['id']] << [elements[index], body] : @unknown << field['id']
          end
        else
          mark_unknown(record)
        end
      end
    end
  end

  # The value of a ReturnStmt-like expression, followed through the TU.
  class Analyzer
    # +optional+: a function returning K or nil is `K?` (NativeReturnKinds.join_optional) instead of unknown. Only the
    # base declarations ask for it; the compile-time kinds (native_fn_kinds.rb) keep single kinds.
    def initialize(fns, external = {}, fields = nil, optional: false)
      @fns = fns
      @optional = optional
      # Kinds of functions defined in other translation units (a previous pass over the sources). A call to one of
      # them takes its kind; `self` is the receiver of the other function, so it is not a kind here.
      @external = external
      @fields = fields || FieldIndex.new([], {}, { 'inner' => [] })
      @self_index = {}
      @memo = {}
      @in_progress = {}
      @narrowed = Set.new
      # The member keys ("base.field") proven non-nil at the value being read.
      @nonnil = Set.new
      @field_memo = {}
      @field_in_progress = {}
      # The names looked up in +external+ (each lookup's callee). A file's result depends on +external+ only through them.
      @external_refs = Set.new
    end

    attr_reader :external_refs

    def join(kinds)
      @optional ? NativeAstReturns.join_optional(kinds) : NativeAstReturns.join(kinds)
    end

    def function_kind(name)
      return @memo[name] if @memo.key?(name)
      return nil if @in_progress[name] # recursion: unknown, the caller's join is then nil (conservative)

      fn = @fns[name] or return external_kind(name)
      @in_progress[name] = true
      outer_narrowed = @narrowed
      outer_nonnil = @nonnil
      stmts = fn[:body]['inner'] || []
      guards = valid_string_guards(stmts, fn[:body])
      kinds = stmts.each_with_index.flat_map do |stmt, i|
        @narrowed = guards.select { |_id, guard_at| guard_at < i }.keys.to_set
        returns = []
        collect_returns(stmt, returns)
        returns.map do |expr, nonnil|
          @nonnil = nonnil
          value_kind(expr, fn[:body])
        end
      end
      kind = join(kinds)
      @narrowed = outer_narrowed
      @nonnil = outer_nonnil
      @in_progress.delete(name)
      @self_index[name] = self_param_index(fn[:node]) if kind == SELF_KIND
      @memo[name] = kind
    end

    # Where the receiver sits among a function's parameters (0 is mrb): a function that returns its `self` parameter
    # returns whatever argument the caller passes in that position. nil when it has no `self` parameter.
    def self_param_index(node)
      params = (node['inner'] || []).select { |child| child['kind'] == 'ParmVarDecl' }
      index = params.index { |param| param['name'] == 'self' }
      index
    end

    # The argument position a call's result is taken from when the callee returns its self parameter: the same-file
    # analysis, or a kind a previous pass recorded for a function of another file ("self:N").
    def identity_index(callee)
      if @fns.key?(callee)
        return nil unless function_kind(callee) == SELF_KIND

        return @self_index[callee]
      end
      @external_refs << callee
      match = /\Aself:(\d+)\z/.match(@external[callee].to_s)
      match && match[1].to_i
    end

    attr_reader :self_index

    # A local tested by a guard `if (!(x.tt == MRB_TT_STRING)) { ...return...; }` at a top-level statement is a String
    # after that statement, when no later statement assigns it (mrb_string_p is that comparison). Returns the locals'
    # ids mapped to the index of their guard, first guard per local.
    def valid_string_guards(stmts, fn_body)
      guards = {}
      stmts.each_with_index do |stmt, i|
        next unless stmt['kind'] == 'IfStmt' && stmt['inner'] && stmt['inner'].size >= 2

        cond, body = stmt['inner'][0], stmt['inner'][1]
        next unless string_test_negated?(cond)

        id = tested_local(cond)
        next unless id && !guards.key?(id)
        # Either the branch leaves (a return), or it makes the local a String: `if (!is_string(v)) v = <String>;` leaves v a
        # String on both paths, and the branch's one assignment must be unconditional in it.
        guards[id] = i if contains_kind?(body, 'ReturnStmt') || string_assignment?(body, id, fn_body)
      end
      guards = guards.select { |id, i| stmts[(i + 1)..].none? { |later| assigns?(later, id) } }
      # `if (mrb_obj_class(mrb, self) != mrb->string_class) return ...;` leaves self an exact String: a receiver whose
      # class is not String returned above (String#to_s, class.c's String counterpart in string.c).
      stmts.each_with_index do |stmt, i|
        next unless stmt['kind'] == 'IfStmt' && stmt['inner'] && stmt['inner'].size >= 2

        cond, body = stmt['inner'][0], stmt['inner'][1]
        next unless self_class_test?(cond) && contains_kind?(body, 'ReturnStmt')

        guards[SELF_GUARD] = i
        break
      end
      guards
    end

    SELF_GUARD = 'self'

    # Whether a guard's branch makes the local +id+ a String: the branch assigns it once, as a direct statement of the
    # branch (so it runs on every path through the branch), and the value is a String.
    def string_assignment?(body, id, fn_body)
      assignments = []
      NativeAstReturns.walk_nodes(body) do |node|
        target, value = NativeAstReturns.assignment(node)
        next unless target && NativeAstReturns.strip(target)['kind'] == 'DeclRefExpr'

        assignments << [node, value] if NativeAstReturns.strip(target).dig('referencedDecl', 'id') == id
      end
      return false unless assignments.size == 1

      node, value = assignments.first
      direct = body['kind'] == 'CompoundStmt' ? body['inner'] || [] : [body]
      return false unless direct.any? { |child| NativeAstReturns.statement_expr(child).equal?(node) }

      value_kind(value, fn_body) == 'String'
    end

    # `mrb_obj_class(mrb, self) != mrb->string_class` (or the equality), the class test a String body makes on self.
    def self_class_test?(cond)
      node = cond
      node = node['inner'].first while %w[ImplicitCastExpr ParenExpr].include?(node['kind']) && node['inner']
      return false unless node['kind'] == 'BinaryOperator' && %w[!= ==].include?(node['opcode'])

      found_self = false
      found_class = false
      walk(node) do |n|
        found_self ||= n['kind'] == 'DeclRefExpr' && n.dig('referencedDecl', 'kind') == 'ParmVarDecl' &&
                       n.dig('referencedDecl', 'name') == 'self'
        found_class ||= n['kind'] == 'MemberExpr' && n['name'] == 'string_class'
      end
      found_self && found_class
    end

    def string_test_negated?(cond)
      node = cond
      node = node['inner'].first while %w[ImplicitCastExpr ParenExpr].include?(node['kind']) && node['inner']
      return false unless node['kind'] == 'UnaryOperator' && node['opcode'] == '!'

      contains_enum?(node, 'MRB_TT_STRING')
    end

    def tested_local(cond)
      found = nil
      walk(cond) do |node|
        decl = node['referencedDecl'] if node['kind'] == 'DeclRefExpr'
        found ||= decl['id'] if decl && decl['kind'] == 'VarDecl'
      end
      found
    end

    def contains_enum?(node, name)
      found = false
      walk(node) do |n|
        found ||= n['kind'] == 'DeclRefExpr' && n.dig('referencedDecl', 'kind') == 'EnumConstantDecl' &&
                  n.dig('referencedDecl', 'name') == name
      end
      found
    end

    def contains_kind?(node, kind)
      found = false
      walk(node) { |n| found ||= n['kind'] == kind }
      found
    end

    # `local = value` in either form: a built-in assignment, or the overloaded operator= a C++ struct copy becomes.
    def assigns?(node, id)
      found = false
      walk(node) do |n|
        target =
          if n['kind'] == 'BinaryOperator' && n['opcode'] == '=' && n['inner']
            n['inner'].first
          elsif n['kind'] == 'CXXOperatorCallExpr' && n['inner'] && n['inner'].size >= 2
            n['inner'][1]
          end
        next unless target

        target = target['inner'].first while %w[ImplicitCastExpr ParenExpr].include?(target['kind']) && target['inner']
        found ||= target['kind'] == 'DeclRefExpr' && target.dig('referencedDecl', 'id') == id
      end
      found
    end

    private

    def external_kind(name)
      @external_refs << name
      kind = @external[name]
      kind == SELF_KIND || kind.to_s.start_with?('self:') ? nil : kind
    end

    # Each ReturnStmt's value with the member keys proven non-nil where it is reached. Only the branches of an if
    # narrow; a return reached through no nil test has none.
    def collect_returns(node, out, nonnil = Set.new)
      return unless node.is_a?(Hash)
      return if node['kind'] == 'LambdaExpr' || node['kind'] == 'BlockExpr'

      children = node['inner'] || []
      out << [children.first, nonnil] if node['kind'] == 'ReturnStmt' && children.any?
      if node['kind'] == 'IfStmt' && children.size >= 2
        cond, yes, no = children
        collect_returns(cond, out, nonnil)
        collect_returns(yes, out, nonnil | proven_non_nil(cond, yes, when_true: true))
        collect_returns(no, out, nonnil | proven_non_nil(cond, no, when_true: false)) if no
        return
      end
      children.each { |child| collect_returns(child, out, nonnil) }
    end

    # The member keys a branch may rely on as non-nil: the test, taken with the branch's truth value, proves the key
    # non-nil (`!nil(x)` is true only for a non-nil x; `nil(x)` is false only for one), and the branch does not change it.
    def proven_non_nil(cond, branch, when_true:)
      test = nil_test(cond)
      return Set.new unless test

      negated, key = test
      return Set.new unless negated == when_true

      base, field = key.split('.')
      unsafe_branch?(branch, base, field) ? Set.new : Set[key]
    end

    # `[negated, key]` for a nil test of exactly one field read through a variable, or nil. mrb_nil_p is a macro, so the
    # test is its expansion, in either value encoding: `(o).w == MRB_Qnil` (word boxing) or
    # `(o).tt == MRB_TT_FALSE && !fixnum(o)`.
    def nil_test(cond)
      node = NativeAstReturns.strip(cond)
      negated = node['kind'] == 'UnaryOperator' && node['opcode'] == '!'
      node = NativeAstReturns.strip(node['inner'].first) if negated
      return nil unless node['kind'] == 'BinaryOperator'

      word = node['opcode'] == '==' && contains_enum?(node, 'MRB_Qnil')
      type = node['opcode'] == '&&' && contains_enum?(node, 'MRB_TT_FALSE')
      return nil unless word || type

      keys = member_keys(node).uniq
      keys.size == 1 ? [negated, keys.first] : nil
    end

    # Every member key under +node+.
    def member_keys(node)
      keys = []
      NativeAstReturns.walk_nodes(node) do |n|
        key = member_key(n)
        keys << key if key
      end
      keys
    end

    # "base.field" for a read of a field of a record this file defines, through a variable; nil otherwise.
    def member_key(node)
      node = NativeAstReturns.strip(node)
      return nil unless node['kind'] == 'MemberExpr' && @fields.owners.key?(node['referencedMemberDecl'])

      base = NativeAstReturns.strip(node['inner'].first)
      decl = base['kind'] == 'DeclRefExpr' && base['referencedDecl']
      return nil unless decl && %w[VarDecl ParmVarDecl].include?(decl['kind'])

      "#{decl['id']}.#{node['referencedMemberDecl']}"
    end

    # Whether a branch can change the key or reach its object by another name: a store to the field or to the object,
    # or a use of the object other than as the base of a member read (`&x`, a copy, a pointer handed out).
    def unsafe_branch?(branch, base, field)
      return false unless branch
      return true if bare_use?(branch, base)

      stored = false
      NativeAstReturns.walk_nodes(branch) do |n|
        target, = NativeAstReturns.assignment(n)
        next unless target

        lhs = NativeAstReturns.strip(target)
        stored ||= lhs['kind'] == 'MemberExpr' && lhs['referencedMemberDecl'] == field
        stored ||= lhs['kind'] == 'DeclRefExpr' && lhs.dig('referencedDecl', 'id') == base
      end
      stored
    end

    # Whether +id+ is used under +node+ other than as the base of a member read.
    def bare_use?(node, id)
      return false unless node.is_a?(Hash)
      return node.dig('referencedDecl', 'id') == id if node['kind'] == 'DeclRefExpr'

      children = node['inner'] || []
      if node['kind'] == 'MemberExpr' && children.any?
        base = NativeAstReturns.strip(children.first)
        return true if base['kind'] != 'DeclRefExpr' && bare_use?(children.first, id)

        return children.drop(1).any? { |child| bare_use?(child, id) }
      end
      children.any? { |child| bare_use?(child, id) }
    end

    # A value expression's kind; `body` is the enclosing function body (for its locals).
    def value_kind(expr, body, seen = {})
      case expr['kind']
      when 'ImplicitCastExpr', 'CStyleCastExpr', 'ParenExpr', 'ExprWithCleanups', 'MaterializeTemporaryExpr',
           'CXXFunctionalCastExpr', 'ConstantExpr', 'CXXBindTemporaryExpr'
        value_kind(expr['inner'].first, body, seen)
      when 'CXXConstructExpr'
        # `return self;` on a class type (mrb_value in C++) is a copy: the one argument is the value.
        args = expr['inner'] || []
        args.size == 1 ? value_kind(args.first, body, seen) : nil
      when 'CXXBoolLiteralExpr'
        'bool'
      when 'ConditionalOperator'
        _cond, yes, no = expr['inner']
        join([value_kind(yes, body, seen), value_kind(no, body, seen)])
      when 'CallExpr'
        callee = callee_name(expr) or return nil
        return CONTRACT_KINDS[callee] if CONTRACT_KINDS.key?(callee)
        return 'Class' if callee == 'mrb_obj_value' && real_class_call?(expr['inner'][1])

        # A callee that returns its self parameter yields the argument passed for it: the CallExpr's children are the
        # callee, then the arguments, so parameter N is argument N + 1.
        index = identity_index(callee)
        return value_kind(expr['inner'][index + 1], body, seen) if index && expr['inner'][index + 1]

        NativeAstReturns.constructor_kind(callee) || function_kind(callee)
      when 'MemberExpr'
        field = expr['referencedMemberDecl']
        return nil unless @fields.owners.key?(field)

        field_kind(field, @nonnil.include?(member_key(expr)))
      when 'DeclRefExpr'
        decl = expr['referencedDecl'] or return nil
        return 'String' if decl['kind'] == 'ParmVarDecl' && decl['name'] == 'self' && @narrowed.include?(SELF_GUARD)
        return 'self' if decl['kind'] == 'ParmVarDecl' && decl['name'] == 'self'
        return nil unless decl['kind'] == 'VarDecl'
        return 'String' if @narrowed.include?(decl['id'])

        local_kind(decl['id'], body, seen)
      else
        nil
      end
    end

    # The join of every value the file stores into a field. With +nonnil+ the stores of a definitely-nil value are left
    # out: the read is proven non-nil, so the store that set the field is not one of those. A field with no store, or
    # whose stores are not all known, is unknown.
    def field_kind(field, nonnil)
      return nil if @fields.unknown?(field)

      memo = [field, nonnil]
      return @field_memo[memo] if @field_memo.key?(memo)
      return nil if @field_in_progress[field] # a store that reads the field itself: unknown

      @field_in_progress[field] = true
      saved = [@narrowed, @nonnil]
      @narrowed = Set.new
      @nonnil = Set.new
      kinds = @fields.stores(field).map { |value, body| value_kind(value, body) }
      @narrowed, @nonnil = saved
      kinds = kinds.reject { |kind| kind == 'nil' } if nonnil
      @field_in_progress.delete(field)
      @field_memo[memo] = join(kinds)
    end

    # The join of a local's initializer and of every `local = value` in the body. A local seen twice in one chain
    # (a loop that feeds itself) contributes nothing new.
    def local_kind(id, body, seen)
      return NativeAstReturns::UNKNOWN if seen[id]

      seen = seen.merge(id => true)
      values = []
      walk(body) do |node|
        if node['kind'] == 'VarDecl' && node['id'] == id && node['inner']
          values << node['inner'].last
        elsif node['kind'] == 'BinaryOperator' && node['opcode'] == '=' && node['inner']
          lhs = node['inner'].first
          target = lhs
          target = target['inner'].first while target['kind'] && %w[ImplicitCastExpr ParenExpr].include?(target['kind']) && target['inner']
          values << node['inner'].last if target['kind'] == 'DeclRefExpr' && target.dig('referencedDecl', 'id') == id
        end
      end
      return nil if values.empty?

      join(values.map { |v| value_kind(v, body, seen) })
    end

    def walk(node, &block)
      return unless node.is_a?(Hash)

      block.call(node)
      (node['inner'] || []).each { |child| walk(child, &block) }
    end

    def callee_name(call)
      callee = call['inner'].first
      callee = callee['inner'].first while callee && callee['inner'] && callee['kind'] != 'DeclRefExpr'
      decl = callee && callee['referencedDecl']
      decl && decl['kind'] == 'FunctionDecl' ? decl['name'] : nil
    end

    # Whether +node+ is a call to a REAL_CLASS_FNS function, through any casts.
    def real_class_call?(node)
      node = NativeAstReturns.strip(node)
      node && node['kind'] == 'CallExpr' && REAL_CLASS_FNS.include?(callee_name(node))
    end
  end

  # { 'function name' => kind-or-nil } for every function defined in +source+.
  # self_index (optional, a Hash) receives the self-parameter position of each function that returns its self.
  # external_refs (optional, a Set) receives the names the analysis looked up in +external+.
  # optional: see Analyzer#initialize.
  def analyze(root, source, external: {}, self_index: nil, external_refs: nil, optional: false)
    unit = translation_unit(root, source)
    fns = unit[:fns]
    analyzer = Analyzer.new(fns, external, FieldIndex.new(unit[:records], fns, root), optional: optional)
    kinds = fns.keys.sort.to_h { |name| [name, analyzer.function_kind(name)] }
    self_index&.merge!(analyzer.self_index)
    external_refs&.merge(analyzer.external_refs)
    kinds
  end
end

if $PROGRAM_NAME == __FILE__
  source = ARGV.fetch(0)
  root = JSON.parse($stdin.read)
  kinds = NativeAstReturns.analyze(root, source)
  puts JSON.pretty_generate(kinds)
end
