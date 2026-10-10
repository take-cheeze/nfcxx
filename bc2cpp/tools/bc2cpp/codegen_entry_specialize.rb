# frozen_string_literal: true

require 'set'
require_relative 'numeric_flow'

# CodeGen: ENTRY_GUARDED_SPECIALIZATION (docs/adr/0379).
#
# A hot method whose parameter is monomorphic at run time (BC2CPP_TRACE_PARAMS) but not provable from its
# call sites gets a second body compiled under the ASSUMPTION that the listed parameters are exactly the
# listed classes, and the original body gets one entry check in front of it:
#
#     mrb_value X_impl(M, self, a, b) {
#       if (<a is exactly Hash> && <b is exactly Integer>) return X_spec_impl(M, self, a, b);
#       ... the generic body, byte for byte what it was ...
#     }
#
# A wrong guess therefore only costs speed: a call whose argument is anything else (a subclass, nil, a bigint,
# a Float, a singleton-bearing object) runs the generic body, which is unchanged. Every `_impl` caller, the
# mrb_func_t wrapper and the registration reach the guard, because it sits in `_impl` itself.
#
# How the assumption reaches the compiler. The class pools of ADR 0295 hold, per (irep label, argument
# position), the class set an argument may carry on entry; the exact-class flow of ADR 0289 reads them
# (class_pool_entry_mask) and every unguarded consumer (a by-name send on the argument becomes a direct call,
# a Hash receiver a native body) reads the flow. The specialized body is the SAME irep compiled under a
# clone label (`<label>~spec`) whose pool entries are the assumed masks, so every per-label memo (flow states,
# fixnum proof, numeric states, class tests) is the clone's own and nothing computed under the assumption can
# be seen by the generic compile, nor the other way round. The clone is registered in the label-keyed tables
# for the duration of the compile only.
#
# What is deliberately not specialized (the method keeps its generic body only; each is a stderr line):
#   * a method with a nested block irep (BLOCK, LAMBDA, inlined each/any/times): the block's captured-local
#     facts come from a parent table keyed by the original irep, and its helper functions are named from
#     the method's. Blocks, rescue/ensure ranges, `&blk`, `yield`, optional, rest and keyword parameters,
#     Fiber-resumable `_step` bodies and core (mruby's own Ruby) methods are all out of scope for now.
#   * a parameter that is not a plain required positional one.
#   * an assumption that changes the body not at all: the specialized body is compared with an identity clone
#     (the generic body under another name) and dropped when equal, so a no-op costs no code.
#   * a class the guard cannot test exactly or no consumer reads: only Integer (a fixnum; a bigint takes the generic
#     body), Float, Array, Hash, String, Range and a closed-world class (compared against the object's own
#     class pointer, so a subclass and an object with a singleton class both miss).
#
# Gate: BC2CPP_SPECIALIZE=<file>, one line per method, `Owner#name param=Class ...` (`#` comments; the owner
# of a class method is `Owner.singleton`). Unset, empty or `0` is off, and with it off nothing here runs and
# the generated code is byte-identical to a build without this file. A line with no `param=Class` is an
# identity clone: the specialized function is emitted under no assumption and not called, which is how
# scripts/bc2cpp_entry_specialize_check.rb proves the clone path reproduces the generic body.
class CodeGen
  ENTRY_SPEC_ENV = 'BC2CPP_SPECIALIZE'
  ENTRY_SPEC_SUFFIX = '_spec'

  # class name -> NumericFlow mask, the C++ test of one argument (`%<v>s`), and whether the numeric flow
  # (ADR 0276) may carry the mask too (it carries INT/FLT/ARR/HSH/STR/NIL, never a Range or a class bit).
  ENTRY_SPEC_CORE = {
    'Integer' => { mask: NumericFlow::INT, test: 'mrb_fixnum_p(%<v>s)', numeric: true, fixnum: true },
    'Float' => { mask: NumericFlow::FLT, test: 'mrb_float_p(%<v>s)', numeric: true },
    'Array' => { mask: NumericFlow::ARR, test: 'mrb_array_p(%<v>s) && mrb_obj_ptr(%<v>s)->c == M->array_class', numeric: true },
    'Hash' => { mask: NumericFlow::HSH, test: 'mrb_hash_p(%<v>s) && mrb_obj_ptr(%<v>s)->c == M->hash_class', numeric: true },
    'String' => { mask: NumericFlow::STR, test: 'mrb_string_p(%<v>s) && mrb_obj_ptr(%<v>s)->c == M->string_class', numeric: true },
    'Range' => { mask: NumericFlow::RNG, test: 'mrb_range_p(%<v>s) && mrb_obj_ptr(%<v>s)->c == M->range_class', numeric: false }
  }.freeze

  # Class names a plan may name that have no exact test (their instances are immediates or modules).
  ENTRY_SPEC_REFUSED = %w[NilClass Symbol TrueClass FalseClass Object BasicObject Kernel Comparable Enumerable Numeric].freeze

  def entry_specialize_enabled?
    value = ENV[ENTRY_SPEC_ENV].to_s
    !(value.empty? || value == '0')
  end

  # { "Owner#name" => [[param, Class], ...] } from the plan file; empty when the gate is off.
  def entry_specialize_plan
    return {} unless entry_specialize_enabled?

    @entry_spec_plan ||= begin
      path = ENV.fetch(ENTRY_SPEC_ENV)
      raise "#{ENTRY_SPEC_ENV}: no such file #{path}" unless File.file?(path)

      File.readlines(path, encoding: 'UTF-8').each_with_object({}) do |line, plan|
        text = line.strip
        next if text.empty? || text.start_with?('#')

        method, *pairs = text.split(/\s+/)
        raise "#{ENTRY_SPEC_ENV}: #{path}: bad line #{line.inspect}" unless method.match?(/\A\S+#\S+\z/)

        params = pairs.map do |pair|
          param, klass = pair.split('=', 2)
          raise "#{ENTRY_SPEC_ENV}: #{path}: bad parameter #{pair.inspect} (want name=Class)" unless param && klass && !klass.empty?

          [param, klass]
        end
        plan[method] = params
      end
    end
  end

  # Compile-time hook of compile_method. Returns nil (no specialization) or
  # { code: <static specialized function and its helpers>, guard: <C++ condition or nil>, call: <function name> }.
  def entry_specialization(label, d, irep, arg_names, arg_native_types, eligible)
    return nil unless entry_specialize_enabled? && !@entry_spec_active

    params = entry_specialize_plan["#{d.owner}##{d.name}"]
    return nil unless params
    # The constructor and the analysis passes compile methods before the class pools are settled (a probe's
    # answer is not the shipped code's); only a compile after compute_return_classes may specialize, and only
    # its answer is kept.
    return nil if @rc_states.nil?

    @entry_spec_cache ||= {}
    return @entry_spec_cache[label] if @entry_spec_cache.key?(label)

    @entry_spec_cache[label] = entry_specialize_build(label, d, irep, arg_names, arg_native_types, eligible, params)
  end

  # true, or why the method's calling convention is outside the first cut (pure required positionals only).
  def entry_specialization_eligibility(mandatory_ok:, opt:, has_rest:, has_blk:, needs_blk_param:, kw_table:, resumable:,
                                       fiber_guarded:, needs_return_catch:, block_fallback_regions:)
    return 'optional, rest or keyword parameters' unless mandatory_ok && !opt.positive? && !has_rest && kw_table.nil?
    return 'takes or yields to a block' if has_blk || needs_blk_param
    return 'Fiber-resumable or Fiber-guarded body' if resumable || fiber_guarded
    return 'block fallback regions' if needs_return_catch || !block_fallback_regions.empty?

    true
  end

  def entry_specialize_refuse(d, why)
    warn "bc2cpp: specialize: #{d.owner}##{d.name} stays generic: #{why}"
    nil
  end

  def entry_specialize_build(label, d, irep, arg_names, arg_native_types, eligible, params)
    return entry_specialize_refuse(d, eligible) unless eligible == true
    return entry_specialize_refuse(d, 'core method') if d.core
    return entry_specialize_refuse(d, 'has nested blocks') unless (irep.reps || []).empty?
    return entry_specialize_refuse(d, 'has a rescue/ensure range') unless (irep.catch_handlers || []).empty?
    return entry_specialize_refuse(d, 'a parameter has a native C type') unless arg_native_types.all?(&:nil?)
    return entry_specialize_refuse(d, 'no exact-class world (singletons or reflection reachable)') unless @closed_world&.exact_instances_singleton_free?
    return entry_specialize_refuse(d, 'class pools are off') unless @class_pools_on && @rc_scoped_ready

    mand = irep.enter ? irep.enter.enter_fields.first : 0
    assumptions = []
    params.each do |param, klass|
      index = irep.lv.first(mand).index(param)
      return entry_specialize_refuse(d, "#{param} is not a required positional parameter") unless index

      info = entry_specialize_class_info(klass)
      return entry_specialize_refuse(d, "#{klass} (#{param}) has no exact entry test") unless info
      return entry_specialize_refuse(d, "#{param} named twice") if assumptions.any? { |a| a[:index] == index }

      assumptions << info.merge(index: index, reg: index + 1, param: param, klass: klass)
    end

    spec = entry_specialize_compile(label, d, irep, assumptions)
    return entry_specialize_refuse(d, 'the specialized body does not compile clean') unless spec

    # An assumption that resolves nothing would only duplicate the body: the identity clone (no assumption) is
    # the generic body under another name, so a specialized body equal to it earns nothing.
    unless assumptions.empty?
      return entry_specialize_refuse(d, 'the assumption changes nothing (the specialized body equals the generic one)') if spec == entry_specialize_compile(label, d, irep, [], tag: 'base')
    end

    guard = assumptions.map { |a| "(#{format(a[:test], v: arg_names.fetch(a[:index]))})" }.join(' && ')
    warn "bc2cpp: specialize: #{d.owner}##{d.name} #{assumptions.empty? ? '(identity clone)' : assumptions.map { |a| "#{a[:param]}=#{a[:klass]}" }.join(' ')}"
    { code: spec, guard: assumptions.empty? ? nil : guard,
      call: "#{cpp_name(d.owner, d.name)}#{ENTRY_SPEC_SUFFIX}_impl" }
  end

  # { mask:, test:, numeric:, fixnum: } for a class name, or nil.
  def entry_specialize_class_info(klass)
    return ENTRY_SPEC_CORE[klass] if ENTRY_SPEC_CORE.key?(klass)
    return nil if ENTRY_SPEC_REFUSED.include?(klass) || klass.end_with?('.singleton')
    return nil unless @closed_world.class_declared?(klass) && @closed_world.instance_class?(klass)

    # The object's own class pointer, not mrb_obj_class: a subclass instance and an instance with a
    # singleton class both differ from it and take the generic body.
    { mask: numeric_class_bit(klass), numeric: false,
      test: "!mrb_immediate_p(%<v>s) && mrb_obj_ptr(%<v>s)->c == #{owner_class_ptr_expr(klass)}" }
  end

  # The specialized function (and the helpers compile_method emitted ahead of it) as C++ text, or nil.
  def entry_specialize_compile(label, d, irep, assumptions, tag: 'spec')
    # One label per compile: every per-label memo (flow states, fixnum proof, class tests) stays the compile's own.
    clone_label = "#{label}~#{tag}"
    clone = irep.dup
    clone.label = clone_label

    # Label-keyed tables the compile reads. Memoized ones are built first so the clone's row is not
    # mistaken for the whole table.
    owners = entry_arg_body_owner
    numeric_owners = numeric_irep_owner
    return_class_method_oracle(irep)
    tables = [[@ireps, clone], [@owner_of, d], [owners, d], [numeric_owners, d]]
    tables << [@class_annotations, @class_annotations[label]] if @class_annotations[label]
    tables << [@rc_body_owners, @rc_body_owners[label]] if @rc_body_owners && @rc_body_owners[label]
    keys = []
    tables.each do |table, value|
      table[clone_label] = value
      keys << table
    end
    # What the call sites already prove about this method's arguments (the pools of ADR 0276/0295/0370,
    # the Fixnum entry proof) holds for the clone too: it is the same method. The assumptions then replace
    # their positions, since the guard fixes those to exactly the assumed class.
    pool_keys = []
    [@class_arg_pools, @entry_arg_numeric].compact.each do |pool|
      pool.keys.each do |key|
        next unless key.is_a?(Array) && key.first == label

        pool[[clone_label, key.last]] = pool[key]
        pool_keys << [pool, [clone_label, key.last]]
      end
    end
    if @entry_arg_fixnum.respond_to?(:<<)
      @entry_arg_fixnum.to_a.each do |key|
        next unless key.first == label

        @entry_arg_fixnum << [clone_label, key.last]
        pool_keys << [@entry_arg_fixnum, [clone_label, key.last]]
      end
    end
    assumptions.each do |a|
      key = [clone_label, a[:reg]]
      @class_arg_pools[key] = a[:mask]
      pool_keys << [@class_arg_pools, key]
      # Positions the assumption replaces must not keep a stale numeric / Fixnum fact of the generic body.
      @entry_arg_numeric&.delete(key)
      @entry_arg_fixnum.delete(key) if @entry_arg_fixnum.respond_to?(:delete)
      if a[:numeric] && @entry_arg_numeric
        @entry_arg_numeric[key] = a[:mask]
        pool_keys << [@entry_arg_numeric, key]
      end
      if a[:fixnum] && @entry_arg_fixnum.respond_to?(:<<)
        @entry_arg_fixnum << key
        pool_keys << [@entry_arg_fixnum, key]
      end
    end
    saved = [@entry_spec_active, @entry_spec_suffix]
    @entry_spec_active = true
    @entry_spec_suffix = ENTRY_SPEC_SUFFIX
    begin
      result = compile_method(clone_label)
    ensure
      @entry_spec_active, @entry_spec_suffix = saved
      keys.each { |table| table.delete(clone_label) }
      pool_keys.each { |pool, key| pool.delete(key) }
    end
    return nil if result[:unsupported] || result[:code].include?('#error')

    entry = "static mrb_value #{cpp_name(d.owner, d.name)}(mrb_state* M, mrb_value self) {\n"
    cut = result[:code].rindex(entry)
    return nil unless cut

    code = result[:code][0...cut]
    impl = "#{cpp_name(d.owner, d.name)}#{ENTRY_SPEC_SUFFIX}_impl"
    code = code.sub(/^\/\/ (\S+) \(compiled from irep \S+,/) { "// ENTRY_SPECIALIZED #{Regexp.last_match(1)} (compiled from irep #{label}," }
    return nil unless code.sub!(/^mrb_value #{Regexp.escape(impl)}\(/, "[[maybe_unused]] static mrb_value #{impl}(")

    code
  end
end
