# frozen_string_literal: true

# Extracts a deliberately small set of direct-call expressions from mruby's
# C method implementations. This is not a C-to-C++ translator: it accepts
# only one-return-expression bodies whose calls are known to be pure value
# helpers, and only zero-argument registrations. Anything else remains on
# ordinary Ruby dispatch.
module NativeExpressionDevirt
  PURE_CALLS = %w[mrb_bool_value mrb_test mrb_true_value mrb_false_value mrb_nil_value mrb_nil_p].freeze
  # These expressions have a proven receiver-independent meaning for every
  # receiver. Other single-expression C bodies may be parseable but need a
  # separate class/ancestor proof before they can become call-site code.
  WHOLE_RECEIVER_EXPRESSIONS = {
    '!' => 'mrb_bool_value(!mrb_test(recv))',
  }.freeze
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
        registrations[name] << [function.strip, no_args?(aspec)] if name
      end
      %w[
        mrb_define_method_id mrb_define_private_method_id mrb_define_class_method_id
        mrb_define_module_function_id mrb_define_singleton_method_id
      ].each do |macro|
        macro_calls(source, macro).each do |arguments|
          next unless arguments.length == 5

          symbol = arguments[2]
          name = symbol_name(symbol)
          registrations[name] << [arguments[3].strip, no_args?(arguments[4])] if name
        end
      end
      %w[
        mrb_define_method mrb_define_private_method mrb_define_class_method
        mrb_define_module_function mrb_define_singleton_method
      ].each do |macro|
        macro_calls(source, macro).each do |arguments|
          next unless arguments.length == 5 && arguments[2].start_with?('"')

          name = unescape_c_string(arguments[2][1...-1])
          registrations[name] << [arguments[3].strip, no_args?(arguments[4])]
        end
      end
      macro_calls(source, 'mrb_define_method_raw').each do |arguments|
        next unless arguments.length == 4

        name = symbol_name(arguments[2])
        registrations[name] << [nil, false] if name
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
      source.to_enum(:scan, /(?:static\s+|MRB_API\s+)?mrb_value\s+(\w+)\s*\(\s*mrb_state\s*\*\s*(\w+)\s*,\s*mrb_value\s+(\w+)\s*\)\s*\{/).each do
        function, state_arg, self_arg = Regexp.last_match.captures
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
