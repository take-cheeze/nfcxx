# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'native_rom_extract'

# Direct-call candidates for mruby core's native methods, from the clang AST (ADR 0257 / 0263).
#
#   clang -fsyntax-only -Xclang -ast-dump=json <flags> 3rd/mruby/src/array.c |
#     ruby tools/bc2cpp/native_core_candidates.rb 3rd/mruby/src/array.c
#
# Each `MRB_MT_ENTRY(fn, SYM, ARGS)` of a `static const mrb_mt_entry NAME_rom_entries[]` table names one C function.
# A candidate is an entry whose function this translation unit defines and whose body is frame-free: it reaches no
# frame reader (mrb_get_args, mrb_get_argc, mrb_block_given_p, mrb_yield, ...), directly or through a function this
# unit defines, and it calls no function outside the unit that takes an mrb_state unless that function is in
# MRB_API_ALLOW. Anything else is not a candidate and stays by-name: the generator never guesses.
#
# Output: JSON, one object per entry: {table, owner, name, function, aspec, defined, frame_free}.
module NativeCoreCandidates
  FRAME_READERS = %w[mrb_get_args mrb_get_argc mrb_get_argv mrb_get_arg1 mrb_block_given_p mrb_get_mid mrb_yield
                     mrb_yield_argv mrb_yield_with_class mrb_yield_cont mrb_proc_cfunc_env_get mrb_call_super
                     mrb_super_class mrb_get_backtrace mrb_vm_ci_target_class mrb_vm_ci_env mrb_proc_env_get
                     mrb_obj_call_init].freeze

  # The class each core ROM table defines methods on. A table absent here has no owner and yields no candidate.
  OWNERS = {
    'array' => 'Array', 'string' => 'String', 'integer' => 'Integer', 'float' => 'Float', 'numeric' => 'Numeric',
    'hash' => 'Hash', 'range' => 'Range', 'symbol' => 'Symbol', 'proc' => 'Proc', 'kernel' => 'Kernel',
    'comparable' => 'Comparable', 'class' => 'Class', 'module' => 'Module', 'object' => 'Object',
    'nil' => 'NilClass', 'true' => 'TrueClass', 'false' => 'FalseClass'
  }.freeze

  OPSYM = {
    'add' => '+', 'sub' => '-', 'mul' => '*', 'div' => '/', 'mod' => '%', 'lt' => '<', 'le' => '<=', 'gt' => '>',
    'ge' => '>=', 'eq' => '==', 'eqq' => '===', 'cmp' => '<=>', 'lshift' => '<<', 'rshift' => '>>', 'aref' => '[]',
    'aset' => '[]=', 'and' => '&', 'or' => '|', 'xor' => '^', 'not' => '!', 'neq' => '!=', 'pow' => '**',
    'uplus' => '+@', 'uminus' => '-@', 'neg' => '-@', 'mul_nr' => '*'
  }.freeze

  # mruby APIs that take an mrb_state and do not depend on the calling frame: the list scripts/native/binding_facts.py
  # reviews (its MRB_API_ALLOW). Any other function taking an mrb_state, defined outside this unit, makes a body
  # frame-unknown, so the body is not a candidate.
  MRB_API_ALLOW = %w[
    mrb_ary_new mrb_ary_new_capa mrb_ary_new_from_values mrb_ary_push mrb_ary_ref mrb_ary_entry
    mrb_ary_set mrb_ary_shift mrb_ary_pop mrb_ary_clear mrb_ary_concat mrb_boxing_int_value
    mrb_word_boxing_float_value mrb_word_boxing_cptr_value mrb_float_value mrb_int_value mrb_fixnum_value mrb_class_get
    mrb_class_get_under mrb_module_get mrb_module_get_under mrb_const_defined mrb_const_get mrb_const_set
    mrb_data_get_ptr mrb_data_check_get_ptr mrb_data_object_alloc mrb_data_init mrb_ensure_float_type mrb_ensure_int_type
    mrb_ensure_string_type mrb_check_type mrb_format mrb_free mrb_malloc mrb_realloc
    mrb_calloc mrb_funcall mrb_funcall_argv mrb_funcall_id mrb_gc_type_counts mrb_gc_arena_save
    mrb_gc_arena_restore mrb_gc_protect mrb_hash_get mrb_hash_set mrb_hash_keys mrb_hash_new
    mrb_hash_size mrb_hash_key_p mrb_hash_delete_key mrb_intern_cstr mrb_intern_static mrb_intern
    mrb_intern_str mrb_sym_name mrb_sym_str mrb_iv_get mrb_iv_set mrb_iv_defined
    mrb_obj_as_string mrb_obj_class mrb_obj_classname mrb_obj_equal mrb_obj_is_kind_of mrb_obj_new
    mrb_obj_value mrb_raise mrb_raisef mrb_exc_get_id mrb_str_new mrb_str_new_cstr
    mrb_str_new_static mrb_str_to_cstr mrb_string_value_cstr mrb_string_value_len mrb_str_cat mrb_str_cat_cstr
    mrb_str_cat_str mrb_str_append mrb_debug_get_position
  ].to_set.freeze

  module_function

  # [table, name, function, aspec] for every MRB_MT_ENTRY of every ROM table in +source+, in table order.
  def entries(source)
    text = File.read(source)
    text.scan(/static const mrb_mt_entry (\w+)_rom_entries\[\] = \{(.*?)\n\};/m).flat_map do |table, body|
      split_entries(body).map do |args|
        fn, sym, aspec = split_args(args)
        next unless fn && sym

        [table, symbol_name(sym), fn, aspec]
      end.compact
    end
  end

  # The text inside each MRB_MT_ENTRY( ... ), balanced over nested parentheses.
  def split_entries(body)
    out = []
    pos = 0
    while (start = body.index('MRB_MT_ENTRY(', pos))
      i = start + 'MRB_MT_ENTRY('.length
      depth = 1
      while depth.positive? && i < body.length
        depth += 1 if body[i] == '('
        depth -= 1 if body[i] == ')'
        i += 1
      end
      out << body[(start + 'MRB_MT_ENTRY('.length)...(i - 1)]
      pos = i
    end
    out
  end

  # Top-level comma split of `fn, SYM(name), ARGS`.
  def split_args(args)
    parts = []
    depth = 0
    cur = +''
    args.each_char do |c|
      if c == ',' && depth.zero?
        parts << cur.strip
        cur = +''
        next
      end
      depth += 1 if c == '('
      depth -= 1 if c == ')'
      cur << c
    end
    parts << cur.strip
    parts
  end

  # MRB_SYM(name), MRB_SYM_Q(name) and MRB_OPSYM(op) spelled as the Ruby method name.
  def symbol_name(sym)
    case sym
    when /\AMRB_OPSYM\((\w+)\)\z/ then OPSYM.fetch(Regexp.last_match(1), nil)
    when /\AMRB_SYM_Q\((\w+)\)\z/ then "#{Regexp.last_match(1)}?"
    when /\AMRB_SYM_E\((\w+)\)\z/ then "#{Regexp.last_match(1)}="
    when /\AMRB_SYM\((\w+)\)\z/ then Regexp.last_match(1)
    end
  end

  # Functions this unit defines with a body, by name -> frame-free? A body is frame-free when it reaches no frame reader
  # through the unit, and calls no function outside the unit that takes an mrb_state unless that function is reviewed.
  def frame_free(ast)
    bodies = {}
    collect_bodies(ast, bodies)
    unit = bodies.keys.to_set
    direct = bodies.transform_values { |decls| decls.flat_map { |d| referenced_functions(d) }.to_set }
    reads = Set.new(bodies.keys.select { |f| direct[f].any? { |c| FRAME_READERS.include?(c) } })
    reads |= bodies.keys.select { |f| bodies[f].any? { |d| unknown_state_call?(d, unit) } }
    loop do
      grew = false
      bodies.each_key do |f|
        next if reads.include?(f)
        next unless direct[f].any? { |c| reads.include?(c) }

        reads << f
        grew = true
      end
      break unless grew
    end
    bodies.keys.to_h { |f| [f, !reads.include?(f)] }
  end

  def collect_bodies(node, out)
    return unless node.is_a?(Hash)

    if node['kind'] == 'FunctionDecl' && node['name'] && (node['inner'] || []).any? { |c| c['kind'] == 'CompoundStmt' }
      (out[node['name']] ||= []) << node
    end
    (node['inner'] || []).each { |c| collect_bodies(c, out) }
  end

  # The state's frame fields (`mrb->c`, `->ci`, `->root_c`), which binding_facts.py also treats as frame reads.
  FRAME_FIELDS = %w[c ci root_c].freeze

  # A call, inside a body, to a function this unit does not define that takes an mrb_state and is not in MRB_API_ALLOW,
  # or a read of a frame field. Either way the frame use is unknown, so the body is not frame-free.
  def unknown_state_call?(node, unit)
    return false unless node.is_a?(Hash)
    return true if node['kind'] == 'MemberExpr' && FRAME_FIELDS.include?(node['name'])

    ref = node['referencedDecl']
    if ref && ref['kind'] == 'FunctionDecl' && %w[CallExpr DeclRefExpr].include?(node['kind']) && ref['name'] &&
       !unit.include?(ref['name'])
      return true if ref.dig('type', 'qualType').to_s.include?('mrb_state') && !MRB_API_ALLOW.include?(ref['name'])
    end
    (node['inner'] || []).any? { |c| unknown_state_call?(c, unit) }
  end

  # Every name a body calls or refers to as a function: a frame reader it names, or a unit function it calls.
  def referenced_functions(node, out = [])
    return out unless node.is_a?(Hash)

    ref = node['referencedDecl']
    out << ref['name'] if ref && ref['kind'] == 'FunctionDecl' && %w[CallExpr DeclRefExpr].include?(node['kind'])
    (node['inner'] || []).each { |c| referenced_functions(c, out) }
    out
  end

  # Candidate records for the table entries of +source+, from its clang AST +ast+.
  def candidates(source, ast)
    defined = NativeRomExtract.defined_functions(ast)
    free = frame_free(ast)
    entries(source).map do |table, name, fn, aspec|
      owner = OWNERS[table]
      frame = free.fetch(fn, false)
      { 'table' => "#{table}_rom_entries", 'owner' => owner, 'name' => name, 'function' => fn, 'aspec' => aspec,
        'defined' => defined.include?(fn), 'frame_free' => frame && defined.include?(fn) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  source = ARGV.fetch(0) { abort 'usage: native_core_candidates.rb SOURCE.c < clang-ast.json' }
  puts JSON.pretty_generate(NativeCoreCandidates.candidates(source, JSON.parse($stdin.read)))
end
