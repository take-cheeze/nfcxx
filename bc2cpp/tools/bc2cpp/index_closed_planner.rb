# frozen_string_literal: true

require 'set'
require_relative 'call_facts'
require_relative 'native_expression_devirt'

# IndexClosedPlanner: the INDEX_CLOSED closure verdict (ADR 0365) as a
# standalone module. CodeGen uses it to close the shared index helpers'
# by-name tails; the static dispatch proof uses the same verdict to admit
# proven `[]` / `[]=` entries to the unregistered lists. Sharing the
# computation (rather than reimplementing it) keeps the two consumers from
# diverging on what "closed" means.
#
# A Planner answers one question per name: :closed with the covered class
# set, or a refusal Symbol. It is built from plain data both consumers
# already hold:
#   answers:        CallFacts::Answers over the closed world
#   registry:       name => definitions (with #owner), the engine's own
#   superclass_of:  class => superclass name / :none
#   struct_members: Struct.new-class members (nil: use ancestors only)
#   source:         (relative path) => whitespace-stripped source text, or nil
#   gems:           linked gem names (nil: no gem filtering)
#   blocked_name?:  (name) => whether codegen must keep it dynamic
#   world:          the closed-world queries the resolution needs
#                   (class_declared?, module_declared?, outside_ruby_paths,
#                   native_paths)
class IndexClosedPlanner
  # Per name and native owner. `file`: path below the mruby tree, or a repo path starting `mruby-`. `gem`: the gem that
  # provides the class (nil: mruby core). `mt`: the MRB_MT_ENTRY function (nil: registered by a hand-written
  # mrb_define_method*, counted in opaque_owners). `needs`: text the source must contain, spaces ignored. `test` and
  # `call`/`stmt`: C++ over `recv` and the helper's argument expressions (`%<key>s`, `%<idx>s`, `%<val>s`). A gem's
  # exported function is declared weak (a libmruby without the gem, which the checks link against, still links) and
  # `guard` names the one the test must see linked before it runs.
  ARMS = {
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
      # `proc[x]` is mrb_funcall(proc, "[]", x) once `[]` is found on Proc (proc_call, a cfunc): mrb_funcall_with_method skips
      # the lookup and nothing else (src/vm.c's funcall_with_block_m). A cfunc-backed proc (a compiled block) is still
      # yielded to directly, as bc2cpp_funcall_argv does.
      'Proc' => { file: 'src/proc.c', gem: nil, mt: 'proc_call', test: 'mrb_proc_p(recv)',
                  call: '(MRB_PROC_CFUNC_P(mrb_proc_ptr(recv)) && mrb_obj_ptr(recv)->c == M->proc_class) ? ' \
                         'bc2cpp_yield_argv(M, recv, 1, &bc2cpp_key) : mrb_proc_aref_impl(M, recv, 1, &bc2cpp_key)',
                  decl: ['mrb_value mrb_proc_aref_impl(mrb_state*, mrb_value, mrb_int, const mrb_value*)'],
                  needs: ['mrb_proc_aref_impl(mrb_state *mrb, mrb_value proc, mrb_int argc, const mrb_value *argv) { ' \
                          'mrb_method_t m; MRB_METHOD_FROM_FUNC(m, proc_call); ' \
                          'return mrb_funcall_with_method(mrb, proc, MRB_OPSYM(aref), &m, mrb->proc_class, argc, argv, ' \
                          'mrb_nil_value()); }'],
                  also: { 'src/vm.c' => ['return funcall_with_block_m(mrb, self, mid, argc, argv, NULL, FALSE, blk, m, owner);',
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
                  stmt: 'bc2cpp_hash_aset(M, recv, %<idx>s, %<val>s)', result: '%<val>s',
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
  CLASS_ARMS = {
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
  OWNER_GEMS = { 'Method' => 'mruby-method', 'OnigMatchData' => 'mruby-onig-regexp' }.freeze

  IndexPlan = Struct.new(:name, :natives, :classes, :resolution, keyword_init: true)
  # Per name and native owner. `file`: path below the mruby tree, or a repo path starting `mruby-`. `gem`: the gem that
  # provides the class (nil: mruby core). `mt`: the MRB_MT_ENTRY function (nil: registered by a hand-written
  # mrb_define_method*, counted in opaque_owners). `needs`: text the source must contain, spaces ignored. `test` and
  # `call`/`stmt`: C++ over `recv` and the helper's argument expressions (`%<key>s`, `%<idx>s`, `%<val>s`). A gem's
  # exported function is declared weak (a libmruby without the gem, which the checks link against, still links) and
  # `guard` names the one the test must see linked before it runs.


  def initialize(answers:, registry:, superclass_of:, struct_members:, source:, gems:, world:,
                 enabled: true, blocked_name: ->(_name) { false })
    @answers = answers
    @registry = registry
    @superclass_of = superclass_of
    @struct_members = struct_members
    @source = source
    @gems = gems
    @world = world
    @enabled = enabled
    @blocked_name = blocked_name
    @plan = {}
    @reasons = {}
    @outside_supers = nil
  end

  # name => the refusal Symbol, for the summary.
  attr_reader :reasons

  # Shared with integer_tag_else's Array-body proof (via CodeGen's
  # delegations below): whether `owner`'s arm is linked, and whether its
  # registration and sources verify.
  def owner_linked?(owner, spec)
    gem = spec ? spec[:gem] : OWNER_GEMS[owner]
    gem.nil? || @gems.nil? || @gems.include?(gem)
  end

  # The CodeGen state the rest of the helper emission still reads.
  def self.build_state(plan)
    { plan: plan, used: false, overflow: false }
  end

  # The registration is the one the arm stands for (one per owner), and the sources hold the bodies it calls.
  def arm_verified?(name, owner, spec)
    return false unless spec_sources_found?(spec)

    if spec[:mt]
      entries = @answers.registrations.fetch(name, []).select { |e| e[:owner]&.fetch(:class_name, nil) == owner }
      entries.size == 1 && entries.first[:function] == spec[:mt] && entries.first[:path].end_with?("/#{spec[:file]}") &&
        @answers.opaque_owners.fetch(name, []).count(owner).zero?
    else
      @answers.opaque_owners.fetch(name, []).count(owner) == 1 &&
        @answers.registrations.fetch(name, []).none? { |e| e[:owner]&.fetch(:class_name, nil) == owner }
    end
  end

  # The plan for `name` (`[]` or `[]=`), or nil with the reason in reasons.
  def plan(name)
    return @plan[name] if @plan.key?(name)

    computed = compute(name)
    @reasons[name] = computed if computed.is_a?(Symbol)
    @plan[name] = computed.is_a?(Symbol) ? nil : computed
  end

  # The plan, or the Symbol naming why the name stays by-name.
  def compute(name)
    return :disabled unless @enabled && world_closed?
    return :blocked_name if @blocked_name.call(name)

    definers = @answers.definers(name)
    return :unbounded if definers.nil?
    return :singleton_definer if definers[:singleton]
    return :outside_definer unless definers[:foreign].empty? && definers[:modules].empty?

    members = closed_members(name, definers)
    return :unbounded if members.nil?

    arms = ARMS.fetch(name)
    natives = definers[:native].select { |owner| owner_linked?(owner, arms[owner]) }.sort
    missing = natives.find { |owner| !arms.key?(owner) }
    return :"no_arm_#{missing}" if missing
    return :arm_unverified unless natives.all? { |owner| arm_verified?(name, owner, arms.fetch(owner)) }

    classes = class_arms(name, definers)
    return :class_object unless classes

    built = IndexPlan.new(name: name, natives: natives, classes: classes, resolution: {})
    reason = resolve_members(built, definers, members)
    reason || built
  end

  private

  def world_closed?
    @world.global_refusal.nil? && @world.exact_instances_singleton_free? && @world.method_missing_classes.empty?
  end

  # `members` less the classes of gems the build does not link. nil when the name is unbounded or a removed class
  # has a declared subclass.
  def closed_members(name, definers)
    members = @answers.members(name)
    return nil if members.nil?
    return members if @gems.nil?

    arms = ARMS.fetch(name)
    unlinked = definers[:native].reject { |owner| owner_linked?(owner, arms[owner]) }
    return members if unlinked.empty?

    gone = members.select do |k|
      k != CallFacts::CLASS_OBJECT && @answers.ancestors(k).first.any? { |a| unlinked.include?(a) }
    end
    return nil if gone.any? { |k| @world.class_declared?(k) && !unlinked.include?(k) }

    members - gone
  end

  def needles_found?(relative, needles)
    text = @source.call(relative)
    !text.nil? && needles.all? { |needle| text.include?(needle.gsub(/\s+/, '')) }
  end

  def spec_sources_found?(spec)
    needles_found?(spec.fetch(:file), spec.fetch(:needs)) &&
      (spec[:also] || {}).all? { |relative, needles| needles_found?(relative, needles) }
  end

  # Arms for a class or module object receiver: {} when none can answer, nil when a class-level registration of `name`
  # is not one the generator reproduces (or a Class/Module answers for another reason).
  def class_arms(name, definers)
    registrations = @answers.class_registrations.fetch(name, [])
    if registrations.empty?
      return nil if @answers.members(name)&.include?(CallFacts::CLASS_OBJECT)

      return {}
    end
    return nil unless name == '[]'

    arms = {}
    registrations.each do |entry|
      spec = CLASS_ARMS[entry[:owner]]
      return nil unless spec && entry[:function] == spec[:function] && entry[:macro] == spec[:macro] &&
                        entry[:path].end_with?("/#{spec[:file]}")
      next unless owner_linked?(entry[:owner], spec)
      return nil unless spec_sources_found?(spec)

      arms[entry[:owner]] = spec
    end
    # A Class/Module answering for another reason (a Ruby or foreign definer on one) is not covered by these arms.
    return nil if [definers[:ruby], definers[:native], definers[:foreign]].any? { |s| s.intersect?(CallFacts::CLASS_OR_MODULE) }

    arms
  end

  # How `klass` resolves `name`: [:ruby, owner] (a definition of the world), [:native, owner] or [:none]; nil when
  # unknown. Declared classes are walked by full name, so a namesake (the native `File`, the world's `LCF::File`) cannot
  # stand in for the other; an undeclared class is only reached by native definers.
  def resolve(klass, definers, ruby_owners)
    seen = Set.new
    cur = klass
    while cur.is_a?(String) && seen.add?(cur)
      return resolve_outside(cur, definers) unless @world.class_declared?(cur)
      return [:ruby, cur] if ruby_owners.include?(cur)
      # A top-level declaration of a core class is a reopening of it; a nested namesake is ambiguous.
      if definers[:native].include?(@answers.simple(cur))
        return cur == @answers.simple(cur) ? [:native, cur] : nil
      end

      sup = @superclass_of[cur]
      # No superclass written: a reopening of a class the sources outside the world define (File).
      return resolve_outside(cur, definers) unless sup.is_a?(String)

      cur = sup
    end
    nil
  end

  # A class the world does not declare (or only reopens): resolved from the chain CallFacts knows, else the one the
  # outside sources spell. [:native, owner], [:none] or nil.
  def resolve_outside(cur, definers)
    # `Name = Struct.new(...)`: a class below Struct that no declaration spells (STRUCT_MEMBERS_ANALYSIS).
    return definers[:native].include?('Struct') ? [:native, 'Struct'] : [:none] if @struct_members&.key?(cur)

    ancestors, unknown = @answers.ancestors(cur)
    ancestors = outside_ancestors(@answers.simple(cur)) if unknown
    return nil unless ancestors

    first = ancestors.find { |a| definers[:native].include?(a) }
    first ? [:native, first] : [:none]
  end

  # The simple names of the superclasses of an undeclared class, read from the sources outside the closed world
  # (`class A < B` in Ruby, mrb_define_class*(.., A, B) in C) when CallFacts cannot name its chain (File includes a module
  # the scan cannot read); nil when one link is missing or ambiguous. Mixins do not matter: no module definer exists here.
  def outside_ancestors(name)
    chain = [name]
    seen = Set.new
    cur = name
    while seen.add?(cur)
      return chain if cur == 'Object' || cur == 'BasicObject'

      supers = outside_supers[cur]
      return nil if supers.nil? || supers.size != 1

      cur = supers.first
      chain << cur
    end
    nil
  end

  def outside_supers
    @outside_supers ||= begin
      map = Hash.new { |hash, key| hash[key] = Set.new }
      @world.outside_ruby_paths.each do |path|
        File.read(path, encoding: 'UTF-8').scan(/^\s*class\s+([A-Z]\w*(?:::[A-Z]\w*)*)\s*<\s*([A-Z]\w*(?:::[A-Z]\w*)*)/) do |klass, sup|
          map[klass.split('::').last] << sup.split('::').last
        end
      end
      @world.native_paths.each { |path| native_supers(path, map) }
      map
    end
  end

  def native_supers(path, map)
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
  def resolve_members(plan, definers, members)
    ruby_owners = @registry.fetch(plan.name, []).reject { |d| d.owner == '<native>' || d.owner.end_with?('.singleton') }
                           .to_set(&:owner)
    members.to_a.sort.each do |klass|
      next if klass == CallFacts::CLASS_OBJECT
      return :module_member if @world.module_declared?(klass)

      resolved = resolve(klass, definers, ruby_owners)
      return :"unresolved_#{klass}" unless resolved
      return :"no_arm_#{resolved.last}" if resolved.first == :native && !plan.natives.include?(resolved.last)

      plan.resolution[klass] = resolved
    end
    nil
  end
end
