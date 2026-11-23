# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'

# MULTI_RETURN: `x, y = f(...)` is `SEND; AREF; AREF`. When the SEND compiles to a direct call of a compiled method whose
# every return is a fresh literal `[e0, e1, ...]` of one length (tuple_shape), the caller passes a frame-local buffer and
# the callee writes the elements into it instead of building an Array (`X_mr(..., bc2cpp_mrv)`). `X_impl` stays the
# Array-returning entry for every other caller (a by-name send, a caller that keeps the result): it calls `X_mr` and
# builds the Array from the buffer, so a callee that no destructuring caller reaches keeps its plain body.
#
# A caller site is placed only when all of these hold (anything else keeps the Array):
#   shape     the AREFs that read the call's register follow the SEND directly, entered only from it (tuple_aref_call)
#   dead      no other instruction may read the call's register while it holds the SEND's value (the masgn's value,
#             a copy, a handler), so nothing sees that the Array was never made
#   direct    the SEND's text is exactly `rD = X_impl(args);`, X compiled by this unit (multi_return_unit_impls)
# A callee qualifies when tuple_shape holds, it is not core and has no declared parameter guard (a direct `X_mr` call
# would skip that check; a declared return holds by construction). Its own body is compiled a second time with each
# returned literal writing the buffer; when that second compile is not placed whole (or the callee is resumable), a
# caller still links against a fallback `X_mr` that unpacks `X_impl`'s Array (multi_return_link!).
#
# GC: an element in the buffer is the callee's C local, rooted as a returned value is; the caller's AREF stays an element
# read, so ELEMENT_READ_ROOTS keeps it when it is live across a call. BC2CPP_MULTI_RETURN=0 turns it off.
class CodeGen
  MULTI_RETURN_MAX = 8
  MULTI_RETURN_BUFFER = 'bc2cpp_mrv'
  MULTI_RETURN_OUT = 'bc2cpp_mr_out'

  def multi_return_enabled?
    ENV['BC2CPP_MULTI_RETURN'] != '0'
  end

  # {n:, sites: [[ARRAY index, lead, element regs]]} when +label+'s method qualifies as a callee, else nil.
  def multi_return_callee(label)
    @multi_return_callees ||= {}
    return @multi_return_callees[label] if @multi_return_callees.key?(label)

    @multi_return_callees[label] = multi_return_callee_uncached(label)
  end

  # The buffer name and the per-irep plan of the method being compiled, read by codegen_method's prologue.
  def multi_return_declarations(irep)
    state = @multi_return_state
    return '' unless state && state[:label] == irep.label && state[:size].positive?

    "  [[maybe_unused]] mrb_value #{MULTI_RETURN_BUFFER}[#{state[:size]}];\n"
  end

  # Called from the method's instruction loop, as stack_tuple_visit.
  def multi_return_visit(irep, idx, bypassed)
    state = @multi_return_state
    return unless bypassed && state && state[:label] == irep.label && state[:mapped].include?(idx)

    state[:bypassed] << idx
  end

  # True while the callee's second compile places the ARRAY at +idx+ (STACK_TUPLES leaves it alone then).
  def multi_return_site?(irep, idx)
    state = @multi_return_state
    !state.nil? && state[:label] == irep.label && state[:callee]&.key?(idx)
  end

  # The placed text for instruction +idx+, or nil (compile it as usual). +compile+ returns the usual text.
  def multi_return_insn(irep, idx, reg_offset)
    state = @multi_return_state
    return yield unless state && idx && irep && state[:label] == irep.label && state[:mapped].include?(idx)
    if reg_offset != 0 || @resumable
      state[:bypassed] << idx
      return yield
    end

    if (site = state[:callee]&.[](idx))
      state[:hooked] << idx
      return multi_return_out_text(site)
    end
    if (group = state[:groups][idx])
      text = yield
      call = multi_return_direct_call(text, group[:dest])
      return text unless call

      state[:placed][idx] = call
      state[:hooked] << idx
      return "#{call[:lead]}  #{call[:mr]}(#{call[:args]}, #{MULTI_RETURN_BUFFER});\n"
    end
    j = state[:aref_group][idx]
    call = state[:placed][j]
    return yield unless call

    state[:hooked] << idx
    dest, c = state[:groups][j][:arefs][idx]
    "  r#{dest} = #{c < call[:n] ? "#{MULTI_RETURN_BUFFER}[#{c}]" : 'mrb_nil_value()'};\n"
  end

  # Runs the block (the method's compile) under the caller plan of +label+, and again with the callee plan when the
  # method qualifies; the second text is the result's :mr_code. A caller group that was not placed whole (a path that
  # bypasses compile_insn, such as a rescue body's own function) is dropped and the method compiles again.
  def multi_return_compile_method(label, &compile)
    return compile.call unless multi_return_enabled?

    irep = @ireps.fetch(label)
    @multi_return_kept ||= {}
    groups = @multi_return_kept[label] || multi_return_groups(irep)
    result = nil
    loop do
      result, bad, = multi_return_run(label, groups, nil, &compile)
      break if bad.empty?

      groups = groups.reject { |j, _| bad.include?(j) }
    end
    @multi_return_kept[label] = groups
    multi_return_report(label, groups, result)
    # A cleanliness probe's text is never emitted, so it needs no second compile.
    return result if @probing && !@probing.empty?

    callee = multi_return_callee(label)
    return result unless callee && result.is_a?(Hash) && !result[:resumable] && result[:code].is_a?(String)

    head = multi_return_head(result)
    return result unless head

    result[:mr] = head.merge(n: callee[:n])
    second, bad, whole = multi_return_run(label, groups, callee, &compile)
    code = bad.empty? && whole && second.is_a?(Hash) && !second[:resumable] ? multi_return_split(second[:code], head, callee[:n]) : nil
    result[:mr_code] = code if code
    result
  end

  # MULTI_RETURN, the link step over one unit's compiled methods: a callee some caller's text names by its `X_mr`
  # gets the split body (or, without one, a fallback `X_mr` over `X_impl`) and a declaration.
  def multi_return_link!(compiled)
    providers = compiled.select { |m| m.is_a?(Hash) && m[:mr] }.to_h { |m| [m[:mr][:mr], m] }
    # Every `X_mr` a text calls (a callee's own recursive call included), before any split body is swapped in.
    used = compiled.flat_map { |m| m.is_a?(Hash) ? m[:code].to_s.scan(/\b(\w+_mr)\(M, /).flatten : [] }.uniq
    # A callee whose final compile kept no second text (it ran inside a probe, or is resumable) still has its `X_impl`.
    (used - providers.keys).each do |name|
      m = compiled.find { |c| c.is_a?(Hash) && c[:impl] == "#{name.delete_suffix('_mr')}_impl" }
      callee = m && m[:label] && multi_return_callee(m[:label])
      head = callee && multi_return_head(m)
      raise "MULTI_RETURN: #{name} called with no definition in this unit" unless head

      m[:mr] = head.merge(n: callee[:n])
      providers[name] = m
    end

    used.each do |name|
      m = providers.fetch(name)
      m[:code] = m[:mr_code] || "#{m[:code]}#{multi_return_fallback(m[:mr])}"
      m[:mr_decl] = "mrb_value #{name}(#{(m[:mr][:types] + ['mrb_value*']).join(', ')})"
    end
    compiled
  end

  private

  # BC2CPP_MULTI_RETURN_REPORT=1: per compiled method, its candidate groups and whether the plan was placed whole.
  def multi_return_report(label, groups, result)
    return unless ENV['BC2CPP_MULTI_RETURN_REPORT'] == '1'

    warn "bc2cpp multi return #{label}: groups #{groups.keys} callee #{multi_return_callee(label)&.fetch(:n).inspect} " \
         "#{result ? 'placed' : 'refused'}"
  end

  def multi_return_callee_uncached(label)
    return nil unless multi_return_enabled?

    irep = @ireps[label]
    d = @owner_of[label]
    return nil if irep.nil? || d.nil? || d.core
    return nil unless declared_param_guards(label).empty?

    found = tuple_shape(irep)
    return nil unless found

    prog = BytecodeIR.for(irep)
    n = found.first[1]
    return nil unless n.between?(1, MULTI_RETURN_MAX)

    sites = found.map do |idx, _|
      lit = prog.container_literal(idx)
      return nil unless lit && lit.kind == :array && lit.count == n

      [idx, prog.source_at(idx).reg.to_i, lit.value_regs.map(&:to_i)]
    end
    { n: n, sites: sites.to_h { |idx, lead, elems| [idx, { lead: lead, elems: elems }] } }
  end

  # impl name => label for every method this unit compiles that qualifies as a callee (compile_all's leaves).
  # Empty before compile_all has chosen the unit (an analysis probe compiles methods earlier).
  def multi_return_unit_impls
    return {} unless @unit_leaves

    @multi_return_unit_impls ||= begin
      names = Hash.new { |h, k| h[k] = [] }
      @unit_leaves.each do |label|
        d = @owner_of[label]
        names["#{cpp_name(d.owner, d.name)}_impl"] << label if d && multi_return_callee(label)
      end
      names.select { |_, labels| labels.size == 1 }.transform_values(&:first)
    end
  end

  # The largest tuple any callee named +name+ returns, or nil when none qualifies.
  def multi_return_name_size(name)
    @multi_return_name_sizes ||= {}
    return @multi_return_name_sizes[name] if @multi_return_name_sizes.key?(name)

    sizes = (@registry[name] || []).filter_map { |d| d.irep && multi_return_callee(d.irep)&.fetch(:n) }
    @multi_return_name_sizes[name] = sizes.max
  end

  # {SEND index => {dest:, name:, arefs: {AREF index => [dest, literal index]}}} for +irep+'s destructured calls that
  # hold the shape and dead conditions.
  def multi_return_groups(irep)
    @multi_return_groups ||= {}
    return @multi_return_groups[irep.label] if @multi_return_groups.key?(irep.label)

    @multi_return_groups[irep.label] = multi_return_groups_uncached(irep)
  end

  def multi_return_groups_uncached(irep)
    prog = BytecodeIR.for(irep)
    return {} unless prog.resolved? && prog.handlers_resolved?

    groups = {}
    prog.instructions.each do |ins|
      next unless ins.op == :AREF

      src, c = ins.source.src_and_literal
      name = src && tuple_aref_call(irep, ins.index, src)
      next unless name && multi_return_name_size(name)

      j = BytecodeIR.reaching_writer_indices(irep, ins.index, src)&.first
      next unless j

      group = (groups[j] ||= { dest: src.to_i, name: name, arefs: {} })
      group[:arefs][ins.index] = [ins.source.reg.to_i, c.to_i]
    end
    params = stack_tuple_params(irep)
    groups.select { |j, group| multi_return_dead?(irep, prog, j, group, params) }
  end

  # No instruction but the group's AREFs reads the call's register while it may hold the call's value.
  def multi_return_dead?(irep, prog, j, group, params)
    dest = group[:dest]
    return false if dest.between?(1, params + 1)

    prog.instructions.all? do |ins|
      i = ins.index
      next true if i == j || group[:arefs].key?(i)

      # A MOVE reads only its source (stack_tuple_reads leaves copies to its reaching definitions).
      reads = ins.op == :MOVE ? [ins.source.regs[1].to_i] : stack_tuple_reads(ins.source, params)
      next true unless reads == :all || reads.include?(dest)

      prods = BytecodeIR.producers(irep, i, dest, through_handlers: true)
      !prods.nil? && prods.none? { |p| !p.entry? && p.index == j }
    end
  end

  # One compile under a plan: [result, the groups not placed whole, whether every callee site was placed].
  def multi_return_run(label, groups, callee)
    return [yield, Set.new, true] if groups.empty? && callee.nil?

    size = groups.values.map { |g| multi_return_name_size(g[:name]) }.max.to_i
    mapped = Set.new
    aref_group = {}
    groups.each do |j, g|
      mapped << j
      g[:arefs].each_key { |k| mapped << k; aref_group[k] = j }
    end
    callee&.[](:sites)&.each_key { |k| mapped << k }
    state = { label: label, groups: groups, aref_group: aref_group, callee: callee && callee[:sites], size: size,
              mapped: mapped, placed: {}, hooked: Set.new, bypassed: Set.new }
    saved = @multi_return_state
    @multi_return_state = state
    result = begin
      yield
    ensure
      @multi_return_state = saved
    end
    [result, multi_return_unplaced(state), multi_return_callee_whole?(state)]
  end

  # A group is placed whole when none of its instructions was bypassed and, if its call was placed, every AREF was.
  def multi_return_unplaced(state)
    state[:groups].each_with_object(Set.new) do |(j, g), bad|
      idxs = [j, *g[:arefs].keys]
      bad << j if idxs.any? { |k| state[:bypassed].include?(k) } ||
                  (state[:placed].key?(j) && !g[:arefs].each_key.all? { |k| state[:hooked].include?(k) })
    end
  end

  def multi_return_callee_whole?(state)
    sites = state[:callee]
    sites.nil? || sites.each_key.all? { |k| state[:hooked].include?(k) && !state[:bypassed].include?(k) }
  end

  # The elements are copied before the destination is cleared: the destination may be one of them.
  def multi_return_out_text(site)
    copies = site[:elems].each_with_index.map { |reg, k| "  #{MULTI_RETURN_OUT}[#{k}] = r#{reg};\n" }
    (copies + ["  r#{site[:lead]} = mrb_nil_value();\n"]).join
  end

  # Blank and `//` comment lines may lead the call; they are kept.
  MULTI_RETURN_DIRECT_CALL = %r{\A((?:[ \t]*(?://[^\n]*)?\n)*)  r(\d+) = ([A-Za-z_]\w*_impl)\(([\w, ()]*)\);\n\z}.freeze

  # {mr:, args:, n:} when +text+ is exactly a direct call of a qualifying callee of this unit into r+dest+.
  def multi_return_direct_call(text, dest)
    m = MULTI_RETURN_DIRECT_CALL.match(text)
    return nil unless m && m[2].to_i == dest && multi_return_balanced?(m[4])

    label = multi_return_unit_impls[m[3]]
    callee = label && multi_return_callee(label)
    return nil unless callee && callee[:n] <= @multi_return_state[:size]

    { lead: m[1], mr: "#{m[3].delete_suffix('_impl')}_mr", args: m[4], n: callee[:n] }
  end

  def multi_return_balanced?(args)
    depth = 0
    args.each_char do |ch|
      depth += 1 if ch == '('
      depth -= 1 if ch == ')'
      return false if depth.negative?
    end
    depth.zero?
  end

  # The body's definition line in a compile result: `X_impl` itself, or `X_impl_unguarded` under a declared guard.
  def multi_return_head(result)
    impl = result[:impl]
    return nil unless impl&.end_with?('_impl')

    head = /^static inline mrb_value #{Regexp.escape(impl)}_unguarded\(([^)]*)\) \{$/
    head = /^mrb_value #{Regexp.escape(impl)}\(([^)]*)\) \{$/ unless result[:code].match?(head)
    heads = result[:code].scan(head)
    return nil unless heads.size == 1

    params = heads.first.first
    names = params.split(',').map { |p| p.strip[/(\w+)\z/, 1] }
    types = params.split(',').map { |p| p.strip.sub(/\s*\w+\z/, '').strip }
    return nil unless names.all? && names.first == 'M'

    { mr: "#{impl.delete_suffix('_impl')}_mr", impl: impl, head: head, params: params, names: names, types: types }
  end

  # The callee's second text with its body renamed `X_mr` (taking the buffer) and the old definition building the Array
  # from it, or nil when the text does not have the expected shape (ENTRY_GUARDED_SPECIALIZATION returns early).
  def multi_return_split(code, head, n)
    return nil unless code.is_a?(String) && code.scan(head[:head]).size == 1
    return nil if code.match?(/^  if \(.*\) return \w+_impl\(M, /)

    call_args = head[:names].join(', ')
    code.sub(head[:head]) do |line|
      "#{line}\n  mrb_value bc2cpp_mr[#{n}];\n  #{head[:mr]}(#{call_args}, bc2cpp_mr);\n" \
        "  return mrb_ary_new_from_values(M, #{n}, bc2cpp_mr);\n}\n\n" \
        "mrb_value #{head[:mr]}(#{head[:params]}, mrb_value* #{MULTI_RETURN_OUT}) {"
    end
  end

  # A callee whose own body could not be split still serves `X_mr`: it unpacks the Array `X_impl` returns.
  def multi_return_fallback(mr)
    copies = (0...mr[:n]).map { |k| "  #{MULTI_RETURN_OUT}[#{k}] = mrb_ary_entry(bc2cpp_mr_ary, #{k});\n" }.join
    "mrb_value #{mr[:mr]}(#{mr[:params]}, mrb_value* #{MULTI_RETURN_OUT}) {\n" \
      "  mrb_value bc2cpp_mr_ary = #{mr[:impl]}(#{mr[:names].join(', ')});\n#{copies}  return mrb_nil_value();\n}\n\n"
  end
end

# Prepended to CodeGen: compile_method runs under the caller plan, and again under the callee plan.
module MultiReturnCompileMethod
  def compile_method(label)
    multi_return_compile_method(label) { super(label) }
  end
end

# Prepended to CodeGen: the placed instructions' text.
module MultiReturnCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    multi_return_insn(irep, idx, reg_offset) { super(insn, irep, owner_def, idx, reg_offset) }
  end
end

CodeGen.prepend(MultiReturnCompileMethod)
CodeGen.prepend(MultiReturnCompileInsn)
