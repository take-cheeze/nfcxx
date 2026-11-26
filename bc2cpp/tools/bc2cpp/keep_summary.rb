# frozen_string_literal: true

require 'set'
require 'stringio'
require_relative 'compact_output'

# ELEMENT_READ_SUMMARY (element_read_roots.rb): a root an element read gets for being live across a call carries a
# marker naming what those calls call. Once the whole unit is printed, each function it defines is summarised over
# its own text and its callees', and a marked root is dropped when every name is safe for the caller (caller_safe?):
#   - a clean function calls nothing outside AUDITED, the store, restore and raise names below and the unit's
#     summarised functions, so no Ruby code runs and nothing is unlinked except by a store that roots what it
#     replaces (bc2cpp_keep_old ...) or replaces an immediate (an embedded field, GC_KEEP_OVERWRITTEN);
#   - and it does not both store and restore the arena: such a store's root lives in the arena until a restore, and
#     a callee's own restore is the only one that can come before the caller's use (one at or above its entry level
#     never drops an entry the caller made, so the element's container stays reachable as it was);
#   - code that runs only on the way to a raise (a raise helper, a [[noreturn]] function) is safe when the call is
#     outside every handler region: the raise leaves the caller and the element is never used. A function that
#     catches turns such code into unknown code, since it then returns normally.
# Anything the text scan cannot read (a #define of the name, a call through a pointer or a member, a brace-initialised
# object, a store that is not to a plain local or an embedded field) is unknown. BC2CPP_ELEMENT_READ_SUMMARY=0 emits
# no markers and keeps every root.
module KeepSummary
  MARK = 'KEEP_SUMMARY'
  MARKED = %r{^([ \t]*)bc2cpp_keep\(M, ([^;\n]*)\); /\* #{MARK}(H?) ([^*\n]*) \*/\n}

  # External names that run no Ruby code, store into no existing slot and restore no arena: value constructors,
  # predicates and accessors, reads, identity tests, interning, class tests that walk ancestors, the write barriers
  # (a store's companion; the store itself is read from the text), allocators of plain objects (a GC frees only
  # unreachable objects) and the arena save (it only reads the index).
  AUDITED = Set[
    'mrb_fixnum_value', 'mrb_fixnum', 'mrb_integer', 'mrb_integer_value', 'mrb_fixnum_p', 'mrb_integer_p',
    'mrb_float_p', 'mrb_float_value', 'mrb_float', 'mrb_nil_p', 'mrb_nil_value', 'mrb_undef_value', 'mrb_undef_p',
    'mrb_array_p', 'mrb_hash_p', 'mrb_string_p', 'mrb_range_p', 'mrb_symbol_p', 'mrb_symbol_value', 'mrb_symbol',
    'mrb_sym', 'mrb_test', 'mrb_bool_value', 'mrb_immediate_p', 'mrb_obj_ptr', 'mrb_obj_value', 'mrb_ary_ptr',
    'mrb_hash_ptr', 'mrb_str_ptr', 'mrb_ptr', 'mrb_true_value', 'mrb_false_value', 'mrb_bool', 'mrb_true_p',
    'mrb_false_p', 'mrb_type', 'mrb_class_ptr', 'mrb_basic_ptr', 'mrb_frozen_p', 'mrb_likely', 'mrb_unlikely',
    'mrb_ary_entry', 'mrb_ary_ref', 'RARRAY_LEN', 'RARRAY_PTR', 'ARY_PTR', 'ARY_LEN', 'ARY_EMBED_P', 'RSTRING_LEN',
    'RSTRING_PTR', 'ARY_EMBED_PTR', 'ARY_SHARED_P', 'ARY_EMBED_LEN', 'DATA_PTR', 'MRB_SYM', 'MRB_OPSYM', 'MRB_IVSYM',
    'MRB_QSYM', 'mrb_intern_cstr', 'mrb_intern_lit',
    'mrb_intern_static', 'mrb_intern', 'mrb_iv_get', 'mrb_obj_eq', 'mrb_obj_equal', 'mrb_str_equal', 'mrb_obj_class',
    'mrb_obj_is_kind_of', 'mrb_obj_is_instance_of', 'mrb_field_write_barrier', 'mrb_field_write_barrier_value',
    'mrb_write_barrier', 'mrb_ary_new', 'mrb_ary_new_capa', 'mrb_ary_new_from_values', 'mrb_str_new',
    'mrb_str_new_cstr', 'mrb_str_new_static', 'mrb_str_new_lit', 'mrb_hash_new', 'mrb_hash_new_capa', 'mrb_int_value',
    'mrb_gc_arena_save', 'bc2cpp_keep', 'bc2cpp_root', 'mrb_gc_protect', 'BC2CPP_FIXNUM_PAIR_P', 'BC2CPP_FIXNUM_WORD',
    'BC2CPP_SAME_WORD', '__builtin_add_overflow', '__builtin_sub_overflow', '__builtin_mul_overflow',
    'mrb_int_add_overflow',
    'mrb_int_sub_overflow', 'mrb_int_mul_overflow', 'FIXABLE',
    # numops.c: Integer, bigint and Float arithmetic, which allocates and otherwise raises a TypeError.
    'mrb_num_add', 'mrb_num_sub', 'mrb_num_mul',
    # reads: a global (no hooks in mruby), a class name, a String's length, a Hash's emptiness, the bigint tag
    'mrb_gv_get', 'mrb_obj_classname', 'mrb_class_name', 'mrb_exc_ptr', 'mrb_bigint_p', 'RSTR_LEN', 'mrb_hash_empty_p',
    'mrb_hash_size', 'mrb_class', 'mrb_class_p', 'mrb_module_p', 'mrb_sclass_p', 'mrb_proc_p', 'mrb_proc_ptr',
    # appends to a String's own buffer (a FrozenError otherwise)
    'mrb_str_cat', 'mrb_str_cat_cstr', 'mrb_str_cat_lit',
    # include/mrb_array_access.hxx: an Array's length and element pointer
    'ary_size', 'ary_items',
    # conversions and division that compute or raise a TypeError / ZeroDivisionError (object.c, numeric.c)
    'mrb_as_float', 'mrb_ensure_float_type', 'mrb_as_int', 'mrb_ensure_int_type', 'mrb_ensure_integer_type',
    'mrb_bint_cmp', 'mrb_div_float', 'mrb_div_int_value',
    # mruby-rgss/src/lib.cxx: each returns the class its init stored
    'native_rect_class', 'native_color_class', 'native_tone_class', 'native_sprite_class', 'native_bitmap_class',
    'native_table_class', 'native_window_class', 'native_viewport_class', 'native_plane_class', 'native_tilemap_class'
  ].freeze
  # Stores that root the value they replace or unlink before it is lost (bc2cpp.rb, GC_KEEP_OVERWRITTEN), and the
  # appends, which unlink nothing.
  STORES = Set[
    'bc2cpp_keep_old', 'bc2cpp_keep_olds2', 'bc2cpp_keep_olds3', 'bc2cpp_keep_old_range', 'bc2cpp_keep_removed',
    'bc2cpp_iv_set', 'bc2cpp_gv_set', 'bc2cpp_embed_store', 'bc2cpp_embed_store_unfrozen', 'bc2cpp_ary_set',
    'bc2cpp_raw_ary_set', 'bc2cpp_mrb_ary_set', 'bc2cpp_mrb_ary_splice', 'bc2cpp_mrb_ary_clear',
    'bc2cpp_mrb_ary_replace', 'bc2cpp_mrb_ary_pop', 'bc2cpp_mrb_ary_shift', 'mrb_ary_set', 'mrb_ary_splice',
    'mrb_ary_clear', 'mrb_ary_replace', 'mrb_ary_pop', 'mrb_ary_shift', 'bc2cpp_ary_push', 'mrb_ary_push'
  ].freeze
  RESTORES = Set['mrb_gc_arena_restore', 'bc2cpp_arena_keep'].freeze
  # Unit helpers read by hand: bc2cpp_sym interns a name into the unit's mrb_sym cache, which holds no object; the
  # TAGGED_FIXNUM word helpers (tagged_fixnum.rb) write their result through a reference to the caller's register.
  # The constant and class caches (codegen_const_tables.rb, the owner class slots) fill a slot once with what the
  # lookup finds, which a missing constant turns into const_missing's raise.
  AUDITED_HELPERS = Set['bc2cpp_sym', 'bc2cpp_fixnum_add', 'bc2cpp_fixnum_sub', 'bc2cpp_fixnum_mul',
                        'bc2cpp_cconst_get', 'bc2cpp_owner_class_at', 'bc2cpp_owner_ref'].freeze
  # Calls that run code only on the way to a raise: the raise helpers, and the frozen check, which returns normally
  # having run nothing. mrb_exc_get_id names the raised class (an argument of the raise).
  RAISES = Set['mrb_raise', 'mrb_raisef', 'mrb_exc_raise', 'mrb_no_method_error', 'mrb_argnum_error',
               'mrb_check_frozen', 'mrb_frozen_error', 'mrb_exc_get_id'].freeze
  KEYWORDS = Set['if', 'while', 'for', 'switch', 'return', 'sizeof', 'else', 'do', 'catch', 'throw', 'alignof',
                 'decltype', 'static_assert', 'defined', '__builtin_expect',
                 # function-style casts of scalars
                 'int', 'unsigned', 'char', 'bool', 'size_t', 'intptr_t', 'uintptr_t', 'int16_t', 'uint16_t',
                 'int32_t', 'uint32_t', 'int64_t', 'uint64_t', 'uint8_t', 'mrb_int', 'mrb_float', 'mrb_sym'].freeze
  # SymbolCache rewrites a `_named` helper of a method's text into these by the time the unit is printed, so a
  # marker naming the first stands for all of the second.
  RENAMED = { 'bc2cpp_nomethod_named' => %w[bc2cpp_nomethod],
              'bc2cpp_nomethod_raise_named' => %w[bc2cpp_nomethod_raise],
              'bc2cpp_guard_violation_named' => %w[bc2cpp_guard_violation],
              'bc2cpp_hint_violation_named' => %w[bc2cpp_hint_violation],
              'bc2cpp_nil_receiver_named' => %w[bc2cpp_nil_receiver bc2cpp_nil_receiver_id] }.freeze
  NAME = /(?<![\w$])([A-Za-z_][\w$]*)\s*\(/
  NAME_BYTES = Array.new(256) do |ch|
    ch == 36 || ch == 95 || (ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)
  end.freeze
  SPACE_BYTES = Array.new(256) { |ch| ch == 32 || (ch >= 9 && ch <= 13) }.freeze
  # `Type name{...}` / `Type{...}`: an object whose constructor and destructor the scan cannot see.
  BRACE_INIT = /(?<![\w$])([A-Za-z_][\w$:<>]*)\s+[A-Za-z_]\w*\s*\{|
                (?<![\w$])(?!(?:else|do|try)\b)([A-Za-z_][\w$:<>]*)\s*\{/x

  module_function

  # NAME over the binary, comment/literal-blanked body. Locate each '(' in C, then walk back over its whitespace and
  # identifier. Reading the whole token also enforces NAME's left boundary: neither a digit nor '$' may start it.
  # Unlike scan with a capture, this allocates only the name, without a capture Array or regexp match at every call.
  def each_call_name(body)
    pos = 0
    while (at = body.index('(', pos))
      pos = at + 1
      last = at - 1
      last -= 1 while last >= 0 && SPACE_BYTES[body.getbyte(last)]
      first = last
      first -= 1 while first >= 0 && NAME_BYTES[body.getbyte(first)]
      first += 1
      next if first > last

      ch = body.getbyte(first)
      next unless ch == 95 || (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)

      yield body.byteslice(first, last - first + 1)
    end
  end

  def marker(callees, handler)
    "/* #{MARK}#{handler ? 'H' : ''} #{callees.to_a.sort.join(' ')} */"
  end

  # Registered after the other output passes, so it runs first (at_exit is last-in first-out) on the unit as printed.
  def capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      original.write(rewrite(buffer.string)) unless $!
    end
  end

  def rewrite(text)
    return text unless text.include?(MARK)

    report = ENV['BC2CPP_KEEP_SUMMARY_REPORT'] == '1'
    unit = Unit.new(text)
    dropped = 0
    out = text.gsub(MARKED) do
      indent, value, handler, names = Regexp.last_match.captures
      if names.split.all? { |name| unit.caller_safe?(name, handler == 'H') }
        dropped += 1
        ''
      else
        unit.explain(names.split, handler == 'H') if report
        "#{indent}bc2cpp_keep(M, #{value});\n"
      end
    end
    if report
      warn "KEEP_SUMMARY: dropped #{dropped} of #{text.scan(MARKED).size} marked roots"
      unit.report
    end
    out
  end

  # The unit's top-level function definitions and their summaries.
  class Unit
    class Unreadable < StandardError; end

    VALUE_GLOBAL = /^(?:static\s+|inline\s+)*mrb_value\s+([A-Za-z_]\w*)\s*(?:\[[^\]\n]*\])?\s*[=;]/

    Summary = Struct.new(:unknown, :stores, :restores, :raises, :blocker)

    def initialize(text)
      @text = text.gsub(CompactOutput::TOKENS) { |token| token.gsub(/[^\n]/, ' ') }.b
      @macros = Set.new
      @bodies = {}
      @noreturn = Set.new
      # File-scope mrb_value variables: a store to one by name is a slot store, not a local's.
      # Both sets are collected by scan_definitions' own line walk below, so the text is read once.
      @value_globals = Set.new
      @summaries = {}
      begin
        scan_definitions
      rescue Unreadable => e
        warn "KEEP_SUMMARY: the unit is not read (#{e.message}); every marked root is kept"
        @bodies = {}
      end
    end

    def clean?(name, handler)
      s = summary(name)
      !s.unknown && !(s.stores && s.restores) && !(handler && s.raises)
    end

    # A name a caller's marked root guards against is harmless there. A store helper roots what it replaces in the
    # caller's own arena, which only the caller's own restore (itself a marked name) could drop; it may raise.
    def caller_safe?(name, handler)
      return RENAMED[name].all? { |renamed| caller_safe?(renamed, handler) } if RENAMED.key?(name)
      return !handler if STORES.include?(name) || RAISES.include?(name)
      return false if RESTORES.include?(name)
      return true if AUDITED_HELPERS.include?(name)
      return clean?(name, handler) if @bodies.key?(name)

      AUDITED.include?(name) && !(@macros.include?(name) && !name.start_with?('BC2CPP_'))
    end

    def explain(names, handler)
      names.each do |name|
        s = summary(name)
        next if caller_safe?(name, handler)

        warn "KEEP_SUMMARY kept for #{name}: unknown=#{s.unknown} (#{s.blocker}) stores=#{s.stores} " \
             "restores=#{s.restores} raises=#{s.raises} handler=#{handler}"
      end
    end

    def report
      blockers = Hash.new(0)
      @summaries.each_value { |s| blockers[s.blocker] += 1 if s.unknown }
      blockers.sort_by { |_, n| -n }.first(40).each { |b, n| warn "KEEP_SUMMARY blocker #{n} #{b}" }
    end

    # Greatest fixed point over the call graph: a function on a cycle is assumed clean until a member proves
    # otherwise, so the summaries are computed for all definitions together, then read.
    def summary(name)
      compute_all if @summaries.empty?
      @summaries[name] || Summary.new(true, true, true, true, "undefined #{name}")
    end

    private

    def compute_all
      own = @bodies.to_h do |name, bodies|
        [name, @noreturn.include?(name) ? noreturn_effects : own_effects(bodies.join("\n"))]
      end
      cur = own.transform_values(&:dup)
      changed = true
      while changed
        changed = false
        cur.each do |name, s|
          own[name][:callees].each do |callee|
            c = cur[callee]
            next unless c

            %i[unknown stores restores raises].each do |bit|
              next if s[bit] || !c[bit]

              s[bit] = true
              s[:blocker] ||= "via #{callee}" if bit == :unknown
              changed = true
            end
          end
          next unless own[name][:catches] && s[:raises] && !s[:unknown]

          s[:unknown] = true
          s[:blocker] ||= 'catches a raise'
          changed = true
        end
      end
      cur.each do |name, s|
        @summaries[name] = Summary.new(s[:unknown], s[:stores], s[:restores], s[:raises], s[:blocker])
      end
    end

    # A [[noreturn]] function only ever leaves by a raise, whatever it runs first.
    def noreturn_effects
      { unknown: false, stores: false, restores: false, raises: true, callees: Set.new, blocker: nil, catches: false }
    end

    def own_effects(body)
      s = { unknown: false, stores: false, restores: false, raises: false, callees: Set.new, blocker: nil,
            catches: body.match?(/\bcatch\s*\(/) }
      flag = lambda do |why|
        s[:unknown] = true
        s[:blocker] ||= why
      end
      KeepSummary.each_call_name(body) do |called|
        next if KEYWORDS.include?(called)

        if STORES.include?(called)
          s[:stores] = true
          s[:raises] = true
        elsif RESTORES.include?(called)
          s[:restores] = true
        elsif RAISES.include?(called)
          s[:raises] = true
        elsif AUDITED_HELPERS.include?(called)
          next
        elsif @bodies.key?(called)
          s[:callees] << called
        elsif (@macros.include?(called) && !called.start_with?('BC2CPP_')) || !AUDITED.include?(called)
          flag.call(called)
        end
      end
      body.scan(BRACE_INIT) { |a, b| flag.call("brace-init #{a || b}") }
      values = Set.new(body.scan(/\bmrb_value\s+([A-Za-z_]\w*)/).flatten)
      # Attributes never contain a statement boundary, so they are blanked once for the body
      # instead of once per statement below.
      body = body.gsub(/\[\[[^\]]*\]\]/, ' ')
      statements(body).each do |stmt|
        case store_kind(stmt, values)
        when :embedded then s[:stores] = true
        when :raw then flag.call("store #{stmt.strip[0, 60]}")
        end
        flag.call('reference binding') if stmt.match?(/(?<!&)&\s*[A-Za-z_]\w*\s*=(?!=)/)
      end
      s
    end

    ASSIGN_AT = /(?<![=!<>])(?:[+\-*\/%&|^]|<<|>>)?=(?!=)/
    PLAIN_LHS = /\A\s*(?:[A-Za-z_][\w:]*(?:<[^<>]*>)?[\s*]+)*[A-Za-z_]\w*\s*\z/
    # The member of a local mrb_value (`v.w = x`): the value itself, not a slot.
    VALUE_MEMBER = /\A\s*([A-Za-z_]\w*)\s*\.\s*(?:w|tt|value\s*\.\s*\w+)\s*\z/
    # An embedded ivar field, `((T_ivars*)DATA_PTR(obj))->ivar_x` (the statement split leaves the part after the cast):
    # GC_KEEP_OVERWRITTEN roots what such a store replaces, or proves it an immediate (IMMEDIATE_OLD, a typed field).
    EMBEDDED_LHS = /\A\s*DATA_PTR\(\s*\w+\s*\)\s*\)\s*->\s*ivar_\w+\s*\z/
    STEP = /\+\+|--/

    # :none when a statement writes only plain locals, :embedded for an embedded ivar store, :raw for any other write
    # (an assignment through a pointer, a member or a subscript, or an increment of one).
    # PLAIN_IDENT is PLAIN_LHS's single-identifier shape, without its backtracking-heavy optional groups: anything it
    # accepts PLAIN_LHS accepts too (zero group iterations), so only the rest needs the full pattern.
    PLAIN_IDENT = /\A\s*[A-Za-z_]\w*\s*\z/
    def store_kind(stmt, values)
      kind = :none
      stmt.scan(ASSIGN_AT) do
        lhs = stmt.byteslice(0, Regexp.last_match.begin(0))
        if lhs.match?(EMBEDDED_LHS)
          kind = :embedded
          next
        end
        # The assigned expression starts after the last open parenthesis, comma or operator: `if (!f(x = g()))`.
        lhs = lhs[/(?:\A|[(,!?]|&&|\|\||\breturn\b)([^(,!?]*)\z/, 1].to_s
        name = lhs[/([A-Za-z_]\w*)\s*\z/, 1]
        next if (lhs.match?(PLAIN_IDENT) || lhs.match?(PLAIN_LHS)) && !@value_globals.include?(name)
        next if (m = VALUE_MEMBER.match(lhs)) && values.include?(m[1])

        return :raw
      end
      if stmt.include?('++') || stmt.include?('--')
        stmt.scan(STEP) do
          m = Regexp.last_match
          before = stmt.byteslice(0, m.begin(0))[/[\w$.\->\[\]*]*\z/]
          after = stmt.byteslice(m.end(0)..)[/\A[\w$.\->\[\]*]*/]
          operand = before.empty? ? after : before
          return :raw unless operand.match?(/\A[A-Za-z_]\w*\z/)
        end
      end
      kind
    end

    # The body split at statement and block boundaries; an assignment never spans one.
    def statements(body)
      body.split(/[;{}]|\b(?:if|while|for|switch)\s*\(|\)\s*(?=[A-Za-z_*])/)
    end

    # Top-level `name(...) {` definitions. Every branch of an #if group is read, each from the depth at its #if; the
    # group must leave the same depth on every branch, or the unit is not read at all. A name defined twice with
    # different bodies is unknown. The walk also collects the #define names and the mrb_value globals the summaries
    # read, so the text is scanned once: a continued directive line is not a definition, and a global spanning lines
    # (which the generated code never emits) is missed, keeping its stores conservative.
    def scan_definitions
      macro_define = /\A[ \t]*#[ \t]*define[ \t]+([A-Za-z_][\w$]*)/
      depth = 0
      start = nil
      header_from = 0
      groups = []
      continued = false
      pos = 0
      @text.each_line do |line|
        directive = continued || line.lstrip.start_with?('#')
        if directive
          unless continued
            if (defined_name = macro_define.match(line))
              @macros << defined_name[1]
            end
            case line.lstrip[/\A#\s*(\w+)/, 1]
            when 'if', 'ifdef', 'ifndef' then groups << [depth, nil]
            when 'elif', 'else'
              group = groups.last or raise Unreadable, 'unmatched #else'
              raise Unreadable, 'branches end at different depths' if group[1] && group[1] != depth

              group[1] = depth
              depth = group[0]
            when 'endif'
              group = groups.pop or raise Unreadable, 'unmatched #endif'
              raise Unreadable, 'branches end at different depths' if group[1] && group[1] != depth
            end
          end
          continued = line.rstrip.end_with?('\\')
          pos += line.bytesize
          header_from = pos if depth.zero?
          next
        end
        if (global = VALUE_GLOBAL.match(line))
          @value_globals << global[1]
        end
        line.each_byte.with_index do |ch, i|
          if ch == 123 # {
            if depth.zero?
              header = @text.byteslice(header_from, pos + i - header_from)
              if header.match?(/\b(?:namespace|extern)\b[^(){}]*\z/)
                header_from = pos + i + 1
                next
              end
              start = [header, pos + i]
            end
            depth += 1
          elsif ch == 125 # }
            depth -= 1
            if depth.zero? && start
              define(start[0], @text.byteslice(start[1], pos + i + 1 - start[1]))
              start = nil
              header_from = pos + i + 1
            elsif depth.negative?
              depth = 0
              header_from = pos + i + 1
            end
          elsif ch == 59 && depth.zero? # ;
            header_from = pos + i + 1
          end
        end
        pos += line.bytesize
      end
    end

    HEADER = /([A-Za-z_][\w$]*)\s*\((?:[^()]|\([^()]*\))*\)\s*(?:const\s*)?(?:noexcept\s*)?\z/

    # A name defined more than once (the branches of an #if) is summarised over every body.
    def define(header, body)
      m = HEADER.match(header.rstrip)
      return unless m

      name = m[1]
      return if KEYWORDS.include?(name)

      # Every definition of the name must be [[noreturn]] for the calls to count as raises.
      noreturn = header.match?(/\bnoreturn\b/)
      if @bodies.key?(name)
        @noreturn.delete(name) unless noreturn
      elsif noreturn
        @noreturn << name
      end
      bodies = (@bodies[name] ||= [])
      bodies << "#{m[0]}#{body}" unless bodies.include?("#{m[0]}#{body}")
    end
  end
end
