# frozen_string_literal: true

# CodeGen: the `- & | <<` helpers close their by-name else (ADR 0366). Array#-, #& and #|, String#<< and IO#<< are
# `static` in mruby-array-ext, mruby-string-ext and mruby-io; patches/mruby-expose-collection-op-bodies.patch
# exports each as `<name>_impl`, called by the method's own wrapper after its argument parsing, and the closed
# helpers call the same function. Everything below proves that the tree bc2cpp scanned really has those exports and
# no other native definer of the operator, so the arm is the method's body and not a guess at it.
class CodeGen
  # Every native registration of the operator the closed form accounts for: [class, function, source path]. A
  # registration outside the list (another gem's `Array#-`, a second `Array#<<`) keeps the helper open.
  NUMERIC_SLOW_NATIVES = {
    '-' => [%w[Integer int_sub src/numeric.c], %w[Float flo_sub src/numeric.c],
            %w[Array ary_sub mrbgems/mruby-array-ext/src/array.c]],
    '&' => [%w[Integer int_and src/numeric.c], %w[NilClass false_and src/object.c], %w[TrueClass true_and src/object.c],
            %w[FalseClass false_and src/object.c], %w[Array ary_intersection mrbgems/mruby-array-ext/src/array.c]],
    '|' => [%w[Integer int_or src/numeric.c], %w[NilClass false_or src/object.c], %w[TrueClass true_or src/object.c],
            %w[FalseClass false_or src/object.c], %w[Array ary_union mrbgems/mruby-array-ext/src/array.c]],
    '<<' => [%w[Integer int_lshift src/numeric.c], %w[Array mrb_ary_push_m src/array.c],
             %w[String str_concat_m mrbgems/mruby-string-ext/src/string.c], %w[IO io_lshift mrbgems/mruby-io/src/io.c]]
  }.freeze
  # Time#- (mruby-time) is the one more definer a build may link; numeric_slow_members removes it with the gem.
  NUMERIC_SLOW_TIME_MINUS = %w[Time time_minus mrbgems/mruby-time/src/time.c].freeze

  # The gems whose natives the closed form calls: a build without one cannot have the exported body to link.
  NUMERIC_SLOW_COLLECTION_GEMS = { '-' => %w[mruby-array-ext], '&' => %w[mruby-array-ext], '|' => %w[mruby-array-ext],
                                   '<<' => %w[mruby-string-ext mruby-io] }.freeze

  # [wrapper function, exported body, the call the wrapper must make]: the wrapper stays the method, so the export
  # is the method's body only while the wrapper calls it.
  NUMERIC_SLOW_EXPORTS = {
    '-' => [['ary_sub', 'mrb_ary_ext_sub_impl', 'mrb_ary_ext_sub_impl(mrb, self, other)']],
    '&' => [['ary_intersection', 'mrb_ary_ext_and_impl', 'mrb_ary_ext_and_impl(mrb, self, other)']],
    '|' => [['ary_union', 'mrb_ary_ext_or_impl', 'mrb_ary_ext_or_impl(mrb, self, other)']],
    '<<' => [['str_concat_m', 'mrb_str_ext_concat_impl', 'mrb_str_ext_concat_impl(mrb, self, mrb_get_arg1(mrb))'],
             ['io_lshift', 'mrb_io_lshift_impl', 'mrb_io_lshift_impl(mrb, io, mrb_get_arg1(mrb))']]
  }.freeze

  # True for an operator without exported bodies; else the proof above, memoized per operator.
  def numeric_slow_collection_ready?(name)
    return true unless NUMERIC_SLOW_NATIVES.key?(name)

    @numeric_slow_collection_ready ||= {}
    @numeric_slow_collection_ready.fetch(name) { @numeric_slow_collection_ready[name] = numeric_slow_collection_proof(name) }
  end

  # BC2CPP_COLLECTION_EXPORTS=1 says the libmruby the output links is built from the patched tree with the gems of
  # BC2CPP_BUILD_GEMS: a real build (bc2cpp_closed_world_env) and the checks that run against a full-core build set it.
  # A harness that links a core-only libmruby leaves it unset and keeps the helpers by name.
  def numeric_slow_collection_proof(name)
    return false unless ENV['BC2CPP_COLLECTION_EXPORTS'] == '1'

    gems = CodeGen.build_gem_names
    return false unless gems && NUMERIC_SLOW_COLLECTION_GEMS.fetch(name).all? { |gem| gems.include?(gem) }

    # A registration the table scan could not attribute to a ROM entry (a plain mrb_define_method) is another definer.
    return false unless call_facts_answers.opaque_owners.fetch(name, []).empty?

    found = call_facts_answers.registrations.fetch(name, []).map do |entry|
      [entry[:owner]&.fetch(:class_name, nil), entry[:function], entry[:path].to_s]
    end
    expected = NUMERIC_SLOW_NATIVES.fetch(name)
    found = found.reject { |owner, function, path| name == '-' && [owner, function] == NUMERIC_SLOW_TIME_MINUS.first(2) && path.end_with?(NUMERIC_SLOW_TIME_MINUS.last) }
    return false unless found.size == expected.size

    paths = expected.to_h do |owner, function, suffix|
      hits = found.select { |o, f, p| o == owner && f == function && p.end_with?("/#{suffix}") }
      return false unless hits.size == 1

      [function, hits.first.last]
    end
    NUMERIC_SLOW_EXPORTS.fetch(name).all? { |function, impl, call| numeric_slow_export?(paths.fetch(function), function, impl, call) }
  end

  # `impl` is defined without `static` and the method's `function` calls it as `call`.
  def numeric_slow_export?(path, function, impl, call)
    text = File.read(path, encoding: 'BINARY')
    wrapper = text[/^static mrb_value\n#{Regexp.escape(function)}\(mrb_state \*mrb, mrb_value \w+\)\n\{.*?^\}\n/m].to_s
    text.match?(/^mrb_value\n#{Regexp.escape(impl)}\(mrb_state \*mrb, mrb_value \w+, mrb_value \w+\)\n\{/) && wrapper.include?(call)
  end

  private

  def numeric_slow_extern(impl)
    "extern \"C\" mrb_value #{impl}(mrb_state*, mrb_value, mrb_value);\n"
  end

  # `-` has no String arm; Array#- is mruby-array-ext's body for an Array operand (mrb_get_args "A").
  def numeric_slow_closed_minus_arms
    { array: <<~CPP.chomp.gsub(/^(?=.)/, '    ') }
      mrb_ensure_array_type(M, b);
      r = mrb_ary_ext_sub_impl(M, a, b);
    CPP
  end

  # int_and / int_or, false_and / false_or (nil shares them), true_and / true_or, and Array#& / Array#| of
  # mruby-array-ext; an Integer receiver reads its operand as the method does, as in the `^` helper.
  def numeric_slow_closed_bits_source(key, head)
    op, bint = NUMERIC_SLOW_BITS.fetch(key)
    impl = key == 'and' ? 'mrb_ary_ext_and_impl' : 'mrb_ary_ext_or_impl'
    falsy, truthy = key == 'and' ? ['mrb_false_value()', 'mrb_bool_value(mrb_test(b))'] : ['mrb_bool_value(mrb_test(b))', 'mrb_true_value()']
    <<~CPP
      #{numeric_slow_extern(impl)}#{head}, mrb_value b) {
        if (bc2cpp_slow_int_p(a)) {
          int ai = mrb_gc_arena_save(M);
          mrb_value r;
      #ifdef MRB_USE_BIGINT
          if (mrb_bigint_p(a)) r = #{bint}(M, a, b);
          else if (mrb_bigint_p(b)) r = #{bint}(M, mrb_as_bint(M, a), b);
          else
      #endif
          r = mrb_int_value(M, mrb_integer(a) #{op} mrb_integer(b));
          #{NUMERIC_SLOW_DONE}
        }
        if (mrb_nil_p(a) || mrb_false_p(a)) return #{falsy};
        if (mrb_true_p(a)) return #{truthy};
        if (mrb_array_p(a)) {
          int ai = mrb_gc_arena_save(M);
          mrb_ensure_array_type(M, b);
          mrb_value r = #{impl}(M, a, b);
          #{NUMERIC_SLOW_DONE}
        }
        return bc2cpp_nomethod_named(M, a, "#{op}", 1, b);
      }

    CPP
  end

  # int_lshift (any count the method accepts: mrb_as_int coerces it), Array#<< with one operand (mrb_ary_push_m is
  # mrb_ary_push), String#<< and IO#<< (the exported bodies). IO is the class and its subclasses (File), not an
  # exact class test.
  def numeric_slow_closed_lshift_source(head)
    <<~CPP
      #{numeric_slow_extern('mrb_str_ext_concat_impl')}#{numeric_slow_extern('mrb_io_lshift_impl')}#{head}, mrb_value b) {
        if (bc2cpp_slow_int_p(a)) {
          mrb_state* mrb = M;  // E_RANGE_ERROR names the state `mrb`
          mrb_int width = mrb_as_int(M, b);
          if (width == 0) return a;
          if (width == MRB_INT_MIN) mrb_raise(M, E_RANGE_ERROR, "integer overflow in bit shift");
          int ai = mrb_gc_arena_save(M);
          mrb_value r;
      #ifdef MRB_USE_BIGINT
          if (mrb_bigint_p(a)) r = mrb_bint_lshift(M, a, width);
          else
      #endif
          {
            mrb_int val = mrb_integer(a);
            if (val == 0) return a;
            if (mrb_num_shift(M, val, width, &val)) {
              r = mrb_int_value(M, val);
            } else {
      #ifdef MRB_USE_BIGINT
              r = mrb_bint_lshift(M, mrb_bint_new_int(M, val), width);
      #else
              mrb_raise(M, E_RANGE_ERROR, "integer overflow in bit shift");
      #endif
            }
          }
          #{NUMERIC_SLOW_DONE}
        }
        if (mrb_array_p(a)) {
          mrb_ary_push(M, a, b);
          return a;
        }
        if (mrb_string_p(a)) {
          int ai = mrb_gc_arena_save(M);
          mrb_value r = mrb_str_ext_concat_impl(M, a, b);
          #{NUMERIC_SLOW_DONE}
        }
        if (mrb_obj_is_kind_of(M, a, mrb_class_get(M, "IO"))) {
          int ai = mrb_gc_arena_save(M);
          mrb_value r = mrb_io_lshift_impl(M, a, b);
          #{NUMERIC_SLOW_DONE}
        }
        return bc2cpp_nomethod_named(M, a, "<<", 1, b);
      }

    CPP
  end
end
