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
#   - a conditional -> the join of its two arms; casts and parentheses are transparent;
#   - anything else -> nil (unknown). A join of different kinds is nil.
require 'json'
require_relative 'native_return_kinds'

module NativeAstReturns
  UNKNOWN = :unknown
  # Calls that return their value argument unchanged; `mrb_str_new_frozen` is mrb_obj_freeze over mrb_str_new.
  IDENTITY_CALLS = %w[mrb_obj_freeze].freeze

  module_function

  # The kind of a constructor call by its callee name, or nil.
  def constructor_kind(name)
    entry = NativeReturnKinds::ENTRIES.find { |e| "#{name}(".match?(e.pattern) }
    entry&.kind
  end

  # Joins kinds: the one kind every value agrees on, else nil. UNKNOWN (no value yet) is the identity.
  def join(kinds)
    kinds = kinds.reject { |k| k == UNKNOWN }
    return nil if kinds.empty? || kinds.any?(&:nil?)

    kinds.uniq.size == 1 ? kinds.first : nil
  end

  # One translation unit: the function definitions in the file the source names, with their bodies.
  def functions_of(root, source)
    fns = {}
    current = nil
    visit = lambda do |node|
      current = node['loc']['file'] if node.is_a?(Hash) && node['loc'].is_a?(Hash) && node['loc']['file']
      if node['kind'] == 'FunctionDecl' && node['name'] && node['inner']
        body = node['inner'].find { |c| c['kind'] == 'CompoundStmt' }
        fns[node['name']] = { node: node, body: body, file: current } if body
      elsif %w[NamespaceDecl LinkageSpecDecl].include?(node['kind']) && node['inner']
        node['inner'].each { |child| visit.call(child) }
      end
    end
    root['inner'].each { |node| visit.call(node) }
    fns.select { |_, f| f[:file] && File.expand_path(f[:file]) == File.expand_path(source) }
  end

  # The value of a ReturnStmt-like expression, followed through the TU.
  class Analyzer
    def initialize(fns)
      @fns = fns
      @memo = {}
      @in_progress = {}
    end

    def function_kind(name)
      return @memo[name] if @memo.key?(name)
      return nil if @in_progress[name] # recursion: unknown, the caller's join is then nil (conservative)

      fn = @fns[name] or return nil
      @in_progress[name] = true
      returns = []
      collect_returns(fn[:body], returns)
      kind = NativeAstReturns.join(returns.map { |expr| value_kind(expr, fn[:body]) })
      @in_progress.delete(name)
      @memo[name] = kind
    end

    private

    def collect_returns(node, out)
      return unless node.is_a?(Hash)
      return if node['kind'] == 'LambdaExpr' || node['kind'] == 'BlockExpr'

      out << node['inner'].first if node['kind'] == 'ReturnStmt' && node['inner']
      (node['inner'] || []).each { |child| collect_returns(child, out) }
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
        NativeAstReturns.join([value_kind(yes, body, seen), value_kind(no, body, seen)])
      when 'CallExpr'
        callee = callee_name(expr) or return nil
        # An identity call returns its value argument (mrb_obj_freeze(mrb, obj) is obj, frozen): the kind is the value's.
        # The CallExpr's children are the callee, then the arguments: mrb_obj_freeze(mrb, obj) has the value at [2].
        return value_kind(expr['inner'][2], body, seen) if IDENTITY_CALLS.include?(callee) && expr['inner'][2]

        NativeAstReturns.constructor_kind(callee) || function_kind(callee)
      when 'DeclRefExpr'
        decl = expr['referencedDecl'] or return nil
        return 'self' if decl['kind'] == 'ParmVarDecl' && decl['name'] == 'self'
        return nil unless decl['kind'] == 'VarDecl'
        local_kind(decl['id'], body, seen)
      else
        nil
      end
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

      NativeAstReturns.join(values.map { |v| value_kind(v, body, seen) })
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
  end

  # { 'function name' => kind-or-nil } for every function defined in +source+.
  def analyze(root, source)
    fns = functions_of(root, source)
    analyzer = Analyzer.new(fns)
    fns.keys.sort.to_h { |name| [name, analyzer.function_kind(name)] }
  end
end

if $PROGRAM_NAME == __FILE__
  source = ARGV.fetch(0)
  root = JSON.parse($stdin.read)
  kinds = NativeAstReturns.analyze(root, source)
  puts JSON.pretty_generate(kinds)
end
