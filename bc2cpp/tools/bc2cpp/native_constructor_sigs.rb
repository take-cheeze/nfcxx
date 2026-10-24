# frozen_string_literal: true

require 'prism'
require_relative 'native_direct'
require_relative 'native_owner_map'
require_relative 'native_core_result_sigs'
require_relative 'ruby_parse_cache'
require_relative 'scan_cache'

# NativeConstructorSigs: the constructor overloads of sig/bc2cpp/declarations.rbs#rgss_constructors (OVERLOADED_CONSTRUCT),
# each audited against the source of the initialize it describes.
#
# An overload is { req: [type...], opt: [type...], path: [:direct, fn, [arg...]] | [:compiled], else: bool } with
# type :num (Integer | Float, what mrb_get_args "i"/"f" convert), :str (String, "z"/"s"/"S") or :boolish (boolish,
# "b": truthiness only). `audit` derives the same list from the sources: a C initialize registered in mruby-rgss/src (one overload
# per mrb_get_args format, the format reached when no argc branch is taken being the `else`, plus an empty one for an
# `if (mrb_get_argc(M) == 0)` branch that reads no argument), or a Ruby initialize that splits on
# `<first param>.kind_of? String` between two native helpers (each helper's format is an overload, the non-String one
# the `else`). A declaration that does not equal what its source derives refuses the file.
module NativeConstructorSigs
  PATH = NativeSigs.table('rgss_constructors')
  ROOT = File.expand_path('../..', __dir__)
  # "o" (any object, untouched) has no declarable type here: an overload taking one is not modelled.
  FORMAT_TYPES = { 'i' => :num, 'f' => :num, 'z' => :str, 's' => :str, 'S' => :str, 'b' => :boolish }.freeze

  module_function

  # { 'RGSS::Bitmap' => [overload, ...] }, audited; raises on a declaration its source does not support.
  def table(path = PATH, root: ROOT)
    @tables ||= {}
    @tables[[path, root]] ||= begin
      declared = load(path)
      problems = audit(declared, root)
      raise "bc2cpp: #{path}: constructor overloads disagree with their source:\n  #{problems.join("\n  ")}" unless problems.empty?

      declared
    end
  end

  # NATIVE_CONSTRUCT_TARGETS rows (dispatch_targets.rb), keyed by the class's last segment, from the audited overloads.
  # A row comes from a `bc2cpp:direct` overload whose every argument is a positional read (`int` / `float`, with an
  # optional `=K`). codegen_send.rb's direct arm calls `fn` with exactly the arguments the call passes and fills no
  # defaults, so a literal-argument form (Rect's empty form) or a count the function does not take is left to
  # OVERLOADED_CONSTRUCT, which does fill them. Several accepted counts can come out of that rule only if the
  # direct overloads name different counts; each class's direct overloads must agree on one function and one type.
  DIRECT_READ = /\A(int|float)(?:=-?\d+(?:\.\d+)?)?\z/

  def construct_targets(declared = table, root: ROOT)
    raise "bc2cpp: #{PATH}: rgss_constructors declares no class (the section is missing or empty)" if declared.empty?

    declared.each_with_object({}) do |(klass, overloads), rows|
      direct = overloads.select do |o|
        o[:path].first == :direct && o[:path][2].all? { |a| a.match?(DIRECT_READ) }
      end
      next if direct.empty?

      fns = direct.map { |o| o[:path][1] }.uniq
      types = direct.flat_map { |o| o[:path][2].map { |a| a[DIRECT_READ, 1] } }.uniq
      counts = direct.map { |o| o[:path][2].size }.uniq.sort
      raise "bc2cpp: #{PATH}: #{klass} direct overloads name #{fns.inspect}, one function is required" unless fns.size == 1
      raise "bc2cpp: #{PATH}: #{klass} direct overloads read #{types.inspect}, one type is required" unless types.size == 1

      leaf = klass.split('::').last
      class_fn = "rgss::native_#{leaf.downcase}_class"
      header = File.read(File.join(root, 'include/rgss_construct.hxx'))
      raise "bc2cpp: #{PATH}: #{class_fn} is not declared in include/rgss_construct.hxx" unless header.include?("RClass* native_#{leaf.downcase}_class(void);")
      raise "bc2cpp: #{PATH}: #{fns.first} is not declared in include/rgss_construct.hxx" unless header.match?(/\b#{Regexp.escape(fns.first.delete_prefix('rgss::'))}\(/)
      raise "bc2cpp: #{PATH}: two classes map to the row key #{leaf}" if rows.key?(leaf)

      rows[leaf] = { fn: fns.first, class_fn: class_fn, class_owner: klass,
                     arity: counts.size == 1 ? counts.first : counts, arg_type: types.first.to_sym }
    end
  end

  # The gem-relative path (`mruby-rgss/mrblib/lib.rb`) of the Ruby initialize the audit read for `klass`, or nil. A
  # `compiled` overload calls the program's own initialize only when that is the definition the audit read.
  def ruby_source(klass)
    table
    @ruby_sources&.[](klass)
  end

  def load(path)
    decls = NativeCoreResultSigs.parse_decls(path)
    decls.to_h do |decl|
      klass = decl.name.to_s.delete_prefix('::')
      members = decl.members.select { |m| m.is_a?(RBS::AST::Members::MethodDefinition) && m.name == :initialize }
      raise "bc2cpp: #{path}: #{klass} declares only `initialize`" unless members.size == 1 && decl.members.size == 1

      [klass, members.first.overloads.map { |overload| overload_of(overload, klass, path) }.freeze]
    end.freeze
  end

  def overload_of(overload, klass, path)
    fn = overload.method_type.type
    unless fn.rest_positionals.nil? && fn.trailing_positionals.empty? && fn.required_keywords.empty? &&
           fn.optional_keywords.empty? && fn.rest_keywords.nil? && overload.method_type.block.nil?
      raise "bc2cpp: #{path}: #{klass}#initialize overloads take positional parameters only"
    end

    notes = overload.annotations.map(&:string)
    path_note = notes.find { |n| n.start_with?('bc2cpp:direct ') || n == 'bc2cpp:compiled' }
    raise "bc2cpp: #{path}: #{klass}#initialize overload needs a bc2cpp:direct or bc2cpp:compiled annotation" unless path_note

    route = if path_note == 'bc2cpp:compiled'
              [:compiled]
            else
              _, function, *args = path_note.split
              [:direct, function, args]
            end
    { req: fn.required_positionals.map { |p| type_of(p.type, klass, path) },
      opt: fn.optional_positionals.map { |p| type_of(p.type, klass, path) },
      path: route, else: notes.include?('bc2cpp:else') }.freeze
  end

  def type_of(type, klass, path)
    case type.to_s
    when 'Integer | Float', 'Float | Integer' then :num
    when 'String' then :str
    when 'boolish' then :boolish
    else raise "bc2cpp: #{path}: #{klass}#initialize: unsupported parameter type #{type}"
    end
  end

  # The shape [req, opt, else] the sources accept, per class.
  def shape(overload)
    [overload[:req], overload[:opt], overload[:else]]
  end

  # Problems (strings) of `declared` against the sources under `root`; empty when every class agrees.
  def audit(declared, root)
    sources = Dir[File.join(root, 'mruby-rgss/src/*.cxx')].sort
    ruby = Dir[File.join(root, 'mruby-rgss/mrblib/*.rb')].sort
    declared.flat_map do |klass, overloads|
      derived = derive(klass, sources, ruby)
      next ["#{klass}: no initialize source found"] unless derived

      want = derived.map { |o| shape(o) }.sort_by(&:inspect)
      got = overloads.map { |o| shape(o) }.sort_by(&:inspect)
      problems = []
      problems << "#{klass}: declared #{got.inspect}, source accepts #{want.inspect}" unless want == got
      overloads.each { |o| problems.concat(path_problems(klass, o)) }
      problems.concat(default_problems(klass, overloads, derived, sources)) if problems.empty?
      problems
    end
  end

  # A direct path converts every positional it reads, once and in order, with the conversion the format applied.
  def path_problems(klass, overload)
    return [] unless overload[:path].first == :direct

    args = overload[:path][2]
    types = overload[:req] + overload[:opt]
    reads = args.grep(/\A(?:int|float)(?:=-?\d+(?:\.\d+)?)?\z/)
    return ["#{klass}: #{overload[:path][1]} reads #{reads.size} positional(s), the overload has #{types.size}"] unless reads.size == types.size
    return ["#{klass}: #{overload[:path][1]}: a `=K` default belongs to an optional positional only"] unless
      reads.each_with_index.all? { |arg, i| arg.include?('=') == (i >= overload[:req].size) }
    return ["#{klass}: #{overload[:path][1]} converts a non-numeric positional"] unless types.all?(:num)

    []
  end

  # A direct path's `=K` defaults are the C variables' initial values, and literal arguments of an empty form are the
  # zero every field of its default-initialized struct holds.
  def default_problems(klass, overloads, derived, sources)
    overloads.flat_map do |o|
      next [] unless o[:path].first == :direct

      source = derived.find { |s| shape(s) == shape(o) }
      args = o[:path][2]
      if o[:req].empty? && o[:opt].empty?
        fields = source[:zero_fields] && struct_defaults(source[:zero_fields], sources)
        next ["#{klass}: the empty form's struct defaults cannot be read"] unless fields
        next [] if args == fields

        next ["#{klass}: #{o[:path][1]} passes #{args.join(' ')}, the default #{source[:zero_fields]} holds #{fields.join(' ')}"]
      end
      declared = args.grep(/=/).map { |a| a.split('=', 2)[1] }
      wanted = Array(source[:defaults])
      next [] if declared.size == wanted.size && declared.zip(wanted).all? { |a, b| b && a.to_f == b.to_f }

      ["#{klass}: #{o[:path][1]} defaults #{declared.inspect}, the C initialize starts its variables at #{wanted.inspect}"]
    end
  end

  # The `{K}` initializers of `struct name`'s mrb_int/mrb_float fields, in order, or nil.
  def struct_defaults(name, sources)
    sources.each do |path|
      text = NativeDirect.strip_comments(File.binread(path).force_encoding('UTF-8'))
      match = text.match(/^struct\s+#{Regexp.escape(name)}\s*\{/)
      next unless match

      body = NativeOwnerMap.brace_body(text, match.end(0) - 1)
      values = body.scan(/^\s*(?:mrb_int|mrb_float|double|int)\s+([^;]+);/).flatten.flat_map do |decl|
        decl.split(',').map { |part| part[/\{\s*(-?[\d.]+)\s*\}/, 1] }
      end
      return values.all? ? values : nil
    end
    nil
  end

  # The overloads the source of `klass`'s initialize accepts, or nil when it cannot be read.
  def derive(klass, sources, ruby)
    from_c = c_initialize(klass, sources)
    return from_c if from_c

    ruby_initialize(klass, sources, ruby)
  end

  def c_initialize(klass, sources)
    body = registered_body(klass, 'initialize', sources)
    body && c_overloads(body, defaults: true)
  end

  def c_overloads(body, defaults: false)
    calls = body.scan(/\bmrb_get_args\(\s*\w+\s*,\s*"([^"]*)"((?:\s*,\s*&\s*\w+)*)\s*\)/)
    return nil if calls.empty?

    overloads = calls.each_with_index.map do |(format, vars), i|
      overload = format_overload(format)
      return nil unless overload

      overload = overload.merge(else: i == calls.size - 1)
      next overload unless defaults

      # The value an optional positional's variable starts with, which is what the native uses when it is absent.
      names = vars.scan(/&\s*(\w+)/).flatten
      overload.merge(defaults: names.drop(overload[:req].size).map { |v| body[/\b#{v}\s*=\s*(-?\d+(?:\.\d+)?)\b/, 1] })
    end
    zero = body.match(/if\s*\(\s*mrb_get_argc\(\s*\w+\s*\)\s*==\s*0\s*\)\s*\{([^{}]*)\}/m)
    if zero && !zero[1].include?('mrb_get_args')
      # The empty form builds the default-initialized struct (`alloc_obj(M, self)` with no field values).
      empty = { req: [], opt: [], else: false }
      empty = empty.merge(zero_fields: zero[1][/DataType<(\w+)>::alloc_obj\(\s*\w+\s*,\s*\w+\s*\)/, 1]) if defaults
      overloads.unshift(empty)
    end
    overloads
  end

  def format_overload(format)
    req, opt = format.split('|', 2)
    opt ||= ''
    return nil unless (req + opt).chars.all? { |c| FORMAT_TYPES.key?(c) }

    { req: req.chars.map { |c| FORMAT_TYPES.fetch(c) }, opt: opt.chars.map { |c| FORMAT_TYPES.fetch(c) } }
  end

  # `def initialize f, s = nil; if f.kind_of? String ... self.A(f, s) ... else self.B(f, s) end; end` in a class
  # named `klass`'s last segment: A's format is the String overload, B's the `else`.
  def ruby_initialize(klass, sources, ruby)
    name = klass.split('::').last
    ruby.each do |path|
      found = find_initialize(RubyParseCache.parse(File.read(path), path).value, name)
      next unless found

      params = found.parameters
      return nil unless params && params.requireds.size == 1 && params.optionals.size <= 1 && params.rest.nil?

      first = params.requireds.first.name
      node = found.body&.body&.first
      return nil unless found.body.body.size == 1 && node.is_a?(Prism::IfNode)

      cond = node.predicate
      return nil unless cond.is_a?(Prism::CallNode) && %i[kind_of? is_a?].include?(cond.name) &&
                        cond.receiver.is_a?(Prism::LocalVariableReadNode) && cond.receiver.name == first &&
                        cond.arguments&.arguments&.map(&:slice) == ['String']

      string_helper = self_calls(node.statements).first
      else_helper = self_calls(node.subsequent&.statements).first
      return nil unless string_helper && else_helper

      string_body = registered_body(klass, string_helper, sources)
      else_body = registered_body(klass, else_helper, sources)
      string_overloads = string_body && c_overloads(string_body)
      else_overloads = else_body && c_overloads(else_body)
      return nil unless string_overloads&.size == 1 && else_overloads&.size == 1
      return nil unless string_overloads.first[:req].first == :str

      (@ruby_sources ||= {})[klass] = path.delete_prefix("#{File.expand_path('..', File.dirname(File.dirname(path)))}/")
      return [string_overloads.first.merge(else: false), else_overloads.first.merge(else: true)]
    end
    nil
  end

  def find_initialize(node, name, inside = false)
    return nil unless node.is_a?(Prism::Node)

    if node.is_a?(Prism::ClassNode)
      inside = node.constant_path.slice.split('::').last == name
    elsif node.is_a?(Prism::DefNode) && inside && node.name == :initialize && node.receiver.nil?
      return node
    end
    node.compact_child_nodes.each do |child|
      found = find_initialize(child, name, inside)
      return found if found
    end
    nil
  end

  # The names of `self.x(...)` calls in a statements node, in order.
  def self_calls(statements)
    return [] unless statements

    out = []
    walk = lambda do |n|
      next unless n.is_a?(Prism::Node)

      out << n.name.to_s if n.is_a?(Prism::CallNode) && n.receiver.is_a?(Prism::SelfNode)
      n.compact_child_nodes.each { |c| walk.call(c) }
    end
    walk.call(statements)
    out
  end

  # The body text of the C function `mrb_define_method(M, <var of klass>, "name", fn, ...)` registers: a lambda's
  # own braces, or the definition of the named function in the same sources.
  def registered_body(klass, name, sources)
    needle = "\"#{name}\""
    sources.each do |path|
      text = stripped(path)
      # The name is a whole argument, so its literal must occur in the file; a file without it (or without any
      # mrb_define_method) has no registration to match and never needs its class table (see class_vars).
      next unless text.include?('mrb_define_method') && text.include?(needle)

      vars = nil
      text.scan(/\bmrb_define_method\s*\(/) do
        open = Regexp.last_match.end(0) - 1
        args, = NativeOwnerMap.call_args(text, open)
        next unless args && args.size >= 4 && args[2] == needle

        vars ||= class_vars(path, text)
        next unless vars[args[1]] == klass

        fn = args[3]
        # A lambda's body has top-level commas of its own, so it is read from the text, not from the split.
        return lambda_body(text[text.index(fn[0, 40], open)..]) if fn.start_with?('[')
        return function_body(sources, fn) if fn.match?(/\A\w+\z/)

        return nil
      end
    end
    nil
  end

  # The comment-stripped text of a source file. Keyed by its bytes, so a changed file is never served stale text.
  def stripped(path)
    raw = File.binread(path).force_encoding('UTF-8')
    @stripped ||= {}
    @stripped[raw] ||= NativeDirect.strip_comments(raw)
  end

  # NativeDirect.class_variables of a stripped source. Both its inputs are the key: the text and the sibling owners.
  # Across processes the key is the file and its siblings, which determine both (text is stripped(path)).
  def class_vars(path, text)
    owners = NativeDirect.sibling_param_owners(path)
    @class_vars ||= {}
    @class_vars[[text, owners]] ||= ScanCache.fetch('native_constructor_sigs.class_variables',
                                                    [path, *NativeDirect.sibling_sources(path)]) do
      NativeDirect.class_variables(text, owners)
    end
  end

  def lambda_body(text)
    open = text.index('{')
    open && NativeOwnerMap.brace_body(text, open)
  end

  def function_body(sources, fn)
    sources.each do |path|
      text = NativeDirect.strip_comments(File.binread(path).force_encoding('UTF-8'))
      match = text.match(/^\s*(?:static\s+)?(?:mrb_value|V)\s+#{Regexp.escape(fn)}\s*\([^)]*\)\s*\{/)
      return NativeOwnerMap.brace_body(text, match.end(0) - 1) if match
    end
    nil
  end
end
