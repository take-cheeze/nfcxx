# frozen_string_literal: true

require 'prism'
require 'set'
require_relative 'ruby_parse_cache'

# PredicateReturns: a method whose name ends in `?` returns bool. The program is closed, so the check is static: every
# return of such a method must be provably bool, or the method must be listed in scripts/bc2cpp/predicate_whitelist.txt.
# A method that is neither is a build error, not a run-time one (the rule is the compiler's, not the program's).
#
# Provably bool is judged from the source alone: the literals true and false, `&&` / `||` of two bool values, a branch
# (if, unless, case, begin) whose every arm is bool and that has an else, and a call to one of the built-in predicates in
# BOOL_CALLS. Any other call is unknown, so a `?` call that is not in the list is not a proof: the rule never trusts a
# method name it cannot see the body of.
module PredicateReturns
  WHITELIST = File.expand_path('../../scripts/bc2cpp/predicate_whitelist.txt', __dir__)
  ROOT = File.expand_path('../..', __dir__)

  # Built-in calls whose result is a boolean. A program redefining one of these would make the proof wrong; the closed
  # world does not allow redefining a core method, so the names are trusted.
  BOOL_CALLS = %i[== != < > <= >= ! nil? is_a? kind_of? instance_of? respond_to? include? empty? frozen? equal? eql?
                  start_with? end_with? any? all? none? key? has_key? has_value? member? between?
                  const_defined? method_defined? instance_variable_defined? block_given?].freeze

  Violation = Struct.new(:path, :line, :name, :reason)

  module_function

  # The bool proof of one value expression.
  def bool_expr?(node)
    case node
    when nil then false
    when Prism::TrueNode, Prism::FalseNode then true
    when Prism::ParenthesesNode then bool_expr?(node.body)
    when Prism::StatementsNode then !node.body.empty? && bool_expr?(node.body.last)
    when Prism::AndNode, Prism::OrNode then bool_expr?(node.left) && bool_expr?(node.right)
    when Prism::CallNode then BOOL_CALLS.include?(node.name)
    when Prism::IfNode then !node.subsequent.nil? && bool_expr?(node.statements) && bool_expr?(node.subsequent)
    when Prism::UnlessNode then !node.else_clause.nil? && bool_expr?(node.statements) && bool_expr?(node.else_clause)
    when Prism::ElseNode then bool_expr?(node.statements)
    when Prism::CaseNode then case_bool?(node)
    when Prism::BeginNode then begin_bool?(node)
    else false
    end
  end

  def case_bool?(node)
    return false if node.else_clause.nil? || !bool_expr?(node.else_clause)

    node.conditions.all? { |when_node| bool_expr?(when_node.statements) }
  end

  def begin_bool?(node)
    return false unless bool_expr?(node.statements)
    return false unless node.rescue_clause.nil? || rescue_bool?(node.rescue_clause)

    node.else_clause.nil? || bool_expr?(node.else_clause)
  end

  def rescue_bool?(clause)
    clause.statements && bool_expr?(clause.statements) && (clause.subsequent.nil? || rescue_bool?(clause.subsequent))
  end

  # The value of each explicit `return` in a method (not in a nested method); nil for a bare `return`.
  def return_values(def_node)
    found = []
    collect = lambda do |node|
      next if node.is_a?(Prism::DefNode) && !node.equal?(def_node)

      found << (node.arguments&.arguments&.first) if node.is_a?(Prism::ReturnNode)
      node.compact_child_nodes.each { |child| collect.call(child) }
    end
    collect.call(def_node.body) if def_node.body
    found
  end

  # The value a method returns by falling off its end; nil for an empty body. A last `return` is already in
  # return_values, so it is not a value of its own.
  def last_value(def_node)
    last = def_node.body.is_a?(Prism::StatementsNode) ? def_node.body.body.last : def_node.body
    last.is_a?(Prism::ReturnNode) ? :returned : last
  end

  # The method's violation, or nil when every value it returns is provably bool.
  def predicate_violation(path, def_node, owner)
    last = last_value(def_node)
    values = return_values(def_node)
    values << last unless last == :returned
    return nil if values.all? { |value| bool_expr?(value) }

    Violation.new(path, def_node.location.start_line, "#{owner}##{def_node.name}", 'a return is not provably bool')
  end

  # Every predicate of one source text, as violations (the whitelist is applied by the caller).
  def violations_in(path, source = nil)
    parsed = source ? RubyParseCache.parse(source, path) : RubyParseCache.parse_file(path)
    out = []
    walk = lambda do |node, owner|
      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = [owner, node.constant_path.slice].compact.join('::')
        node.compact_child_nodes.each { |child| walk.call(child, inner) }
        next
      when Prism::DefNode
        if node.name.to_s.end_with?('?')
          violation = predicate_violation(path, node, owner || 'Object')
          out << violation if violation
        end
      end
      node.compact_child_nodes.each { |child| walk.call(child, owner) }
    end
    walk.call(parsed.value, nil)
    out
  end

  # The whitelist: one `path Owner#name` per line, `#` comments and blank lines ignored.
  def whitelist
    return Set.new unless File.exist?(WHITELIST)

    File.readlines(WHITELIST, chomp: true).reject { |l| l.empty? || l.start_with?('#') }.to_set
  end

  def key(violation)
    "#{relative(violation.path)} #{violation.name}"
  end

  def relative(path)
    File.expand_path(path).delete_prefix("#{ROOT}/")
  end

  # Build gate: raises with every unlisted predicate, and warns about whitelist entries that are no longer needed.
  def enforce!(paths)
    listed = whitelist
    checked = paths.map { |path| relative(path) }.to_set
    found = paths.flat_map { |path| violations_in(path) }
    unlisted = found.reject { |v| listed.include?(key(v)) }
    stale = listed.select { |entry| checked.include?(entry.split(' ', 2).first) }.to_set - found.map { |v| key(v) }.to_set
    stale.each { |entry| warn "bc2cpp: predicate whitelist entry is no longer needed: #{entry}" }
    return if unlisted.empty?

    lines = unlisted.map { |v| "  #{relative(v.path)}:#{v.line}: #{v.name} #{v.reason}" }
    raise "bc2cpp: #{unlisted.size} predicate(s) must return bool (return a bool, or list them in " \
          "#{relative(WHITELIST)}):\n#{lines.join("\n")}"
  end
end
