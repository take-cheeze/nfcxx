# frozen_string_literal: true

# PURE_CONST_EVAL: a class body's computed constant (`X = (0..11).each_with_object({}) { ... }.freeze`) evaluated once, at
# build time, under CRuby, and handed to the class program (LoadCompile::Blob) as the data it came to. The load then
# builds the value from bytes like any literal table and no block runs at boot.
#
# What makes a constant foldable is that nothing in it can differ between the build machine and the device:
#
#   * the statement reads only literals, earlier constants of the same body that are themselves pure (replayed first,
#     in source order, so the value is the one the statement would have read; `prelude_for`), and the core classes
#     named in CORE_CONSTS;
#   * it calls only the methods in METHODS (arithmetic, Array/Hash/String/Symbol/Range/Integer methods that every mruby
#     build has and that do not read the environment, the clock, a random source or a file), always on a receiver, so no
#     engine method, no `new` of an engine class and no global is reachable;
#   * the value is data (`value_ok?`): nil/true/false, Integers that fit 32 bits (a wider one is a bignum on a 32-bit
#     mrb_int target, which only an irep literal builds), Floats a float32 holds exactly, Symbols, UTF-8/ASCII Strings,
#     Arrays, Hashes and Ranges of those, exact classes, no default procs or ivars, and no unfrozen container or String
#     reached twice (the copy would split it).
#
# Anything else is not folded and the statement stays as it is: bytecode, in the residual mrblib. Fidelity against the
# mruby runtime is `scripts/bc2cpp/class_body_check.rb`'s job: it boots mruby, computes the same statements and
# compares class, frozen state, order and content with this module's value through `CANONICAL`.
require 'prism'
require 'set'
require_relative 'class_body_scan'

