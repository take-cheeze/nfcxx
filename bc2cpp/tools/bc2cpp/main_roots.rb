# frozen_string_literal: true

require 'json'
require 'set'
require 'digest'

# Read the compiler's selected host program, including preprocessing and callbacks.
# Function names intentionally join overloads: an extra edge retains code.
module MainRoots
  FUNCTION_KINDS = %w[FunctionDecl CXXMethodDecl CXXConstructorDecl CXXDestructorDecl CXXConversionDecl].freeze
  BODY_KINDS = %w[CompoundStmt CXXTryStmt CoroutineBodyStmt].freeze
  EXPORT_ATTRIBUTES = %w[UsedAttr ConstructorAttr DestructorAttr VisibilityAttr DLLExportAttr].freeze
  WRAPPERS = %w[ImplicitCastExpr ParenExpr ExprWithCleanups ConstantExpr CStyleCastExpr CXXStaticCastExpr].freeze
  BRIDGES = %w[mrb_funcall mrb_funcall_id mrb_funcall_argv mrb_funcall_with_block
               mrb_respond_to mrb_obj_respond_to mrb_method_search mrb_method_search_vm
               mrb_method_search_class mrb_define_alias mrb_alias_method].freeze
  NAME_ARGUMENT = { 'mrb_define_alias' => 3, 'mrb_alias_method' => 3 }.freeze
  CONSTRUCTORS = %w[mrb_obj_new mrb_instance_new].freeze
  REFLECTION = %w[send __send__ public_send eval instance_eval instance_exec class_eval module_eval
                  class_exec module_exec define_method define_singleton_method alias_method remove_method
                  undef_method method public_method singleton_method instance_method public_instance_method
                  methods public_methods private_methods protected_methods singleton_methods instance_methods
                  public_instance_methods private_instance_methods protected_instance_methods binding
                  method_defined? public_method_defined? private_method_defined? protected_method_defined?
                  inject reduce to_enum enum_for to_proc].to_set.freeze
  Result = Struct.new(:names, :functions, :refusals, :native_paths, keyword_init: true)

  module_function

  def read(path)
    data = JSON.parse(File.read(path))
    raise 'BC2CPP_MAIN_AST: unsupported manifest format' unless data['format'] == 1

    data.fetch('dependencies').each do |file, digest|
      unless File.file?(file) && Digest::SHA256.file(file).hexdigest == digest
        raise "BC2CPP_MAIN_AST: stale host AST (#{file}); regenerate with scripts/bc2cpp/main_ast.rb"
      end
    end
    roots = data.fetch('roots')
    Result.new(names: roots.fetch('names').to_set, functions: roots.fetch('functions').to_set,
               refusals: roots.fetch('refusals'), native_paths: data.fetch('native_paths', []).to_set)
  end

  def analyze(ast, literal_roots: true)
    functions = Hash.new { |h, k| h[k] = [] }
    variables = {}
    parameters = Hash.new { |h, k| h[k] = [] }
    calls = Hash.new { |h, k| h[k] = [] }
    native_functions = Set.new
    explicit_functions = Set.new
    global_main = false
    initializers = []
    collect = lambda do |node, inside_function, native_unit = false, global_scope = true|
      native_unit ||= node['bc2cpp_native_unit']
      function = FUNCTION_KINDS.include?(node['kind'])
      if function
        if node['virtual'] || %w[CXXConstructorDecl CXXDestructorDecl].include?(node['kind']) ||
           children(node).any? { |child| EXPORT_ATTRIBUTES.include?(child['kind']) }
          explicit_functions << node['name']
        end
        if children(node).any? { |child| BODY_KINDS.include?(child['kind']) }
          global_main ||= node['kind'] == 'FunctionDecl' && node['name'] == 'main' && global_scope && !inside_function
          functions[node['name']] << node
          native_functions << node['name'] if native_unit
          children(node).select { |child| child['kind'] == 'ParmVarDecl' }.each_with_index do |param, index|
            variables[param['id']] = param
            param['bc2cpp_local'] = node['storageClass'] == 'static' || node['mangledName'].to_s.include?('GLOBAL__N_')
            parameters[node['name']] << [param, index]
          end
        end
      elsif node['kind'] == 'VarDecl'
        variables[node['id']] = node
        initializers << node unless inside_function
      elsif %w[FieldDecl ParmVarDecl].include?(node['kind']) && !children(node).empty?
        # Implicit constructors and default arguments need not contain their initializer's AST again.
        initializers << node
      end
      if node['kind'] == 'CallExpr'
        callee = unwrap(children(node).first)
        name = callee&.dig('referencedDecl', 'name')
        calls[name] << children(node).drop(1) if name
      end
      nested_scope = %w[NamespaceDecl CXXRecordDecl RecordDecl ClassTemplateDecl ClassTemplateSpecializationDecl].include?(node['kind'])
      children(node).each { |child| collect.call(child, inside_function || function, native_unit, global_scope && !nested_scope) }
    end
    collect.call(ast, false)
    raise 'BC2CPP_MAIN_AST contains no global definition of main' unless global_main

    escaped = Set.new
    writes = lambda do |node, parent, direct_callee = false|
      if node['kind'] == 'DeclRefExpr' && (variable = variables[node.dig('referencedDecl', 'id')])
        variable['bc2cpp_mutable'] = true unless parent && parent['kind'] == 'ImplicitCastExpr' && parent['castKind'] == 'LValueToRValue'
      end
      if node['kind'] == 'DeclRefExpr' && FUNCTION_KINDS.include?(node.dig('referencedDecl', 'kind')) && !direct_callee
        escaped << node.dig('referencedDecl', 'name')
      end
      children(node).each_with_index do |child, index|
        writes.call(child, node, direct_callee || (node['kind'] == 'CallExpr' && index.zero?))
      end
    end
    writes.call(ast, nil)
    parameters.each do |name, params|
      params.each do |param, index|
        param['bc2cpp_arguments'] = calls[name].map { |args| args[index] } if param['bc2cpp_local'] && !escaped.include?(name)
      end
    end

    names = Set.new
    reached = Set.new
    refusals = []
    queue = ['main', *native_functions, *explicit_functions]
    constructors_seeded = false
    indirect_seeded = false
    visit = lambda do |node, bridge_callee = false, context = 'static initialization'|
      if node['kind'] == 'DeclRefExpr'
        declaration = node['referencedDecl'] || {}
        queue << declaration['name'] if FUNCTION_KINDS.include?(declaration['kind'])
        if BRIDGES.include?(declaration['name']) && !bridge_callee
          refusals << "address of #{declaration['name']} escapes direct-call analysis"
        end
      elsif node['kind'] == 'MemberExpr'
        queue << node['name']
      elsif %w[CXXConstructExpr CXXTemporaryObjectExpr].include?(node['kind'])
        # Constructors/destructors may run callbacks without a DeclRefExpr.
        unless constructors_seeded
          constructors_seeded = true
          functions.each do |name, definitions|
            queue << name if definitions.any? { |d| %w[CXXConstructorDecl CXXDestructorDecl].include?(d['kind']) }
          end
        end
      elsif node['kind'] == 'CallExpr'
        callee = unwrap(children(node).first)
        declaration = callee && callee['referencedDecl']
        function = declaration && declaration['name']
        if BRIDGES.include?(function)
          values = string_values(children(node)[NAME_ARGUMENT.fetch(function, 2) + 1], variables, Set.new)
          values = values.to_set { |value| value.partition("\0").first } if values && function == 'mrb_funcall'
          if values
            names.merge(values)
            reflected = values & REFLECTION
            refusals << "native call to reflective method #{reflected.to_a.sort.join(', ')}" unless reflected.empty?
          else
            refusals << "unresolved method name passed to #{function} in #{context}"
          end
        elsif CONSTRUCTORS.include?(function)
          names << 'initialize'
        elsif (!declaration || !FUNCTION_KINDS.include?(declaration['kind'])) && !indirect_seeded
          # A function pointer may be assigned after its declaration or supplied externally.
          indirect_seeded = true
          queue.concat(functions.keys)
        end
      end
      if literal_roots && node['kind'] == 'StringLiteral' && (value = c_string(node.fetch('value')))
        names << value
        names << value.partition("\0").first
      end
      children(node).each_with_index do |child, index|
        visit.call(child, bridge_callee || (node['kind'] == 'CallExpr' && index.zero? && declaration && BRIDGES.include?(function)), context)
      end
    end
    initializers.each { |node| visit.call(node) }
    until queue.empty?
      name = queue.pop
      next unless reached.add?(name)

      functions[name].each { |definition| visit.call(definition, false, name) }
    end
    Result.new(names: names, functions: reached, refusals: refusals.uniq, native_paths: Set.new)
  end

  def children(node)
    node.fetch('inner', [])
  end

  def unwrap(node)
    while node && WRAPPERS.include?(node['kind'])
      if node['kind'].end_with?('CastExpr')
        allowed = %w[NoOp LValueToRValue ArrayToPointerDecay FunctionToPointerDecay NullToPointer].include?(node['castKind'])
        allowed ||= node['castKind'] == 'IntegralCast' && node.dig('type', 'qualType') == 'mrb_sym' &&
                    children(node).first&.dig('referencedDecl', 'kind') == 'EnumConstantDecl'
        break unless allowed
      end
      node = children(node).first
    end
    node
  end

  def string_values(node, variables, seen)
    node = unwrap(node)
    return nil unless node

    case node['kind']
    when 'StringLiteral'
      value = c_string(node.fetch('value'))
      value && Set[value]
    when 'CXXNullPtrLiteralExpr', 'GNUNullExpr'
      Set.new
    when 'ConditionalOperator'
      arms = children(node).last(2).map { |arm| string_values(arm, variables, seen.dup) }
      arms.all? ? arms.reduce(Set.new, :|) : nil
    when 'DeclRefExpr'
      declaration = node['referencedDecl'] || {}
      if declaration['kind'] == 'EnumConstantDecl' && node.dig('type', 'qualType') == 'mruby_presym' &&
         (match = declaration['name'].match(/\AMRB_(SYM(?:_[QBE])?|OPSYM)__(\w+)\z/))
        if match[1] == 'OPSYM'
          require_relative '../../3rd/mruby/lib/mruby/presym'
          name = MRuby::Presym::OPERATORS.key(match[2])
          return name && Set[name]
        end
        return Set[match[2] + { 'SYM_Q' => '?', 'SYM_B' => '!', 'SYM_E' => '=' }.fetch(match[1], '')]
      end
      id = declaration['id']
      return nil unless id && seen.add?(id)

      variable = variables[id]
      # An address escape or any non-read use can replace the initializer's value.
      return nil unless variable && !variable['bc2cpp_mutable']

      if variable['kind'] == 'ParmVarDecl'
        arguments = variable['bc2cpp_arguments']
        return nil if arguments.nil? || arguments.empty?

        values = arguments.map { |arg| string_values(arg, variables, seen.dup) }
        values.all? ? values.reduce(Set.new, :|) : nil
      else
        string_values(children(variable).last, variables, seen)
      end
    when 'CallExpr'
      callee = unwrap(children(node).first)
      function = callee&.dig('referencedDecl', 'name')
      if %w[mrb_intern mrb_intern_lit mrb_intern_cstr mrb_intern_static].include?(function)
        values = string_values(children(node)[2], variables, seen)
        return nil unless values
        return values.to_set { |value| value.partition("\0").first } if function == 'mrb_intern_cstr'

        length = integer_value(children(node)[3])
        return nil unless length && length >= 0 && values.all? { |value| length <= value.bytesize }

        sliced = values.to_set { |value| value.byteslice(0, length) }
        sliced.all?(&:valid_encoding?) ? sliced : nil
      end
    end
  end

  def integer_value(node)
    return nil unless node
    return node['value'].to_i if node['kind'] == 'IntegerLiteral'

    if %w[ParenExpr ConstantExpr].include?(node['kind'])
      return integer_value(children(node).first)
    end
    if node['kind'] == 'ImplicitCastExpr'
      value = integer_value(children(node).first)
      return value if node['castKind'] == 'NoOp' || (node['castKind'] == 'IntegralCast' && value && (0..127).cover?(value))
    elsif node['kind'] == 'UnaryExprOrTypeTraitExpr' && node['name'] == 'sizeof'
      type = node.dig('argType', 'qualType') || children(node).first&.dig('type', 'qualType')
      match = type&.match(/\A(?:const )?char\[(\d+)\]\z/)
      return match[1].to_i if match
    elsif node['kind'] == 'BinaryOperator' && %w[+ -].include?(node['opcode'])
      left, right = children(node).map { |child| integer_value(child) }
      return node['opcode'] == '+' ? left + right : left - right if left && right
    end
    nil
  end

  def c_string(value)
    literal = value.match(/\A(?:u8)?"(.*)"\z/m)
    return nil unless literal

    literal[1].b.gsub(/\\(?:x[0-9a-fA-F]+|[0-7]{1,3}|.)/m) do |escape|
      if escape.start_with?('\\x') then escape[2..].to_i(16).chr
      elsif escape[1].match?(/[0-7]/) then escape[1..].to_i(8).chr
      else
        { 'n' => "\n", 'r' => "\r", 't' => "\t", 'a' => "\a", 'b' => "\b", 'f' => "\f", 'v' => "\v" }.fetch(escape[1], escape[1])
      end
    end.force_encoding(Encoding::UTF_8)
  end
end
