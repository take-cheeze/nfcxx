# frozen_string_literal: true

# CodeGen: sends devirtualized to native primitives.

class CodeGen
  # Owner/class pairs for frame-independent wrapper bodies that mirror these
  # mruby-rgss registrations. Keep exact owners here: NATIVE_SRCS records the
  # method name globally, while the runtime class guard selects the owner.
  # `bitmap=` is not listed: NativeDirect::ENTRIES gives it the same entry
  # point, and the generic NATIVE_DIRECT arms (codegen_native_direct.rb) emit it.
  NATIVE_WRAPPER_DIRECT_OWNERS = {
    'clear' => %w[RGSS::Bitmap],
    'rect' => %w[RGSS::Bitmap RGSS::Viewport],
    'fill_rect' => %w[RGSS::Bitmap],
    'blt' => %w[RGSS::Bitmap],
    'stretch_blt' => %w[RGSS::Bitmap],
    'draw_text' => %w[RGSS::Bitmap],
    'copy_blt' => %w[RGSS::Bitmap],
    'text_size' => %w[RGSS::Bitmap],
    'width' => %w[RGSS::Bitmap RGSS::Rect],
    'height' => %w[RGSS::Bitmap RGSS::Rect],
    'x' => %w[RGSS::Rect],
    'y' => %w[RGSS::Rect],
    'red' => %w[RGSS::Color RGSS::Tone],
    'green' => %w[RGSS::Color RGSS::Tone],
    'blue' => %w[RGSS::Color RGSS::Tone],
    'alpha' => %w[RGSS::Color],
    'gray' => %w[RGSS::Tone],
    'disposed?' => %w[RGSS::Bitmap RGSS::Sprite RGSS::Viewport RGSS::Plane RGSS::Tilemap RGSS::Window],
    'visible' => %w[RGSS::Sprite RGSS::Viewport RGSS::Plane],
    'update' => %w[RGSS::Sprite RGSS::Viewport RGSS::Window],
    'dispose' => %w[RGSS::Bitmap RGSS::Sprite RGSS::Viewport RGSS::Plane RGSS::Tilemap RGSS::Window],
    'openness=' => %w[RGSS::Window],
    'tone=' => %w[RGSS::Sprite RGSS::Window RGSS::Viewport],
    'opacity=' => %w[RGSS::Sprite]
  }.freeze

  NATIVE_WRAPPER_ZERO_ARG_DIRECT = {
    'clear' => { 'RGSS::Bitmap' => 'bitmap_clear_direct' },
    'rect' => { 'RGSS::Bitmap' => 'bitmap_rect_direct', 'RGSS::Viewport' => 'viewport_rect_direct' },
    'width' => { 'RGSS::Bitmap' => 'bitmap_width_direct', 'RGSS::Rect' => 'rect_width_direct' },
    'height' => { 'RGSS::Bitmap' => 'bitmap_height_direct', 'RGSS::Rect' => 'rect_height_direct' },
    'x' => { 'RGSS::Rect' => 'rect_x_direct' },
    'y' => { 'RGSS::Rect' => 'rect_y_direct' },
    'red' => { 'RGSS::Color' => 'color_red_direct', 'RGSS::Tone' => 'tone_red_direct' },
    'green' => { 'RGSS::Color' => 'color_green_direct', 'RGSS::Tone' => 'tone_green_direct' },
    'blue' => { 'RGSS::Color' => 'color_blue_direct', 'RGSS::Tone' => 'tone_blue_direct' },
    'alpha' => { 'RGSS::Color' => 'color_alpha_direct' },
    'gray' => { 'RGSS::Tone' => 'tone_gray_direct' },
    'disposed?' => %w[RGSS::Bitmap RGSS::Sprite RGSS::Viewport RGSS::Plane RGSS::Tilemap RGSS::Window]
      .to_h { |owner| [owner, 'disposed_direct'] },
    'visible' => %w[RGSS::Sprite RGSS::Viewport RGSS::Plane].to_h { |owner| [owner, 'visible_direct'] },
    'update' => {
      'RGSS::Sprite' => 'sprite_update_direct',
      'RGSS::Viewport' => 'viewport_update_direct',
      'RGSS::Window' => 'window_update_direct'
    }
  }.freeze

  # Each wrapper class's accessor is native_<last segment, snake_case>_class (include/rgss_construct.hxx).
  # RGSS::Table has a native_table_class accessor too, but it has no wrapper here and stays out.
  NATIVE_WRAPPER_CLASS_ACCESSORS = %w[RGSS::Rect RGSS::Color RGSS::Tone RGSS::Bitmap RGSS::Sprite
                                      RGSS::Viewport RGSS::Plane RGSS::Tilemap RGSS::Window].to_h do |klass|
    snake = klass.delete_prefix('RGSS::').gsub(/(?<!\A)([A-Z])/, '_\1').downcase
    [klass, "native_#{snake}_class"]
  end.freeze

  # LITERAL_EQQ_SUPPORT soundness gate, re-checked against this run's @registry:
  # both `#==` and `#===` must be MONO native. `LITERAL === arg` must reach
  # mrb_eqq_m (src/kernel.c), which calls mrb_equal (src/object.c); mrb_equal
  # dispatches to the receiver's `#==` unless mrb_func_basic_p, and the Symbol
  # (mrb_obj_equal_m) and Fixnum (int_equal, src/numeric.c) branches rely on
  # those defaults. A reopened `#==` on any class could change that, so the
  # check is by name, not by owner. Any reopening flips this to false and the
  # sites fall back to POLY dispatch. Memoized: @registry is fixed after
  # CodeGen.new.
  def eqq_literal_devirt_safe?
    return @eqq_literal_devirt_safe if defined?(@eqq_literal_devirt_safe)

    @eqq_literal_devirt_safe = %w[== ===].all? do |n|
      defs = @registry[n]
      defs && defs.size == 1 && defs.first.owner == '<native>' && eqq_name_unrebound?(n)
    end
  end

  # NATIVE_PRIMITIVE_SEND_ARITY: the Ruby operator names compile_native_primitive_send inlines, with the arity a call
  # site must match: `!` and `!=` (the operators) and `===` (case/when). Every other native method, whatever its
  # name, dispatches through its normal send path (its name is not a language feature).
  NATIVE_PRIMITIVE_SEND_ARITY = { '!' => 0, '===' => 1, '!=' => 1 }.freeze

  # Shared gate for NATIVE_PRIMITIVE_SEND_ARITY: `name` has exactly one registry
  # def and it is the native placeholder (irep nil). The opposite of
  # monomorphic_target, which needs an `_impl`. A game-side `def nil?` would add
  # a second def and fall back to POLY dispatch. Without NATIVE_SRCS there is no
  # placeholder, so nothing is proven.
  def native_only_mono?(name)
    defs = @registry[name]
    defs && defs.size == 1 && defs.first.irep.nil?
  end

  # The rgss:: wrappers are defined by mruby-rgss/src, so a build that does not
  # link it (optcarrot probe) must not emit them: a core native of the same
  # name (Array#clear) satisfies the registry test but not the link.
  def rgss_native_registers?(name)
    return true unless @native_name_sources

    @native_name_sources.fetch(name, []).any? { |path| path.include?('mruby-rgss/src/') }
  end

  # An exact runtime class guard selects a C wrapper only when that owner has
  # one native registration and no prepended module can take lookup precedence.
  def native_wrapper_owner_safe?(name, owner)
    return false unless NATIVE_WRAPPER_DIRECT_OWNERS.fetch(name, []).include?(owner)
    return false unless rgss_native_registers?(name)

    defs = @registry[name]
    return false unless defs

    defs.any? { |definition| definition.owner == '<native>' && definition.irep.nil? } &&
      defs.none? { |definition| definition.owner == owner } &&
      Array(@prepended_modules[owner]).empty?
  end

  # OWNERLESS_NATIVE_DISPATCH: the primitive gate; with the closed world in view (every engine body; a core
  # body compiles with it withheld, ADR 0264) it also proves no external Ruby definition or dynamic installer can
  # replace this method.
  def ownerless_native_dispatch_safe?(name)
    native_only_mono?(name) && (!@closed_world || @closed_world.ownerless_native_dispatch_safe?(name))
  end

  # Permit per-class fast paths only for exact built-in receivers, with a
  # native registration present and no Ruby replacement on those classes.
  # A prepend can sit ahead of the native method, so decline the fast path
  # for any base class with a known or unresolved prepend.
  def builtin_class_send_safe?(name, builtins)
    @builtin_class_send_safe ||= {}
    cache_key = [name, builtins]
    return @builtin_class_send_safe[cache_key] if @builtin_class_send_safe.key?(cache_key)

    defs = @registry[name]
    @builtin_class_send_safe[cache_key] = defs && defs.any? { |d| d.owner == '<native>' && d.irep.nil? } &&
                                          defs.none? { |d| builtins.include?(d.owner) } &&
                                          builtins.none? do |owner|
                                            !Array(@prepended_modules[owner]).empty? || @unknown_mixins.include?(owner)
                                          end
  end

  # Classes whose instances are immediate values: a type-tag test is their whole class
  # test, and `mrb_obj_ptr(v)->c` on one reads through a tagged (or integer) word.
  IMMEDIATE_NATIVE_CLASSES = %w[Float Symbol Integer].freeze

  # The closed world proves no Ruby respond_to_missing? exists, and every native
  # one is mruby core's (kernel.c/class.c/method.c), whose default answers false.
  def respond_to_missing_absent?
    return false unless @closed_world&.respond_to_missing_free?
    return false unless @native_name_sources

    @native_name_sources.fetch('respond_to_missing?', []).all? { |path| path.match?(%r{/3rd/mruby/(?:src|mrbgems)/}) }
  end

  # Guarded direct C++ for one NATIVE_PRIMITIVE_SEND_ARITY name, or an exact-class
  # expression generated from registered native C methods. The per-method
  # soundness notes are at compile_send's call site.
  # `proof` is [irep, site index] of the call (GUARD_VIOLATION, ADR 0290), nil without one.
  def compile_native_primitive_send(name, d, recv, argv, proof: nil)
    if @native_registered_expressions.key?(name) && name != 'to_s'
      return compile_native_registered_expression(name, d, recv, argv)
    end

    case name
    when '!'
      expression = @native_expression_devirt[name]
      if expression
        "  // ! -- generated from mruby's registered C implementation\n" \
          "  r#{d} = #{expression.gsub('recv', recv)};\n"
      else
        "  r#{d} = mrb_funcall(M, #{recv}, \"!\", 0);\n"
      end
    when '==='
      # EQQ_TYPE_TAG_DISPATCH: the tag switch (Module#===, Range#===, Kernel#=== bodies, all
      # static in mruby and reading their argument from the frame, so reproduced from public
      # APIs) is the shared bc2cpp_eqq, see eqq_helper_code. MRB_TT_DATA (mruby-onig-regexp's
      # bytecode Regexp#===) and MRB_TT_PROC (mruby-proc-ext's Proc#===) dispatch by name.
      return dynamic_dispatch_line(d, recv, name, argv) unless eqq_name_unrebound?('===')

      outlined_eqq_call("r#{d}", recv, argv.first)
      # CLASS_EQQ (ADR 0290) lives in compile_eqq_direct: a stable constant receiver never reaches here
      # while the world proves `===`, and a rebound one takes the shared helper.
    when '!='
      # NEQ_UNCONDITIONAL: `!=` is a hand-written bytecode RProc in class.c bob_init
      # (`return !(self == other)`), registered via mrb_define_method_raw (hence that
      # scan in extract_native_method_names). vm.c OP_EQ is identity, then a
      # hardcoded false for Symbols, then numeric fast paths or SEND :==. mrb_equal
      # (src/object.c) gives the same answer for every type (for a Symbol with the
      # default `==`, mrb_func_basic_p skips dispatch and returns false), so
      # `!mrb_equal(...)` needs no fallback.
      arg = argv.first
      "  // != -- native primitive, no lookup needed for any receiver (real\n" \
      "  // bytecode is exactly `!(self == other)`, mrb_equal reproduces ==\n" \
      "  // exactly for every type -- see compile_native_primitive_send's own\n" \
      "  // NEQ_UNCONDITIONAL comment)\n" \
      "  r#{d} = mrb_bool_value(!mrb_equal(M, #{recv}, #{arg}));\n"
    else
      dynamic_dispatch_line(d, recv, name, argv)
    end
  end

  # INTEGER_UNARY: an Integer runs Numeric#-@ (`0 - self`), Numeric#zero? (`self == 0`),
  # both Ruby in libmruby, and int_round (`self`); see docs/adr/0200.
  INTEGER_UNARY_OPS = {
    '-@' => ['mrb_int_value(M, -mrb_integer(%<r>s))', ' && mrb_integer(%<r>s) != MRB_INT_MIN'],
    'zero?' => ['mrb_bool_value(mrb_integer(%<r>s) == 0)', ''],
    'round' => ['%<r>s', '']
  }.freeze

  def compile_integer_unary(name, n, d, recv, argv)
    value, extra_guard = INTEGER_UNARY_OPS[name]
    return nil unless value && n.zero? && native_only_mono?(name) && integer_ancestry_native?(name)

    # NUMERIC_SLOW_PATH: a Float receiver runs Numeric#-@ / #zero? too (both Ruby over Numeric), so
    # it joins only when Float's ancestry is as clean as Integer's; `zero?` has nothing to add otherwise.
    float = integer_ancestry_native?(name, 'Float')
    fallback = if name == 'zero?' && !float
                 dynamic_dispatch_line(d, recv, name, argv)
               else
                 numeric_slow_call(name, d, recv, argv, float: name == '-@' && float)
               end
    <<~CPP
        // INTEGER_UNARY :#{name} -- Integer receiver computed inline; bigint, Float and other classes take NUMERIC_SLOW_PATH
        if (mrb_integer_p(#{recv})#{format(extra_guard, r: recv)}) {
          r#{d} = #{format(value, r: recv)};
        } else {
          #{fallback.chomp}
        }
    CPP
  end

  # builtin_class_send_safe? over `klass`'s ancestry (Integer by default) and every module mixed into it.
  def integer_ancestry_native?(name, klass = 'Integer')
    owners = [klass, 'Numeric', 'Comparable']
    queue = owners.dup
    until queue.empty?
      owner = queue.shift
      (Array(@included_modules[owner]) + Array(@prepended_modules[owner])).each do |mod|
        next if owners.include?(mod)

        owners << mod
        queue << mod
      end
    end
    builtin_class_send_safe?(name, owners)
  end

  # The send after the last generated arm. NativeCoreDirectFallback adds the audited core arms
  # the registered expressions could not derive (String#size).
  def registered_expression_fallback(_d, _recv, _name, _argv, dispatch)
    dispatch
  end

  # Exhaustive exact-class sets need only select a native expression by tag.
  # The caller has already proved every registration's body and lookup safe.
  def native_expression_union_code(name, d, recv, argv, irep, idx, reg)
    return nil if ENV['BC2CPP_NATIVE_EXPRESSION_UNIONS'] == '0'
    return nil unless @closed_world&.exact_instances_singleton_free? && irep && idx && reg

    mask = exact_flow_mask(irep, idx, reg)
    return nil unless mask.is_a?(Integer) && mask.positive?

    classes = RETURN_CORE_CLASS.select { |bit, _klass| mask.anybits?(bit) }
    return nil unless classes.size > 1 && classes.keys.reduce(0, :|) == mask

    entries = classes.values.map do |klass|
      matches = @native_registered_expressions.fetch(name, []).select { |entry| entry[:owner][:class_name] == klass && entry[:arity] == argv.size }
      return nil unless matches.one?

      matches.first
    end
    arms = entries.map do |entry|
      expression = entry[:expression].gsub('recv', recv)
      expression = expression.gsub('BC2CPP_ARG0', argv.fetch(0)) if entry[:arity] == 1
      "case #{entry[:owner][:tag]}: r#{d} = #{expression}; break;"
    end.join("\n    ")
    "  // NATIVE_EXPRESSION_UNION :#{name} -- proven #{classes.values.join('/')} receiver set, no dispatch\n" \
      "  switch (mrb_type(#{recv})) {\n    #{arms}\n" \
      "    default: mrb_raise(M, mrb_exc_get(M, \"RuntimeError\"), \"bc2cpp: invalid exact native receiver set\");\n  }\n"
  end

  # Emit a generated native expression behind a runtime type-tag guard. Heap
  # objects also require their exact built-in class pointer; Float and Symbol
  # are immediate values and use only their unambiguous type tags.
  def compile_native_registered_expression(name, d, recv, argv)
    entries = @native_registered_expressions[name]
    fallback = dynamic_dispatch_line(d, recv, name, argv)
    return fallback unless entries && !entries.empty?
    return fallback unless entries.all? { |entry| entry[:arity] == argv.length }

    fallback = registered_expression_fallback(d, recv, name, argv, fallback)

    # EXACT_CORE_RECEIVER (ADR 0280, ADR 0301): a proven exact class takes its own arm without the tag
    # test, or none when no registration is its own (the arms' classes are all other ones).
    site = exact_core_site_for(recv, name)
    if site
      exact = entries.find { |entry| entry[:owner][:class_name] == site[:klass] }
      return fallback unless exact

      expression = exact[:expression].gsub('recv', recv)
      expression = expression.gsub('BC2CPP_ARG0', argv.fetch(0)) if exact[:arity] == 1
      return "// CLOSED_WORLD_NATIVE_EXACT :#{name} -> #{site[:klass]} registered body; exact receiver (unguarded proof), no dispatch fallback\n" \
             "  r#{d} = #{expression};\n"
    end

    arms = entries.map do |entry|
      owner = entry[:owner]
      expression = entry[:expression].gsub('recv', recv)
      expression = expression.gsub('BC2CPP_ARG0', argv.fetch(0)) if entry[:arity] == 1
      source_comment = if name == 'clear' && owner[:class_name] == 'Array' && expression.include?('mrb_ary_clear')
                         '// ARRAY_CLEAR :clear -- generated from mruby core C'
                       end
      exact_class = IMMEDIATE_NATIVE_CLASSES.include?(owner[:class_name]) ? '' :
                      " && mrb_obj_ptr(#{recv})->c == M->#{owner[:field]}"
      <<~CPP.chomp
        #{source_comment}
        if (mrb_type(#{recv}) == #{owner[:tag]}#{exact_class}) {
          r#{d} = #{expression};
        } else
      CPP
    end.join
    <<~CPP
      // #{name} -- generated from native registrations and C method bodies
      {
      #{arms} {
        #{fallback.chomp}
      }
      }
    CPP
  end
end
