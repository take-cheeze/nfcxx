# frozen_string_literal: true

# STATIC_CONSTANTS (BC2CPP_STATIC_CONSTANTS=0 turns it off): the constant caches and lookups of const_site_cache.rb
# as ROM rows read by one shared function each, instead of a generated fill function per cached (scope, name), a
# lookup function per lexical scope and a fill per GETMCNST name. A row holds what the generated function spelled: the
# lexical scope's segments, the name and the store test (class/module, any value, or CONST_BINDING_CACHE's
# path list), so a fill runs the same lookup in the same order and stores under the same condition; only where the
# text lives changes. Strings are interned at the (rare) fill, so the rows need no compile-time symbols.
class CodeGen
  STATIC_CONST_CLASS_TEST = 0xffff
  STATIC_CONST_VALUE_TEST = 0xfffe
  # CONST_BINDING_DROP rows: the test is this plus the name's slot in the per-VM table; path lists stay below it.
  STATIC_CONST_DROP_TEST = 0x8000
  STATIC_CONST_DROP_LIMIT = STATIC_CONST_VALUE_TEST - STATIC_CONST_DROP_TEST

  def static_constants?
    ENV['BC2CPP_STATIC_CONSTANTS'] != '0'
  end

  # CONST_SLOT_NIL_EMPTY (BC2CPP_CONST_SLOT_NIL_EMPTY=0 keeps a have-flag array per slot table): a constant slot is empty
  # while it holds nil. A zero-initialised mrb_value is nil in every boxing mode (word: MRB_Qnil is 0; NaN: nil is u == 0;
  # unboxed: {0, MRB_TT_FALSE}, MRB_TT_FALSE being 0), so a static slot starts empty with no reset having run, and a
  # stored nil reads as empty again: a nil-valued constant is looked up on every read, which finds the same nil.
  def const_slot_nil_empty?
    ENV['BC2CPP_CONST_SLOT_NIL_EMPTY'] != '0'
  end

  # The zero-is-nil premise as far as a boxing mode states it at compile time (NaN boxing's nil is a macro:
  # const_bindings_check runs a zero slot in each mode).
  CONST_SLOT_NIL_ASSERTS = "#if defined(MRB_WORD_BOXING)\nstatic_assert(MRB_Qnil == 0, \"CONST_SLOT_NIL_EMPTY\");\n" \
                           "#elif !defined(MRB_NAN_BOXING)\nstatic_assert(MRB_TT_FALSE == 0, \"CONST_SLOT_NIL_EMPTY\");\n#endif\n"

  # The declaration of a slot table's have flags, or the assertions when nil marks the empty slot.
  def const_slot_have_decl(flags, count)
    const_slot_nil_empty? ? CONST_SLOT_NIL_ASSERTS : "static bool #{flags}[#{count}] = {};\n"
  end

  # The reset of a slot table: every slot empty again.
  def const_slot_reset(slots, flags)
    const_slot_nil_empty? ? "  for (mrb_value& s : #{slots}) s = mrb_nil_value();\n" : "  for (bool& h : #{flags}) h = false;\n"
  end

  # Whether slot +at+ holds a value.
  def const_slot_full(slots, flags, at)
    const_slot_nil_empty? ? "!mrb_nil_p(#{slots}[#{at}])" : "#{flags}[#{at}]"
  end

  # The store of +value+ into slot +at+ (indented by +pad+).
  def const_slot_store(slots, flags, at, value, pad)
    out = "#{pad}#{slots}[#{at}] = #{value};\n"
    out << "#{pad}#{flags}[#{at}] = true;\n" unless const_slot_nil_empty?
    out
  end

  # One NUL-terminated pool for every string the rows name; the offset of +text+.
  def static_const_string(text)
    @static_const_pool ||= { text: +'', at: {} }
    pool = @static_const_pool
    pool[:at][text] ||= begin
      at = pool[:text].bytesize
      pool[:text] << text << "\0"
      raise 'STATIC_CONSTANTS: the string pool outgrew a uint16_t offset' if pool[:text].bytesize > 0xfff0

      at
    end
  end

  # The offset of +owner_path+'s row in bc2cpp_const_scopes: its segment count, then each segment's string.
  # ['Object'] is the top level (no segments: the lookup is mrb_const_get on Object, as const_lookup_block's).
  def static_const_scope(owner_path)
    @static_const_scopes ||= { words: [], at: {} }
    table = @static_const_scopes
    table[:at][owner_path] ||= begin
      segs = owner_path == ['Object'] ? [] : owner_path
      at = table[:words].size
      table[:words] << segs.size
      segs.each { |seg| table[:words] << static_const_string(seg) }
      raise 'STATIC_CONSTANTS: the scope table outgrew a uint16_t offset' if table[:words].size > 0xfff0

      at
    end
  end

  def static_const_words(words)
    words.each_slice(16).map { |row| "  #{row.join(', ')},\n" }.join
  end

  # One literal piece per string: an identifier or `A::B` path, so the NUL ending a piece never runs into the next.
  def static_const_pool_text
    pool = (@static_const_pool || { text: +'' })[:text]
    pieces = pool.split("\0", -1)[0...-1]
    pieces = [''] if pieces.empty?
    pieces.map { |text| "  \"#{text}\\0\"\n" }.join
  end

  # The scope helpers: each bc2cpp_const_scope_<N> is a call of bc2cpp_const_lookup with its scope row. Printed before
  # the site cache, so it also carries the pool and the scope table the cache rows (registered first) point into.
  def emit_const_scope_helpers_table(used)
    called = used && helper_calls(used, 'bc2cpp_const_scope_')
    helpers = (@const_scope_helpers || {}).reject { |_, slot| called && !called.include?(slot[:index]) }
    helpers.each_key { |owner_path| static_const_scope(owner_path) }
    scopes = @static_const_scopes
    out = +"// STATIC_CONSTANTS -- see tools/bc2cpp/codegen_const_tables.rb.\n"
    return out unless scopes || @static_const_pool

    depth = [(scopes ? scope_depths(scopes[:at].keys).max : 0).to_i, 1].max
    out << "static const char bc2cpp_const_strings[] =\n#{static_const_pool_text};\n"
    words = scopes ? scopes[:words] : [0]
    out << "static const uint16_t bc2cpp_const_scopes[] = {\n#{static_const_words(words)}};\n"
    # The order of the generated scope helper (see emit_const_scope_helpers): resolve every segment from Object first,
    # then each own table innermost first, Object's, and the innermost scope's ancestors.
    out << "[[maybe_unused]] [[gnu::noinline]] static mrb_value bc2cpp_const_lookup(mrb_state* M, int at, mrb_sym name) {\n" \
           "  const uint16_t* row = bc2cpp_const_scopes + at;\n" \
           "  int n = *row++;\n" \
           "  if (n == 0) return mrb_const_get(M, mrb_obj_value(M->object_class), name);\n"
    if @const_lookup_helper_used
      out << "  mrb_value scope[#{depth}];\n" \
             "  mrb_value current = mrb_obj_value(M->object_class);\n" \
             "  for (int i = 0; i < n; ++i) current = scope[i] = mrb_const_get(M, current, mrb_intern_cstr(M, bc2cpp_const_strings + row[i]));\n" \
             "  mrb_value result;\n" \
             "  for (int i = n - 1; i >= 0; --i) if (bc2cpp_const_own(M, scope[i], name, &result)) return result;\n" \
             "  if (bc2cpp_const_own(M, mrb_obj_value(M->object_class), name, &result)) return result;\n" \
             "  return bc2cpp_const_inherited(M, scope[n - 1], name);\n"
    else
      out << "  return mrb_nil_value();\n"
    end
    out << "}\n"
    helpers.each do |owner_path, slot|
      out << "static inline mrb_value bc2cpp_const_scope_#{slot[:index]}(mrb_state* M, mrb_sym name) {\n" \
             "  return bc2cpp_const_lookup(M, #{static_const_scope(owner_path)}, name);\n}\n"
    end
    out
  end

  def scope_depths(paths)
    paths.map { |path| path == ['Object'] ? 0 : path.size }
  end

  # The site cache as rows: { scope row, name, test }, one per helper the printed code calls, numbered densely (the
  # slots too). A test is CLASS (store a class/module), VALUE (store anything) or the offset of a CONST_BINDING_CACHE
  # list in bc2cpp_cconst_tests: a count, then the binding paths of the name, each a bc2cpp_const_path_has of the
  # name, then the scope's own path (bc2cpp_const_scope_has), the generated fill's tests in its order.
  def emit_const_site_cache_table(used)
    called = used && helper_calls(used, 'bc2cpp_cconst_')
    live = (@const_site_cache || {}).values.select { |slot| !called || called.include?(slot[:index]) }
                                   .sort_by { |slot| slot[:index] }
    member_live = (@const_member_sites || []).each_with_index.reject { |_, i| used && !helper_calls(used, 'bc2cpp_mcnst_').include?(i) }
    count = [live.size, 1].max
    members = [member_live.size, 1].max
    out = +"// CONST_SITE_CACHE -- see tools/bc2cpp/const_site_cache.rb; the rows are STATIC_CONSTANTS'.\n"
    out << "static mrb_state* bc2cpp_cconst_state = nullptr;\n"
    out << "static mrb_value bc2cpp_cconst_slots[#{count}];\n"
    out << const_slot_have_decl('bc2cpp_cconst_have', count)
    out << "static struct RClass* bc2cpp_mcnst_from[#{members}];\n"
    out << "static mrb_value bc2cpp_mcnst_slots[#{members}];\n"
    drop_reads = const_drop_live(@const_drop_reads, used, 'bc2cpp_cdef_mget_')
    drop_defs = const_drop_live(@const_drop_defs, used, 'bc2cpp_cdef_set_')
    out << "static mrb_value bc2cpp_cdef_mslots[#{[drop_reads.size, 1].max}];\n"
    out << "static bool bc2cpp_cdef_mhave[#{[drop_reads.size, 1].max}] = {};\n" unless const_slot_nil_empty?
    out << "static void bc2cpp_reset_const_site_cache() {\n" \
           "  bc2cpp_cconst_state = nullptr;\n" \
           "#{const_slot_reset('bc2cpp_cconst_slots', 'bc2cpp_cconst_have')}" \
           "  for (struct RClass*& f : bc2cpp_mcnst_from) f = nullptr;\n" \
           "#{const_slot_reset('bc2cpp_cdef_mslots', 'bc2cpp_cdef_mhave')}" \
           "}\n"
    out << vm_cache_bind('bc2cpp_cconst_bind', 'bc2cpp_cconst_state', 'CONST_SITE_CACHE')
    dropped = live.any? { |slot| slot[:drop] }
    out << emit_const_drop_table(drop_defs, drop_reads) if dropped || @const_drop_put || !drop_defs.empty? || !drop_reads.empty?
    tests = [0]
    lists = {}
    rows = live.map do |slot|
      test = if slot[:drop]
               raise 'CONST_BINDING_DROP: the per-VM table outgrew a row test' if slot[:drop] >= STATIC_CONST_DROP_LIMIT

               STATIC_CONST_DROP_TEST + slot[:drop]
             elsif slot[:paths]
               lists[slot[:paths]] ||= begin
                 at = tests.size
                 tests << slot[:paths].size
                 slot[:paths].each { |path| tests << static_const_string(path) }
                 at
               end
             elsif slot[:value]
               STATIC_CONST_VALUE_TEST
             else
               STATIC_CONST_CLASS_TEST
             end
      raise 'STATIC_CONSTANTS: the test table outgrew a uint16_t offset' if tests.size >= STATIC_CONST_DROP_TEST

      "{#{static_const_scope(slot[:scope])}, #{static_const_string(slot[:name])}, #{test}},"
    end
    unless live.empty?
      paths = live.any? { |slot| slot[:paths] }
      out << emit_const_path_test if paths
      out << "struct bc2cpp_cconst_row { uint16_t scope, name, test; };\n"
      out << "static const bc2cpp_cconst_row bc2cpp_cconst_rows[] = {\n#{rows.map { |r| "  #{r}\n" }.join}};\n"
      if paths
        out << "static const uint16_t bc2cpp_cconst_tests[] = {\n#{static_const_words(tests)}};\n"
        # CONST_BINDING_CACHE's scope test: the lexical scope's path exists, each segment in its outer's own table.
        out << "static bool bc2cpp_const_scope_has(mrb_state* M, int at) {\n" \
               "  const uint16_t* row = bc2cpp_const_scopes + at;\n" \
               "  int n = *row++;\n" \
               "  mrb_value scope = mrb_obj_value(M->object_class);\n" \
               "  for (int i = 0; i < n; ++i) {\n" \
               "    if (i > 0 && !mrb_class_p(scope) && !mrb_module_p(scope)) return false;\n" \
               "    mrb_sym seg = mrb_intern_cstr(M, bc2cpp_const_strings + row[i]);\n" \
               "    if (!mrb_iv_defined(M, scope, seg)) return false;\n" \
               "    scope = mrb_iv_get(M, scope, seg);\n" \
               "  }\n" \
               "  return true;\n" \
               "}\n"
      end
      path_test = if paths
                    "    const uint16_t* t = bc2cpp_cconst_tests + row.test;\n" \
                    "    keep = true;\n" \
                    "    for (int n = *t++; keep && n > 0; --n) keep = bc2cpp_const_path_has(M, bc2cpp_const_strings + *t++, name);\n" \
                    "    keep = keep && bc2cpp_const_scope_has(M, row.scope);\n"
                  else
                    "    keep = false;\n"
                  end
      # CONST_BINDING_DROP: a defined constant is the value the lookup would find (ConstBindingDrop's read_keys
      # condition); an undefined one runs the lookup, which raises as before, and stores nothing.
      drop_fill = if dropped
                    "  if (row.test >= #{STATIC_CONST_DROP_TEST} && row.test < #{STATIC_CONST_VALUE_TEST}) {\n" \
                      "    mrb_value v;\n" \
                      "    if (!bc2cpp_cdef_value(M, row.test - #{STATIC_CONST_DROP_TEST}, &v)) return bc2cpp_const_lookup(M, row.scope, name);\n" \
                      "#{const_slot_store('bc2cpp_cconst_slots', 'bc2cpp_cconst_have', 'i', 'v', '    ')}" \
                      "    return v;\n" \
                      "  }\n"
                  else
                    ''
                  end
      out << "[[gnu::noinline]] static mrb_value bc2cpp_cconst_fill(mrb_state* M, int i) {\n" \
             "  bc2cpp_cconst_bind(M);\n" \
             "  const bc2cpp_cconst_row& row = bc2cpp_cconst_rows[i];\n" \
             "  mrb_sym name = mrb_intern_cstr(M, bc2cpp_const_strings + row.name);\n" \
             "#{drop_fill}" \
             "  mrb_value r0 = bc2cpp_const_lookup(M, row.scope, name);\n" \
             "  bool keep;\n" \
             "  if (row.test == #{STATIC_CONST_CLASS_TEST}) {\n" \
             "    keep = mrb_type(r0) == MRB_TT_CLASS || mrb_type(r0) == MRB_TT_MODULE;\n" \
             "  } else if (row.test == #{STATIC_CONST_VALUE_TEST}) {\n" \
             "    keep = true;\n" \
             "  } else {\n#{path_test}" \
             "  }\n" \
             "  if (keep) {\n" \
             "#{const_slot_store('bc2cpp_cconst_slots', 'bc2cpp_cconst_have', 'i', 'r0', '    ')}" \
             "  }\n" \
             "  return r0;\n" \
             "}\n"
      out << "static inline mrb_value bc2cpp_cconst_get(mrb_state* M, int i) {\n" \
             "  return #{const_slot_full('bc2cpp_cconst_slots', 'bc2cpp_cconst_have', 'i')} ? bc2cpp_cconst_slots[i] : bc2cpp_cconst_fill(M, i);\n" \
             "}\n"
      live.each_with_index do |slot, i|
        out << "static inline mrb_value bc2cpp_cconst_#{slot[:index]}(mrb_state* M) { return bc2cpp_cconst_get(M, #{i}); }\n"
      end
    end
    out << emit_const_member_cache_table(member_live)
    out
  end

  # The GETMCNST caches, one row (its name) per helper the printed code calls, numbered densely.
  def emit_const_member_cache_table(member_live)
    return +'' if member_live.empty?

    names = member_live.map { |name, _| static_const_string(name) }
    out = +"static const uint16_t bc2cpp_mcnst_names[] = {\n#{static_const_words(names)}};\n"
    out << "[[gnu::noinline]] static mrb_value bc2cpp_mcnst_fill(mrb_state* M, int i, mrb_value recv) {\n" \
           "  bc2cpp_cconst_bind(M);\n" \
           "  mrb_sym name = mrb_intern_cstr(M, bc2cpp_const_strings + bc2cpp_mcnst_names[i]);\n" \
           "  mrb_value r0 = mrb_const_get(M, recv, name);\n" \
           "  if ((mrb_class_p(recv) || mrb_module_p(recv)) && mrb_const_defined_at(M, recv, name)) {\n" \
           "    bc2cpp_mcnst_from[i] = mrb_class_ptr(recv);\n" \
           "    bc2cpp_mcnst_slots[i] = r0;\n" \
           "  }\n" \
           "  return r0;\n" \
           "}\n" \
           "static inline mrb_value bc2cpp_mcnst_get(mrb_state* M, int i, mrb_value recv) {\n" \
           "  if ((mrb_class_p(recv) || mrb_module_p(recv)) && mrb_class_ptr(recv) == bc2cpp_mcnst_from[i]) return bc2cpp_mcnst_slots[i];\n" \
           "  return bc2cpp_mcnst_fill(M, i, recv);\n" \
           "}\n"
    member_live.each_with_index do |(_, index), i|
      out << "static inline mrb_value bc2cpp_mcnst_#{index}(mrb_state* M, mrb_value recv) { return bc2cpp_mcnst_get(M, #{i}, recv); }\n"
    end
    out
  end

  # CONST_BINDING_DROP (const_binding_drop.rb) -----------------------------------------------------------------------

  def const_drop?(name)
    !!self.class.const_binding_drop&.drop?(name)
  end

  def const_drop_index(name)
    self.class.const_binding_drop.index(name)
  end

  # The write of the one SETCONST of +name+, in the class body of +owner+: a PLAIN_WRITE (ConstBindingDrop.plain_write?)
  # is the table store alone, any other the bc2cpp_cdef_set_<N> call of its row.
  def const_drop_set(name, owner, value)
    if self.class.const_binding_drop.names.fetch(name)[:plain]
      @const_drop_put = true
      return "  bc2cpp_cdef_put(M, #{const_drop_index(name)}, #{value});\n"
    end

    @const_drop_defs ||= []
    n = @const_drop_defs.size
    fn = owner_class_fn_name(owner)
    @const_drop_defs << { name: name, k: const_drop_index(name), owner: owner }
    args = class_test_fuse? ? '' : ", #{fn}(M)"
    "  bc2cpp_cdef_set_#{n}(M#{args}, #{value});\n"
  end

  # The bc2cpp_cdef_mget_<N> helper index of a GETMCNST of +name+; the sites of one name share it.
  def const_drop_read(name)
    @const_drop_reads ||= []
    @const_drop_read_index ||= {}
    @const_drop_read_index[name] ||= (@const_drop_reads << { name: name, k: const_drop_index(name) }).size - 1
  end

  # [[helper index, row], ...] of the rows +used+ calls (all of them without +used+), numbered densely by position.
  def const_drop_live(rows, used, prefix)
    called = used && helper_calls(used, prefix)
    (rows || []).each_with_index.reject { |_, i| called && !called.include?(i) }.map { |row, i| [i, row] }
  end

  # The per-VM table: an Array in a global no Ruby can spell (hidden from ObjectSpace, as mrb_gc_register's root
  # table is), slot 0 the world's fingerprint, slot k + 1 constant k (nil while undefined, undef for a nil value).
  # The table roots every value and is made at its full size; the fingerprint stops a gem of another world reading the
  # wrong slot.
  def emit_const_drop_table(defs, reads)
    drop = self.class.const_binding_drop
    world = drop.fingerprint
    out = +"// CONST_BINDING_DROP -- see tools/bc2cpp/const_binding_drop.rb.\n"
    out << "[[gnu::noinline]] static mrb_value bc2cpp_cdef_table(mrb_state* M, bool make) {\n" \
           "  mrb_sym key = mrb_intern_lit(M, \"__bc2cpp_cdef\");\n" \
           "  mrb_value t = mrb_gv_get(M, key);\n" \
           "  if (mrb_array_p(t)) {\n" \
           "    if (RARRAY_LEN(t) == 0 || !mrb_fixnum_p(RARRAY_PTR(t)[0]) || mrb_fixnum(RARRAY_PTR(t)[0]) != #{world}) {\n" \
           "      mrb_bug(M, \"bc2cpp CONST_BINDING_DROP: the constant table belongs to another world\");\n" \
           "    }\n" \
           "    return t;\n" \
           "  }\n" \
           "  if (!make) return mrb_nil_value();\n" \
           "  t = mrb_ary_new_capa(M, #{drop.names.size + 1});\n" \
           "  mrb_obj_ptr(t)->c = NULL;\n" \
           "  mrb_ary_push(M, t, mrb_fixnum_value(#{world}));\n" \
           "  mrb_gv_set(M, key, t);\n" \
           "  return t;\n" \
           "}\n"
    out << "[[maybe_unused]] static bool bc2cpp_cdef_value(mrb_state* M, int k, mrb_value* out) {\n" \
           "  mrb_value t = bc2cpp_cdef_table(M, false);\n" \
           "  if (!mrb_array_p(t) || k + 1 >= RARRAY_LEN(t)) return false;\n" \
           "  mrb_value v = RARRAY_PTR(t)[k + 1];\n" \
           "  if (mrb_nil_p(v)) return false;\n" \
           "  *out = mrb_undef_p(v) ? mrb_nil_value() : v;\n" \
           "  return true;\n" \
           "}\n"
    out << "[[maybe_unused]] [[gnu::noinline]] static void bc2cpp_cdef_put(mrb_state* M, int k, mrb_value v) {\n" \
           "  bc2cpp_cconst_bind(M);\n" \
           "  mrb_ary_set(M, bc2cpp_cdef_table(M, true), k + 1, mrb_nil_p(v) ? mrb_undef_value() : v);\n" \
           "}\n"
    unless defs.empty?
      fuse = class_test_fuse?
      rows = defs.map do |_, row|
        slot = fuse ? @owner_class_cache.fetch(row[:owner])[:index] : 0
        "  {#{row[:k]}, #{slot}, #{static_const_string(row[:name])}},\n"
      end
      out << "struct bc2cpp_cdef_def { uint16_t k, owner, name; };\n"
      out << "static const bc2cpp_cdef_def bc2cpp_cdef_defs[] = {\n#{rows.join}};\n"
      # mrb_const_set's effects: FrozenError for a frozen owner (mrb_obj_iv_set), and a class or module value is
      # still bound, which names it. The const_added hook is ruled out (ConstDefElide::REFLECTION).
      owner = fuse ? '' : ', struct RClass* c'
      out << "[[gnu::noinline]] static void bc2cpp_cdef_set(mrb_state* M, int i#{owner}, mrb_value v) {\n" \
             "  bc2cpp_cconst_bind(M);\n" \
             "  const bc2cpp_cdef_def& d = bc2cpp_cdef_defs[i];\n" \
             "#{fuse ? "  struct RClass* c = bc2cpp_owner_class_at(M, d.owner);\n" : ''}" \
             "  mrb_check_frozen(M, c);\n" \
             "  if (mrb_type(v) == MRB_TT_CLASS || mrb_type(v) == MRB_TT_MODULE) {\n" \
             "    mrb_const_set(M, mrb_obj_value(c), mrb_intern_cstr(M, bc2cpp_const_strings + d.name), v);\n" \
             "  }\n" \
             "  bc2cpp_cdef_put(M, d.k, v);\n" \
             "}\n"
      defs.each_with_index do |(index, _), i|
        out << "[[gnu::always_inline]] static inline void bc2cpp_cdef_set_#{index}(mrb_state* M#{owner}, mrb_value v) " \
               "{ bc2cpp_cdef_set(M, #{i}#{fuse ? '' : ', c'}, v); }\n"
      end
    end
    unless reads.empty?
      rows = reads.map { |_, row| "  {#{row[:k]}, #{static_const_string(row[:name])}},\n" }
      out << "struct bc2cpp_cdef_read { uint16_t k, name; };\n"
      out << "static const bc2cpp_cdef_read bc2cpp_cdef_reads[] = {\n#{rows.join}};\n"
      out << "[[gnu::noinline]] static mrb_value bc2cpp_cdef_mget(mrb_state* M, int i, mrb_value recv) {\n" \
             "  if (#{const_slot_full('bc2cpp_cdef_mslots', 'bc2cpp_cdef_mhave', 'i')}) return bc2cpp_cdef_mslots[i];\n" \
             "  bc2cpp_cconst_bind(M);\n" \
             "  mrb_value v;\n" \
             "  if (bc2cpp_cdef_value(M, bc2cpp_cdef_reads[i].k, &v)) {\n" \
             "#{const_slot_store('bc2cpp_cdef_mslots', 'bc2cpp_cdef_mhave', 'i', 'v', '    ')}" \
             "    return v;\n" \
             "  }\n" \
             "  return mrb_const_get(M, recv, mrb_intern_cstr(M, bc2cpp_const_strings + bc2cpp_cdef_reads[i].name));\n" \
             "}\n"
      reads.each_with_index do |(index, _), i|
        out << "[[gnu::always_inline]] static inline mrb_value bc2cpp_cdef_mget_#{index}(mrb_state* M, mrb_value recv) " \
               "{ return bc2cpp_cdef_mget(M, #{i}, recv); }\n"
      end
    end
    out
  end
end
