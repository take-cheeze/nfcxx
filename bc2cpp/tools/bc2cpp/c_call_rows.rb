# frozen_string_literal: true

require 'set'

# C_CALL_ROWS (closed only, the core rows run): a native names a method to a C call that finds a row where its entry
# would be (mrb_vm_find_method_rows: the funcall family, mrb_method_memo, mrb_func_basic_p), or to one that looks
# nothing up (a call with the method already found, a comparison). Such a name operand reaches no entry the rows run
# must keep visible, so it is blanked before the native is read for names (CoreNativeCandidates.reachable).
#
# A name reaches those calls through a C function or macro of the natives too: a parameter or a local `mrb_sym` whose
# every use is such an operand, a comparison, or (a local) an assignment of a literal name. Such a function's callers
# pass their literal into the same operand, so it is a sink in its turn, to a fixpoint. A function counts only when
# every definition of its name, in any native, is one; a C++ source's definitions never count. Anything else, a
# computed name included, is left in place.
module CCallRows
  module_function

  # Sink function => the argument positions of its method name. LOOKUP: finds rows (vm.c funcall_with_block_m,
  # kernel.c mrb_method_memo and mrb_func_basic_p, class.c mrb_vm_find_method_rows / mrb_method_search_rows); FOUND:
  # calls a method its caller already found, so the name is the frame's, looked up by nothing.
  LOOKUP = { 'mrb_funcall' => 2, 'mrb_funcall_id' => 2, 'mrb_funcall_argv' => 2, 'mrb_funcall_with_block' => 2,
             'mrb_funcall_send' => 2, 'mrb_method_memo' => 2, 'mrb_func_basic_p' => 2,
             'mrb_vm_find_method_rows' => 3, 'mrb_method_search_rows' => 2 }.freeze
  FOUND = { 'mrb_funcall_with_method' => 2, 'mrb_funcall_send_with_method' => 2 }.freeze
  BASE = LOOKUP.merge(FOUND).transform_values { |pos| Set[pos] }.freeze
  # The generated code's by-name funcall (bc2cpp.rb: `bc2cpp_keep_call(M, [&] { return mrb_funcall(M, __VA_ARGS__); })`).
  GENERATED = BASE.merge('bc2cpp_funcall_keep' => Set[2]).freeze

  KEYWORDS = %w[if while for switch return sizeof do else case defined __attribute__ __typeof__ typeof _Generic].freeze
  # A definition: `name(params) {` with no parenthesis in the parameter list.
  DEFINITION = /(?<![\w.>:])([A-Za-z_]\w*)\s*\(([^()]*)\)\s*\{/
  MACRO = /^[ \t]*#[ \t]*define[ \t]+(\w+)\(([^)]*)\)((?:[^\n]*\\\n)*[^\n]*)/
  CXX = /\.(?:cxx|cpp|cc|hpp|hxx|hh)\z/
  COMPARE = /(?:==|!=)\s*\z/
  COMPARED = /\A\s*(?:==|!=)/
  NAME_LITERAL = /\bmrb_intern_(?:lit|cstr)\(\s*\w+\s*,\s*"(?:[^"\\\n]|\\.)*"\s*\)|"(?:[^"\\\n]|\\.)*"|\bMRB_(?:SYM|SYM_Q|SYM_B|SYM_E|OPSYM)\(\w+\)/
  NAME_OPERAND = /\A(?:#{NAME_LITERAL})\z/
  # MESSAGE_ARGS (the rows run, under the closed-world literal-lookup proof): mruby's exception-message formatters by
  # the position of their format; a literal from there on is message text, which no lookup can take as a name.
  MESSAGE_ARGS = { 'mrb_raisef' => 2, 'mrb_name_error' => 2, 'mrb_no_method_error' => 3, 'mrb_warn' => 1 }.freeze
  MESSAGE_CALL = /(?<![\w.>])(#{MESSAGE_ARGS.keys.join('|')})\s*\(/
  STRING_LITERAL = /"(?:[^"\\\n]|\\.)*"/

  # The sinks of `texts` ({path => comment-free text}): BASE and the functions and macros found to pass a parameter
  # into one. nil when a source redefines a BASE name as a macro (the calls might not be the runtime's).
  def sinks(texts)
    return nil if texts.any? { |path, t| !path.end_with?('/presym/scanning.h') && t.match?(/^[ \t]*#[ \t]*(?:define|undef)[ \t]+(?:#{(BASE.keys + MESSAGE_ARGS.keys).join('|')})\b/) }

    defs = Hash.new { |h, k| h[k] = [] }
    texts.each do |path, text|
      next if path.end_with?('/presym/scanning.h')

      text.scan(MACRO) { |name, params, body| defs[name] << [path, params, body.gsub("\\\n", ' ')] }
      each_definition(text) { |name, params, body| defs[name] << [path, params, body] }
    end
    out = BASE.dup
    loop do
      grew = false
      defs.each do |name, list|
        next if BASE.key?(name) || list.any? { |path, _, _| path.match?(CXX) }

        positions = list.map do |_path, params, body|
          names = params.split(',').map { |p| p[/(\w+)\s*(?:\[\s*\])?\s*\z/, 1] }
          names.each_index.select { |i| names[i] && sink_variable?(body, names[i], out, param: true) }.to_set
        end
        common = positions.inject(:&)
        next if common.nil? || common.empty? || out[name] == common
        next unless every_definition?(texts, name, list.size)

        out[name] = common
        grew = true
      end
      break unless grew
    end
    out.freeze
  end

  # Whether `count` is every definition of `name` the natives spell: a definition each_definition or MACRO could not
  # read (a function-pointer parameter, an object-like macro) leaves its calls' operands in place.
  def every_definition?(texts, name, count)
    call = /(?<![\w.>:])#{Regexp.escape(name)}\s*\(/
    macro = /^[ \t]*#[ \t]*define[ \t]+#{Regexp.escape(name)}\b/
    texts.sum do |path, t|
      next 0 if path.end_with?('/presym/scanning.h') || !t.include?(name)

      bodies = t.to_enum(:scan, call).count do
        spans = StaticDispatchRegistrations.call_arg_spans(t, Regexp.last_match.end(0) - 1)
        spans.nil? || t[spans.last[1] + 1, 64].to_s.match?(/\A\s*\{/)
      end
      bodies + t.scan(macro).size
    end == count
  end

  # Yields [name, params, body, offset of body] of each function definition in `text`.
  def each_definition(text)
    text.scan(DEFINITION) do |name, params|
      next if KEYWORDS.include?(name)

      open = Regexp.last_match.end(0) - 1
      list = params.strip
      next unless list.empty? || list == 'void' || list.split(',').all? { |p| p.strip.match?(/\A[\w\s\*]+\w\s*(?:\[\s*\])?\z|\A\.\.\.\z/) }

      close = matching_brace(text, open) or next
      yield name, list, text[open..close], open
    end
  end

  # Index of the brace closing the one at `open`, skipping literals; nil when unbalanced.
  def matching_brace(text, open)
    depth = 0
    i = open
    while i < text.length
      c = text[i]
      if c == '"' || c == "'"
        i += 1
        i += (text[i] == '\\' ? 2 : 1) while i < text.length && text[i] != c
      elsif c == '{'
        depth += 1
      elsif c == '}'
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  # Whether every use of `var` in `body` is a sink operand, a comparison or, for a local, its `mrb_sym` declaration or
  # an assignment of a NAME_LITERAL.
  def sink_variable?(body, var, sinks, param: false, offsets: nil)
    ok = (offsets || operand_offsets(body, sinks)).select { |from, to| body[from...to].strip == var }.to_set { |from, to| from + body[from...to].index(var) }
    # A NAME_LITERAL spelling the variable's own name (`mrb_sym included = MRB_SYM(included)`) is no use of it.
    literals = body.to_enum(:scan, NAME_LITERAL).map { Regexp.last_match.begin(0)...Regexp.last_match.end(0) }
    uses = body.to_enum(:scan, /(?<![\w.>"])#{Regexp.escape(var)}\b/).map { Regexp.last_match.begin(0) }
    uses.reject! { |at| literals.any? { |span| span.cover?(at) } }
    return false if uses.empty?

    uses.all? do |at|
      before = body[[at - 64, 0].max...at]
      after = body[(at + var.size), 160].to_s
      ok.include?(at) || before.match?(COMPARE) || after.match?(COMPARED) ||
        (!param && (before.match?(/\bmrb_sym\s+\z/) && after.match?(/\A\s*(?:;|=\s*(?:#{NAME_LITERAL})\s*;)/) ||
                    after.match?(/\A\s*=\s*(?:#{NAME_LITERAL})\s*;/) && before.match?(/[;{}]\s*\z/)))
    end
  end

  # [from, to) of each sink-position argument of each sink call in `text`.
  def operand_offsets(text, sinks)
    re = /(?<![\w.>])(?:::)?(#{sinks.keys.map { |k| Regexp.escape(k) }.join('|')})\s*\(/
    out = []
    text.scan(re) do |(name)|
      spans = StaticDispatchRegistrations.call_arg_spans(text, Regexp.last_match.end(0) - 1) or next
      sinks[name].each { |pos| out << spans[pos] if spans[pos] }
    end
    out
  end

  # `text` with each name literal blanked that reaches only sinks: a sink operand, a compared literal, and what a
  # local sink variable is assigned.
  # +proven+ (under the closed-world literal-lookup proof): MESSAGE_ARGS' literals too.
  def blank(text, sinks, cxx: false, proven: false)
    return text unless sinks

    sinks = sinks.select { |name, _| BASE.key?(name) } if cxx

    out = text.dup
    wipe = ->(from, to) { out[from...to] = ' ' * (to - from) }
    blank_operands_and_comparisons(text, sinks, wipe)
    each_definition(text) { |_name, _params, body, start| blank_locals(body, start, sinks, wipe) }
    blank_proven(text, wipe) if proven
    out
  end

  # A generated source read the same way (the rows run's reading of the generated code) with GENERATED's sinks. Only
  # the definitions around a literal assignment are read for locals: the units are large and few locals take one.
  def blank_generated(src, proven: false)
    out = nil
    wipe = ->(from, to) { (out ||= src.dup)[from...to] = ' ' * (to - from) }
    blank_operands_and_comparisons(src, GENERATED, wipe)
    seen = Set.new
    src.to_enum(:scan, /(?<![\w.>])\w+\s*=\s*(?:#{NAME_LITERAL})\s*;/o).each do
      at = Regexp.last_match.begin(0)
      start, body = enclosing_definition(src, at)
      next unless body && seen.add?(start)

      blank_locals(body, start, GENERATED, wipe)
    end
    blank_proven(src, wipe) if proven
    out || src
  end

  def blank_operands_and_comparisons(text, sinks, wipe)
    operand_offsets(text, sinks).each do |from, to|
      arg = text[from...to].strip
      wipe.call(from, to) if NativeOwnerMap.name_of(arg) || arg.match?(NAME_OPERAND)
    end
    text.to_enum(:scan, /(?:==|!=)\s*(#{NAME_LITERAL})|(#{NAME_LITERAL})\s*(?:==|!=)/o).each do
      m = Regexp.last_match
      k = m[1] ? 1 : 2
      wipe.call(m.begin(k), m.end(k))
    end
  end

  # The literal assigned to each local `mrb_sym` of `body` (at `start` in its text) that sink_variable? accepts.
  def blank_locals(body, start, sinks, wipe)
    vars = body.scan(/\bmrb_sym\s+(\w+)\s*[;=]/).flatten.uniq
    return if vars.empty?

    offsets = operand_offsets(body, sinks)
    vars.each do |var|
      next unless sink_variable?(body, var, sinks, offsets: offsets)

      body.to_enum(:scan, /(?<![\w.>])#{Regexp.escape(var)}\s*=\s*(#{NAME_LITERAL})/).each do
        m = Regexp.last_match
        wipe.call(start + m.begin(1), start + m.end(1))
      end
    end
  end

  # [offset of the body, body] of the innermost definition each_definition would read around `at`, or nil.
  def enclosing_definition(text, at)
    from = [at - 20_000, 0].max
    found = nil
    text[from...at].to_enum(:scan, DEFINITION).each do
      m = Regexp.last_match
      next if KEYWORDS.include?(m[1])
      list = m[2].strip
      next unless list.empty? || list == 'void' || list.split(',').all? { |p| p.strip.match?(/\A[\w\s\*]+\w\s*(?:\[\s*\])?\z|\A\.\.\.\z/) }

      open = from + m.end(0) - 1
      close = matching_brace(text, open)
      found = [open, text[open..close]] if close && close > at
    end
    found
  end

  def blank_proven(text, wipe)
    text.scan(MESSAGE_CALL) do |(fn)|
      spans = StaticDispatchRegistrations.call_arg_spans(text, Regexp.last_match.end(0) - 1) or next
      spans.drop(MESSAGE_ARGS.fetch(fn)).each do |from, to|
        text[from...to].to_enum(:scan, STRING_LITERAL).each { wipe.call(from + Regexp.last_match.begin(0), from + Regexp.last_match.end(0)) }
      end
    end
  end
end
