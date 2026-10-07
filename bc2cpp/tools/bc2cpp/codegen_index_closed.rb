# frozen_string_literal: true

# CodeGen: INDEX_CLOSED (ADR 0365). The by-name tail of the shared index helpers (bc2cpp_getidx, bc2cpp_getidx0,
# bc2cpp_setidx, ADR 0216) becomes a class-tag switch over the native `[]` / `[]=` bodies plus a proven NoMethodError,
# when CallFacts::Answers says every class that can answer the name is one the helper has an arm for.
#
# The native bodies are static in mruby and read the CALLING frame (mrb_get_args), which a shared helper does not have;
# patches/mruby-expose-index-bodies.patch exports each as a function that takes its arguments. The generator trusts an
# arm only after reading the sources the build compiles: the registration, the wrapper that calls the exported body,
# and, where the arm calls a public function directly (Hash, String), the method body it stands for.
class CodeGen
  INDEX_HELPER_NAMES = { 'getidx' => '[]', 'getidx0' => '[]', 'setidx' => '[]=' }.freeze

  # Per name and native owner. `file`: path below the mruby tree, or a repo path starting `mruby-`. `gem`: the gem that
  # provides the class (nil: mruby core). `mt`: the MRB_MT_ENTRY function (nil: registered by a hand-written
  # mrb_define_method*, counted in opaque_owners). `needs`: text the source must contain, spaces ignored. `test` and
  # `call`/`stmt`: C++ over `recv` and the helper's argument expressions (`%<key>s`, `%<idx>s`, `%<val>s`). A gem's
  # exported function is declared weak (a libmruby without the gem, which the checks link against, still links) and
  # `guard` names the one the test must see linked before it runs.
  INDEX_ARMS = {
    '[]' => {
      'Array' => { file: 'src/array.c', gem: nil, mt: 'mrb_ary_aget', test: 'mrb_array_p(recv)',
                   call: 'mrb_ary_aget1_impl(M, recv, %<key>s)',
                   decl: ['mrb_value mrb_ary_aget1_impl(mrb_state*, mrb_value, mrb_value)'],
                   needs: ['if (mrb_get_argc(mrb) == 1) { return mrb_ary_aget1_impl(mrb, self, mrb_get_arg1(mrb)); }',
                           "mrb_value\nmrb_ary_aget1_impl(mrb_state *mrb, mrb_value self, mrb_value index)\n{"] },
      'Hash' => { file: 'src/hash.c', gem: nil, mt: 'mrb_hash_aget', test: 'mrb_hash_p(recv)',
                  call: 'mrb_hash_get(M, recv, %<key>s)',
                  needs: ['mrb_hash_aget(mrb_state *mrb, mrb_value self) { mrb_value key = mrb_get_arg1(mrb); ' \
                          'return mrb_hash_get(mrb, self, key); }'] },
      'String' => { file: 'src/string.c', gem: nil, mt: 'mrb_str_aref_m', test: 'mrb_string_p(recv)',
                    call: 'mrb_str_aref(M, recv, %<key>s, mrb_undef_value())',
                    needs: ['mrb_str_aref_m(mrb_state *mrb, mrb_value str) { mrb_value a1, a2; ' \
                            'if (mrb_get_args(mrb, "o|o", &a1, &a2) == 1) { a2 = mrb_undef_value(); } ' \
                            'return mrb_str_aref(mrb, str, a1, a2); }'] },
      'Struct' => { file: 'mrbgems/mruby-struct/src/struct.c', gem: 'mruby-struct', mt: 'mrb_struct_aref',
                    test: 'mrb_type(recv) == MRB_TT_STRUCT', call: 'mrb_struct_aref_impl(M, recv, %<key>s)',
                    decl: ['mrb_value mrb_struct_aref_impl(mrb_state*, mrb_value, mrb_value)'],
                    needs: ['mrb_struct_aref(mrb_state *mrb, mrb_value s) { ' \
                            'return mrb_struct_aref_impl(mrb, s, mrb_get_arg1(mrb)); }',
                            "mrb_value\nmrb_struct_aref_impl(mrb_state *mrb, mrb_value s, mrb_value idx)\n{"] },
      'Table' => { file: 'mruby-rgss/src/lib.cxx', gem: 'mruby-rgss', mt: nil, test: 'rgss_table_p(recv)',
                   guard: 'rgss_table_p', call: 'rgss_table_aref_impl(M, recv, mrb_as_int(M, %<key>s), 0, 0)',
                   decl: ['mrb_bool rgss_table_p(mrb_value)',
                          'mrb_value rgss_table_aref_impl(mrb_state*, mrb_value, mrb_int, mrb_int, mrb_int)'],
                   needs: ['mrb_define_method(M, table, "[]", table_get,',
                           'mrb_value table_get(mrb_state* M, V self) { mrb_int x, y = 0, z = 0; ' \
                           'mrb_get_args(M, "i|ii", &x, &y, &z); return table_get_impl(M, self, x, y, z); }',
                           'rgss_table_aref_impl(mrb_state* M, mrb_value self, mrb_int x, mrb_int y, mrb_int z) ' \
                           '{ return table_get_impl(M, self, x, y, z); }'] },
      # `proc[x]` is mrb_funcall(proc, "[]", x) once `[]` is found on Proc (call_proc): mrb_funcall_with_method skips
      # the lookup and nothing else (src/vm.c's funcall_with_block_m).
      'Proc' => { file: 'src/proc.c', gem: nil, mt: nil, test: 'mrb_proc_p(recv)',
                  call: 'mrb_proc_aref_impl(M, recv, 1, &bc2cpp_key)',
                  decl: ['mrb_value mrb_proc_aref_impl(mrb_state*, mrb_value, mrb_int, const mrb_value*)'],
                  needs: ['MRB_METHOD_FROM_PROC(m, &call_proc); mrb_define_method_raw(mrb, pc, MRB_SYM(call), m); ' \
                          'mrb_define_method_raw(mrb, pc, MRB_OPSYM(aref), m);',
                          'mrb_proc_aref_impl(mrb_state *mrb, mrb_value proc, mrb_int argc, const mrb_value *argv) { ' \
                          'mrb_method_t m; MRB_METHOD_FROM_PROC(m, &call_proc); ' \
                          'return mrb_funcall_with_method(mrb, proc, MRB_OPSYM(aref), &m, mrb->proc_class, argc, argv, ' \
                          'mrb_nil_value()); }'],
                  also: { 'src/vm.c' => ['return funcall_with_block_m(mrb, self, mid, argc, argv, blk, NULL, NULL);',
                                         'if (fixed) { m = *fixed; ci->u.target_class = fixed_owner; } else { ' \
                                         'm = mrb_vm_find_method(mrb, ci->u.target_class, &ci->u.target_class, mid); }'] } }
    },
    '[]=' => {
      'Array' => { file: 'src/array.c', gem: nil, mt: 'mrb_ary_aset', test: 'mrb_array_p(recv)',
                   call: 'mrb_ary_aset2_impl(M, recv, %<idx>s, %<val>s)',
                   decl: ['mrb_value mrb_ary_aset2_impl(mrb_state*, mrb_value, mrb_value, mrb_value)'],
                   needs: ['if (mrb_get_argc(mrb) == 2) { const mrb_value *vs = mrb_get_argv(mrb); ' \
                           'return mrb_ary_aset2_impl(mrb, self, vs[0], vs[1]); }',
                           "mrb_value\nmrb_ary_aset2_impl(mrb_state *mrb, mrb_value self, mrb_value v1, mrb_value v2)\n{"] },
      'Hash' => { file: 'src/hash.c', gem: nil, mt: 'mrb_hash_aset', test: 'mrb_hash_p(recv)',
                  stmt: 'mrb_hash_set(M, recv, %<idx>s, %<val>s)', result: '%<val>s',
                  needs: ['mrb_hash_aset(mrb_state *mrb, mrb_value self) { mrb_int argc = mrb_get_argc(mrb); ' \
                          'if (argc != 2) { mrb_argnum_error(mrb, argc, 2, 2); } ' \
                          'const mrb_value *argv = mrb_get_argv(mrb); mrb_value key = argv[0]; mrb_value val = argv[1]; ' \
                          'mrb_hash_set(mrb, self, key, val); return val; }'] },
      'String' => { file: 'src/string.c', gem: nil, mt: 'mrb_str_aset_m', test: 'mrb_string_p(recv)',
                    stmt: 'mrb_str_aset(M, recv, %<idx>s, mrb_undef_value(), %<val>s)', result: '%<val>s',
                    decl: ['void mrb_str_aset(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_value)'],
                    needs: ['mrb_str_aset_m(mrb_state *mrb, mrb_value str) { mrb_value idx, alen, replace; ' \
                            'switch (mrb_get_args(mrb, "oo|S!", &idx, &alen, &replace)) { case 2: replace = alen; ' \
                            'alen = mrb_undef_value(); break; case 3: break; } ' \
                            'mrb_str_aset(mrb, str, idx, alen, replace); return replace; }',
                            "\nvoid\nmrb_str_aset(mrb_state *mrb, mrb_value str, mrb_value idx, mrb_value alen, mrb_value replace)\n{"] },
      'Struct' => { file: 'mrbgems/mruby-struct/src/struct.c', gem: 'mruby-struct', mt: 'mrb_struct_aset',
                    test: 'mrb_type(recv) == MRB_TT_STRUCT', call: 'mrb_struct_aset_impl(M, recv, %<idx>s, %<val>s)',
                    decl: ['mrb_value mrb_struct_aset_impl(mrb_state*, mrb_value, mrb_value, mrb_value)'],
                    needs: ['mrb_struct_aset(mrb_state *mrb, mrb_value s) { mrb_value idx; mrb_value val; ' \
                            'mrb_get_args(mrb, "oo", &idx, &val); return mrb_struct_aset_impl(mrb, s, idx, val); }',
                            "mrb_value\nmrb_struct_aset_impl(mrb_state *mrb, mrb_value s, mrb_value idx, mrb_value val)\n{"] },
      'Table' => { file: 'mruby-rgss/src/lib.cxx', gem: 'mruby-rgss', mt: nil, test: 'rgss_table_p(recv)',
                   guard: 'rgss_table_p', call: 'rgss_table_aset_impl(M, recv, 2, %<idx>s, %<val>s, mrb_nil_value(), mrb_nil_value())',
                   decl: ['mrb_bool rgss_table_p(mrb_value)',
                          'mrb_value rgss_table_aset_impl(mrb_state*, mrb_value, mrb_int, mrb_value, mrb_value, mrb_value, mrb_value)'],
                   needs: ['mrb_define_method(M, table, "[]=", table_set,',
                           'mrb_value table_set(mrb_state* M, V self) { mrb_value a0, a1, a2 = mrb_nil_value(), ' \
                           'a3 = mrb_nil_value(); mrb_get_args(M, "oo|oo", &a0, &a1, &a2, &a3); ' \
                           'return table_set_impl(M, self, mrb_get_argc(M), a0, a1, a2, a3); }',
                           'rgss_table_aset_impl(mrb_state* M, mrb_value self, mrb_int argc, mrb_value a0, mrb_value a1, ' \
                           'mrb_value a2, mrb_value a3) { return table_set_impl(M, self, argc, a0, a1, a2, a3); }'] }
    }
  }.freeze

  # `[]` on a class object, by the owner the scan names for the registration (nil: Struct.new's fresh class), with the
  # function, the macro and the source it must come from, and the C++ over the receiver class `k` and the argument
  # `bc2cpp_key`.
  INDEX_CLASS_ARMS = {
    'Array' => { file: 'src/array.c', gem: nil, function: 'mrb_ary_s_create', macro: 'mrb_define_class_method_id',
                 test: 'bc2cpp_class_inherits(k, M->array_class)', call: 'mrb_ary_s_create_impl(M, recv, 1, &bc2cpp_key)',
                 decl: ['mrb_value mrb_ary_s_create_impl(mrb_state*, mrb_value, mrb_int, const mrb_value*)'],
                 needs: ['mrb_ary_s_create(mrb_state *mrb, mrb_value klass) { const mrb_value *vals; mrb_int len; ' \
                         'mrb_get_args(mrb, "*!", &vals, &len); return mrb_ary_s_create_impl(mrb, klass, len, vals); }',
                         "mrb_value\nmrb_ary_s_create_impl(mrb_state *mrb, mrb_value klass, mrb_int len, const mrb_value *vals)\n{"] },
    'Hash' => { file: 'mrbgems/mruby-hash-ext/src/hash_ext.c', gem: 'mruby-hash-ext', function: 'hash_s_create',
                macro: 'mrb_define_class_method_id', test: 'bc2cpp_class_inherits(k, M->hash_class)',
                guard: 'mrb_hash_s_create_impl',
                call: 'mrb_hash_s_create_impl(M, recv, 1, &bc2cpp_key)',
                decl: ['mrb_value mrb_hash_s_create_impl(mrb_state*, mrb_value, mrb_int, const mrb_value*)'],
                needs: ['hash_s_create(mrb_state *mrb, mrb_value klass) { const mrb_value *argv; mrb_int argc; ' \
                        'mrb_get_args(mrb, "*", &argv, &argc); return mrb_hash_s_create_impl(mrb, klass, argc, argv); }',
                        "mrb_value\nmrb_hash_s_create_impl(mrb_state *mrb, mrb_value klass, mrb_int argc, const mrb_value *argv)\n{"] },
    'Set' => { file: 'mrbgems/mruby-set/src/set.c', gem: 'mruby-set', function: 'set_s_create',
               macro: 'mrb_define_class_method', test: 'bc2cpp_class_inherits(k, mrb_class_get(M, "Set"))',
               guard: 'mrb_set_s_create_impl',
               call: 'mrb_set_s_create_impl(M, recv, 1, &bc2cpp_key)',
               decl: ['mrb_value mrb_set_s_create_impl(mrb_state*, mrb_value, mrb_int, const mrb_value*)'],
               needs: ['set_s_create(mrb_state *mrb, mrb_value klass) { const mrb_value *argv; mrb_int argc; ' \
                       'mrb_get_args(mrb, "*", &argv, &argc); return mrb_set_s_create_impl(mrb, klass, argc, argv); }',
                       "mrb_value\nmrb_set_s_create_impl(mrb_state *mrb, mrb_value klass, mrb_int argc, const mrb_value *argv)\n{"] },
    # Struct.new's class gets `[]` = mrb_instance_new, which is mrb_obj_new plus the call's block; `[]` passes none.
    nil => { file: 'mrbgems/mruby-struct/src/struct.c', gem: 'mruby-struct', function: 'mrb_instance_new',
             macro: 'mrb_define_class_method_id', test: 'bc2cpp_struct_class_p(M, k)',
             call: 'mrb_obj_new(M, k, 1, &bc2cpp_key)',
             needs: ['mrb_define_class_method_id(mrb, c, MRB_OPSYM(aref), mrb_instance_new, MRB_ARGS_ANY());'],
             also: { 'src/class.c' => [
               'mrb_instance_new(mrb_state *mrb, mrb_value cv) { const mrb_value *argv; mrb_int argc; mrb_value blk; ' \
               'mrb_get_args(mrb, "*!&", &argv, &argc, &blk); mrb_value obj = mrb_instance_alloc(mrb, cv); ' \
               'mrb_sym init = MRB_SYM(initialize); if (!mrb_func_basic_p(mrb, obj, init, mrb_do_nothing)) { ' \
               'mrb_funcall_with_block(mrb, obj, init, argc, argv, blk); } return obj; }',
               'mrb_obj_new(mrb_state *mrb, struct RClass *c, mrb_int argc, const mrb_value *argv) { ' \
               'mrb_value obj = mrb_instance_alloc(mrb, mrb_obj_value(c)); mrb_sym mid = MRB_SYM(initialize); ' \
               'if (!mrb_func_basic_p(mrb, obj, mid, mrb_do_nothing)) { mrb_funcall_argv(mrb, obj, mid, argc, argv); } ' \
               'return obj; }'
             ] } }
  }.freeze

  # Classes the scan names as `[]` owners whose gem the closed worlds never link; no arm exists for them, so a build
  # that does link one keeps the by-name helper.
  INDEX_OWNER_GEMS = { 'Method' => 'mruby-method', 'OnigMatchData' => 'mruby-onig-regexp' }.freeze

  INDEX_CLASS_PRELUDE = <<~CPP
    // INDEX_CLOSED (ADR 0365): `k` is `base` or below it, which is where a singleton method of `base` is found.
    static inline bool bc2cpp_class_inherits(struct RClass* k, struct RClass* base) {
      for (struct RClass* c = k; c; c = c->super) if (c == base) return true;
      return false;
    }
    // Struct.new defines `.[]` on the class it makes, so it and the classes below it answer it; `class X < Struct` does not.
    static bool bc2cpp_struct_class_p(mrb_state* M, struct RClass* k) {
      if (!mrb_class_defined(M, "Struct")) return false;
      struct RClass* st = mrb_class_get(M, "Struct");
      mrb_sym members = mrb_intern_lit(M, "__members__");
      bool found = false;
      for (struct RClass* c = k; c; c = c->super) {
        if (c == st) return found;
        if (c->tt == MRB_TT_CLASS && !mrb_nil_p(mrb_iv_get(M, mrb_obj_value(c), members))) found = true;
      }
      return false;
    }

  CPP

  # The `site` the helper's chain passes to guarded_fallback_line: no real site, and nothing else is this object.
  INDEX_CLOSED_SITE = { index_closed: true }.freeze

  IndexPlan = Struct.new(:name, :natives, :classes, :resolution, keyword_init: true)

  # For the stderr summary: each helper called, closed or the reason it is not.
  def index_closed_summary(codes)
    index_helpers_used(codes).map do |kind|
      closed = @index_helper_code.fetch(kind).include?('INDEX_CLOSED')
      "#{kind} #{closed ? 'closed' : "by-name (#{index_closed_reasons.fetch(INDEX_HELPER_NAMES.fetch(kind), :not_planned)})"}"
    end.join(', ').then { |s| s.empty? ? 'none' : s }
  end

  # The extern "C" declarations of the exported bodies `helpers` call (they are in no mruby header), and the class
  # helpers its class-object arm uses.
  def index_closed_prelude(helpers)
    specs = INDEX_ARMS.values.flat_map(&:values) + INDEX_CLASS_ARMS.values
    decls = specs.flat_map { |spec| (spec[:decl] || []).map { |decl| [decl, spec[:gem] ? '__attribute__((weak)) ' : ''] } }.uniq.select do |decl, _|
      helpers.match?(/\b#{decl[/(\w+)\(/, 1]}\(/)
    end
    return '' if decls.empty? && !helpers.include?('INDEX_CLOSED')

    out = +"// INDEX_CLOSED (ADR 0365): exported by patches/mruby-expose-index-bodies.patch, or by mruby-rgss/src/lib.cxx.\n"
    decls.each { |decl, weak| out << "extern \"C\" #{weak}#{decl};\n" }
    out << "\n"
    out << INDEX_CLASS_PRELUDE if helpers.include?('bc2cpp_class_inherits(') || helpers.include?('bc2cpp_struct_class_p(')
    out
  end

  # BC2CPP_INDEX_HELPER_CLOSED=0 keeps the by-name helpers.
  def index_closed_world?
    ENV['BC2CPP_INDEX_HELPER_CLOSED'] != '0' && @closed_world && @native_name_sources && @closed_world.global_refusal.nil? &&
      @closed_world.exact_instances_singleton_free? && @closed_world.method_missing_classes.empty?
  end

  # name => the refusal Symbol, for the summary.
  def index_closed_reasons
    @index_closed_reasons ||= {}
  end

  # The plan for `name` (`[]` or `[]=`), or nil with the reason in index_closed_reasons.
  def index_closed_plan(name)
    @index_closed_plan ||= {}
    return @index_closed_plan[name] if @index_closed_plan.key?(name)

    plan = compute_index_closed_plan(name)
    index_closed_reasons[name] = plan if plan.is_a?(Symbol)
    @index_closed_plan[name] = plan.is_a?(Symbol) ? nil : plan
  end

  # The plan, or the Symbol naming why the name stays by-name.
  def compute_index_closed_plan(name)
    return :disabled unless index_closed_world?
    return :blocked_name if devirt_blocked_name?(name)

    answers = call_facts_answers
    definers = answers.definers(name)
    return :unbounded if definers.nil?
    return :singleton_definer if definers[:singleton]
    return :outside_definer unless definers[:foreign].empty? && definers[:modules].empty?

    members = index_closed_members(answers, name, definers)
    return :unbounded if members.nil?

    arms = INDEX_ARMS.fetch(name)
    natives = definers[:native].select { |owner| index_owner_linked?(owner, arms[owner]) }.sort
    missing = natives.find { |owner| !arms.key?(owner) }
    return :"no_arm_#{missing}" if missing
    return :arm_unverified unless natives.all? { |owner| index_arm_verified?(answers, name, owner, arms.fetch(owner)) }

    classes = index_class_arms(answers, name, definers)
    return :class_object unless classes

    plan = IndexPlan.new(name: name, natives: natives, classes: classes, resolution: {})
    reason = index_resolve_members(plan, answers, definers, members)
    reason || plan
  end

  # `members` less the classes of gems the build does not link (the host scan reads every core gem; ADR 0364 does the
  # same for Time). nil when the name is unbounded or a removed class has a declared subclass.
  def index_closed_members(answers, name, definers)
    members = answers.members(name)
    return nil if members.nil?

    gems = CodeGen.build_gem_names
    return members if gems.nil?

    arms = INDEX_ARMS.fetch(name)
    unlinked = definers[:native].reject { |owner| index_owner_linked?(owner, arms[owner]) }
    return members if unlinked.empty?

    gone = members.select { |k| k != CallFacts::CLASS_OBJECT && answers.ancestors(k).first.any? { |a| unlinked.include?(a) } }
    return nil if gone.any? { |k| @closed_world.class_declared?(k) && !unlinked.include?(k) }

    members - gone
  end

  def index_owner_linked?(owner, spec)
    gem = spec ? spec[:gem] : INDEX_OWNER_GEMS[owner]
    gems = CodeGen.build_gem_names
    gem.nil? || gems.nil? || gems.include?(gem)
  end

  # The root of the mruby tree the build scans, from its src/array.c.
  def index_mruby_root
    @index_mruby_root ||= begin
      array = @native_name_sources.each_value.flat_map(&:to_a).find { |p| p.end_with?('/src/array.c') }
      array&.delete_suffix('/src/array.c') || false
    end
  end

  # The text of `relative` (below the mruby tree, or a repo path `mruby-...`) with its spaces removed, or nil.
  def index_source(relative)
    path = if relative.start_with?('mruby-')
             @native_name_sources.each_value.flat_map(&:to_a).find { |p| p.end_with?("/#{relative}") }
           elsif index_mruby_root
             File.join(index_mruby_root, relative)
           end
    return nil unless path && File.file?(path)

    @index_sources ||= {}
    @index_sources[path] ||= File.read(path, encoding: 'UTF-8').gsub(%r{/\*.*?\*/}m, '').gsub(/\s+/, '')
  end

  def index_needles_found?(relative, needles)
    text = index_source(relative)
    !text.nil? && needles.all? { |needle| text.include?(needle.gsub(/\s+/, '')) }
  end

  def index_spec_sources_found?(spec)
    index_needles_found?(spec.fetch(:file), spec.fetch(:needs)) &&
      (spec[:also] || {}).all? { |relative, needles| index_needles_found?(relative, needles) }
  end

  # The registration is the one the arm stands for (one per owner), and the sources hold the bodies it calls.
  def index_arm_verified?(answers, name, owner, spec)
    return false unless index_spec_sources_found?(spec)

    if spec[:mt]
      entries = answers.registrations.fetch(name, []).select { |e| e[:owner]&.fetch(:class_name, nil) == owner }
      entries.size == 1 && entries.first[:function] == spec[:mt] && entries.first[:path].end_with?("/#{spec[:file]}") &&
        answers.opaque_owners.fetch(name, []).count(owner).zero?
    else
      answers.opaque_owners.fetch(name, []).count(owner) == 1 &&
        answers.registrations.fetch(name, []).none? { |e| e[:owner]&.fetch(:class_name, nil) == owner }
    end
  end

  # Arms for a class or module object receiver: {} when none can answer, nil when a class-level registration of `name`
  # is not one the generator reproduces (or a Class/Module answers for another reason).
  def index_class_arms(answers, name, definers)
    registrations = answers.class_registrations.fetch(name, [])
    if registrations.empty?
      return nil if answers.members(name)&.include?(CallFacts::CLASS_OBJECT)

      return {}
    end
    return nil unless name == '[]'

    arms = {}
    registrations.each do |entry|
      spec = INDEX_CLASS_ARMS[entry[:owner]]
      return nil unless spec && entry[:function] == spec[:function] && entry[:macro] == spec[:macro] &&
                        entry[:path].end_with?("/#{spec[:file]}")
      next unless index_owner_linked?(entry[:owner], spec)
      return nil unless index_spec_sources_found?(spec)

      arms[entry[:owner]] = spec
    end
    # A Class/Module answering for another reason (a Ruby or foreign definer on one) is not covered by these arms.
    return nil if [definers[:ruby], definers[:native], definers[:foreign]].any? { |s| s.intersect?(CallFacts::CLASS_OR_MODULE) }

    arms
  end

  # How `klass` resolves `name`: [:ruby, owner] (a definition of the world), [:native, owner] or [:none]; nil when
  # unknown. Declared classes are walked by full name, so a namesake (the native `File`, the world's `LCF::File`) cannot
  # stand in for the other; an undeclared class is only reached by native definers.
  def index_resolve(answers, klass, definers, ruby_owners)
    seen = Set.new
    cur = klass
    while cur.is_a?(String) && seen.add?(cur)
      return index_resolve_outside(answers, cur, definers) unless @closed_world.class_declared?(cur)
      return [:ruby, cur] if ruby_owners.include?(cur)
      # A top-level declaration of a core class is a reopening of it; a nested namesake is ambiguous.
      return (cur == answers.simple(cur) ? [:native, cur] : nil) if definers[:native].include?(answers.simple(cur))

      sup = @superclass_of[cur]
      # No superclass written: a reopening of a class the sources outside the world define (File).
      return index_resolve_outside(answers, cur, definers) unless sup.is_a?(String)

      cur = sup
    end
    nil
  end

  # A class the world does not declare (or only reopens): resolved from the chain CallFacts knows, else the one the outside
  # sources spell. [:native, owner], [:none] or nil.
  def index_resolve_outside(answers, cur, definers)
    # `Name = Struct.new(...)`: a class below Struct that no declaration spells (STRUCT_MEMBERS_ANALYSIS).
    return definers[:native].include?('Struct') ? [:native, 'Struct'] : [:none] if CodeGen.struct_members&.key?(cur)

    ancestors, unknown = answers.ancestors(cur)
    ancestors = index_outside_ancestors(answers.simple(cur)) if unknown
    return nil unless ancestors

    first = ancestors.find { |a| definers[:native].include?(a) }
    first ? [:native, first] : [:none]
  end

  # The simple names of the superclasses of an undeclared class, read from the sources outside the closed world
  # (`class A < B` in Ruby, mrb_define_class*(.., A, B) in C) when CallFacts cannot name its chain (File includes a module
  # the scan cannot read); nil when one link is missing or ambiguous. Mixins do not matter: no module definer exists here.
  def index_outside_ancestors(name)
    chain = [name]
    seen = Set.new
    cur = name
    while seen.add?(cur)
      return chain if cur == 'Object' || cur == 'BasicObject'

      supers = index_outside_supers[cur]
      return nil if supers.nil? || supers.size != 1

      cur = supers.first
      chain << cur
    end
    nil
  end

  def index_outside_supers
    @index_outside_supers ||= begin
      map = Hash.new { |hash, key| hash[key] = Set.new }
      @closed_world.outside_ruby_paths.each do |path|
        File.read(path, encoding: 'UTF-8').scan(/^\s*class\s+([A-Z]\w*(?:::[A-Z]\w*)*)\s*<\s*([A-Z]\w*(?:::[A-Z]\w*)*)/) do |klass, sup|
          map[klass.split('::').last] << sup.split('::').last
        end
      end
      @closed_world.native_paths.each { |path| index_native_supers(path, map) }
      map
    end
  end

  def index_native_supers(path, map)
    source = NativeExpressionDevirt.read_source(path)
    return unless source.include?('mrb_define_class')

    vars = NativeExpressionDevirt.class_variable_map(source)
    super_name = lambda do |expr|
      vars.dig(expr, :class_name) || (expr.match(/\Amrb->(\w+)_class\z/) && Regexp.last_match(1).capitalize)
    end
    %w[mrb_define_class_id mrb_define_class mrb_define_class_under_id mrb_define_class_under].each do |macro|
      NativeExpressionDevirt.macro_calls(source, macro).each do |args|
        under = macro.include?('under')
        name_arg, super_arg = args[under ? 2 : 1], args[under ? 3 : 2]
        next unless name_arg && super_arg

        name = name_arg[/MRB_SYM\((\w+)\)/, 1] || name_arg[/\A"([^"]+)"\z/, 1]
        sup = super_name.call(super_arg)
        map[name.split('::').last] << (sup || "?#{super_arg}") if name
      end
    end
  end

  # Fills plan.resolution with member class => [kind, owner]; the refusal Symbol when a member has no arm.
  def index_resolve_members(plan, answers, definers, members)
    ruby_owners = @registry.fetch(plan.name, []).reject { |d| d.owner == '<native>' || d.owner.end_with?('.singleton') }
                           .to_set(&:owner)
    members.to_a.sort.each do |klass|
      next if klass == CallFacts::CLASS_OBJECT
      return :module_member if @closed_world.module_declared?(klass)

      resolved = index_resolve(answers, klass, definers, ruby_owners)
      return :"unresolved_#{klass}" unless resolved
      return :"no_arm_#{resolved.last}" if resolved.first == :native && !plan.natives.include?(resolved.last)

      plan.resolution[klass] = resolved
    end
    nil
  end

  # INHERITED_GUARD for the helper chain: the strict subclasses of candidate `owner` whose lookup of the name ends at its
  # definition, from the plan's own resolution (the general rule declines a name with a native outside mruby's core).
  def index_closed_subclasses(owner)
    subs = @index_closed_build[:plan].resolution.select { |klass, (kind, o)| kind == :ruby && o == owner && klass != owner }.keys.sort
    @index_closed_build[:overflow] = true if subs.size > POLY_SMALL_N_INHERITED_MAX
    subs.first(POLY_SMALL_N_INHERITED_MAX)
  end

  # The else arm of the helper's chain: native arms and a proven NoMethodError, or nil to keep the by-name line.
  # `listed` is every class the chain above it covers.
  def index_closed_fallback(d, recv, name, argv, listed)
    build = @index_closed_build
    plan = build[:plan]
    ruby_classes = plan.resolution.select { |_, (kind, _)| kind == :ruby }.keys
    return nil unless ruby_classes.all? { |klass| listed.include?(klass) } && !build[:overflow]

    build[:used] = true
    index_closed_tail(plan, d, recv, name, argv)
  end

  def index_arm_test(spec, test)
    spec[:guard] ? "#{spec[:guard]} != nullptr && #{test}" : test
  end

  def index_closed_tail(plan, d, recv, name, argv)
    arms = INDEX_ARMS.fetch(name)
    getter = name == '[]'
    args = { key: 'bc2cpp_key', idx: argv[0], val: argv[1] }
    branches = plan.natives.map do |owner|
      spec = arms.fetch(owner)
      body = if spec[:call]
               "r#{d} = #{format(spec[:call], args)};"
             else
               "#{format(spec[:stmt], args)};\n      r#{d} = #{format(spec[:result], args)};"
             end
      "if (#{index_arm_test(spec, spec[:test].gsub('recv', recv))}) {\n      #{body}\n    }"
    end
    nomethod = "r#{d} = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\", #{argv.size}, #{getter ? 'bc2cpp_key' : argv.join(', ')});"
    unless plan.classes.empty?
      classes = plan.classes.values.map do |spec|
        "if (#{index_arm_test(spec, spec[:test])}) {\n        r#{d} = #{spec[:call].gsub('recv', recv)};\n      }"
      end
      branches << "if (mrb_class_p(#{recv})) {\n      struct RClass* k = mrb_class_ptr(#{recv});\n      " \
                  "#{classes.join(' else ')} else {\n        #{nomethod}\n      }\n    }"
    end
    text = +"  // INDEX_CLOSED :#{name} -- every class that can answer is a chain arm above or one of: " \
            "#{(plan.natives + plan.classes.keys.map { |k| k ? "#{k}.#{name}" : "<Struct class>.#{name}" }).join(', ')}; " \
            "any other receiver is a proven NoMethodError\n"
    text << "  {\n"
    text << "    mrb_value bc2cpp_key = #{argv.first};\n" if getter
    text << "    #{branches.join(' else ')}#{branches.empty? ? '' : ' else '}{\n      #{nomethod}\n    }\n  }\n"
    text
  end

  # The closed body of helper `kind` (without the leading fast paths), or nil to keep the by-name form. `fast` is the
  # helper's own inline fast-path text, `chain_args` the arguments the chain passes on.
  def index_helper_closed_source(fast, name, argv)
    plan = index_closed_plan(name)
    return nil unless plan

    @index_closed_build = { plan: plan, used: false, overflow: false }
    chain = compile_poly_dispatch(name, 0, 'recv', argv, argv.size, closed_world_site: INDEX_CLOSED_SITE)
    build = @index_closed_build
    chain ||= index_closed_fallback(0, 'recv', name, argv, []) if plan.resolution.none? { |_, (kind2, _)| kind2 == :ruby }
    unless chain && build[:used] && !build[:overflow] && !chain.match?(/\bmrb_funcall\w*\(|\bbc2cpp_send\(/)
      index_closed_reasons[name] = :chain_uncovered
      @index_closed_plan[name] = nil
      return nil
    end

    "#{fast}mrb_value r0 = mrb_nil_value();\n#{chain}  return r0;\n"
  ensure
    @index_closed_build = nil
  end
end
