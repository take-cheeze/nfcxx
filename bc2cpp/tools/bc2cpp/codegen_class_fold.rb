# frozen_string_literal: true

# CLASS_BODY_FOLD: a constant a class body builds with a block (`X = (0..11).each_with_object({}) { ... }.freeze`) has no
# unit code of its own (BLOCK and SENDB are not in a unit). PureEval folds it at build time, under CRuby, from the body's
# source; the unit writes the folded value where the statement's SETCONST reads its register, and skips the statement's
# instructions. A constant that does not fold leaves its body refused, as before.

require 'prism'
require 'set'
require_relative 'pure_eval'

class CodeGen
  # The instructions a folded statement may contain besides its block: what a constant statement is made of.
  FOLD_WINDOW_OPS = (CLASS_BODY_OPS + %i[BLOCK SENDB SEND0]).freeze

  # Raised when a folded value has no C++ form here; the constant then does not fold.
  class Unfoldable < StandardError; end

  # { SETCONST index => { skip: [indices of the statement's other instructions], code: C++ text } } for the constants of
  # `program` that a block builds and that fold; {} when none does.
  def folded_class_constants(program, irep, owner)
    folds = {}
    window_start = 0
    ordinal = 0
    program.each_source do |insn, idx|
      next unless insn.op == :SETCONST

      window = (window_start...idx).map { |i| [program.source_at(i), i] }
      window_start = idx + 1
      ordinal += 1
      next unless window.any? { |w, _| %i[BLOCK SENDB].include?(w&.op) }
      next unless window.all? { |w, _| w.nil? || FOLD_WINDOW_OPS.include?(w.op) }

      code = folded_constant_code(irep, owner, insn.const_name, insn.regs.last, ordinal - 1)
      next unless code

      folds[idx] = { skip: window.map(&:last), code: code }
    end
    folds
  end

  # The C++ assigning the folded value of constant `name` (defined in `owner`'s body in the source) to register `reg`,
  # or nil when the constant does not fold or has no C++ form.
  def folded_constant_code(irep, owner, name, reg, ordinal)
    statements = source_statements(irep.file, owner)
    return nil unless statements

    # The instructions between this SETCONST and the one before it are this statement's only when the statement before it
    # is a constant write (or it is the first statement): then nothing else in the source lies in the skipped window.
    index = statements.index { |s| s.node.is_a?(Prism::ConstantWriteNode) && s.node.name.to_s == name }
    return nil unless index
    return nil unless index.zero? || statements[index - 1].node.is_a?(Prism::ConstantWriteNode)
    return nil unless statements.count { |s| s.node.is_a?(Prism::ConstantWriteNode) && s.node.name.to_s == name } == 1

    value, why, = PureEval.fold(statements, index)
    return nil if value.nil? && why

    lines = +''
    result = fold_expr(value, lines, reg)
    "#{lines}  r#{reg} = #{result};\n"
  rescue Unfoldable
    nil
  end

  # The statements of the class or module `owner` in `file`, as PureEval.fold reads them: one wrapper per statement.
  def source_statements(file, owner)
    return nil unless file && File.file?(file)

    node = find_path(Prism.parse_file(file).value.statements, owner.split('::'))
    return nil unless node

    node.body.body.map { |statement| FoldStatement.new(statement) }
  end

  FoldStatement = Struct.new(:node)

  # The class or module node whose lexical path is `path`, searched through the nesting; nil or ambiguous -> nil.
  def find_path(statements, path, prefix = [])
    hits = []
    statements.body.each do |node|
      next unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

      full = prefix + node.constant_path.slice.split('::')
      hits << node if full == path
      nested = find_path(node.body, path, full) if node.body.is_a?(Prism::StatementsNode)
      hits.concat(nested ? [nested] : []) if nested.is_a?(Prism::ClassNode) || nested.is_a?(Prism::ModuleNode)
    end
    hits.size == 1 ? hits.first : nil
  end

  # C++ for a folded value: statements that build it go into `lines`, the result is the expression for them.
  def fold_expr(value, lines, reg)
    case value
    when nil then 'mrb_nil_value()'
    when true then 'mrb_true_value()'
    when false then 'mrb_false_value()'
    when Integer then "mrb_fixnum_value(#{value})"
    when Float
      raise Unfoldable unless value.finite?

      "mrb_float_value(M, #{format('%.17g', value)})"
    when Symbol then "mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(value.to_s)}))"
    when String
      raise Unfoldable if value.include?("\0")

      name = fold_name(reg, lines)
      lines << "  mrb_value #{name} = mrb_str_new_cstr(M, #{c_string_literal(value)});\n"
      freeze_fold(name, value, lines)
    when Array
      name = fold_name(reg, lines)
      lines << "  mrb_value #{name} = mrb_ary_new_capa(M, #{value.size});\n"
      value.each { |element| lines << "  mrb_ary_push(M, #{name}, #{fold_expr(element, lines, reg)});\n" }
      freeze_fold(name, value, lines)
    when Hash
      name = fold_name(reg, lines)
      lines << "  mrb_value #{name} = mrb_hash_new_capa(M, #{value.size});\n"
      value.each do |key, element|
        lines << "  mrb_hash_set(M, #{name}, #{fold_expr(key, lines, reg)}, #{fold_expr(element, lines, reg)});\n"
      end
      freeze_fold(name, value, lines)
    when Range
      left = fold_expr(value.begin, lines, reg)
      right = fold_expr(value.end, lines, reg)
      "mrb_range_new(M, #{left}, #{right}, #{value.exclude_end? ? 'TRUE' : 'FALSE'})"
    else
      raise Unfoldable
    end
  end

  def fold_name(reg, lines)
    @fold_count = (@fold_count || 0) + 1
    "fold#{reg}_#{@fold_count}"
  end

  def freeze_fold(name, value, lines)
    lines << "  #{name} = mrb_obj_freeze(M, #{name});\n" if value.frozen?
    name
  end
end