module PureEval
  module_function

  # The constants a folded statement may name without defining them: classes every mruby has, used as namespaces for
  # their own pure methods (`Array.new(3, 0)`).
  CORE_CONSTS = %w[Array Hash String Integer Symbol Range Float].freeze

  # Methods a folded statement may call. By name, on any receiver: the evaluation runs under CRuby and the check
  # compares the result with mruby's, so a method that behaves differently between the two shows up there.
  METHODS = %w[
    each each_with_object each_with_index map collect flat_map select filter reject zip with_index inject reduce
    times upto downto step to_a to_h to_s to_sym to_i to_f upcase downcase capitalize swapcase reverse
    sort sort_by min max sum size length count first last take drop join uniq compact flatten
    + - * / % ** << >> & | ^ ~ == != < <= > >= <=> ! -@ +@ [] []= push append unshift concat pop shift
    freeze dup merge key? include? fetch keys values succ pred abs ceil floor divmod
    chars bytes split strip ljust rjust center start_with? end_with? new
  ].to_set.freeze
  # `X.new(...)`: a core container only. Any other receiver is an engine object or a class.
  NEW_RECEIVERS = %w[Array Hash String].freeze
  # Statements between a constant a fold replays and the fold that may change what it holds: anything that is not one
  # of these could (a DSL call, a block, a branch).
  HARMLESS_BETWEEN = %i[def declarative const_literal const_pure const_computed class_ivar].freeze

  # [value, reason, source]: the CRuby value of constant `statements[index]` of one body (ClassBodyScan::Statement, in
  # source order) and the Ruby source that computed it (the constants it read, then the statement), or nil and why it is
  # not folded. `magic`: the file has `# frozen_string_literal: true`.
  def fold(statements, index, magic: false)
    node = statements.fetch(index).node
    return [nil, 'not a constant', nil] unless node.is_a?(Prism::ConstantWriteNode)

    why = reject_reason(node.value)
    return [nil, why, nil] if why

    prelude = prelude_for(statements, index)
    return [nil, prelude, nil] if prelude.is_a?(String)

    source = prelude.map { |s| s.node.slice }.push(node.slice).join("\n")
    value = evaluate(source, node.name.to_s, magic)
    return [nil, 'the evaluation raised', nil] unless value

    value = value.first
    why = value_ok?(value) || prelude_frozen?(prelude, magic)
    why ? [nil, why, nil] : [value, nil, source]
  end

  # The earlier constants of the body that `statements[index]` reads, transitively, in source order; or a reason.
  def prelude_for(statements, index)
    names = reads(statements[index].node.value)
    chosen = []
    loop do
      added = false
      (0...index).each do |i|
        s = statements[i]
        next unless s.node.is_a?(Prism::ConstantWriteNode) && names.include?(s.node.name.to_s) && !chosen.include?(i)

        why = reject_reason(s.node.value)
        return "reads #{s.node.name}, which is #{why}" if why

        chosen << i
        names.merge(reads(s.node.value))
        added = true
      end
      break unless added
    end
    missing = names.reject { |n| CORE_CONSTS.include?(n) || chosen.any? { |i| statements[i].node.name.to_s == n } }
    return "reads #{missing.first}, which the body does not define before it" unless missing.empty?

    unless chosen.empty?
      between = statements[chosen.min + 1...index]
      return 'something that may change the constants it reads sits between them and it' unless between.all? { |s| HARMLESS_BETWEEN.include?(s.category) }
    end
    chosen.sort.map { |i| statements[i] }
  end

  # A constant the fold read must not be changeable afterwards: its container is frozen.
  def prelude_frozen?(prelude, magic)
    prelude.each_with_index do |s, i|
      value = evaluate(prelude.first(i + 1).map { |p| p.node.slice }.join("\n"), s.node.name.to_s, magic)&.first
      return "reads #{s.node.name}, which is not frozen" unless value.frozen?
    end
    nil
  end

  def reads(node, into = Set.new)
    case node
    when Prism::ConstantReadNode then into << node.name.to_s
    when Prism::ConstantPathNode then into << node.slice
    else node.compact_child_nodes.each { |c| reads(c, into) } if node
    end
    into
  end

  # Runs `source` in a fresh Module and returns [value of constant `name`], or nil when it raises.
  def evaluate(source, name, magic)
    text = +''
    text << "# frozen_string_literal: true\n" if magic
    text << source
    verbose = $VERBOSE
    $VERBOSE = nil
    mod = Module.new
    mod.module_eval(text, '(pure_eval)', 1)
    [mod.const_get(name, false)]
  rescue StandardError, ScriptError
    nil
  ensure
    $VERBOSE = verbose
  end

  # ---- the guard: which expressions may be evaluated at build time ----------------------------------------------

  PASS_THROUGH = [Prism::StatementsNode, Prism::ArrayNode, Prism::HashNode, Prism::AssocNode, Prism::RangeNode,
                  Prism::ParenthesesNode, Prism::BeginNode, Prism::SplatNode, Prism::BlockNode, Prism::BlockParametersNode,
                  Prism::ParametersNode, Prism::RequiredParameterNode, Prism::MultiTargetNode, Prism::IfNode,
                  Prism::UnlessNode, Prism::ElseNode, Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode,
                  Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableTargetNode, Prism::AndNode, Prism::OrNode,
                  Prism::ArgumentsNode, Prism::KeywordHashNode].freeze

  # nil when `node` may be evaluated at build time, else why not.
  def reject_reason(node)
    case node
    when nil then nil
    when Prism::IntegerNode, Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SymbolNode
      nil
    when Prism::StringNode then ClassBodyScan::Pure.heredoc?(node) ? 'a heredoc' : nil
    when Prism::ConstantReadNode then ClassBodyScan::RUNTIME_CONSTS.include?(node.name.to_s) ? 'a runtime constant' : nil
    when Prism::ConstantPathNode then node.parent.nil? ? nil : reject_reason(node.parent)
    when Prism::CallNode then call_reason(node)
    else
      return "a #{node.class.name.split('::').last}" unless PASS_THROUGH.any? { |k| node.is_a?(k) }
      return 'a begin/rescue' if node.is_a?(Prism::BeginNode) && (node.rescue_clause || node.ensure_clause || node.else_clause)

      node.compact_child_nodes.each do |c|
        why = reject_reason(c)
        return why if why
      end
      nil
    end
  end

  def call_reason(node)
    name = node.name.to_s
    return 'a call without a receiver' if node.receiver.nil?
    return 'a safe-navigation call' if node.safe_navigation?
    return "the method #{name}" unless METHODS.include?(name)
    return 'new on a class that is not a core container' if name == 'new' && !NEW_RECEIVERS.include?(node.receiver.slice)

    [node.receiver, node.arguments, node.block].each do |c|
      why = reject_reason(c)
      return why if why
    end
    nil
  end

  # ---- the value ----------------------------------------------------------------------------------------------

  # nil when `value` is data the class program can spell, else why not.
  def value_ok?(value, seen = {}.compare_by_identity)
    case value
    when nil, true, false, Symbol then nil
    when Integer then ClassBodyScan::Pure::INT_RANGE.cover?(value) ? nil : 'an Integer outside 32 bits'
    when Float
      value.finite? && [value].pack('e').unpack1('e') == value ? nil : 'a Float that float32 does not hold exactly'
    when String
      return 'a String subclass, or with ivars' unless value.instance_of?(String) && value.instance_variables.empty?
      return 'a String that is not UTF-8' unless [Encoding::UTF_8, Encoding::US_ASCII].include?(value.encoding) && value.valid_encoding?

      share(value, seen)
    when Array
      return 'an Array subclass, or with ivars' unless value.instance_of?(Array) && value.instance_variables.empty?

      share(value, seen) || first_reason(value, seen)
    when Hash
      return 'a Hash with a default, identity keys or ivars' unless value.instance_of?(Hash) && value.default.nil? && value.default_proc.nil? &&
                                                                    !value.compare_by_identity? && value.instance_variables.empty?

      share(value, seen) || first_reason(value.flatten(1), seen)
    when Range
      return 'a Range of something other than Integers' unless value.instance_of?(Range) && [value.begin, value.end].all? { |e| e.nil? || e.is_a?(Integer) }

      [value.begin, value.end].all? { |e| e.nil? || ClassBodyScan::Pure::INT_RANGE.cover?(e) } ? nil : 'a Range past 32 bits'
    else "a #{value.class}, which is not data"
    end
  end

  def first_reason(values, seen)
    values.each do |e|
      why = value_ok?(e, seen)
      return why if why
    end
    nil
  end

  # An unfrozen container or String reached twice would be two objects after the copy; a frozen String can be shared.
  def share(value, seen)
    return nil if value.is_a?(String) && value.frozen?
    return 'an unfrozen object that two places share' if seen.key?(value)

    seen[value] = true
    nil
  end

  # One description of a value, written to run under CRuby and under mruby alike (no Regexp, no format), so the check
  # can run it in each VM and compare: class, frozen state, order, content. A Float is spelled by its integer and
  # fraction parts because Float#to_s differs between the two; a Range's frozen state is not part of it.
  CANONICAL = <<~'RUBY'
    def bc2cpp_canonical(v)
      case v
      when nil then 'nil'
      when true then 'true'
      when false then 'false'
      when Symbol then [':', v.to_s].join
      when Integer then ['i', v.to_s].join
      when Float then ['f', v.floor.to_s, '+', ((v - v.floor) * 1048576).floor.to_s].join
      when String then [v.frozen? ? 'S' : 's', v.size.to_s, ':', v].join
      when Array then [v.frozen? ? 'A' : 'a', '[', v.map { |e| bc2cpp_canonical(e) }.join(','), ']'].join
      when Hash then [v.frozen? ? 'H' : 'h', '{', v.map { |k, x| [bc2cpp_canonical(k), '=>', bc2cpp_canonical(x)].join }.join(','), '}'].join
      when Range then ['r', bc2cpp_canonical(v.begin), v.exclude_end? ? '...' : '..', bc2cpp_canonical(v.end)].join
      else [v.class.to_s, '?'].join
      end
    end
  RUBY
end
