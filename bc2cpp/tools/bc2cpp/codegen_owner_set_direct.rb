# frozen_string_literal: true

# OWNER_SET_DIRECT: an owner call (OUTSIDE_OWNER_CALL / NAME_OWNER_SET) whose name's every owner is an audited mruby
# native with a fixed answer is computed in place, with no method lookup. NAME_OWNER_SET lists every class whose
# definition of the name a lookup can find; when each listed owner's registration is a row of
# NativeCoreDirect::OWNER_SET_ENTRIES (its function and body checked against the mruby source), the receiver's
# method is one of those bodies, and OWNER_SET_ROWS gives the one expression they all agree on:
#
#   - `nil?` over Kernel (mrb_false) and NilClass (mrb_true): mrb_nil_p(recv);
#   - `respond_to?(sym[, priv])` over Kernel (obj_respond_to): mrb_respond_to(recv, sym), because the only
#     respond_to_missing? anywhere is Kernel's mrb_false default, which obj_respond_to skips.
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
  Row = Struct.new(:owners, :argc, :expression, :arg_guard, :requires, keyword_init: true)

  OWNER_SET_ROWS = {
    'nil?' => Row.new(owners: %w[Kernel NilClass], argc: [0], expression: 'mrb_bool_value(mrb_nil_p(%<recv>s))',
                      arg_guard: nil, requires: []),
    'respond_to?' => Row.new(owners: %w[Kernel], argc: [1, 2],
                             expression: 'mrb_bool_value(mrb_respond_to(M, %<recv>s, mrb_symbol(%<a>s)))',
                             arg_guard: 'mrb_symbol_p(%<a>s)', requires: %w[respond_to_missing?])
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
      next unless row

      out << code[pos...m.begin(0)] << owner_set_direct_code(m, row, argv)
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
    return false unless owners.all? { |owner| owner_set_entry_verified?(name, owner) }

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

  def owner_set_entry_verified?(name, owner)
    entry = NativeCoreDirect::OWNER_SET_ENTRIES.find { |row| row.name == name && row.owner == owner }
    return false unless entry && @native_name_sources

    NativeCoreDirect.verified?(@native_name_sources.values.flatten.uniq, entry) &&
      owner_set_name_native_only?(name)
  end
end

CodeGen.prepend(OwnerSetDirect)
