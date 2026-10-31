# frozen_string_literal: true

require 'digest'

class CodeGen
  # ARRAY_SORT_CMP_DIRECT: array_native_refusal excludes Ruby/native replacements,
  # installers and prepends. Pin the providing file so its body and binding cannot drift.
  def sort_array_cmp_direct?
    return false if ENV['BC2CPP_SORT_ARRAY_CMP'] == '0'
    return @sort_array_cmp_direct unless @sort_array_cmp_direct.nil?

    @sort_array_cmp_direct = array_native_refusal('<=>').nil? &&
                             Array(self.class.native_source_paths).any? do |path|
                               mruby_core_array_source?(path) && sort_array_cmp_source_matches?(File.binread(path))
                             end
  end

  def sort_array_cmp_source_matches?(source)
    Digest::SHA256.hexdigest(source) == '0e73f68c2aa22a497b9106d043931f5e4bbebef1b6c56f3acd8395bdf04cb30f'
  end

  def emit_sort_array_cmp_helper(compiled)
    return '' unless compiled.any? { |method| method[:code].include?('bc2cpp_sort_key_cmp(') }

    <<~CPP
      // ARRAY_SORT_CMP_DIRECT: the emitter proves the builtin Array#<=> body is unchanged.
      static inline mrb_int bc2cpp_sort_key_cmp(mrb_state *M, mrb_value a, mrb_value b) {
        if (mrb_class(M, a) != M->array_class || !mrb_array_p(b)) return mrb_cmp(M, a, b);
        if (mrb_obj_equal(M, a, b)) return 0;
        for (mrb_int i = 0; i < RARRAY_LEN(a) && i < RARRAY_LEN(b); ++i) {
          mrb_int c = mrb_cmp(M, RARRAY_PTR(a)[i], RARRAY_PTR(b)[i]);
          if (c != 0) return c;
        }
        mrb_int length = RARRAY_LEN(a) - RARRAY_LEN(b);
        return length == 0 ? 0 : length > 0 ? 1 : -1;
      }

    CPP
  end
end
