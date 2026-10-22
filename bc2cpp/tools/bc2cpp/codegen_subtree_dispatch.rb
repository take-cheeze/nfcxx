# frozen_string_literal: true

require 'set'
require_relative 'subtree_facts'

# SUBTREE_DISPATCH (docs/adr/0453): a send whose receiver carries a SUBTREE(A) hint (subtree_facts.rb) is dispatched
# over A's closed subtree instead of the name-wide POLY_SMALL_N chain or POLY_TABLE.
#
# For every class K in the subtree the closed-world lookup (closed_world_lookup_target) names the definition `N`
# resolves to. When every K resolves to one definition the site is one direct call behind a subtree membership guard
# (SUBTREE_DIRECT, `mrb_obj_is_kind_of`). Otherwise the site indexes a per-root slot table (SUBTREE_TABLE): one row per
# class of the subtree, one column per (name, argc) used on it, shared by every site of the root; a class outside the
# rows, or a null slot (no Ruby `_impl` of the plain shape: native, accessor, arity, block parameter), takes the else
# arm. The else arm is guarded_fallback_line, listing only the classes the site calls directly; it is forced only when
# BC2CPP_STRICT_HINTS names the `subtree` family, which is outside the default set.
class CodeGen
  class << self
    attr_accessor :subtree_facts
  end

  SUBTREE_TABLE_MEMO = 8

  def subtree_dispatch_enabled?
    !CodeGen.subtree_facts.nil? && !CodeGen.subtree_facts.empty?
  end

  # The code for the site, or nil to leave it to the name-wide chains.
  def compile_subtree_dispatch(name, n, d, recv, argv, irep, proof_idx, proof_reg, owner_def, site)
    return nil unless subtree_dispatch_enabled? && @closed_world && site && !@call_block_expr

    root = subtree_receiver_root(irep, proof_idx, proof_reg, owner_def)
    if root.nil? && ENV['BC2CPP_SUBTREE_DEBUG'] && CodeGen.subtree_facts.ivars[owner_def&.owner]
      warn "  SUBTREE_UNTRACED :#{name}/#{n} in #{owner_def.owner}##{owner_def.name}"
    end
    return nil unless root

    plan = subtree_plan(root, name, n)
    warn "  SUBTREE_REFUSED :#{name}/#{n} on #{root}: #{@subtree_refusal}" if plan.nil? && ENV['BC2CPP_SUBTREE_DEBUG']
    return nil unless plan

    return subtree_direct_code(plan, root, name, d, recv, argv, site) if plan[:direct]

    subtree_table_code(plan, root, name, n, d, recv, argv, site)
  end

  # The root A of the receiver's SUBTREE(A) hint: the same receiver trace TYPED runs, fed only the subtree tables.
  def subtree_receiver_root(irep, proof_idx, proof_reg, owner_def)
    facts = CodeGen.subtree_facts
    return nil unless irep && proof_idx && proof_reg

    owner = owner_def&.owner
    ivars = owner && facts.ivars[owner]
    args = facts.args[irep.label]
    return nil if ivars.nil? && args.nil? && facts.returns.empty?

    mand = irep.enter ? irep.enter.enter_fields.first : 0
    returns = ->(called, *) { subtree_return_root(called) }
    root = trace_new_target(irep, proof_idx, proof_reg, ivars, mand, args, owner: owner, method_return_class: returns,
                                                                         ret_class_proof: returns, guarded: true)
    root if facts.roots.include?(root)
  end

  # A name every Ruby definition of which declares the same SUBTREE return (a hint, as method_return_class is).
  def subtree_return_root(name)
    @subtree_return_roots ||= {}
    return @subtree_return_roots[name] if @subtree_return_roots.key?(name)

    defs = @registry.fetch(name, [])
    roots = defs.map { |definition| definition.irep && CodeGen.subtree_facts.returns[definition.irep] }.uniq
    @subtree_return_roots[name] = !defs.empty? && roots.one? ? roots.first : nil
  end

  # { direct: MethodDef } or { rows: { klass => MethodDef or nil } }, or nil when the site keeps the chains.
  def subtree_plan(root, name, n)
    classes = subtree_classes(root, name)
    return nil unless classes

    resolved = classes.to_h do |klass|
      target, known = closed_world_lookup_target(name, klass, Set.new, any_visibility: true)
      # A native definition the registry cannot place (`<native>`) could sit on an ancestor the walk passed over;
      # a Ruby definition reached only through declared classes nothing outside touches cannot be shadowed by it.
      known = false if known && !(target && subtree_chain_untouched?(klass, target.owner))
      [klass, known ? target : :unknown]
    end
    targets = resolved.values.uniq
    if targets.one? && targets.first.is_a?(MethodDef) && targets.first.visibility == :public &&
       cha_unready_reason(targets.first, name, n, true, classes).nil?
      return { direct: targets.first, classes: classes }
    end

    rows = resolved.transform_values { |target| subtree_slot_ready?(target, n) ? target : nil }
    return nil if rows.values.none?

    { rows: rows, classes: classes }
  end

  # Root and descendants, or nil when the name cannot be judged over them (CHA_SELF's gates, plus visibility).
  def subtree_classes(root, name)
    world = @closed_world
    installed = symbol_installed_names
    @subtree_refusal =
      if !SubtreeFacts.closed_root?(root, world) then :open_hierarchy
      elsif !world.exact_instances_singleton_free? then :singleton_maker
      elsif devirt_blocked_name?(name) then :runtime_definition
      elsif !world.inherited_lookup_safe?(name, root) then :unsafe_name
      elsif !world.visibility_stable?(name) then :visibility
      elsif installed.nil? || installed.include?(name) then :installed_name
      elsif !world.self_method_missing_free?(root) then :method_missing
      end
    return nil if @subtree_refusal

    @subtree_refusal = :no_callable_definition

    [root] + world.class_hierarchy(root)[:descendants].sort
  end

  # Every class from `klass` up to `owner` (the definer, or a module mixed in on the way) is declared and untouched
  # by outside sources, so no native definition sits between them.
  def subtree_chain_untouched?(klass, owner)
    seen = Set.new
    current = klass
    while current.is_a?(String) && seen.add?(current)
      return false unless @closed_world.class_declared?(current) && @closed_world.untouched_class?(current)
      mixins = Array(@included_modules[current]) + Array(@prepended_modules[current])
      return true if current == owner || mixins.include?(owner)

      current = @superclass_of[current]
    end
    false
  end

  # Can a table slot hold `target`'s `_impl`, called as `fn(M, recv, args...)` with `n` arguments (POLY_TABLE's
  # shape)?
  def subtree_slot_ready?(target, n)
    return false unless target.is_a?(MethodDef) && target.irep && target.visibility == :public && !target.core
    return false if target.owner.end_with?('.singleton')
    return false if @only_owners && !@only_owners.include?(target.owner) && !@other_owners&.include?(target.owner)
    return false unless compiles_clean?(target.irep)

    irep = @ireps.fetch(target.irep)
    poly_arity_fits?(irep, n, false) && native_arg_types(target, mandatory_arity(irep)).compact.empty? &&
      !takes_block_param?(irep)
  end

  def subtree_fallback(name, d, recv, argv, listed, site)
    strict_hint_wrap('subtree', d, recv, name, argv, nil, listed: listed) do
      guarded_fallback_line(d, recv, name, argv, listed, site)
    end
  end

  def subtree_direct_code(plan, root, name, d, recv, argv, site)
    target = plan[:direct]
    call = cha_call_code(target, root, recv, name, d, argv, indent: '    ')
    note = "  // SUBTREE_DIRECT :#{name} -> #{target.owner}##{target.name} (receiver hint: #{root} or a descendant; " \
           "every class of the subtree resolves to it), subtree-membership-checked direct C++ call, " \
           "mrb_funcall fallback\n"
    "#{note}  {\n" \
      "  struct RClass* bc2cpp_sroot = #{owner_class_ptr_expr(root)};\n" \
      "  if (bc2cpp_sroot && mrb_obj_is_kind_of(M, #{recv}, bc2cpp_sroot)) {\n" \
      "    #{call}\n" \
      "  } else {\n" \
      "    #{subtree_fallback(name, d, recv, argv, plan[:classes], site)}" \
      "  }\n" \
      "  }\n"
  end

  def subtree_table_code(plan, root, name, n, d, recv, argv, site)
    table = subtree_table(root)
    rows = plan[:rows].transform_values { |target| target && "#{cpp_name(target.owner, target.name)}_impl" }
    slot = subtree_slot(table, name, n, rows)
    listed = plan[:rows].select { |_, target| target }.keys
    arms = plan[:rows].values.compact.uniq.map do |target|
      "#{target.owner}##{target.name} (#{plan[:rows].select { |_, t| t.equal?(target) }.keys.join(', ')})"
    end
    fn_type = "mrb_value (*)(#{(['mrb_state*'] + Array.new(n + 1, 'mrb_value')).join(', ')})"
    sym = table[:symbol]
    note = "  // SUBTREE_TABLE :#{name}/#{n} -> #{sym} slot #{slot} (receiver hint: #{root} or a descendant; " \
           "#{arms.join('; ')}), class row lookup then indexed direct C++ call, mrb_funcall fallback\n"
    "#{note}  {\n" \
      "  int bc2cpp_vrow = bc2cpp_vtbl_lookup(M, mrb_obj_class(M, #{recv}), #{sym});\n" \
      "  bc2cpp_vtbl_fn bc2cpp_vfn = bc2cpp_vrow >= 0 ? #{sym}_fns[bc2cpp_vrow][#{slot}] : nullptr;\n" \
      "  if (bc2cpp_vfn) {\n" \
      "    r#{d} = reinterpret_cast<#{fn_type}>(bc2cpp_vfn)(M, #{([recv] + argv).join(', ')});\n" \
      "  } else {\n" \
      "    #{subtree_fallback(name, d, recv, argv, listed, site)}" \
      "  }\n" \
      "  }\n"
  end

  # One table per root, shared by every name used on its subtree.
  def subtree_table(root)
    @subtree_tables ||= {}
    @subtree_tables[root] ||= { root: root, classes: subtree_table_classes(root), slots: {},
                                symbol: "bc2cpp_vtbl_#{@subtree_tables.size}" }
  end

  def subtree_table_classes(root)
    [root] + @closed_world.class_hierarchy(root)[:descendants].sort
  end

  # The column of (name, n); a later site of the same name and argc resolves the same rows.
  def subtree_slot(table, name, n, rows)
    column = (table[:slots][[name, n]] ||= { index: table[:slots].size, rows: rows })
    raise "bc2cpp: SUBTREE_TABLE #{table[:root]} :#{name}/#{n} resolved two ways" unless column[:rows] == rows

    column[:index]
  end

  def subtree_tables_used(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    (@subtree_tables || {}).values.select { |t| texts.any? { |text| text.include?("#{t[:symbol]});") } }
  end

  # `SUBTREE_TABLE` / `SUBTREE_DIRECT` sites per root, for the stderr summary.
  def subtree_site_counts(codes)
    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    texts.flat_map { |text| text.scan(%r{// (SUBTREE_TABLE|SUBTREE_DIRECT) :(\S+) -> .*?\(receiver hint: (\S+) or}) }
         .tally.sort_by { |key, _| key }
  end
end

# The tables' storage: OWNER_CLASS_CACHE slots (reserved with POLY_TABLE's), a lookup memo cleared with that cache,
# and the rows printed with the POLY tables.
module SubtreeDispatchTables
  def reserve_poly_table_slots(codes)
    super
    @subtree_tables_emitted = subtree_tables_used(codes)
    @subtree_tables_emitted.each_with_index do |t, i|
      t[:getters] = t[:classes].map { |owner| owner_class_fn_name(owner) }
      t[:cache_slots] = t[:classes].map { |owner| @owner_class_cache.fetch(owner)[:index] }
      t[:memo] = i * CodeGen::SUBTREE_TABLE_MEMO
    end
  end

  def emit_owner_class_cache
    out = super
    return out if @subtree_tables_emitted.nil? || @subtree_tables_emitted.empty?

    size = @subtree_tables_emitted.size * CodeGen::SUBTREE_TABLE_MEMO
    decl = "// SUBTREE_TABLE memo -- see codegen_subtree_dispatch.rb.\n" \
           "struct bc2cpp_vtbl_memo {\n  struct RClass* c;\n  int row;\n};\n" \
           "static bc2cpp_vtbl_memo bc2cpp_vtbl_memos[#{size}];\n"
    reset = "static void bc2cpp_reset_owner_classes() {\n"
    out.sub(reset) { "#{decl}#{reset}  for (bc2cpp_vtbl_memo& m : bc2cpp_vtbl_memos) m = {};\n" }
  end

  def emit_poly_tables(codes)
    out = super
    used = subtree_tables_used(codes)
    return out if used.empty?

    texts = codes.map { |c| c.is_a?(Hash) ? c[:code] : c }
    out + subtree_tables_cpp(used, texts)
  end

  def subtree_tables_cpp(used, texts)
    out = +<<~CPP
      // SUBTREE_TABLE -- see codegen_subtree_dispatch.rb. A row per class of one closed subtree, a column per
      // (name, argc) its sites use; the lookup is memoized like bc2cpp_poly_lookup.
      typedef void (*bc2cpp_vtbl_fn)(void);
      struct bc2cpp_vtbl_row {
        struct RClass* (*owner)(mrb_state*);
        int slot;
      };
      struct bc2cpp_vtbl {
        const bc2cpp_vtbl_row* rows;
        int n;
        bc2cpp_vtbl_memo* memo;
      };
      [[gnu::noinline]] static int bc2cpp_vtbl_lookup(mrb_state* M, struct RClass* c, const bc2cpp_vtbl& t) {
        if (bc2cpp_owner_class_state != M) {
          bc2cpp_reset_owner_classes();
          bc2cpp_owner_class_state = M;
        }
        uintptr_t h = reinterpret_cast<uintptr_t>(c);
        bc2cpp_vtbl_memo& m = t.memo[((h >> 4) ^ (h >> 10)) & #{CodeGen::SUBTREE_TABLE_MEMO - 1}];
        if (m.c == c) return m.row;
        int row = -1;
        for (int i = 0; i < t.n; ++i) {
          struct RClass* k = bc2cpp_owner_class_slots[t.rows[i].slot];
          if (k == c || (!k && t.rows[i].owner(M) == c)) {
            row = i;
            break;
          }
        }
        m.c = c;
        m.row = row;
        return row;
      }
    CPP
    used.each do |table|
      sym = table[:symbol]
      columns = table[:slots].sort_by { |_, column| column[:index] }
      # A column only a dropped method used stays null.
      live = columns.map do |_, column|
        texts.any? { |text| text.include?("#{sym}_fns[bc2cpp_vrow][#{column[:index]}]") }
      end
      out << "// SUBTREE_TABLE #{table[:root]}: #{columns.map { |(name, n), _| "#{name}/#{n}" }.join(', ')}\n"
      out << "static const bc2cpp_vtbl_row #{sym}_rows[] = {\n"
      table[:classes].zip(table.fetch(:getters), table.fetch(:cache_slots)).each do |owner, getter, slot|
        out << "  {#{getter}, #{slot}},  // #{owner}\n"
      end
      out << "};\n"
      out << "static const bc2cpp_vtbl_fn #{sym}_fns[#{table[:classes].size}][#{columns.size}] = {\n"
      table[:classes].each do |owner|
        cells = columns.each_with_index.map do |(_, column), i|
          impl = live[i] && column[:rows][owner]
          impl ? "reinterpret_cast<bc2cpp_vtbl_fn>(#{impl})" : 'nullptr'
        end
        out << "  {#{cells.join(', ')}},  // #{owner}\n"
      end
      out << "};\n"
      out << "static const bc2cpp_vtbl #{sym} = {#{sym}_rows, #{table[:classes].size}, " \
             "bc2cpp_vtbl_memos + #{table.fetch(:memo)}};\n"
    end
    out << "\n"
  end
end

CodeGen.prepend(SubtreeDispatchTables)
