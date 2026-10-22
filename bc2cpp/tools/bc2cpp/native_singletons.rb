# frozen_string_literal: true

require 'set'
require_relative 'native_direct'
require_relative 'native_names'

# NATIVE_SINGLETON_CALL: which native sources register `name` as a singleton method of
# which class or module, read from the C/C++ registrations themselves.
#
# NativeDirect.registered_owners answers the same question for the RGSS sources and the
# `mrb_define_xxx(mrb, var, "name", ...)` spelling only; mruby's own gems register through
# `mrb_define_class_method_id(mrb, file, MRB_SYM_Q(exist), ...)` on classes found by
# `mrb_class_get_id` / `mrb_define_class_id`. Both spellings are parsed here, and the answer is nil
# whenever a spelling of the name in a file is not a registration this parser understands (an alias,
# a ROM table entry, a call by name, a registration on a class it cannot name): a name the compiler cannot
# fully account for is never bound.
module NativeSingletons
  CLASS_FUNCTION = /\A(?:mrb_)(define_class|define_module|class_get|module_get)(_under)?(_id)?\z/
  # kind => the registration lands on the class's own table (:instance) or its singleton class (:singleton).
  REGISTRATIONS = {
    'method' => :instance, 'method_id' => :instance,
    'private_method' => :instance, 'private_method_id' => :instance,
    'class_method' => :singleton, 'class_method_id' => :singleton,
    'module_function' => :singleton, 'module_function_id' => :singleton
  }.freeze
  NAME_ARG = %r{"((?:[^"\\\n]|\\.)*)"|MRB_(SYM_Q|SYM_B|SYM_E|SYM|OPSYM)\((\w+)\)}
  STRING_LITERAL = /"((?:[^"\\\n]|\\.)*)"/

  @files = {}

  module_function

  # path => { var => full class path } for the classes and modules one file binds to a C variable. A variable
  # with two different bindings in the file has none (it is not told apart by scope).
  def class_variables(text, param_owners = {})
    bindings = Hash.new { |hash, key| hash[key] = [] }
    text.scan(/(?:\b(?:struct\s+)?RClass\s*\*\s*)?\b(\w+)\s*=\s*(mrb_\w+)\s*\(([^;]*?)\)\s*;/m) do |var, function, args|
      shape = function.match(CLASS_FUNCTION) or next
      parts = split_args(args)
      outer = shape[2] ? parts[1] : nil
      name_arg = shape[2] ? parts[2] : parts[1]
      name = class_name(name_arg)
      next unless name && parts[0] && (!shape[2] || outer =~ /\A\w+\z/)

      bindings[var] << [outer, name]
    end
    # A function's `RClass* param` that every call site (any sibling file) hands the same class or module.
    text.scan(/(\w+)\s*\(\s*mrb_state\s*\*\s*\w+\s*,\s*RClass\s*\*\s*(\w+)\s*\)\s*\{/) do |function, param|
      bindings[param] << [:full, param_owners[function]]
    end
    owners = {}
    4.times do
      bindings.each do |var, list|
        found = list.map do |outer, name|
          if outer == :full then name
          elsif outer then owners[outer] && "#{owners[outer]}::#{name}"
          else name
          end
        end.uniq
        owners[var] = found.size == 1 ? found.first : nil
      end
    end
    owners.compact
  end

  # The comma-separated top-level arguments of a call's text.
  def split_args(text)
    args = []
    depth = 0
    current = +''
    in_string = nil
    text.each_char do |c|
      if in_string
        current << c
        in_string = nil if c == in_string
        next
      end
      case c
      when '"', "'" then in_string = c
      when '(', '[', '{' then depth += 1
      when ')', ']', '}' then depth -= 1
      when ','
        if depth.zero?
          args << current.strip
          current = +''
          next
        end
      end
      current << c
    end
    args << current.strip unless current.strip.empty?
    args
  end

  def class_name(arg)
    return nil unless arg

    if (m = arg.match(/\A"(\w+)"\z/)) then m[1]
    elsif (m = arg.match(/\AMRB_SYM\((\w+)\)\z/)) then m[1]
    end
  end

  # { name => [[kind, owner], ...] } for one file, plus how many times the file spells each name:
  # { name => { registrations: [[:instance|:singleton, owner or nil], ...], spellings: n } }.
  def file_table(path)
    @files[path] ||= begin
      text = NativeDirect.strip_comments(File.binread(path).force_encoding('UTF-8'))
      owners = class_variables(text, NativeDirect.sibling_param_owners(path))
      table = Hash.new { |hash, key| hash[key] = { registrations: [], spellings: 0 } }
      text.scan(STRING_LITERAL) { |(literal)| table[literal][:spellings] += 1 }
      text.scan(MRB_SYM_TOKEN_RE) { |macro, token| table[resolve_mrb_sym_token(macro, token)][:spellings] += 1 }
      text.scan(/\bmrb_define_(\w+)\s*\(\s*\w+\s*,\s*(\w+)\s*,\s*(#{NAME_ARG})\s*,/) do |kind, var, arg, literal, macro, token|
        where = REGISTRATIONS[kind] or next
        name = literal || resolve_mrb_sym_token(macro, token)
        _ = arg
        owner = owners[var]
        table[name][:registrations] << [where, owner]
      end
      table.default_proc = nil
      table
    end
  end

  # The owners ("File.singleton", "Kernel") `paths` register `name` on, or nil when a spelling of the name
  # is not one of the registrations parsed above. A name no path spells has no owners.
  def registered_owners(name, paths)
    owners = []
    Array(paths).each do |path|
      entry = file_table(path)[name]
      next unless entry
      return nil if entry[:spellings] != entry[:registrations].size

      entry[:registrations].each do |where, owner|
        return nil unless owner

        owners << (where == :singleton ? "#{owner}.singleton" : owner)
      end
    end
    owners
  end

  # `class_path.singleton` is registered for `name` by `paths` (at least once; every registration is a C function,
  # and the call resolves the one the VM ends up with), and no spelling is unaccounted for.
  def unique_singleton?(name, class_path, paths)
    owners = registered_owners(name, paths)
    !owners.nil? && owners.count("#{class_path}.singleton") >= 1
  end
end
