# frozen_string_literal: true

# Extracts a deliberately small set of direct-call expressions from mruby's
# C method implementations. This is not a C-to-C++ translator: it accepts
# only zero-argument registrations with one return expression, optionally
# preceded by simple local initializers, whose calls are known pure value
# helpers. Anything else remains on ordinary Ruby dispatch.
module NativeExpressionDevirt
  PURE_CALLS = %w[mrb_bool_value mrb_test mrb_true_value mrb_false_value mrb_nil_value mrb_nil_p].freeze
  # These expressions have a proven receiver-independent meaning for every
  # receiver. Other single-expression C bodies may be parseable but need a
  # separate class/ancestor proof before they can become call-site code.
  WHOLE_RECEIVER_EXPRESSIONS = {
    '!' => 'mrb_bool_value(!mrb_test(recv))',
  }.freeze
  CLASS_EXPRESSION_CALLS = %w[
    mrb_bool_value mrb_int_value mrb_ary_ptr mrb_hash_size mrb_hash_empty_p
    mrb_str_ptr mrb_range_beg mrb_range_end mrb_float mrb_float_value isfinite isnan signbit
  ].freeze
  # Keep this list to macros exported by mruby headers. RSTRING_CHAR_LEN is
  # private to string.c (and calls a private UTF-8 helper), so generated C++
  # must leave String#size on ordinary dispatch.
  CLASS_EXPRESSION_MACROS = %w[ARY_LEN RSTR_LEN RSTRING_LEN].freeze
  module_function

  def analyze(paths)
    registrations = Hash.new { |hash, name| hash[name] = [] }
    implementations = {}

    Array(paths).each do |path|
      next unless File.file?(path)

      source = File.read(path, encoding: 'UTF-8')
      macro_calls(source, 'MRB_MT_ENTRY').each do |arguments|
        next unless arguments.length == 3

        function, symbol, aspec = arguments
        name = symbol_name(symbol)
        registrations[name] << [function.strip, no_args?(aspec)] if WHOLE_RECEIVER_EXPRESSIONS.key?(name)
      end
      %w[
        mrb_define_method_id mrb_define_private_method_id mrb_define_class_method_id
        mrb_define_module_function_id mrb_define_singleton_method_id
      ].each do |macro|
        macro_calls(source, macro).each do |arguments|
          next unless arguments.length == 5

          symbol = arguments[2]
          name = symbol_name(symbol)
          registrations[name] << [arguments[3].strip, no_args?(arguments[4])] if WHOLE_RECEIVER_EXPRESSIONS.key?(name)
        end
      end
      %w[
        mrb_define_method mrb_define_private_method mrb_define_class_method
        mrb_define_module_function mrb_define_singleton_method
      ].each do |macro|
        macro_calls(source, macro).each do |arguments|
          next unless arguments.length == 5 && arguments[2].start_with?('"')

          name = unescape_c_string(arguments[2][1...-1])
          registrations[name] << [arguments[3].strip, no_args?(arguments[4])] if WHOLE_RECEIVER_EXPRESSIONS.key?(name)
        end
      end
      macro_calls(source, 'mrb_define_method_raw').each do |arguments|
        next unless arguments.length == 4

        name = symbol_name(arguments[2])
        registrations[name] << [nil, false] if WHOLE_RECEIVER_EXPRESSIONS.key?(name)
      end
      macro_calls(source, 'mrb_define_alias_id').each do |arguments|
        next unless arguments.length == 4

        name = symbol_name(arguments[2])
        registrations[name] << [nil, false] if name
      end
      macro_calls(source, 'mrb_define_alias').each do |arguments|
        next unless arguments.length == 4 && arguments[2].start_with?('"')

        name = unescape_c_string(arguments[2][1...-1])
        registrations[name] << [nil, false]
      end
      needed = registrations.values.flatten(1).map(&:first).to_set
      source.to_enum(:scan, /(?:static\s+|MRB_API\s+)?mrb_value\s+(\w+)\s*\(\s*mrb_state\s*\*\s*(\w+)\s*,\s*mrb_value\s+(\w+)\s*\)\s*\{/).each do
        function, state_arg, self_arg = Regexp.last_match.captures
        next unless needed.include?(function)

        opening = Regexp.last_match.end(0) - 1
        body, finish = brace_body(source, opening)
        next unless body

        implementations[function] ||= []
        implementations[function] << direct_return_expression(body, state_arg, self_arg)
      end
    end

    registrations.each_with_object({}) do |(name, entries), result|
      next if entries.empty? || entries.any? { |_function, no_args| !no_args }

      funcs = entries.map(&:first).uniq
      next unless funcs.all? do |function|
        implementations.key?(function) && implementations[function].all?
      end

      expressions = funcs.flat_map { |function| implementations[function] }.uniq
      next unless expressions.one?
      next unless WHOLE_RECEIVER_EXPRESSIONS[name] == expressions.first

      result[name] = expressions.first
    end
  end

  # Extract exact-class native expressions from ROM method tables. The
  # registration table is linked to the runtime class field through
  # MRB_MT_INIT_ROM, and the class's instance tag comes from
  # MRB_SET_INSTANCE_TT. Both are needed to emit a guarded call-site path.
  def analyze_exact_class_expressions(paths)
    registrations = Hash.new { |hash, name| hash[name] = [] }
    implementations = Hash.new { |hash, function| hash[function] = [] }
    opaque_owners = Hash.new { |hash, name| hash[name] = [] }
    target_classes = %w[Array Hash String Float Symbol Range].to_set

    Array(paths).each do |path|
      next unless File.file?(path)

      source = File.read(path, encoding: 'UTF-8')
      class_variables = {}
      source.scan(/(?:mrb->(\w+)\s*=\s*)?(\w+)\s*=\s*mrb_define_(?:class|module)_id\s*\(\s*\w+\s*,\s*MRB_SYM\((\w+)\)/) do |field, variable, class_name|
        class_variables[variable] = { field: field, class_name: class_name }
      end
      source.scan(/(\w+)\s*=\s*mrb_class_get(?:_id)?\s*\(\s*\w+\s*,\s*MRB_SYM\((\w+)\)/) do |variable, class_name|
        class_variables[variable] ||= { field: nil, class_name: class_name }
      end
      source.scan(/(\w+)\s*=\s*mrb->(\w+_class)\b/) do |variable, field|
        class_variables[variable] ||= { field: field, class_name: field.sub(/_class\z/, '').capitalize }
      end
      source.scan(/mrb->(\w+_class)\s*=\s*(\w+)\s*;/) do |field, variable|
        info = class_variables[variable]
        info[:field] ||= field if info
      end
      source.scan(/\bmrb->(\w+_class)\b/) do |field|
        field = field.first
        class_variables["mrb->#{field}"] ||= { field: field, class_name: field.sub(/_class\z/, '').capitalize }
      end
      source.scan(/(\w+)\s*=\s*mrb_define_(?:class|module)\s*\(\s*\w+\s*,\s*"([^"]+)"/) do |variable, class_name|
        class_variables[variable] ||= { field: nil, class_name: class_name }
      end
      tags = {}
      source.scan(/MRB_SET_INSTANCE_TT\s*\(\s*(\w+)\s*,\s*(MRB_TT_\w+)\s*\)/) do |variable, tag|
        tags[variable] = tag
      end
      table_owners = {}
      macro_calls(source, 'MRB_MT_INIT_ROM').each do |arguments|
        next unless arguments.length == 3

        _mrb, variable, table = arguments
        class_info = class_variables[variable]
        if class_info.nil? && (field = variable.match(/\Amrb->(\w+_class)\z/)&.[](1))
          class_info = { field: field, class_name: field.sub(/_class\z/, '').capitalize }
        end
        tag = tags[variable]
        table_owners[table] ||= []
        table_owners[table] << (class_info && class_info.merge(tag: tag))
      end

      rom_entries(source).each do |table, arguments|
        function, symbol, aspec = arguments
        name = symbol_name(symbol)
        next unless name

        owners = Array(table_owners[table]).uniq
        owner = owners.one? ? owners.first : nil
        registrations[name] << { function: function.strip, no_args: no_args?(aspec), owner: owner }
      end

      %w[mrb_define_method_id mrb_define_private_method_id mrb_define_class_method_id
         mrb_define_module_function_id mrb_define_singleton_method_id].each do |macro|
        macro_calls(source, macro).each do |arguments|
          next unless arguments.length == 5

          name = symbol_name(arguments[2])
          opaque_owners[name] << class_variables.dig(arguments[1], :class_name)
        end
      end
      %w[mrb_define_method mrb_define_private_method mrb_define_class_method
         mrb_define_module_function mrb_define_singleton_method].each do |macro|
        macro_calls(source, macro).each do |arguments|
          next unless arguments.length == 5 && arguments[2].start_with?('"')

          name = unescape_c_string(arguments[2][1...-1])
          opaque_owners[name] << class_variables.dig(arguments[1], :class_name)
        end
      end
      %w[mrb_define_method_raw mrb_define_alias_id].each do |macro|
        macro_calls(source, macro).each do |arguments|
          next unless arguments.length == 4

          name = symbol_name(arguments[2])
          opaque_owners[name] << class_variables.dig(arguments[1], :class_name)
        end
      end
      macro_calls(source, 'mrb_define_alias').each do |arguments|
        next unless arguments.length == 4 && arguments[2].start_with?('"')

        name = unescape_c_string(arguments[2][1...-1])
        opaque_owners[name] << class_variables.dig(arguments[1], :class_name)
      end

    end

    needed_functions = registrations.values.flat_map { |entries| entries.map { |entry| entry[:function] } }.to_set
    function_pattern = /(?:static\s+|MRB_API\s+)?mrb_value\s+(\w+)\s*\(\s*mrb_state\s*\*\s*(\w+)\s*,\s*mrb_value\s+(\w+)\s*\)\s*\{/
    Array(paths).each do |path|
      next unless File.file?(path)

      source = File.read(path, encoding: 'UTF-8')
      source.to_enum(:scan, function_pattern).each do
        function, state_arg, self_arg = Regexp.last_match.captures
        next unless needed_functions.include?(function)

        opening = Regexp.last_match.end(0) - 1
        body, = brace_body(source, opening)
        implementations[function] << (body && exact_class_return_expression(body, state_arg, self_arg))
      end
    end

    names = registrations.filter_map do |name, entries|
      name if entries.any? do |entry|
        owner = entry[:owner]
        owner.nil? || owner[:class_name].nil? || target_classes.include?(owner[:class_name])
      end
    end
    names.each_with_object({}) do |name, result|
      entries = registrations[name]
      next if entries.empty?
      next if opaque_owners[name].any? { |owner| owner.nil? || target_classes.include?(owner) }
      if entries.any? { |entry| entry[:owner].nil? || entry[:owner][:class_name].nil? }
        next
      end

      relevant = entries.select { |entry| target_classes.include?(entry[:owner][:class_name]) }
      generated = relevant.group_by { |entry| entry[:owner][:class_name] }.filter_map do |_class_name, class_entries|
        next unless class_entries.all? do |entry|
          entry[:no_args] && entry[:owner][:field] && entry[:owner][:tag] &&
            implementations.key?(entry[:function]) && implementations[entry[:function]].all?
        end

        expressions = class_entries.flat_map { |entry| implementations[entry[:function]] }.uniq
        next unless expressions.one?

        owner = class_entries.first[:owner]
        next unless class_entries.all? { |entry| entry[:owner] == owner }

        { owner: owner, expression: expressions.first }
      end
      result[name] = generated unless generated.empty?
    end
  end

  def rom_entries(source)
    entries = []
    tables = []
    table_pattern = /(?:static\s+)?const\s+mrb_mt_entry\s+(\w+)\s*\[\s*\]\s*=\s*\{/
    source.to_enum(:scan, table_pattern).each do
      table = Regexp.last_match(1)
      opening = Regexp.last_match.end(0) - 1
      _body, closing = brace_body(source, opening)
      tables << [opening, closing, table] if closing
    end
    table_index = 0
    source.to_enum(:scan, /MRB_MT_ENTRY\s*\(/).each do
      opening = Regexp.last_match.end(0) - 1
      position = opening
      arguments, = split_call_arguments(source, opening)
      next unless arguments && arguments.length == 3

      table_index += 1 while table_index < tables.length && tables[table_index][1] < position
      table = tables[table_index][2] if table_index < tables.length &&
                                         tables[table_index][0] < position && position < tables[table_index][1]
      next unless table

      entries << [table, arguments]
    end
    entries
  end

  def exact_class_return_expression(body, state_arg, self_arg)
    body = body.gsub(%r{/\*.*?\*/|//[^\n]*}, ' ').strip
    conditional = body.match(/\A(.*?)if\s*\((.+?)\)\s*return\s+(.+?)\s*;\s*return\s+(.+?)\s*;\s*\z/m)
    match = conditional || body.match(/\A(.*?)return\s+(.+?)\s*;\s*\z/m)
    return unless match

    statements = match[1].split(';').map(&:strip).reject(&:empty?)
    locals = {}
    statements.each do |statement|
      declaration = statement.match(/\A(?:struct\s+\w+|mrb_int|mrb_float)\s*\*?\s*(\w+)\s*=\s*(.+)\z/m)
      return unless declaration

      local, initializer = declaration.captures
      return unless locals[local].nil?

      locals[local] = substitute_expression(initializer, state_arg, self_arg, locals)
      return unless locals[local]
    end
    if conditional
      condition = substitute_expression(match[2], state_arg, self_arg, locals)
      when_true = substitute_expression(match[3], state_arg, self_arg, locals)
      when_false = substitute_expression(match[4], state_arg, self_arg, locals)
      return unless condition && when_true && when_false

      "(#{condition}) ? (#{when_true}) : (#{when_false})"
    else
      substitute_expression(match[2], state_arg, self_arg, locals)
    end
  end

  def substitute_expression(expression, state_arg, self_arg, locals)
    expression = expression.gsub(/\b#{Regexp.escape(state_arg)}\b/, 'M')
                           .gsub(/\b#{Regexp.escape(self_arg)}\b/, 'recv')
    locals.each { |name, value| expression = expression.gsub(/\b#{Regexp.escape(name)}\b/, "(#{value})") }
    tokens = expression.scan(/[A-Za-z_]\w*|\d+|&&|\|\||==|!=|<=|>=|\S/)
    return if tokens.empty?
    return unless expression.gsub(/[A-Za-z_]\w*|\d+|\s+|&&|\|\||==|!=|<=|>=|[!~(),?:+\-*\/%<>&|^]/, '').empty?
    allowed = %w[M recv] + CLASS_EXPRESSION_CALLS + CLASS_EXPRESSION_MACROS
    return if tokens.each_with_index.any? do |token, index|
      next false unless token.match?(/\A[A-Za-z_]/)

      allowed.include?(token) ? (CLASS_EXPRESSION_CALLS.include?(token) || CLASS_EXPRESSION_MACROS.include?(token) ? tokens[index + 1] != '(' : false) : true
    end

    expression.strip
  end

  def symbol_name(symbol)
    match = symbol.match(/\A#{MRB_SYM_TOKEN_RE}\z/)
    match && resolve_mrb_sym_token(match[1], match[2])
  end

  def no_args?(aspec)
    aspec.strip == 'MRB_ARGS_NONE()'
  end

  def macro_calls(source, macro)
    calls = []
    source.to_enum(:scan, /\b#{Regexp.escape(macro)}\s*\(/).each do
      opening = Regexp.last_match.end(0) - 1
      arguments, = split_call_arguments(source, opening)
      calls << arguments if arguments
    end
    calls
  end

  def split_call_arguments(source, opening)
    depth = 0
    starts = opening + 1
    arguments = []
    quote = nil
    escaped = false
    index = opening
    while index < source.length
      char = source[index]
      if quote
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == quote
          quote = nil
        end
      elsif char == '"' || char == "'"
        quote = char
      elsif char == '(' || char == '[' || char == '{'
        depth += 1
      elsif char == ')'
        depth -= 1
        if depth.zero?
          arguments << source[starts...index].strip
          return [arguments, index]
        end
      elsif char == ']' || char == '}'
        depth -= 1
      elsif char == ',' && depth == 1
        arguments << source[starts...index].strip
        starts = index + 1
      end
      index += 1
    end
    [nil, nil]
  end

  def direct_return_expression(body, state_arg, self_arg)
    body = body.gsub(%r{/\*.*?\*/|//[^\n]*}, ' ')
    match = body.match(/\A\s*return\s+(.+?)\s*;\s*\z/m)
    return unless match

    expression = match[1].gsub(/\b#{Regexp.escape(state_arg)}\b/, 'M')
                           .gsub(/\b#{Regexp.escape(self_arg)}\b/, 'recv')
    tokens = expression.scan(/[A-Za-z_]\w*|\d+|&&|\|\||==|!=|<=|>=|\S/)
    return if tokens.empty?
    return unless expression.gsub(/[A-Za-z_]\w*|\d+|\s+|&&|\|\||==|!=|<=|>=|[!~()+\-*\/%<>&|^]/, '').empty?
    return if tokens.each_with_index.any? do |token, index|
      next false unless token.match?(/\A[A-Za-z_]/)

      if PURE_CALLS.include?(token)
        tokens[index + 1] != '('
      else
        !%w[M recv].include?(token)
      end
    end

    expression.strip
  end

  def brace_body(source, opening)
    depth = 0
    quote = nil
    escaped = false
    line_comment = false
    block_comment = false
    index = opening

    while index < source.length
      char = source[index]
      following = source[index + 1]
      if line_comment
        line_comment = false if char == "\n"
      elsif block_comment
        if char == '*' && following == '/'
          block_comment = false
          index += 1
        end
      elsif quote
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == quote
          quote = nil
        end
      elsif char == '/' && following == '/'
        line_comment = true
        index += 1
      elsif char == '/' && following == '*'
        block_comment = true
        index += 1
      elsif char == '"' || char == "'"
        quote = char
      elsif char == '{'
        depth += 1
      elsif char == '}'
        depth -= 1
        return [source[(opening + 1)...index], index] if depth.zero?
      end
      index += 1
    end
    [nil, nil]
  end
end
