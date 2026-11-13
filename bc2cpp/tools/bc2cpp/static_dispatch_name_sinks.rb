# frozen_string_literal: true

require 'set'

# NAME_SINKS (closed only): the natives that turn a String value into a method name, audited.
#
# With SYMBOL_USES holding, a method is looked up by a name only where that name is a literal in the bytecode (the
# LOADSYM or STRING argument of a LOOKUP_SENDS call, a block Symbol), a name some native spells, or a conversion
# native turns a runtime value into one. A String that is compared, printed, kept in a container or built at run time
# reaches a lookup only through such a conversion, so the engine's identifier-shaped literals (IDENT_USES) and their
# fragments (FRAGMENT_USES) name nothing when every conversion is one of the audited ones below. `inventory` finds them
# in the closed build's native sources; a source with a conversion this list does not know (a new `n` argument, a new
# call of the converting functions) keeps the flow rules until it is audited here.
module StaticDispatchNameSinks
  # Functions that turn a value (a String, a Symbol) into a Symbol, and the macros some file makes of them.
  CONVERTERS = %w[mrb_obj_to_sym mrb_intern_str mrb_str_intern mrb_check_intern_str mrb_str_to_sym].freeze
  # `mrb_intern*(` over the bytes of a Ruby String.
  RAW_INTERN = /\b(?:mrb_intern|mrb_intern_cstr|mrb_intern_static|mrb_check_intern)\s*\(/
  STRING_BYTES = /RSTRING_(?:PTR|CSTR)|mrb_str_to_cstr|RSTR_PTR|mrb_string_value_(?:ptr|cstr)|\.c_str\(\)/
  # mrb_get_args' `n` format converts a Symbol or String argument to a Symbol.
  GET_ARGS = /\bmrb_get_args\s*\(\s*\w+\s*,\s*"([^"]*)"/
  ALIAS_MACRO = /^\s*#\s*define\s+(\w+)\s*\([^)]*\)\s+(?:#{CONVERTERS.join('|')})\s*\(/
  COMMENTS = %r{/\*.*?\*/|//[^\n]*}m
  FUNCTION_START = /^(?:(?:static|inline|extern|MRB_API|MRB_INLINE)\s+)*(?:[\w:<>*&]+[\s*&]+)*(\w+)\s*\(/

  # What a conversion in an audited function can do; the closed build's natives must hold exactly these functions.
  #   lookup        names the method it looks up or removes: a LOOKUP_SENDS member, whose argument SYMBOL_USES proves
  #                 a literal
  #   definition    acts on a method defined while the program loads, before any compiled registration (the attr_*
  #                 family, alias_method, `n` as a name to install)
  #   variable      names an instance, class or constant variable, never a method
  #   conversion    returns a Symbol and looks nothing up (String#to_sym, OP_INTERN); the Symbol reaches a lookup only
  #                 as a LOOKUP_SENDS argument, which is a literal
  #   phantom       respond_to? (RESPOND_TO_PHANTOM answers it for the methods the build leaves out)
  #   introspection method_defined? and its relatives: SYMBOL_USES refuses a program that calls them
  #   comparison    compares the name with a call frame's
  #   error         names the method in an exception
  #   helper        the conversion itself; every caller is a function listed here
  AUDITED = {
    'src/vm.c' => { 'send_method' => :lookup, 'mrb_vm_exec' => :conversion },
    'src/etc.c' => { 'mrb_obj_to_sym' => :helper },
    'src/symbol.c' => { 'mrb_intern_str' => :helper },
    'src/string.c' => { 'mrb_str_intern' => :conversion },
    'src/kernel.c' => { 'mrb_obj_method_recursive_p' => :comparison, 'mrb_obj_remove_instance_variable' => :variable,
                        'obj_respond_to' => :phantom },
    'src/class.c' => { 'mrb_mod_alias' => :definition, 'mrb_mod_const_defined' => :variable, 'mrb_mod_const_set' => :variable,
                       'mrb_mod_remove_const' => :variable, 'mrb_mod_const_missing' => :error,
                       'mrb_mod_method_defined' => :introspection, 'define_method_m' => :lookup,
                       'mrb_mod_undef' => :lookup, 'mrb_obj_missing' => :error, 'attr_reader' => :definition,
                       'attr_writer' => :definition, 'mod_attr_define' => :definition, 'get_args_v' => :helper },
    'mrbgems/mruby-metaprog/src/metaprog.c' => { 'mrb_obj_ivar_defined' => :variable, 'mrb_obj_ivar_get' => :variable,
                                                'mrb_obj_ivar_set' => :variable, 'mrb_mod_remove_cvar' => :variable,
                                                'mrb_mod_cvar_defined' => :variable, 'mrb_mod_cvar_get' => :variable,
                                                'mrb_mod_cvar_set' => :variable, 'mrb_mod_remove_method' => :lookup }
  }.freeze

  module_function

  # "relative/path:function:kind" of every conversion in the native sources under `root` (the world root), sorted.
  def inventory(paths, root)
    third = "#{File.expand_path(root)}/3rd/mruby/"
    base = "#{File.expand_path(root)}/"
    out = Set.new
    paths.each do |path|
      next if path.end_with?('/presym/scanning.h')

      text = File.read(path, encoding: 'BINARY').force_encoding(Encoding::UTF_8).scrub
      text = text.gsub(COMMENTS) { |m| m.gsub(/[^\n]/, ' ') }
      aliases = text.scan(ALIAS_MACRO).flatten
      names = (CONVERTERS + aliases).uniq
      call = /\b(?:#{names.join('|')})\s*\(/
      rel = path.start_with?(third) ? path.delete_prefix(third) : path.delete_prefix(base)
      func = nil
      text.each_line do |line|
        func = Regexp.last_match(1) if line.match?(/\A\S/) && !line.match?(/;\s*\z/) && !line.start_with?('#') && line =~ FUNCTION_START
        next if line.match?(/\A\s*(?:MRB_API\b|#\s*define\b)/) || line.match?(/\A(?:static\s+)?mrb_(?:sym|value)\s*\z/)

        out << "#{rel}:#{func}:to_sym" if line.match?(call) && !definition_line?(line, names)
        out << "#{rel}:#{func}:to_sym" if line.match?(RAW_INTERN) && line.match?(STRING_BYTES)
        out << "#{rel}:#{func}:name_arg" if (m = line.match(GET_ARGS)) && m[1].include?('n')
      end
    end
    out.to_a.sort
  end

  # `mrb_sym name(...)` / `mrb_obj_to_sym(mrb_state *mrb, mrb_value name)` that defines the converter itself.
  def definition_line?(line, names)
    line.match?(/\A(?:\w+\s+)*\**(?:#{names.join('|')})\s*\(\s*mrb_state/)
  end

  # Whether every conversion of the natives is a function the audit lists (with any of its kinds).
  def audited?(paths, root)
    known = AUDITED.flat_map { |file, fns| fns.keys.map { |fn| [file, fn] } }.to_set
    inventory(paths, root).all? do |entry|
      file, fn, = entry.split(':', 3)
      known.include?([file, fn])
    end
  end

  # [unknown entries, audited functions without a conversion] for the check and the failure message.
  def differences(paths, root)
    found = inventory(paths, root)
    seen = found.to_set { |e| e.split(':', 3).first(2) }
    known = AUDITED.flat_map { |file, fns| fns.keys.map { |fn| [file, fn] } }.to_set
    [found.reject { |e| known.include?(e.split(':', 3).first(2)) }, (known - seen).map { |file, fn| "#{file}:#{fn}" }.sort]
  end
end
