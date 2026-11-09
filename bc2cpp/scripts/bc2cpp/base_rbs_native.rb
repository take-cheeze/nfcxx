#!/usr/bin/env ruby
# frozen_string_literal: true

# Base RBS for native (C / C++) method registrations: the mrb_define_* calls of mruby's C API, found in the
# preprocessed source (`clang -E`), so macros such as MRB_ARGS_REQ are already expanded.
#
#   ruby scripts/bc2cpp/base_rbs_native.rb [--jobs N] OUT_DIR [-I DIR]... [-D MACRO]... SRC.cxx...
#
# A class or module is named by the call that defines it (mrb_define_class / _under, mrb_define_module / _under,
# and the _id forms); a method is attached to the variable it is registered on. Methods are written as
# `(*untyped) -> untyped`: the arity of a native method is in its aspec macro, and reading it back is not needed for a
# stub that claims no types. A registration whose owner variable is assigned to two different classes in one file is
# skipped and listed (the scanner does not follow scopes), and so is one whose owner it cannot name.
#
# Every member line is validated with the rbs parser before it is written, as base_rbs.rb does.

require 'json'
require 'open3'
require 'fileutils'
require 'set'
require 'optparse'
require_relative 'base_rbs_workers'
require_relative '../../tools/bc2cpp/native_format_types'
require_relative '../../tools/bc2cpp/native_return_kinds'
require_relative '../../tools/bc2cpp/native_ast_returns'

