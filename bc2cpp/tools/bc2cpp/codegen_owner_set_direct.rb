# frozen_string_literal: true

# OWNER_SET_DIRECT: an owner call (OUTSIDE_OWNER_CALL / NAME_OWNER_SET) whose name's every owner is an audited mruby
# native with a fixed answer is computed in place, with no method lookup. NAME_OWNER_SET lists every class whose
# definition of the name a lookup can find; when each listed owner's registration is a row of
# NativeCoreDirect::OWNER_SET_ENTRIES (its function and body checked against the mruby source), the receiver's
# method is one of those bodies, and OWNER_SET_ROWS gives the one expression they all agree on:
#
#   - `nil?` over Kernel (mrb_false) and NilClass (mrb_true): mrb_nil_p(recv);
#   - `respond_to?(sym[, priv])` over Kernel (obj_respond_to): mrb_respond_to(recv, sym), because the only
#     respond_to_missing? anywhere is Kernel's mrb_false default, which obj_respond_to skips;
#   - `dup` over Kernel (mrb_obj_dup) and Module (mrb_mod_dup): mrb_obj_dup(recv) for a receiver that is not a
#     class or module. Only a class/module-typed value can have Module among its ancestors, so the receiver guard
#     (recv_guard) is what rules Module's body out, and only Kernel's row needs auditing (verify);
#   - `object_id` over Kernel (mrb_obj_id_m) and `__to_int` over Kernel (mrb_ensure_int_type, the API itself).
#
# OWNER_SET_NATIVE_ARMS: an owner call whose name has no row above still gets exact-class arms for each owner whose
# registration is a NativeCoreDirect::OWNER_ARM_ENTRIES (or NUMERIC_CONVERSION_ENTRIES) row, the receiver and
# argument guards of that row in front and the owner call as the else: `to_i` on an Integer or a finite, fixable
# Float, `to_f` on an Integer or Float, `<=>` between fixnums and Floats, `bytesize` on an exact String, `keys` on an
# exact Hash. Each arm is NATIVE_CORE_DIRECT's (native_core_entry_safe?: verified body, no project definition on the
# class, no prepend, no installer); an arm a guard earlier in the method already tests is left out.
#
# The name must have no Ruby definer and no runtime installer (ClosedWorld#ownerless_native_dispatch_safe?,
# symbol_installed_names), and every receiver must include Kernel (kernel_receiver_sealed?; otherwise a Kernel guard
# keeps a bare BasicObject on the owner call, whose NoMethodError is unchanged). An argument the row cannot take (a
# String for respond_to?) also keeps the owner call. Both methods are public and the call's argument count fits
# their aspec, so the owner call's visibility and arity checks would pass.
#
# Like STATIC_OWNER_ARMS this rewrites the owner-call line after compile_method finishes, so every pass matching that
# line has seen it. BC2CPP_OWNER_SET_DIRECT=0 turns it off.
module OwnerSetDirect
  # `verify`: the owners whose rows must be audited (default: all of `owners`); `recv_guard`: a receiver test the
  # expression needs, the owner call taking any other receiver.
  Row = Struct.new(:owners, :argc, :expression, :arg_guard, :requires, :recv_guard, :verify, keyword_init: true) do
    def audited
      verify || owners
    end
  end

  OWNER_SET_ROWS = {
    'nil?' => Row.new(owners: %w[Kernel NilClass], argc: [0], expression: 'mrb_bool_value(mrb_nil_p(%<recv>s))',
                      arg_guard: nil, requires: []),
    'respond_to?' => Row.new(owners: %w[Kernel], argc: [1, 2],
                             expression: 'mrb_bool_value(mrb_respond_to(M, %<recv>s, mrb_symbol(%<a>s)))',
                             arg_guard: 'mrb_symbol_p(%<a>s)', requires: %w[respond_to_missing?]),
    'dup' => Row.new(owners: %w[Kernel Module], verify: %w[Kernel], argc: [0], expression: 'mrb_obj_dup(M, %<recv>s)',
                     recv_guard: '!(mrb_class_p(%<r>s) || mrb_module_p(%<r>s) || mrb_sclass_p(%<r>s))',
                     arg_guard: nil, requires: []),
    'object_id' => Row.new(owners: %w[Kernel], argc: [0], expression: 'mrb_fixnum_value(mrb_obj_id(%<recv>s))',
                           arg_guard: nil, requires: []),
    '__to_int' => Row.new(owners: %w[Kernel], argc: [0], expression: 'mrb_ensure_int_type(M, %<recv>s)',
                          arg_guard: nil, requires: [])
  }.freeze

  OWNER_SET_LINE = %r{^(?<indent>[ \t]*)(?<dest>r\d+)\ =\ (?<call>bc2cpp_owner_call_named\(M,\ (?<recv>r\d+|self),
    \ "(?<name>[^"]+)",\ \d,\ BC2CPP_OWNERS\([^)]*\),\ mrb_nil_value\(\),\ (?<argc>\d+)(?<args>(?:,\ r\d+)*)\);
    \ /\*\ CLOSED_WORLD\ owner-call:\ \S+\ \*/)$}x

  def compile_method(label)
    @owner_set_direct_stack ||= []
    outer = !@owner_set_direct_stack.include?(label)
    @owner_set_direct_stack.push(label)
    begin
      result = super
      outer ? owner_set_direct_expand(result) : result
    ensure
      @owner_set_direct_stack.pop
    end
  end

  # The argument's IR proof survives register shifts in inlined blocks; Symbol values cannot change type.
  def owner_set_symbol_probe_code(name, d, recv, argv, irep, idx, offset)
    return nil unless name == 'respond_to?' && [1, 2].include?(argv.size) && irep && idx
    return nil if ENV['BC2CPP_OWNER_SET_DIRECT'] == '0' || ENV['BC2CPP_SYMBOL_PROBE_DIRECT'] == '0'

    reg = argv.first[/\Ar(\d+)\z/, 1]&.to_i
    return nil unless reg && exact_literal(irep, idx, reg.to_i - offset)&.klass == :Symbol

    row = owner_set_direct_row(name, argv.size)
    return nil unless row

    expr = format(row.expression, recv: recv, a: argv.first)
    note = "  // SYMBOL_PROBE_DIRECT :respond_to? -- proven Symbol argument, audited Kernel body\n"
    return "#{note}  r#{d} = #{expr};\n" if kernel_receiver_sealed?(owner_call_world)

    "#{note}  if (mrb_obj_is_kind_of(M, #{recv}, M->kernel_module)) {\n" \
      "    r#{d} = #{expr};\n  } else {\n    #{dynamic_dispatch_line(d, recv, name, argv).chomp}\n  }\n"
  end

  private

  def owner_set_direct_expand(result)
    return result unless result.is_a?(Hash) && result[:code].is_a?(String) && !result[:unsupported]
    return result if ENV['BC2CPP_OWNER_SET_DIRECT'] == '0' || @clean_probe || !owner_call_world
    return result unless result[:code].include?('CLOSED_WORLD owner-call')

    code = result[:code]
    out = +''
    pos = 0
    code.to_enum(:scan, OWNER_SET_LINE).each do
      m = Regexp.last_match
      argv = m[:args].scan(/r\d+/)
      next unless argv.size == m[:argc].to_i

      row = owner_set_direct_row(m[:name], argv.size)
      replacement = if row
                      owner_set_direct_code(m, row, argv)
                    else
                      owner_set_native_arms_code(m, argv, code[[m.begin(0) - 4000, 0].max...m.begin(0)])
                    end
      next unless replacement

      out << code[pos...m.begin(0)] << replacement
      pos = m.end(0)
    end
    return result if pos.zero?

    out << code[pos..]
    result.merge(code: out)
  end

  def owner_set_direct_code(m, row, argv)
    ind = m[:indent]
    expr = format(row.expression, recv: m[:recv], a: argv.first)
    guards = []
    guards << "mrb_obj_is_kind_of(M, #{m[:recv]}, M->kernel_module)" unless kernel_receiver_sealed?(owner_call_world)
    guards << format(row.recv_guard, r: m[:recv]) if row.recv_guard
    guards << format(row.arg_guard, a: argv.first) if row.arg_guard
    note = "#{ind}// OWNER_SET_DIRECT :#{m[:name]} -> #{row.owners.join(', ')}: every owner is an audited mruby native; " \
           "no lookup\n"
    return "#{note}#{ind}#{m[:dest]} = #{expr};" if guards.empty?

    "#{note}#{ind}if (#{guards.join(' && ')}) {\n#{ind}  #{m[:dest]} = #{expr};\n#{ind}} else {\n" \
      "#{ind}  #{m[:dest]} = #{m[:call]}\n#{ind}}"
  end

  # The row for an owner call of `name` with `argc` arguments, or nil when the proof does not hold.
  def owner_set_direct_row(name, argc)
    @owner_set_direct_rows ||= {}
    key = [name, argc]
    return @owner_set_direct_rows[key] if @owner_set_direct_rows.key?(key)

    row = OWNER_SET_ROWS[name]
    @owner_set_direct_rows[key] = row && row.argc.include?(argc) && owner_set_direct_safe?(name, row) ? row : nil
  end

  def owner_set_direct_safe?(name, row)
    owners = name_owner_set(name)
    return false unless owners && !owners.empty? && (owners - row.owners).empty?
    return false unless row.audited.all? { |owner| owner_set_entry_verified?(name, owner) }

    row.requires.all? do |required|
      outside_owner_call_owners(required) == ['Kernel'] && owner_set_entry_verified?(required, 'Kernel')
    end && owner_set_name_native_only?(name)
  end

  # `name` has only native definers, nothing installs it at run time, and nothing blocks devirtualizing it.
  def owner_set_name_native_only?(name)
    installed = symbol_installed_names
    return false if installed.nil? || installed.include?(name) || devirt_blocked_name?(name)

    owner_call_world.ownerless_native_dispatch_safe?(name)
  end

  # OWNER_SET_NATIVE_ARMS: the arms for this owner-call line, or nil when no owner of its name has an audited row
  # that applies. `seen` is the method's text before the line; an arm whose guard is already there was tested.
  def owner_set_native_arms_code(m, argv, seen)
    owners = m[:call][/BC2CPP_OWNERS\(([^)]*)\)/, 1].to_s.scan(/"([^"]+)"/).flatten
    entries = owner_set_arm_entries(m[:name], argv.size).select { |entry| owners.include?(entry.owner) }
    entries = entries.reject { |entry| seen.include?(entry.guard(m[:recv], argv)) }
    return nil if entries.empty?

    ind = m[:indent]
    note = "#{ind}// OWNER_SET_NATIVE_ARMS :#{m[:name]} -> #{entries.map(&:owner).join(', ')}: exact receiver, the " \
           "audited core body; the owner call for any other\n"
    branches = entries.map do |entry|
      "if (#{entry.guard(m[:recv], argv)}) {\n#{ind}  #{m[:dest]} = #{entry.call(m[:recv], argv)};\n#{ind}} else "
    end
    "#{note}#{ind}#{branches.join}{\n#{ind}  #{m[:dest]} = #{m[:call]}\n#{ind}}"
  end

  ARM_ENTRY_SOURCES = %i[OWNER_ARM_ENTRIES NUMERIC_CONVERSION_ENTRIES].freeze

  def owner_set_arm_entries(name, argc)
    return [] if devirt_blocked_name?(name)

    world = block_core_world
    return [] unless world && @native_name_sources

    @owner_set_arm_entries ||= {}
    @owner_set_arm_entries.fetch([name, argc]) do
      rows = ARM_ENTRY_SOURCES.flat_map { |source| NativeCoreDirect.const_get(source) }
      @owner_set_arm_entries[[name, argc]] = rows.select do |entry|
        entry.name == name && entry.arity == argc && native_core_entry_safe?(entry, world)
      end
    end
  end

  def owner_set_entry_verified?(name, owner)
    entry = NativeCoreDirect::OWNER_SET_ENTRIES.find { |row| row.name == name && row.owner == owner }
    return false unless entry && @native_name_sources

    NativeCoreDirect.verified?(@native_name_sources.values.flatten.uniq, entry) &&
      owner_set_name_native_only?(name)
  end
end

CodeGen.prepend(OwnerSetDirect)
