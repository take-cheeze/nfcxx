# frozen_string_literal: true

require_relative 'core_misc'

# CodeGen: NUMERIC_SLOW_CLOSED for `%` and `-@` (ADR 0367). Their definers are the numeric natives, String's
# (a native `-@`, sprintf's Ruby `%`) and Numeric's Ruby `-@`; patches/mruby-expose-misc-bodies.patch exports the
# static bodies, so the helper calls them directly and every other receiver is a proven NoMethodError.
class CodeGen
  # Classes whose arm the helper of the operator carries.
  NUMERIC_SLOW_MISC_OWNERS = { '%' => %w[Integer Float String], '-@' => %w[Integer Float Numeric String] }.freeze
  # The gem a String arm links against: the exported body lives in it, so a build without the gem keeps the
  # by-name helper (a String then answers from another gem or not at all).
  NUMERIC_SLOW_MISC_GEMS = { '%' => 'mruby-sprintf', '-@' => 'mruby-string-ext' }.freeze

  # `{ string: Boolean }` for an operator whose helper may be closed in this world, nil otherwise.
  def numeric_slow_misc(name)
    return nil unless NUMERIC_SLOW_MISC_OWNERS.key?(name) && numeric_slow_closed_world?

    @numeric_slow_misc ||= {}
    @numeric_slow_misc.fetch(name) { @numeric_slow_misc[name] = numeric_slow_misc_proof(name) }
  end

  private

  # CoreMisc names the definers the bodies stand on; `definers` and `members` say nothing else answers `name`.
  def numeric_slow_misc_proof(name)
    answers = call_facts_answers
    definers = answers.definers(name)
    return nil if definers.nil? || definers[:singleton] || !definers[:ruby].empty? || !definers[:modules].empty?

    verified = CoreMisc.verified(name, @closed_world.outside_ruby_paths, answers.registrations, answers.opaque_owners)
    return nil unless verified
    return nil unless definers[:foreign].subset?(verified) && definers[:native].subset?(verified)

    members = numeric_slow_members(answers, name)
    owners = NUMERIC_SLOW_MISC_OWNERS.fetch(name)
    return nil unless !members.nil? && members.all? { |klass| numeric_slow_inherits_owner?(answers, klass, owners) }

    string = verified.include?('String')
    return nil if string && !numeric_slow_misc_string_arm?(name, answers)
    return nil if name == '-@' && !integer_ancestry_native?('-')

    { string: string }
  end

  # The String arm needs the gem that holds its body, and for `%` the calls String#% makes by name.
  def numeric_slow_misc_string_arm?(name, answers)
    gems = CodeGen.build_gem_names
    return false if gems.nil? || !gems.include?(NUMERIC_SLOW_MISC_GEMS.fetch(name))
    return true unless name == '%'

    numeric_slow_format_calls_direct?(answers)
  end

  # String#% is `args.is_a?(Array) ? sprintf(self, *args) : sprintf(self, args)`: mirrored as the C of Kernel#is_a?
  # and Kernel#sprintf, with `Array` the class constant, for any argument and any String receiver. Both names are
  # spelled only by their one native (CoreMisc pins them), no Ruby, install or BasicObject receiver reaches them, and
  # nothing binds `Array` but the core and no bytecode names BasicObject.
  def numeric_slow_format_calls_direct?(answers)
    world = @closed_world
    paths = @native_name_sources.values.flatten.uniq
    return false unless CoreMisc.format_pins?(answers.registrations, answers.opaque_owners, paths)
    return false unless world.core_constant_plain?('Array') && world.basic_object_unreferenced?

    { 'is_a?' => 'src/kernel.c', 'sprintf' => 'mruby-sprintf/src/sprintf.c' }.all? do |name, file|
      world.kernel_native_dispatch_safe?(name) && name_unrebound?(name) && world.native_only_in?(name, file)
    end
  end

  def numeric_slow_closed_mod_source(head, misc)
    <<~CPP
      extern "C" mrb_value mrb_int_mod_impl(mrb_state*, mrb_value, mrb_value);
      #ifndef MRB_NO_FLOAT
      extern "C" mrb_value mrb_flo_mod_impl(mrb_state*, mrb_value, mrb_value);
      #endif
      #{misc.fetch(:string) ? 'extern "C" mrb_value mrb_str_format_impl(mrb_state*, mrb_int, const mrb_value*, mrb_value) __attribute__((weak));' : ''}
      #{head}, mrb_value b) {
        int ai = mrb_gc_arena_save(M);
        mrb_value r;
        if (bc2cpp_slow_int_p(a)) {
          r = mrb_int_mod_impl(M, a, b);
        }
      #ifndef MRB_NO_FLOAT
        else if (mrb_float_p(a)) {
          r = mrb_flo_mod_impl(M, a, b);
        }
      #endif
      #{numeric_slow_mod_string_arm(misc)}
        else {
          return bc2cpp_nomethod_named(M, a, "%", 1, b);
        }
        #{NUMERIC_SLOW_DONE}
      }

    CPP
  end

  # String#% with the two calls inlined; the splat copies the elements, so a `to_s` that changes the Array cannot move them.
  def numeric_slow_mod_string_arm(misc)
    return '' unless misc.fetch(:string)

    <<~CPP.chomp.gsub(/^(?=.)/, '  ')
      else if (mrb_string_p(a) && mrb_str_format_impl) {
        if (mrb_obj_is_kind_of(M, b, M->array_class)) {
          mrb_value args = mrb_ary_new_from_values(M, RARRAY_LEN(b), RARRAY_PTR(b));
          r = mrb_str_format_impl(M, RARRAY_LEN(args), RARRAY_PTR(args), a);
        }
        else {
          r = mrb_str_format_impl(M, 1, &b, a);
        }
      }
    CPP
  end

  # Numeric#-@ is `0 - self` (OP_SUB): an Integer overflows into mrb_bint_sub_ii, a bigint takes Integer#-, a Float the
  # inline 0 - float (so -0.0 stays +0.0) and any other Numeric Integer#- with the receiver as its operand;
  # String#-@ is the exported body; no other class answers. The two gem exports are weak references: a libmruby
  # without the gem (a check build that is not the target's) links, and a String then takes the NoMethodError arm, which is
  # what its interpreter answers.
  def numeric_slow_closed_neg_source(head, misc)
    string = misc.fetch(:string) ? "  if (mrb_string_p(a) && mrb_str_uminus_impl) return mrb_str_uminus_impl(M, a);\n" : ''
    declaration = misc.fetch(:string) ? "extern \"C\" mrb_value mrb_str_uminus_impl(mrb_state*, mrb_value) __attribute__((weak));\n" : ''
    <<~CPP
      #{declaration}#{head}) {
        if (mrb_integer_p(a)) {
          mrb_int x = mrb_integer(a), z;
          if (!mrb_int_sub_overflow(0, x, &z)) return mrb_int_value(M, z);
      #ifdef MRB_USE_BIGINT
          int ai = mrb_gc_arena_save(M);
          mrb_value r = mrb_bint_sub_ii(M, 0, x);
          #{NUMERIC_SLOW_DONE}
      #else
          mrb_state* mrb = M;  // E_RANGE_ERROR names the state `mrb`
          mrb_raise(M, E_RANGE_ERROR, "integer overflow");
      #endif
        }
      #ifndef MRB_NO_FLOAT
        if (mrb_float_p(a)) {
          int ai = mrb_gc_arena_save(M);
          mrb_value r = mrb_float_value(M, (mrb_float)0 - mrb_float(a));
          #{NUMERIC_SLOW_DONE}
        }
      #endif
      #{string}  if (bc2cpp_slow_int_p(a) || mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"))) {
          int ai = mrb_gc_arena_save(M);
          mrb_value r = mrb_num_sub(M, mrb_fixnum_value(0), a);
          #{NUMERIC_SLOW_DONE}
        }
        return bc2cpp_nomethod_named(M, a, "-@");
      }

    CPP
  end
end
