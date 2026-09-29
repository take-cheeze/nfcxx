# frozen_string_literal: true

require 'set'
require_relative 'compiled_gems'

# CLOSED_WORLD touch analysis (docs/adr/0256): which constants can an outside
# file (native C/C++ or foreign Ruby) CREATE, REOPEN, SUBCLASS or REBIND?
#
# Every scan returns a Result:
#   hard   - constant names the file may reopen/subclass/rebind. A class whose
#            root segment and simple name are both in one file's set is opaque.
#   origin - constants the file natively DEFINES. Defining a class the closed
#            world's Ruby also declares is that class's origin, so it only
#            touches owners the closed world does not declare (module and
#            native-only constants keep the old conservative behaviour).
#   legacy - some construct could not be classified; the caller falls back to
#            "every constant the file spells", the pre-0253 rule.
# WILD stands for an outer namespace the scan could not resolve: it satisfies
# any root-segment requirement.
module TouchScan
  WILD = '*'
  CLASS_FACTORIES = %w[Class Module Struct Data].freeze

  # `evidence` maps a name to the first construct that put it in a set.
  Result = Struct.new(:hard, :origin, :legacy, :evidence, :text, :reasons) do
    def note(set, names, why)
      names.each do |n|
        set << n
        evidence[n] ||= why
      end
    end

    def give_up(why)
      reasons << why
      self.legacy ||= why
    end
  end

  def self.new_result(text = '')
    Result.new(Set.new, Set.new, nil, {}, text, [])
  end

  # -- Ruby ----------------------------------------------------------------

  CONST = /[A-Z]\w*/
  CONST_TOKEN = /\b[A-Z]\w*/
  CONST_PATH = /(?:::)?#{CONST}(?:::#{CONST})*/
  # Calls that reopen, subclass or rebind whatever their receiver evaluates to:
  # the receiver may be a class held in a variable, so the file cannot be
  # classified by the constants it names.
  RUBY_REOPENERS = /(?:\.|&\.|::)\s*(?:class_eval|module_eval|instance_eval|class_exec|module_exec|
                     instance_exec|define_method|define_singleton_method|const_set|remove_const|autoload|
                     alias_method|instance_variable_set|extend|prepend|include|send|__send__|public_send|
                     singleton_class|remove_method|undef_method|refine|append_features|extend_object|
                     prepend_features)\b(?![?!])|
                    \b(?:eval|binding|singleton_class)\b|
                    \b(?:Class|Module|Struct|Data)\s*(?:\.|::)\s*(?:new|define)\b/x
  RUBY_CLASS = /(?<![\w.:@$])class[ \t]+([^\n;]*)/
  RUBY_MODULE = /(?<![\w.:@$])module[ \t]+([^\n;]*)/
  RUBY_ASSIGN = /(?<![=!<>])=(?![=~>])|<<=|>>=/
  RUBY_MIXIN = /\b(?:include|extend|prepend)\b(?![?!:=])/

  # `text` has its full-line comments removed. Text that only mentions a
  # constant (a call, a value, a rescue clause) is not a touch.
  def self.ruby(text)
    res = new_result
    if (m = text.match(RUBY_REOPENERS))
      res.give_up("reopener #{m[0].strip}")
      return res
    end
    text.scan(RUBY_CLASS) { ruby_class(Regexp.last_match(1).strip, res) }
    text.scan(RUBY_MODULE) { ruby_module(Regexp.last_match(1).strip, res) }
    text.each_line do |line|
      ruby_assignment(line, res)
      res.note(res.hard, line.scan(CONST_TOKEN), "mixin: #{line.strip[0, 60]}") if line.match?(RUBY_MIXIN)
    end
    # Copying a class object makes a class the registry cannot see.
    text.scan(/(#{CONST_PATH})[ \t]*&?\.[ \t]*(?:dup|clone)\b/) { |(p)| res.note(res.hard, path_names(p), "#{p}.dup") }
    # A variable assigned straight from a constant path holds the class: copying it copies the class.
    text.scan(/^[ \t]*([a-z_]\w*)[ \t]*=[ \t]*(#{CONST_PATH})[ \t]*(?:#.*)?$/) do |var, path|
      text.scan(/\b#{Regexp.escape(var)}[ \t]*&?\.[ \t]*(?:dup|clone)\b/) do
        res.note(res.hard, path_names(path), "#{var}.dup (#{var} = #{path})")
      end
    end
    text.scan(/\bdef[ \t]+(#{CONST_PATH})[ \t]*\./) { |(p)| res.note(res.hard, path_names(p), "def #{p}.") }
    text.scan(/\bdef[ \t]+([a-z_]\w*)\.\w/) do |(recv)|
      res.give_up("def #{recv}. singleton definition") unless recv == 'self'
    end
    res.give_up('def (expr).') if text.match?(/\bdef[ \t]*\(/)
    res
  end

  def self.path_names(path)
    path.split('::').reject(&:empty?)
  end

  def self.ruby_class(rest, res)
    if (m = rest.match(/\A<<[ \t]*(.*)/))
      target = m[1].strip
      return if target.match?(/\Aself\b/)
      return res.note(res.hard, path_names(target), "class << #{target}") if target.match?(/\A#{CONST_PATH}[ \t]*(?:#.*)?\z/)

      return res.give_up("class << #{target[0, 40]}")
    end
    m = rest.match(/\A(#{CONST_PATH})[ \t]*(.*)\z/m)
    unless m
      res.give_up("class #{rest[0, 40]}") if rest.match?(/\A(?:[a-z_]\w*[ \t]*::|\()/)
      return # prose in a string or trailing comment
    end
    res.note(res.hard, path_names(m[1]), "class #{m[1]}")
    tail = m[2].sub(/[ \t]+#.*\z/, '').strip
    return if tail.empty? || tail.start_with?('#')

    sup = tail[/\A<[ \t]*(.*)\z/, 1]
    return res.give_up("class #{m[1]} #{tail[0, 40]}") unless sup

    sup = sup.strip
    return res.give_up("superclass #{sup[0, 40]}") unless sup.match?(/\A#{CONST_PATH}\z/)

    res.note(res.hard, path_names(sup), "class #{m[1]} < #{sup}")
  end

  def self.ruby_module(rest, res)
    if (m = rest.match(/\A(#{CONST_PATH})/))
      res.note(res.hard, path_names(m[1]), "module #{m[1]}")
    elsif rest.match?(/\A(?:[a-z_]\w*[ \t]*::|\()/)
      res.give_up("module #{rest[0, 40]}")
    end
  end

  def self.ruby_assignment(line, res)
    idx = line.index(RUBY_ASSIGN)
    return unless idx && line[0...idx].match?(CONST_TOKEN)

    res.note(res.hard, line.scan(CONST_TOKEN), "rebind: #{line.strip[0, 60]}")
  end

  # -- native --------------------------------------------------------------

  NATIVE_EVENT = /\bmrb_(define_class(?:_under)?(?:_id)?|define_module(?:_under)?(?:_id)?|class_new|module_new|
                        include_module|prepend_module|extend_object|singleton_class(?:_ptr|_clone)?|obj_new|
                        instance_new|obj_alloc|obj_clone|obj_dup|const_set|const_remove|
                        define_const(?:_id)?|define_global_const(?:_id)?|funcall\w*)[ \t\n]*\(/x
  NATIVE_SUPER_ASSIGN = /->[ \t]*super[ \t]*=(?!=)/
  # Method names that could turn a send into class creation or reopening.
  NATIVE_CLASS_SENDS = %w[include prepend extend send __send__ public_send].freeze
  NATIVE_SYM = /\A\s*(?:MRB_(?:OP)?SYM(?:_[A-Z])?\((\w+)\)|"([^"\\]*)"|mrb_intern_(?:lit|cstr|static)\s*\(\s*\w+\s*,\s*"([^"\\]*)"\s*\))\s*\z/

  # `text` has comments removed and string literals kept. `decl_simples` are
  # the simple names of the classes the closed world declares.
  def self.native(text, decl_simples)
    res = new_result(text)
    norm = decl_simples.group_by { |n| n.downcase.delete('_') }
    text.scan(NATIVE_SUPER_ASSIGN) { res.give_up('direct ->super assignment') }
    text.to_enum(:scan, NATIVE_EVENT).map { Regexp.last_match }.each do |m|
      args = bc2cpp_c_call_args(text[m.end(0)..])
      native_event(m[1], args, res, norm, "#{m[0].strip.chomp('(')}(#{args.join(',').strip[0, 50]})")
    end
    res
  end

  def self.native_event(kind, args, res, norm, why)
    case kind
    when /\Adefine_class/ then native_define(kind, args, res, norm, why, true)
    when /\Adefine_module/ then native_define(kind, args, res, norm, why, false)
    when 'class_new' then native_hard(args[1], res, norm, why)
    when 'module_new' then nil
    when 'include_module', 'prepend_module', 'extend_object', /\Asingleton_class/
      native_hard(args[1], res, norm, why)
    when 'obj_clone', 'obj_dup' then native_copy(args[1], res, norm, why)
    when 'obj_new', 'instance_new' then native_instantiate(args[1], res, norm, why)
    when 'obj_alloc'
      # Only an allocation of a class-like object shapes the hierarchy.
      tt = args[1].to_s
      res.give_up(why) if tt.match?(/MRB_TT_(?:CLASS|MODULE|SCLASS|ICLASS)/) || !tt.match?(/\A\s*MRB_TT_\w+\s*\z/)
    when /\Aconst_(?:set|remove)\z/ then native_const(args[2], args[1], res, norm, why)
    when /\Adefine_const/ then native_const(args[2], args[1], res, norm, why)
    when /\Adefine_global_const/ then native_const(args[1], 'mrb->object_class', res, norm, why)
    when /\Afuncall/ then native_funcall(args, res, norm, why)
    end
  end

  # Defining a class the closed world declares is its origin; anything else
  # (a module, a native-only class) is recorded as `origin` for owners the
  # closed world does not declare. A superclass argument is a subclassing.
  def self.native_define(kind, args, res, norm, why, klass)
    under = kind.include?('_under')
    name = native_literal(args[1 + (under ? 1 : 0)], res)
    return res.give_up(why) unless name&.match?(/\A#{CONST_PATH}\z/)

    outer = under ? (native_resolve(args[1], norm) || Set[WILD]) : Set.new
    res.note(res.origin, path_names(name) + outer.to_a, why)
    return unless klass

    native_hard(args[2 + (under ? 1 : 0)], res, norm, why)
  end

  def self.native_hard(expr, res, norm, why)
    names = native_resolve(expr, norm)
    names ? res.note(res.hard, names, why) : res.give_up(why)
  end

  # `mrb_obj_new(M, klass, ...)` makes an instance; only a class factory as
  # `klass` (or a class we cannot see) could take a superclass argument.
  def self.native_instantiate(expr, res, norm, why)
    names = native_resolve(expr, norm)
    factory = expr.to_s.match?(/\b(?:class_class|module_class|struct_class)\b|"(?:#{CLASS_FACTORIES.join('|')})"/)
    res.give_up(why) if names.nil? || factory
  end

  # dup/clone of a class object copies the class. Only a receiver spelled as a
  # class is treated so: a plain value variable is assumed to be an instance,
  # the same assumption scan_closed_world makes for `dup` in the closed world's
  # own Ruby (ADR 0256, "Residual assumption").
  def self.native_copy(expr, res, norm, why)
    native_hard(expr, res, norm, why) if expr.to_s.match?(/mrb_obj_value\s*\(|\bRClass\b|_(?:class|module)_(?:get|ptr)|->\s*\w+_class\b/)
  end

  def self.native_const(name_expr, target, res, norm, why)
    name = native_literal(name_expr, res)
    return res.give_up(why) unless name

    outer = native_resolve(target, norm) || Set[WILD]
    res.note(res.hard, path_names(name) + outer.to_a, why)
  end

  def self.native_funcall(args, res, norm, why)
    mid = native_literal(args[2], res)
    return res.give_up(why) unless mid

    case mid
    when 'new', 'allocate' then native_instantiate(args[1], res, norm, why)
    when 'dup', 'clone' then native_copy(args[1], res, norm, why)
    when *NATIVE_CLASS_SENDS then res.give_up(why)
    end
  end

  def self.native_literal(expr, res = nil)
    m = expr.to_s.match(NATIVE_SYM)
    return m[1] || m[2] || m[3] if m

    res && expr.to_s.strip.match?(/\A[A-Za-z_]\w*\z/) ? symbol_variable(expr.strip, res) : nil
  end

  # A `mrb_sym` local whose every declaration in the file initialises it with
  # the same literal. A parameter or an uninitialised declaration disqualifies.
  def self.symbol_variable(name, res)
    values = Set.new
    res.text.scan(/\b(?:mrb_sym|auto)\b[ \t\n*&]+(?:const[ \t\n]+)?#{Regexp.escape(name)}\b[ \t\n]*([=,;)]?)([^;]*)/) do |delim, rhs|
      return nil unless delim == '='

      m = rhs.strip.match(NATIVE_SYM)
      return nil unless m

      values << (m[1] || m[2] || m[3])
    end
    values.size == 1 ? values.first : nil
  end

  # The constant names an expression of class type can denote, or nil when it
  # is a variable, parameter or call result this scan cannot see through.
  def self.native_resolve(expr, norm)
    e = expr.to_s.strip
    e = e.sub(/\A\(\s*(?:struct\s+)?RClass\s*\*\s*\)\s*/, '')
    e = e[1..-2].strip while e.start_with?('(') && e.end_with?(')') && wrapped?(e)
    case e
    when /\A\w+\s*->\s*object_class\z/ then Set['Object']
    when /\Amrb_(?:obj_value|class_ptr|module_ptr)\s*\((.*)\)\z/m then native_resolve(Regexp.last_match(1), norm)
    when /\Amrb_(?:class|module)_get(_under)?(?:_id)?\s*\((.*)\)\z/m then native_lookup(Regexp.last_match(1), Regexp.last_match(2), norm)
    when /\A(?:E_[A-Z0-9_]+|\w+\s*->\s*\w+_(?:class|module))\z/ then builtin_handle(e, norm)
    end
  end

  def self.native_lookup(under, inner, norm)
    args = bc2cpp_c_call_args(inner)
    name = native_literal(args.last)
    return nil unless name&.match?(/\A#{CONST_PATH}\z/)

    outer = under ? (native_resolve(args[1], norm) || Set[WILD]) : Set.new
    Set.new(path_names(name)) | outer
  end

  # mruby's built-in class handles (E_STANDARD_ERROR, mrb->array_class) can only
  # matter if the closed world declares a class of that name.
  def self.builtin_handle(handle, norm)
    base = handle.sub(/\AE_/, '').sub(/\A.*->\s*/, '').sub(/_(?:class|module)\z/, '').downcase.delete('_')
    # `eStandardError_class` carries an `e` prefix that `array_class` does not.
    hits = [base, base.delete_prefix('e')].flat_map { |key| norm.fetch(key, []) }
    hits.empty? ? Set.new : Set.new(hits) << WILD
  end

  def self.wrapped?(text)
    depth = 0
    text.each_char.with_index do |ch, i|
      depth += 1 if ch == '('
      depth -= 1 if ch == ')'
      return false if depth.zero? && i < text.length - 1
    end
    true
  end
end