module BaseRbsNative
  DEFINE_CLASS = /\bmrb_define_(class|module)(_under)?(?:_id)?\s*\(/.freeze
  METHOD_CALL = /\bmrb_define_(method|class_method|singleton_method|module_function|private_method)(?:_id)?\s*\(/.freeze
  NAME_TOKEN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/.freeze

  module_function

  # The argument texts of the call whose `(` is at +open+, splitting at top-level commas.
  def call_args(text, open)
    depth = 0
    args = []
    current = +''
    i = open
    while i < text.length
      ch = text[i]
      if ch == '"'
        j = i + 1
        j += 1 while j < text.length && !(text[j] == '"' && text[j - 1] != '\\')
        current << text[i..j]
        i = j + 1
        next
      end
      if '([{'.include?(ch)
        depth += 1
        current << ch unless depth == 1
      elsif ')]}'.include?(ch)
        depth -= 1
        return args << current.strip if depth.zero?

        current << ch
      elsif ch == ',' && depth == 1
        args << current.strip
        current = +''
      elsif depth >= 1
        current << ch
      end
      i += 1
    end
    args
  end

  def string_literal(text)
    text[/\A"((?:[^"\\]|\\.)*)"\z/, 1]
  end

  # A class or method name: a string literal, or the presym `MRB_SYM(name)` of the `_id` forms, which the preprocessor
  # spells `MRB_SYM__name` (MRB_SYM_B / _Q / _E are `name!`, `name?`, `name=`). Operator presyms are not names here.
  PRESYM = /\AMRB_SYM(_[BQE])?__(\w+)\z/.freeze
  PRESYM_SUFFIX = { '' => '', '_B' => '!', '_Q' => '?', '_E' => '=' }.freeze

  def symbol_name(arg)
    literal = string_literal(arg)
    return literal if literal

    m = arg.match(PRESYM)
    m && m[2] + PRESYM_SUFFIX.fetch(m[1].to_s, '')
  end

  # The Ruby class a core class variable names (`mrb->string_class` is String), or nil for any other expression.
  CORE_OWNER = { 'object' => 'Object', 'fixnum' => 'Integer', 'nil' => 'NilClass', 'true' => 'TrueClass',
                 'false' => 'FalseClass' }.freeze
  CORE_CLASS = /\A(?:M|mrb)->(\w+?)_(?:class|module)\z/.freeze

  # mruby's error classes are `eStandardError`-style (the `e` is a prefix, not part of the name).
  def core_owner(expr)
    m = expr.match(CORE_CLASS)
    m && CORE_OWNER.fetch(m[1]) { m[1].sub(/\Ae(?=[A-Z])/, '').split('_').map { |w| w[0].upcase + w[1..] }.join }
  end

  # The variables a call result is assigned to, innermost first (`RClass* rect = mrb_define_class_under(...)`, or the
  # chain `RClass* exception = mrb->eException_class = mrb_define_class_id(...)`).
  def assigned_names(text, index)
    before = text[[index - 200, 0].max...index]
    before[/[^;{}]*\z/].scan(/(\w+)\s*=(?!=)/).flatten.reverse
  end

  # Scans one preprocessed source. Returns [classes, methods, skipped]; classes maps a full name to its kind.
  def scan(text, &ast_kinds)
    owners = {}      # variable -> full class name, or :ambiguous
    kinds = {}       # full class name -> 'class' / 'module'
    supers = {}      # full class name -> superclass expression as written
    methods = []     # [owner full name, singleton?, method name]
    skipped = []
    text.scan(DEFINE_CLASS) do
      m = Regexp.last_match
      open = m.end(0) - 1
      args = call_args(text, open)
      kind = m[1]
      under = !m[2].nil?
      vars = assigned_names(text, m.begin(0))
      if under
        outer, name = args[1], symbol_name(args[2])
      else
        outer, name = nil, symbol_name(args[1])
      end
      next unless name && name.match?(/\A[A-Za-z_]\w*\z/)

      outer_name = outer && owner_of(owners, outer)
      next if outer && outer_name.nil?

      full = [outer_name, name].compact.join('::')
      kinds[full] = kind == 'class' ? 'class' : 'module'
      super_index = under ? 3 : 2
      supers[full] = super_name(args[super_index], owners) if kind == 'class' && args.size > super_index
      vars.each { |var| set_owner(owners, var, full) }
    end
    # A variable taken from a core class (`krn = mrb->kernel_module;`) owns the methods registered on it.
    # A full identifier wins before any suffix; skip those redundant regex starts.
    text.scan(/(?<!\w)(\w+)\s*=\s*((?:M|mrb)->\w+_(?:class|module))\s*;/) do |var, expr|
      set_owner(owners, var, core_owner(expr)) if core_owner(expr)
    end
    text.scan(METHOD_CALL) do
      m = Regexp.last_match
      args = call_args(text, m.end(0) - 1)
      kind = m[1]
      next if args.size < 3

      target = args[1]
      next if target.match?(/\s/) # a prototype from an included header (`struct RClass *cla`), not a call

      name = symbol_name(args[2])
      unless name
        skipped << "#{target} #{args[2]} (operator or unnamed)"
        next
      end

      owner = owner_of(owners, target)
      if owner.nil? || owner.is_a?(Symbol)
        skipped << "#{target}##{name}"
        next
      end
      singleton = %w[class_method singleton_method module_function].include?(kind)
      unless name.match?(/\A[a-z_]\w*[?!=]?\z/i)
        skipped << "#{owner}##{name}"
        next
      end
      sig = method_sig(text, args[3], owner, singleton, args[4], &ast_kinds)
      sig = manual_return(owner, name, sig)
      methods << [owner, singleton, name, sig]
      methods << [owner, false, name, method_sig(text, args[3], owner, false, args[4], &ast_kinds)] if kind == 'module_function'
    end
    [kinds, supers, methods.uniq, skipped]
  end

  # Functions whose mrb_get_args formats differ by argument count, so one parameter list cannot describe them. Each
  # form is one RBS overload, written from that function's own mrb_get_args calls (the object form raises TypeError
  # unless it is the class, DataType<T>::get).
  OVERLOADS = {
    'color_set' => ['(RGSS::Color) -> self', '(Numeric, Numeric, Numeric, ?Numeric) -> self'],
    'tone_set' => ['(RGSS::Tone) -> self', '(Numeric, Numeric, Numeric, ?Numeric) -> self']
  }.freeze

  # The RBS signature of a registered function: its parameters and its return type (NativeReturnKinds). The parameters
  # are the mrb_get_args format when the body reads its arguments that way, and otherwise the arity the registration's
  # aspec declares (aspec_shape). A function that is not in this text keeps the rest parameter and an untyped return.
  # Returns written by hand where the C body's return is not readable from the text (the clang AST still gives
  # `untyped` for them). Each entry is the class and method name, and the return type it must have.
  MANUAL_RETURNS = {
    # stringio.c: read(n) and getc return nil at end of file (read() with no length returns "" there).
    ['StringIO', 'read'] => 'String?',
    ['StringIO', 'getc'] => 'String?',
    # RGSS::Viewport accessors (mruby-rgss/src/lib.cxx: vp_ox, vp_oy, vp_rect, vp_tone) hold an Integer, a Rect and a Tone.
    ['RGSS::Viewport', 'ox'] => 'Integer',
    ['RGSS::Viewport', 'oy'] => 'Integer',
    ['RGSS::Viewport', 'rect'] => 'RGSS::Rect',
    ['RGSS::Viewport', 'tone'] => 'RGSS::Tone'
  }.freeze

  def manual_return(owner, name, sig)
    ret = MANUAL_RETURNS[[owner, name]]
    return sig unless ret

    "#{sig.rpartition(' -> ').first} -> #{ret}"
  end

  def method_sig(text, function, owner, singleton, aspec, &ast_kinds)
    body = function_body_of(text, function)
    return '(*untyped) -> untyped' unless body
    return OVERLOADS[function].join(' | ') if OVERLOADS.key?(function)

    # The clang AST's kind for this function when it has one (native_ast_returns.rb follows locals and same-file calls);
    # otherwise the regex classifier's kind for its return text.
    kind = ast_kinds&.call&.[](function)
    kind = NativeReturnKinds.kind_of_body(body) if kind.nil?
    ret = NativeReturnKinds.rbs_of(kind, owner: owner, singleton: singleton)
    params = if body.match?(/\bmrb_get_args\s*\(/) then param_shape(body)
             else arg1_shape(body) || aspec_shape(aspec) || '*untyped'
             end
    "(#{params}) -> #{ret}"
  end

  # mruby-math's get_float_arg, `mrb_as_float(mrb, mrb_get_arg1(mrb))` once expanded: mrb_get_arg1 takes exactly one
  # argument, and mrb_ensure_float_type is the conversion the `f` format makes (a TypeError for a non-Numeric), so the
  # parameter is the `f` format's type. Any other use of the argument is not read here (nil).
  FLOAT_ARG1 = /\bmrb_ensure_float_type\s*\(\s*\(?\s*\w+\s*\)?\s*,\s*mrb_get_arg1\s*\(/.freeze

  def arg1_shape(body)
    return nil unless body.scan(/\bmrb_get_arg1\s*\(/).size == 1 && body.match?(FLOAT_ARG1)

    NativeFormatTypes.rbs_of('f')
  end

  # The value of a registration's aspec expression, as the preprocessed text spells it (`((mrb_aspec)((1)&0x1f) << 18)`),
  # or nil when the text is not plain integer arithmetic. The text is checked against a whitelist of characters before it
  # is evaluated, so only digits, parentheses and the operators the aspec macros use reach the evaluator.
  def aspec_value(expr)
    return nil unless expr

    text = expr.gsub(/\(\s*mrb_aspec\s*\)/, '')
    return nil unless text.gsub(/0[xX][0-9a-fA-F]+/, '').match?(/\A[\s\d()|&<>]*\z/)

    eval(text) # rubocop:disable Security/Eval -- the whitelist above admits only digits, hex literals and operators
  rescue SyntaxError
    nil
  end

  # The parameter list an aspec declares: its required parameters, then its optional ones. A rest, post-required or
  # keyword parameter is not modelled (nil), so the caller keeps the rest parameter.
  def aspec_shape(expr)
    aspec = aspec_value(expr)
    return nil unless aspec

    req = (aspec >> 18) & 0x1f
    opt = (aspec >> 13) & 0x1f
    return nil if [(aspec >> 12) & 1, (aspec >> 7) & 0x1f, (aspec >> 2) & 0x1f, (aspec >> 1) & 1].any?(&:positive?)

    (Array.new(req) { 'untyped' } + Array.new(opt) { '?untyped' }).join(', ')
  end

  # The parameter list from a function body: its `mrb_get_args` format, when the body makes exactly one such call
  # (NativeFormatTypes). A class type only where the conversion is a check; everything else is untyped. A format that is
  # not modelled keeps the rest parameter.
  def param_shape(body)
    formats = body.scan(/\bmrb_get_args\s*\(\s*\w+\s*,\s*"([^"]*)"/).flatten
    return '*untyped' unless formats.size == 1

    format = formats.first
    positions = NativeFormatTypes.positions(format)
    return '*untyped' unless positions

    params = positions.map do |pos|
      type = NativeFormatTypes.rbs_of(pos[:letter]) || 'untyped'
      type = "(#{type})" if type.include?(' | ')
      pos[:optional] ? "?#{type}" : type
    end
    params << '*untyped' if format.include?('*')
    params.join(', ')
  end

  # The body of a function defined in +text+, from its opening brace to the matching close, or nil.
  def function_body_of(text, function)
    return nil unless function&.match?(/\A\w+\z/)

    head = text.match(/\b#{Regexp.escape(function)}\s*\([^)]*\)\s*\{/)
    head && function_body(text, head.end(0) - 1)
  end

  # The text of a function body from its opening brace at +open+ to the matching close brace.
  def function_body(text, open)
    depth = 0
    cursor = open
    while (brace = /[{}]/.match(text, cursor))
      depth += brace[0] == '{' ? 1 : -1
      return text[open...brace.end(0)] if depth.zero?

      cursor = brace.end(0)
    end
    ''
  end

  # A superclass argument as a Ruby constant name. The core object class is `M->object_class` (or `mrb->...`), which is
  # Object, the superclass a class gets when none is written, so it is left out as the Ruby source leaves it. Any other
  # C expression is not a name, so the superclass is left out rather than written wrong.
  # `E_*_ERROR` is mruby's macro for a core error class; its name is not written here, so the superclass is left out.
  def super_name(expr, owners)
    return nil if expr.match?(/\A(?:M|mrb)->object_class\z/) || expr.start_with?('E_')
    return core_owner(expr) if core_owner(expr)
    return owners[expr] if owners[expr].is_a?(String) # a variable holding an earlier class (`RClass* range_error`)
    return expr if expr.match?(NAME_TOKEN)

    nil
  end

  def owner_of(owners, var)
    return var if var.match?(NAME_TOKEN)
    return core_owner(var.strip) if core_owner(var.strip)

    value = owners[var.strip]
    value == :ambiguous ? :ambiguous : value
  end

  def set_owner(owners, var, full)
    prev = owners[var]
    owners[var] = prev.nil? || prev == full ? full : :ambiguous
  end

  def member(name, sig, singleton: false)
    "def #{singleton ? 'self.' : ''}#{name}: #{sig}"
  end

  # One member per method name: the same name registered twice with different signatures (a module_function pair, or
  # two C functions sharing a name) has no single signature this stub can state, so it is left untyped.
  def merge_sigs(entries)
    entries.group_by(&:first).sort.map do |name, rows|
      sigs = rows.map(&:last).uniq
      [name, sigs.size == 1 ? sigs.first : '(*untyped) -> untyped']
    end
  end

  def render(kinds, supers, methods)
    by_class = Hash.new { |h, k| h[k] = { singleton: [], instance: [] } }
    methods.each do |owner, singleton, name, sig|
      by_class[owner][singleton ? :singleton : :instance] << [name, sig]
    end
    names = (kinds.keys + by_class.keys).uniq.sort
    names.map do |full|
      kind = kinds[full] || 'class'
      head = if kind == 'module' then "module #{full}"
             elsif supers[full] then "class #{full} < #{supers[full]}"
             else "class #{full}"
             end
      body = []
      merge_sigs(by_class.fetch(full, { instance: [] })[:instance]).each { |n, sig| body << member(n, sig) }
      merge_sigs(by_class.fetch(full, { singleton: [] })[:singleton]).each { |n, sig| body << member(n, sig, singleton: true) }
      body = body.select do |line|
        valid = valid_member?(line)
        warn "base_rbs_native: dropped #{full}, not valid RBS: #{line}" unless valid
        valid
      end
      "#{head}\n#{body.map { |l| "  #{l}\n" }.join}end\n"
    end
  end

  def valid_member?(line)
    require 'rbs'
    RBS::Parser.parse_signature("class X\n  #{line}\nend\n")
    true
  rescue RBS::ParsingError
    false
  end

  # Return kinds the clang AST gives the functions of one source (NativeAstReturns). A file clang cannot parse keeps
  # the regex kinds, and says so.
  # +optional+ lets a function returning K or nil be `K?` (the base declarations ask for it; native_fn_kinds.rb does not).
  def ast_function_kinds(path, flags, external = {}, self_index = nil, external_refs = nil, optional: false)
    lang = path.end_with?('.c') ? ['-x', 'c', '-std=gnu11'] : ['-std=gnu++17']
    out, err, status = Open3.capture3('clang', *lang, '-fsyntax-only', '-Xclang', '-ast-dump=json', *flags, path)
    unless status.success?
      warn "base_rbs_native: AST returns unavailable for #{path}, regex kinds kept: #{err.lines.first}"
      return {}
    end

    NativeAstReturns.analyze(JSON.parse(out.force_encoding(Encoding::UTF_8)), path, external: external, self_index: self_index,
                                                                                 external_refs: external_refs, optional: optional)
  end

  def preprocess(path, flags)
    lang = path.end_with?('.c') ? ['-x', 'c', '-std=gnu11'] : ['-std=gnu++17']
    out, err, status = Open3.capture3('clang', *lang, '-E', '-P', *flags, path)
    raise "clang -E failed for #{path}: #{err.lines.first}" unless status.success?

    # The sources are UTF-8 whatever the locale says; a US-ASCII read fails on the first non-ASCII comment.
    out.force_encoding(Encoding::UTF_8)
  end

  def run(out_dir, paths, flags, jobs: BaseRbsWorkers::DEFAULT_JOBS)
    kinds = {}
    supers = {}
    methods = []
    skipped = []
    scans = BaseRbsWorkers.map(paths, jobs: jobs) do |path|
      ast_kinds = nil
      # Only registered functions with readable bodies consume AST return kinds.
      scan(preprocess(path, flags)) { ast_kinds ||= ast_function_kinds(path, flags, optional: true) }
    end
    scans.each do |k, s, m, sk|
      kinds.merge!(k)
      supers.merge!(s)
      methods.concat(m)
      skipped.concat(sk)
    end
    FileUtils.mkdir_p(out_dir)
    text = render(kinds, supers, methods.uniq)
    path = File.join(out_dir, 'native.rbs')
    File.write(path, "# Native base RBS (scripts/bc2cpp/base_rbs_native.rb): mrb_define_* registrations, arity untyped.\n#{text.join("\n")}")
    [path, skipped]
  end
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.dup
  flags = []
  jobs = BaseRbsWorkers::DEFAULT_JOBS
  parser = OptionParser.new do |opts|
    opts.banner = 'usage: base_rbs_native.rb [--jobs N] OUT_DIR [-I DIR] [-D MACRO] SRC...'
    opts.on('-j N', '--jobs N', Integer, 'Native file workers (default: at most 2; 1 runs serially)') { |n| jobs = n }
    opts.on('-I DIR') { |dir| flags << "-I#{dir}" }
    opts.on('-D MACRO') { |macro| flags << "-D#{macro}" }
  end
  begin
    parser.parse!(args)
    raise OptionParser::InvalidArgument, 'jobs must be positive' unless jobs.positive?
  rescue OptionParser::ParseError => e
    abort "#{e.message}\n#{parser}"
  end
  abort parser.to_s if args.size < 2

  path, skipped = BaseRbsNative.run(args.shift, args, flags, jobs: jobs)
  warn "base_rbs_native: wrote #{path}, skipped #{skipped.size} registration(s)"
  skipped.first(10).each { |s| warn "  skipped #{s}" }
end
