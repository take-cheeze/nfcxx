# frozen_string_literal: true

# INTERFACE_TABLE (ADR 0328): shared, uniform adapters for exact-class implementations.
# A table changes dispatch shape; the existing closed-world proof still decides its miss.
module InterfaceTables
  INTERFACE_TABLE_MIN = 5

  def compile_poly_small_n(name, d, recv, argv, n, closed_world_site: nil)
    compile_interface_table(name, d, recv, argv, n, closed_world_site) || super
  end

  def compile_interface_table(name, d, recv, argv, n, site)
    return nil unless ENV['BC2CPP_INTERFACE_TABLES'] == '1' && @closed_world && site && !@call_block_expr
    return nil unless @closed_world.global_refusal.nil? && @closed_world.exact_instances_singleton_free?
    return nil if devirt_blocked_name?(name) || symbol_installed_names.nil? || symbol_installed_names.include?(name)
    return nil unless @closed_world.visibility_stable?(name)

    rows = interface_rows(name, n)
    return nil unless rows.size.between?(INTERFACE_TABLE_MIN, CodeGen::POLY_TABLE_MAX)

    @poly_tables ||= {}
    table = @poly_tables[[:interface, name, n, rows]] ||= {
      name: name, entries: rows, interface: true, symbol: "bc2cpp_poly_table_#{@poly_tables.size}"
    }
    fallback = guarded_fallback_line(d, recv, name, argv, rows.map(&:first), site)
    fn_type = "mrb_value (*)(#{(['mrb_state*'] + Array.new(n + 1, 'mrb_value')).join(', ')})"
    "  // INTERFACE_TABLE :#{name}/#{n} -> #{table[:symbol]} (#{rows.size} exact classes)\n" \
      "  if (bc2cpp_poly_fn bc2cpp_pfn = bc2cpp_poly_lookup(M, mrb_obj_class(M, #{recv}), #{table[:symbol]})) {\n" \
      "    r#{d} = reinterpret_cast<#{fn_type}>(bc2cpp_pfn)(M, #{([recv] + argv).join(', ')});\n" \
      "  } else {\n    #{fallback}  }\n"
  end

  # Per-class adapters are independent of call-site register and argument facts.
  def interface_rows(name, n)
    with_fresh_method_state do
      argv = Array.new(n) { |i| "arg#{i}" }
      rows = {}
      candidates = poly_candidates(name, n, optional: true) || []
      inherited = poly_inherited(name, candidates)
      candidates.each do |target|
        next unless target.visibility == :public && @closed_world.visibility_stable?(name)

        body = if target.irep
                 impl = "#{cpp_name(target.owner, target.name)}_impl"
                 args, = direct_call_args(target, argv, impl)
                 "return #{impl}(M, #{(['recv'] + args).join(', ')});"
               else
                 call = ivar_accessor_call_code(target.owner, 'recv', name, 0, argv)
                 next unless call

                 "mrb_value r0 = mrb_nil_value();\n  #{call}\n  return r0;"
               end
        ([target.owner] + inherited.fetch(target.owner)).each do |klass|
          next if %w[Class Module].include?(klass)
          next unless @closed_world.stable_constant_identity?(klass) && call_facts_native_free?(name, [klass])

          rows[klass] = interface_adapter(name, n, body)
        end
      end
      native_core_entries(name, n).each do |entry|
        # Class equality cannot distinguish Integer's immediate and bigint tags.
        next unless entry.arg == :none && %w[Array String].include?(entry.owner)
        next unless @closed_world.stable_constant_identity?(entry.owner)

        rows[entry.owner] = interface_adapter(name, n, "return #{entry.call('recv', argv)};")
      end
      plan = native_direct_plan(name, n, closed_world_site: true)
      (plan && plan[:arms] || {}).each do |owner, (function, kinds)|
        # Coercing integer arguments needs the wrapper's call frame on a miss.
        next if kinds.include?(:int)
        next unless @closed_world.stable_constant_identity?(owner)

        args = argv.each_with_index.map { |arg, i| kinds[i] == :bool ? "mrb_test(#{arg})" : arg }
        @native_construct_used << owner
        rows[owner] = interface_adapter(name, n, "return rgss::#{function}(#{(['M', 'recv'] + args).join(', ')});")
      end
      rows.sort
    end
  end

  def interface_adapter(name, n, body)
    @interface_adapters ||= {}
    key = [name, n, body]
    (@interface_adapters[key] ||= {
      symbol: "bc2cpp_interface_adapter_#{@interface_adapters.size}", arity: n, body: body
    })[:symbol]
  end

  def interface_adapters_used(codes)
    symbols = poly_tables_used(codes).select { |t| t[:interface] }.flat_map { |t| t[:entries].map(&:last) }.to_set
    (@interface_adapters || {}).values.select { |a| symbols.include?(a[:symbol]) }
  end

  def emit_native_core_helpers(codes)
    adapters = interface_adapters_used(codes).map { |a| { code: a[:body] } }
    super(codes + adapters)
  end

  def emit_poly_tables(codes)
    adapters = interface_adapters_used(codes).map do |a|
      params = ['mrb_state* M', 'mrb_value recv'] + Array.new(a[:arity]) { |i| "mrb_value arg#{i}" }
      "static mrb_value #{a[:symbol]}(#{params.join(', ')}) {\n  #{a[:body]}\n}\n"
    end.join
    adapters + super
  end
end

CodeGen.prepend(InterfaceTables)
