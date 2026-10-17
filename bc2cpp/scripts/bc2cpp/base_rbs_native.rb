#!/usr/bin/env ruby
# frozen_string_literal: true

# Base RBS for native (C / C++) method registrations: the mrb_define_* calls of mruby's C API, found in the
# preprocessed source (`clang -E`), so macros such as MRB_ARGS_REQ are already expanded.
#
#   ruby scripts/bc2cpp/base_rbs_native.rb OUT_DIR [-I DIR]... [-D MACRO]... SRC.cxx...
#
# A class or module is named by the call that defines it (mrb_define_class / _under, mrb_define_module / _under,
# and the _id forms); a method is attached to the variable it is registered on. Methods are written as
# `(*untyped) -> untyped`: the arity of a native method is in its aspec macro, and reading it back is not needed for a
# stub that claims no types. A registration whose owner variable is assigned to two different classes in one file is
# skipped and listed (the scanner does not follow scopes), and so is one whose owner it cannot name.
#
# Every member line is validated with the rbs parser before it is written, as base_rbs.rb does.

require 'open3'
require 'fileutils'
require 'set'
require_relative '../../tools/bc2cpp/native_format_types'

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

  # The variable a call result is assigned to (`RClass* rect = mrb_define_class_under(...)`), if any.
  def assigned_name(text, index)
    before = text[[index - 200, 0].max...index]
    before[/(\w+)\s*=\s*\z/, 1]
  end

  # Scans one preprocessed source. Returns [classes, methods, skipped]; classes maps a full name to its kind.
  def scan(text)
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
      var = assigned_name(text, m.begin(0))
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
      supers[full] = super_name(args[super_index]) if kind == 'class' && args.size > super_index
      next unless var

      set_owner(owners, var, full)
    end
    # A variable taken from a core class (`krn = mrb->kernel_module;`) owns the methods registered on it.
    text.scan(/(\w+)\s*=\s*((?:M|mrb)->\w+_(?:class|module))\s*;/) do |var, expr|
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
      shape = param_shape(text, args[3])
      methods << [owner, singleton, name, shape]
      methods << [owner, false, name, shape] if kind == 'module_function'
    end
    [kinds, supers, methods.uniq, skipped]
  end

  # The parameter list of a registered function: its `mrb_get_args` format, when the body makes exactly one such call
  # (NativeFormatTypes). A class type only where the conversion is a check; everything else is untyped. A function whose
  # format is not modelled, or that is not in this text, keeps the rest parameter.
  def param_shape(text, function)
    return '*untyped' unless function&.match?(/\A\w+\z/)

    head = text.match(/\b#{Regexp.escape(function)}\s*\([^)]*\)\s*\{/)
    return '*untyped' unless head

    body = function_body(text, head.end(0) - 1)
    formats = body.scan(/\bmrb_get_args\s*\(\s*\w+\s*,\s*"([^"]*)"/).flatten
    return '*untyped' unless formats.size == 1

    format = formats.first
    positions = NativeFormatTypes.positions(format)
    return '*untyped' unless positions

    params = positions.map do |pos|
      type = NativeFormatTypes.rbs_of(pos[:letter]) || 'untyped'
      pos[:optional] ? "?#{type}" : type
    end
    params << '*untyped' if format.include?('*')
    params.join(', ')
  end

  # The text of a function body from its opening brace at +open+ to the matching close brace.
  def function_body(text, open)
    depth = 0
    (open...text.length).each do |i|
      depth += 1 if text[i] == '{'
      depth -= 1 if text[i] == '}'
      return text[open..i] if depth.zero?
    end
    ''
  end

  # A superclass argument as a Ruby constant name. The core object class is `M->object_class` (or `mrb->...`), which is
  # Object, the superclass a class gets when none is written, so it is left out as the Ruby source leaves it. Any other
  # C expression is not a name, so the superclass is left out rather than written wrong.
  # `E_*_ERROR` is mruby's macro for a core error class; its name is not written here, so the superclass is left out.
  def super_name(expr)
    return nil if expr.match?(/\A(?:M|mrb)->object_class\z/) || expr.start_with?('E_')
    return core_owner(expr) if core_owner(expr)
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

  def member(name, shape, singleton: false)
    "def #{singleton ? 'self.' : ''}#{name}: (#{shape}) -> untyped"
  end

  # One member per method name: the same name registered twice with different parameter shapes (a module_function
  # pair, or two C functions sharing a name) has no single shape this stub can state, so it is left untyped.
  def merge_shapes(entries)
    entries.group_by(&:first).sort.map do |name, rows|
      shapes = rows.map(&:last).uniq
      [name, shapes.size == 1 ? shapes.first : '*untyped']
    end
  end

  def render(kinds, supers, methods)
    by_class = Hash.new { |h, k| h[k] = { singleton: [], instance: [] } }
    methods.each do |owner, singleton, name, shape|
      by_class[owner][singleton ? :singleton : :instance] << [name, shape]
    end
    names = (kinds.keys + by_class.keys).uniq.sort
    names.map do |full|
      kind = kinds[full] || 'class'
      head = if kind == 'module' then "module #{full}"
             elsif supers[full] then "class #{full} < #{supers[full]}"
             else "class #{full}"
             end
      body = []
      merge_shapes(by_class.fetch(full, { instance: [] })[:instance]).each { |n, shape| body << member(n, shape) }
      merge_shapes(by_class.fetch(full, { singleton: [] })[:singleton]).each { |n, shape| body << member(n, shape, singleton: true) }
      body = body.select { |line| valid_member?(line) }
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

  def preprocess(path, flags)
    lang = path.end_with?('.c') ? ['-x', 'c', '-std=gnu11'] : ['-std=gnu++17']
    out, err, status = Open3.capture3('clang', *lang, '-E', '-P', *flags, path)
    raise "clang -E failed for #{path}: #{err.lines.first}" unless status.success?

    # The sources are UTF-8 whatever the locale says; a US-ASCII read fails on the first non-ASCII comment.
    out.force_encoding(Encoding::UTF_8)
  end

  def run(out_dir, paths, flags)
    kinds = {}
    supers = {}
    methods = []
    skipped = []
    paths.each do |path|
      k, s, m, sk = scan(preprocess(path, flags))
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
  abort 'usage: base_rbs_native.rb OUT_DIR [-I DIR] [-D MACRO] SRC...' if args.size < 2

  out_dir = args.shift
  flags = []
  while args.first&.start_with?('-I', '-D')
    flag = args.shift
    flag = "#{flag}#{args.shift}" if flag.length == 2
    flags << flag
  end
  path, skipped = BaseRbsNative.run(out_dir, args, flags)
  warn "base_rbs_native: wrote #{path}, skipped #{skipped.size} registration(s)"
  skipped.first(10).each { |s| warn "  skipped #{s}" }
end
