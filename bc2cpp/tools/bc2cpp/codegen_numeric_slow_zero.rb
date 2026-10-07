# frozen_string_literal: true

require_relative 'core_misc'

# NUMERIC_SLOW_CLOSED `zero?` (ADR 0373). Numeric#zero? is Ruby (`self == 0`, mruby-numeric-ext), so the helper kept a
# by-name call for every receiver that is not a Float. Its definers are that one Ruby method and, on class objects,
# mruby-io's File.zero? / FileTest.zero?; the first is a compiled core body this run may call (the ADR 0371 view), the
# second raises the ArgumentError of its own first statement for the zero arguments the helper always passes.
class CodeGen
  # Where Integer, Float and Numeric reach a `zero?` definer; Integer and Float have none of their own.
  NUMERIC_SLOW_ZERO_CHAIN = %w[Integer Float Numeric].freeze
  # `mrb_get_arg1` is the first effect of the registered body, and it raises for any argc but one.
  NUMERIC_SLOW_ZERO_FILE = { file: 'mruby-io/src/file_test.c', function: 'mrb_filetest_s_zero_p', owners: %w[File FileTest].freeze,
                             body_start: '{mrb_io_statst;mrb_valueobj=mrb_get_arg1(mrb);' }.freeze

  # BC2CPP_CORE_COMPILED_ZERO=0 keeps the by-name helper.
  def numeric_slow_zero_enabled?
    ENV['BC2CPP_CORE_COMPILED_ZERO'] != '0'
  end

  # `{ target: compiled Numeric#zero?, file: Boolean }` when the helper may be closed in this world, else nil.
  def numeric_slow_zero
    return nil unless numeric_slow_zero_enabled? && numeric_slow_closed_world?

    return @numeric_slow_zero if defined?(@numeric_slow_zero)

    @numeric_slow_zero = numeric_slow_zero_proof
  end

  private

  # BC2CPP_ZERO_WHY=1 reports, on stderr, why the helper stays by name.
  def numeric_slow_zero_refuse(reason)
    warn "[bc2cpp] zero? helper by name: #{reason}" if ENV['BC2CPP_ZERO_WHY'] == '1'
    nil
  end

  # Nothing but the compiled body, the pinned File natives and the numeric receivers' own lookup answers `zero?`:
  # every other receiver is a proven NoMethodError (bc2cpp_nomethod_named dispatches first, so a wrong proof is the
  # right answer or "closed-world proof violated").
  def numeric_slow_zero_proof
    return numeric_slow_zero_refuse('no core program: no compiled body') unless @yield_reach && block_core_world && @native_name_sources

    answers = call_facts_answers
    definers = answers.definers('zero?')
    return numeric_slow_zero_refuse('zero? is unbounded or has a singleton or native instance definer') if definers.nil? || definers[:singleton] || definers[:native].any?
    unless definers[:ruby].empty? && definers[:modules].empty? && definers[:foreign] == Set['Numeric']
      return numeric_slow_zero_refuse("definers other than Numeric#zero?: #{definers.inspect}")
    end

    target = numeric_slow_zero_target(answers)
    return numeric_slow_zero_refuse('the compiled Numeric#zero? is not a direct-call target') unless target

    members = numeric_slow_members(answers, 'zero?')
    return numeric_slow_zero_refuse('members of zero? are unbounded') unless members

    file = !definers[:class_native].empty?
    return numeric_slow_zero_refuse('the File.zero? registrations are not the pinned ones') if file && !numeric_slow_zero_file_ready?(answers, definers[:class_native])
    stray = members.reject { |klass| klass == CallFacts::CLASS_OBJECT ? file : numeric_slow_inherits_owner?(answers, klass, %w[Numeric]) }
    return numeric_slow_zero_refuse("members outside Numeric: #{stray.to_a.first(5)}") unless stray.empty?
    return numeric_slow_zero_refuse('the constant Numeric is rebound') unless @closed_world.core_constant_plain?('Numeric')

    { target: target, file: file }
  end

  # The one compiled Numeric#zero?, behind the ADR 0371 conditions: the foreign definer the scan saw is the one
  # compiled here, the lookup chains of Integer, Float and Numeric reach it with no project, native, prepended,
  # outside or computed definer in between, and its body is yield-free (a direct call skips the entry's Fiber guard).
  def numeric_slow_zero_target(answers)
    defs = core_compiled_definers('zero?')
    return nil unless defs.keys == ['Numeric'] && defs['Numeric'].one? && answers.foreign_definer?('zero?', 'Numeric')

    target = block_core_target('Integer', NUMERIC_SLOW_ZERO_CHAIN, 'zero?', 0, blockless: true)
    target if target && target.owner == 'Numeric' && @yield_reach.yield_free?(target.irep)
  end

  # The class-level registrations are exactly mruby-io's two, the build links the gem, no one rebinds the constants,
  # and the registered body starts by reading its one argument.
  def numeric_slow_zero_file_ready?(answers, owners)
    spec = NUMERIC_SLOW_ZERO_FILE
    gems = CodeGen.build_gem_names
    return false unless gems&.include?('mruby-io') && owners.to_a.sort == spec[:owners].sort

    entries = answers.class_registrations.fetch('zero?', [])
    return false unless entries.size == spec[:owners].size && entries.all? do |entry|
      entry[:function] == spec[:function] && entry[:path].to_s.end_with?("/#{spec[:file]}")
    end
    return false unless answers.opaque_owners.fetch('zero?', []).empty?
    return false unless spec[:owners].all? { |name| @closed_world.core_constant_plain?(name) }

    body = CoreMisc.function_body(File.read(entries.first[:path]), spec[:function])
    !body.nil? && body.start_with?(spec[:body_start])
  end

  def numeric_slow_closed_zero_source(head, zero)
    impl = "#{cpp_name(zero[:target].owner, zero[:target].name)}_impl"
    file = zero[:file] ? numeric_slow_zero_file_arm : ''
    <<~CPP
      #{head}) {
      #ifndef MRB_NO_FLOAT
        if (mrb_float_p(a)) return mrb_bool_value(mrb_float(a) == 0);
      #endif
        // CORE_COMPILED_ZERO -- every other Numeric runs the compiled Numeric#zero? body, no by-name call (ADR 0373)
        if (mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"))) {
          int ai = mrb_gc_arena_save(M);
          mrb_value r = #{impl}(M, a);
          mrb_gc_arena_restore(M, ai);
          return r;
        }
      #{file}  return bc2cpp_nomethod_named(M, a, "zero?");
      }

    CPP
  end

  # File.zero? and FileTest.zero? (and a File subclass's) take the path; the helper passes none, so what dispatch
  # answers is the ArgumentError mrb_get_arg1 raises first.
  def numeric_slow_zero_file_arm
    <<~CPP.gsub(/^(?=.)/, '  ')
      if (mrb_type(a) == MRB_TT_CLASS || mrb_type(a) == MRB_TT_MODULE) {
        struct RClass* file = mrb_class_get(M, "File");
        struct RClass* test = mrb_module_get(M, "FileTest");
        for (struct RClass* k = mrb_class_ptr(a); k; k = k->super)
          if (k == file || k == test) mrb_argnum_error(M, 0, 1, 1);
      }
    CPP
  end
end
