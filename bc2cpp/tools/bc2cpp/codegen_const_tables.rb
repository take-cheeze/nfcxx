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

  def static_constants?
    ENV['BC2CPP_STATIC_CONSTANTS'] != '0'
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
    out << "static bool bc2cpp_cconst_have[#{count}] = {};\n"
    out << "static struct RClass* bc2cpp_mcnst_from[#{members}];\n"
    out << "static mrb_value bc2cpp_mcnst_slots[#{members}];\n"
    out << "static void bc2cpp_reset_const_site_cache() {\n" \
           "  bc2cpp_cconst_state = nullptr;\n" \
           "  for (bool& h : bc2cpp_cconst_have) h = false;\n" \
           "  for (struct RClass*& f : bc2cpp_mcnst_from) f = nullptr;\n" \
           "}\n"
    out << vm_cache_bind('bc2cpp_cconst_bind', 'bc2cpp_cconst_state', 'CONST_SITE_CACHE')
    tests = [0]
    lists = {}
    rows = live.map do |slot|
      test = if slot[:paths]
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
      raise 'STATIC_CONSTANTS: the test table outgrew a uint16_t offset' if tests.size >= STATIC_CONST_VALUE_TEST

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
      out << "[[gnu::noinline]] static mrb_value bc2cpp_cconst_fill(mrb_state* M, int i) {\n" \
             "  bc2cpp_cconst_bind(M);\n" \
             "  const bc2cpp_cconst_row& row = bc2cpp_cconst_rows[i];\n" \
             "  mrb_sym name = mrb_intern_cstr(M, bc2cpp_const_strings + row.name);\n" \
             "  mrb_value r0 = bc2cpp_const_lookup(M, row.scope, name);\n" \
             "  bool keep;\n" \
             "  if (row.test == #{STATIC_CONST_CLASS_TEST}) {\n" \
             "    keep = mrb_type(r0) == MRB_TT_CLASS || mrb_type(r0) == MRB_TT_MODULE;\n" \
             "  } else if (row.test == #{STATIC_CONST_VALUE_TEST}) {\n" \
             "    keep = true;\n" \
             "  } else {\n#{path_test}" \
             "  }\n" \
             "  if (keep) {\n" \
             "    bc2cpp_cconst_slots[i] = r0;\n" \
             "    bc2cpp_cconst_have[i] = true;\n" \
             "  }\n" \
             "  return r0;\n" \
             "}\n"
      out << "static inline mrb_value bc2cpp_cconst_get(mrb_state* M, int i) {\n" \
             "  return bc2cpp_cconst_have[i] ? bc2cpp_cconst_slots[i] : bc2cpp_cconst_fill(M, i);\n" \
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
end
