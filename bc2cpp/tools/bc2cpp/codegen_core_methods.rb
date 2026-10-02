# frozen_string_literal: true

require_relative 'core_mixins'

# CodeGen: the inlines CoreMixins verifies (docs/adr/0261), each behind an exact
# receiver guard whose else arm is the ordinary dispatch.
class CodeGen
  class << self
    # CoreMixins::METHODS the build's core sources match; nil proves nothing.
    attr_accessor :core_methods
  end

  # `classes`, what they mix in, then Object, Kernel and BasicObject; nil when one
  # has an unknown mixin or a prepend that could sit ahead of the modelled method.
  def core_ancestry(*classes)
    seen = []
    work = classes + %w[Object Kernel BasicObject]
    until work.empty?
      klass = work.shift
      next if seen.include?(klass)
      return nil if @unknown_mixins.include?(klass) || !Array(@prepended_modules[klass]).empty?

      seen << klass
      work.concat(Array(@included_modules[klass]))
    end
    seen
  end

  # Is the modelled core definition of `name` (and of each name in `also`, which
  # its body calls) what a receiver of `classes` reaches?
  def core_method_reaches_model?(name, classes, also: [])
    return false unless @closed_world && !@closed_world.global_refusal && self.class.core_methods&.include?(name)

    ancestry = core_ancestry(*classes)
    return false unless ancestry

    installed = symbol_installed_names
    return false if installed.nil?

    ([name] + also).none? do |called|
      installed.include?(called) || devirt_blocked_name?(called) ||
        @registry.fetch(called, []).any? { |definition| ancestry.include?(definition.owner) }
    end
  end

  # The numeric operator natives are not replaced on `classes`' ancestry.
  def core_numeric_native?(op, classes)
    builtin_class_send_safe?(op, classes) && !core_ancestry(*classes).nil?
  end

  # Numeric#positive?/#negative? are `self > 0` / `self < 0` (mruby-numeric-ext).
  def compile_core_numeric_sign(name, n, d, recv, argv)
    return nil unless n.zero? && %w[positive? negative?].include?(name)

    op = name == 'positive?' ? '>' : '<'
    return nil unless %w[Integer Float].all? { |klass| core_method_reaches_model?(name, [klass, 'Numeric', 'Comparable']) }
    return nil unless %w[Integer Float].all? { |klass| core_numeric_native?(op, [klass, 'Numeric', 'Comparable']) }

    <<~CPP
        // CORE_NUMERIC_SIGN :#{name} -- Numeric##{name} is `self #{op} 0` (mruby-numeric-ext); an Integer or Float receiver is computed inline, anything else keeps the dispatch
        if (mrb_integer_p(#{recv})) {
          r#{d} = mrb_bool_value(mrb_integer(#{recv}) #{op} 0);
        #ifndef MRB_NO_FLOAT
        } else if (mrb_float_p(#{recv})) {
          r#{d} = mrb_bool_value(mrb_float(#{recv}) #{op} 0);
        #endif
        } else {
          #{dynamic_dispatch_line(d, recv, name, argv).chomp}
        }
    CPP
  end

  # Enumerable#min/#max without a block on an exact Array: for Integers and non-NaN
  # Floats `<=>` is the C ordering and the first of equal elements wins.
  def compile_core_min_max(insn, name, n, d, recv, argv)
    return nil unless n.zero? && %w[min max].include?(name) && %w[SEND SEND0].include?(insn.op)
    return nil unless core_method_reaches_model?(name, %w[Array Enumerable], also: %w[each __svalue])
    return nil unless core_numeric_native?('<=>', %w[Integer Float Numeric Comparable])

    op = name == 'min' ? '<' : '>'
    array = "bc2cpp_mm_#{d}"
    <<~CPP
        // CORE_MIN_MAX :#{name} -- Enumerable##{name} (mrblib/enum.rb) over an exact Array of Integers or of non-NaN Floats is the extreme element, the first of equal ones; every other receiver keeps the dispatch
        {
          mrb_bool #{array}_done = FALSE;
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class && RARRAY_LEN(#{recv}) > 0) {
            const mrb_value* #{array}_p = RARRAY_PTR(#{recv});
            const mrb_int #{array}_n = RARRAY_LEN(#{recv});
            mrb_int #{array}_i = 1;
            if (mrb_integer_p(#{array}_p[0])) {
              mrb_int #{array}_best = mrb_integer(#{array}_p[0]);
              for (; #{array}_i < #{array}_n && mrb_integer_p(#{array}_p[#{array}_i]); ++#{array}_i) {
                if (mrb_integer(#{array}_p[#{array}_i]) #{op} #{array}_best) #{array}_best = mrb_integer(#{array}_p[#{array}_i]);
              }
              if (#{array}_i == #{array}_n) {
                r#{d} = mrb_int_value(M, #{array}_best);
                #{array}_done = TRUE;
              }
        #ifndef MRB_NO_FLOAT
            } else if (mrb_float_p(#{array}_p[0]) && !isnan(mrb_float(#{array}_p[0]))) {
              mrb_float #{array}_best = mrb_float(#{array}_p[0]);
              for (; #{array}_i < #{array}_n && mrb_float_p(#{array}_p[#{array}_i]) && !isnan(mrb_float(#{array}_p[#{array}_i])); ++#{array}_i) {
                if (mrb_float(#{array}_p[#{array}_i]) #{op} #{array}_best) #{array}_best = mrb_float(#{array}_p[#{array}_i]);
              }
              if (#{array}_i == #{array}_n) {
                r#{d} = mrb_float_value(M, #{array}_best);
                #{array}_done = TRUE;
              }
        #endif
            }
          }
          if (!#{array}_done) {
            #{core_exact_else(d, recv, name, argv)}
          }
        }
    CPP
  end
end
