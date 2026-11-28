# frozen_string_literal: true

require 'set'
require_relative 'branch_hints'

# SYMBOL_CACHE: generated C++ used to spell every ivar/constant/method name and
# symbol literal as `mrb_intern_cstr(M, "name")` (or a `mrb_funcall(M, r,
# "name", ...)`, which interns the same way), paying a presym binary search plus
# a symbol-table lookup per execution -- hot in Game::Interpreter#execute's
# command switch.
#
# This rewrites the finished C++ of every compiled function so each distinct
# literal is interned once per VM and read from a file-scope table afterwards.
# It is a purely textual pass over calls this generator itself emits, so it
# cannot change which symbol a call site names.
module SymbolCache
  STRING = /"(?:[^"\\\n]|\\.)*"/
  INTERN = /\bmrb_intern_(?:cstr|lit)\(M,\s*(#{STRING})\)/
  # CHECKED_SEND: codegen_checked_send.rb marks a by-name call that must do what
  # OP_SEND / OP_SSEND check and mrb_funcall does not; the slot carries the check's level.
  # NATIVE_SINGLETON_CALL: `bc2cpp_native_singleton_named` is an explicit-receiver by-name call whose
  # method the compiler proved to be one native singleton function; it keeps level 2 as its fallback is a
  # checked send, and gets a method cache slot (BC2CPP_NSC_SLOT_OF: one per kind and method id, see NATIVE_SINGLETON).
  # CORE_SELF_NATIVE: `bc2cpp_native_owner_named` is the same for a self call (level 1: no visibility check).
  # EXACT_NATIVE_SLOT: `bc2cpp_native_slot_named` is an explicit-receiver call (level 2) with a slot per method id.
  CHECKED_FUNCALLS = { 'bc2cpp_funcall_noarg' => 1, 'bc2cpp_funcall_explicit' => 2,
                       'bc2cpp_native_singleton_named' => 2, 'bc2cpp_native_owner_named' => 1,
                       'bc2cpp_native_slot_named' => 2 }.freeze
  FUNCALLS = (%w[mrb_funcall] + CHECKED_FUNCALLS.keys).freeze
  # These scans consume binary C++ text. Byte offsets avoid mruby-onig rescanning UTF-8 prefixes.
  FUNCALL_START = /\b(#{FUNCALLS.join('|')}|bc2cpp_owner_call_argv_named|bc2cpp_owner_call_named|bc2cpp_nomethod_named|bc2cpp_nomethod_raise_named|bc2cpp_guard_violation_named|bc2cpp_hint_violation_named|bc2cpp_nil_receiver_named)\(M,\s*/n
  FUNCALL_NAME = /\G,\s*(#{STRING})\s*,/n
  NAMED_NAME = /\G,\s*(#{STRING})(?=\s*[,)])/n
  SEND_INDEX = /\G,\s*(\d+)\s*[,)]/n
  NIL_ID_INDEX = /\G(\d+)\s*[,)]/n
  # OWNER_CALL_DESC: the level and owner set after an owner call's name; the slot and level move into the set's macro.
  OWNER_CALL_SET = /\G,\s*([0-2])\s*,\s*(BC2CPP_OWNERS(?:_D)?)\(/n
  # The slot of a rewritten owner call: the first argument of its set macro (BC2CPP_SHARED's after the key).
  OWNER_CALL_INDEX = /\G,\s*BC2CPP_(?:OWNERS(?:_D)?|SHARED)\((?:0x\h+,\s*)?(\d+)\s*,/n
  private_constant :STRING, :INTERN, :CHECKED_FUNCALLS, :FUNCALLS,
                   :FUNCALL_START, :FUNCALL_NAME, :NAMED_NAME, :SEND_INDEX, :NIL_ID_INDEX, :OWNER_CALL_SET, :OWNER_CALL_INDEX

  # Symbols found so far, in first-seen order: C string literal => index.
  class Table
    # CLOSED_WORLD: set once a bc2cpp_nomethod call is rewritten, so emit adds it.
    attr_accessor :nomethod_used
    # GUARD_VIOLATION: the same for bc2cpp_guard_violation.
    attr_accessor :violation_used
    # STRICT_HINTS: the same for bc2cpp_hint_violation.
    attr_accessor :hint_violation_used
    # NIL_RECEIVER: the same for bc2cpp_nil_receiver.
    attr_accessor :nil_receiver_used
    # NATIVE_SINGLETON_CALL: the same for bc2cpp_native_singleton.
    attr_accessor :native_singleton_used
    # OUTSIDE_OWNER_CALL: the same for bc2cpp_owner_call.
    attr_accessor :owner_call_used

    # EXACT_NATIVE_SLOT: the symbol indices bc2cpp_native_slot calls use, one slot each.
    def native_slots
      @native_slots ||= Set.new
    end

    # CHECKED_SEND: per slot, 0 plain, 1 argument count of an attr_reader, 2 that and
    # the explicit-receiver visibility check.
    attr_reader :checks

    def initialize
      @index = {}
      @checks = []
      @nomethod_used = false
      @violation_used = false
      @hint_violation_used = false
      @nil_receiver_used = false
      @native_singleton_used = false
      @owner_call_used = false
    end

    # A checked send gets a slot of its own, apart from the same name's plain slot.
    def index_for(literal, check = 0)
      key = check.zero? ? literal : [literal, check]
      @index.fetch(key) do
        @checks[@index.size] = check
        @index[key] = @index.size
      end
    end

    def literals
      @index.keys.map { |key| key.is_a?(Array) ? key.first : key }
    end

    def size
      @index.size
    end
  end

  module_function

  # Rewrite one function's C++ text against `table`.
  def rewrite(code, table)
    # PROGRAM_OWNER_SITES: a helper's program-wide calls name no slot, but need the owner call and nomethod bodies.
    table.owner_call_used = true if code.include?('bc2cpp_owner_call_pw')
    table.nomethod_used = true if code.include?('bc2cpp_nomethod_pw(')
    rewrite_interns(rewrite_funcalls(code, table), table)
  end

  def rewrite_interns(code, table)
    code.gsub(INTERN) do
      literal = Regexp.last_match(1)
      presym_macro(literal) || "bc2cpp_sym(M, #{table.index_for(literal)})"
    end
  end

  # PRESYM_SYMBOL: a plain identifier that mruby's presym table already names is the compile-time symbol MRB_SYM(name),
  # so it needs no table slot or cache. The table is the build's include/mruby/presym/id.h (BC2CPP_PRESYM_HEADER,
  # set by closed_build.bash); without it every name keeps the table.
  # PRESYM_ALL: in a real gem build mruby's presym scan reads the generated sources themselves (each gem's
  # src/register.cxx includes its unit), so a name spelled with a presym macro (PresymSpelling.symbol) becomes a presym:
  # a compile-time id, with no RAM slot and no intern at run time. A fixture has no such scan and keeps the table.
  class << self
    attr_writer :presym_names, :presym_all

    def presym_names = @presym_names || Set.new
    def presym_all = @presym_all || false
  end

  # The presym macro for a C string literal, or nil: every spellable name under PRESYM_ALL, otherwise a plain identifier
  # the build's presym table already has.
  def presym_macro(literal)
    name = literal[/\A"([^"\\]*)"\z/, 1]
    return nil unless name
    return PresymSpelling.symbol(name) if SymbolCache.presym_all

    "MRB_SYM(#{name})" if name.match?(/\A[A-Za-z_]\w*\z/) && SymbolCache.presym_names.include?(name)
  end

  # `mrb_funcall(M, RECV, "name", N, ...)` -> `bc2cpp_send(M, RECV, i, N, ...)`. RECV is an arbitrary C++ expression, so the
  # receiver is delimited with a bracket/quote-aware scan; a call whose name is
  # not a plain string literal is left alone.
  # CLOSED_WORLD's `bc2cpp_nomethod_named(M, RECV, "name"...)` becomes
  # `bc2cpp_nomethod(M, RECV, i...)` the same way, and GUARD_VIOLATION's
  # `bc2cpp_guard_violation_named(M, RECV, "name", "site", ...)` becomes
  # `bc2cpp_guard_violation(M, RECV, i, "site", ...)`; NIL_RECEIVER's
  # `bc2cpp_nil_receiver_named(M, RECV, "name", ...)` becomes `bc2cpp_nil_receiver(M, RECV, i, ...)`.
  # CALLER_SELF: an explicit-receiver (level 2) call also passes the generated code's `self` after its arguments, for
  # vm.c's protected check (the caller's self must be a kind_of the method's class or module).
  def rewrite_funcalls(code, table, encoding: code.encoding)
    # The grammar is ASCII; byte offsets avoid rescanning UTF-8 prefixes at each match.
    code = code.b
    out = +''.b
    pos = 0
    selves = []
    copy = lambda do |from, to|
      while (at = selves.first) && at < to
        out << code[from...at] << ', self'.b
        from = at
        selves.shift
      end
      out << code[from...to]
    end
    while (start = code.index(FUNCALL_START, pos))
      kind = Regexp.last_match(1)
      head_end = Regexp.last_match.end(0)
      recv_end = expression_end(code, head_end)
      name = recv_end && (FUNCALLS.include?(kind) ? FUNCALL_NAME : NAMED_NAME).match(code, recv_end)
      if name && caller_self_call?(kind, code, name.end(0)) && (close = call_close(code, recv_end))
        selves << close
        selves.sort!
      end
      if name
        # The receiver may itself contain a funcall; rewrite it first so its
        # names take their slots before this call's own.
        receiver = rewrite_funcalls(code[head_end...recv_end], table, encoding: encoding)
        index = table.index_for(name[1].force_encoding(encoding), CHECKED_FUNCALLS.fetch(kind, 0))
        table.nomethod_used = true if kind == 'bc2cpp_nomethod_named' || kind == 'bc2cpp_nomethod_raise_named'
        table.violation_used = true if kind == 'bc2cpp_guard_violation_named'
        table.hint_violation_used = true if kind == 'bc2cpp_hint_violation_named'
        table.nil_receiver_used = true if kind == 'bc2cpp_nil_receiver_named'
        table.native_singleton_used = true if %w[bc2cpp_native_singleton_named bc2cpp_native_owner_named].include?(kind)
        table.owner_call_used = true if %w[bc2cpp_owner_call_named bc2cpp_owner_call_argv_named].include?(kind)
        if kind == 'bc2cpp_native_slot_named'
          table.native_singleton_used = true
          table.native_slots << index
        end
        replacement = case kind
                      when 'bc2cpp_nomethod_named' then "bc2cpp_nomethod(M, #{receiver}, #{index}"
                      when 'bc2cpp_nomethod_raise_named' then "bc2cpp_nomethod_raise(M, #{receiver}, #{index}"
                      when 'bc2cpp_guard_violation_named' then "bc2cpp_guard_violation(M, #{receiver}, #{index}"
                      when 'bc2cpp_hint_violation_named' then "bc2cpp_hint_violation(M, #{receiver}, #{index}"
                      when 'bc2cpp_nil_receiver_named'
                        nil_tested?(code, start, receiver) ? "bc2cpp_nil_receiver_id(M, #{index}" : "bc2cpp_nil_receiver(M, #{receiver}, #{index}"
                      when 'bc2cpp_owner_call_named' then "bc2cpp_owner_call(M, #{receiver}, #{index}"
                      when 'bc2cpp_owner_call_argv_named' then "bc2cpp_owner_call_argv(M, #{receiver}, #{index}"
                      when 'bc2cpp_native_singleton_named' then "bc2cpp_native_singleton(M, #{receiver}, #{index}, BC2CPP_NSC_SLOT_OF(0, #{index}),"
                      when 'bc2cpp_native_owner_named' then "bc2cpp_native_owner(M, #{receiver}, #{index}, BC2CPP_NSC_SLOT_OF(1, #{index}),"
                      when 'bc2cpp_native_slot_named' then "bc2cpp_native_slot(M, #{receiver}, #{index}, bc2cpp_xslot_#{index},"
                      else "bc2cpp_send(M, #{receiver}, #{index},"
                      end
        copy.call(pos, start)
        pos = recv_end + name[0].length
        if (set = replacement.start_with?('bc2cpp_owner_call') && OWNER_CALL_SET.match(code, pos))
          replacement = "#{replacement.delete_suffix(", #{index}")}, #{set[2]}(#{index}, #{set[1]}, "
          pos = set.end(0)
        end
        out << replacement.b
      else
        copy.call(pos, head_end)
        pos = head_end
      end
    end
    copy.call(pos, code.length)
    out.force_encoding(encoding)
  end

  OWNER_CALL_EXPLICIT = /\G,\s*2\s*,/n
  private_constant :OWNER_CALL_EXPLICIT

  # NIL_RECEIVER_ID: a nil arm passes no receiver when the text right before the call is the `if (mrb_nil_p(RECV))`
  # test of that same receiver expression, so RECV is nil there and the helper can rebuild it. Any other shape keeps
  # the receiver. BC2CPP_NIL_RECEIVER_ID=0 keeps it everywhere.
  NIL_TEST_TAIL = /if \(mrb_nil_p\(([^()]+)\)\)\s*(?:\{\s*)?(?:(?:BC2CPP_COLD_ARM\s+)?r\d+\s*=\s*)?\z/n
  private_constant :NIL_TEST_TAIL

  def nil_tested?(code, start, receiver)
    return false if ENV['BC2CPP_NIL_RECEIVER_ID'] == '0'

    tail = NIL_TEST_TAIL.match(code[[start - 200, 0].max...start])
    !tail.nil? && tail[1].strip == receiver.strip
  end

  def caller_self_call?(kind, code, after_name)
    case kind
    when 'bc2cpp_funcall_explicit', 'bc2cpp_native_singleton_named' then true
    when 'bc2cpp_owner_call_named', 'bc2cpp_owner_call_argv_named' then OWNER_CALL_EXPLICIT.match?(code, after_name)
    else false
    end
  end

  # Index of the `)` closing the call whose receiver ends at `recv_end`.
  def call_close(code, recv_end)
    i = recv_end
    while i && code[i] == ','
      i = expression_end(code, i + 1)
    end
    i if i && code[i] == ')'
  end

  # The symbol index of every `bc2cpp_send(M, RECV, i, ...)` (and
  # `bc2cpp_nomethod(M, RECV, i...)`) in `code`, found with the same receiver
  # scan the rewrite uses(RECV may nest sends).
  def send_indices(code)
    send_index_kinds(code).map(&:last)
  end

  # [helper, index] for each of those calls: helper is the name after `bc2cpp_` (`send`, `nomethod`, ...).
  def send_index_kinds(code)
    send_sites(code).map { |kind, _recv, idx| [kind, idx] }
  end

  # [helper, receiver text, index] for each of those calls.
  def send_sites(code)
    code = code.b
    found = []
    pos = 0
    while (start = code.index(/\bbc2cpp_(send|nomethod|nomethod_raise|guard_violation|hint_violation|nil_receiver_id|nil_receiver|native_singleton|native_owner|native_slot|owner_call_argv|owner_call)\(M,\s*/n, pos))
      kind = Regexp.last_match(1)
      head_end = Regexp.last_match.end(0)
      if kind == 'nil_receiver_id'
        # NIL_RECEIVER_ID: the index is the first argument; the receiver is nil.
        idx = NIL_ID_INDEX.match(code, head_end)
        found << ['nil_receiver', 'mrb_nil_value()', idx[1].to_i] if idx
        pos = head_end
        next
      end
      recv_end = expression_end(code, head_end)
      match = recv_end && (kind.start_with?('owner_call') ? OWNER_CALL_INDEX : SEND_INDEX).match(code, recv_end)
      idx = match && match[1]
      found << [kind, code[head_end...recv_end].strip, idx.to_i] if idx
      pos = head_end
    end
    found
  end

  # Index of the top-level `,` (or closing `)`) ending the expression that
  # starts at `from`, skipping nested brackets and string/char literals.
  def expression_end(code, from)
    depth = 0
    i = from
    while i < code.length
      c = code[i]
      case c
      when '"', "'"
        i += 1
        i += (code[i] == '\\' ? 2 : 1) while i < code.length && code[i] != c
      when '(', '[', '{'
        depth += 1
      when ')', ']', '}'
        return nil if depth.zero? && c != ')'
        return i if depth.zero?

        depth -= 1
      when ','
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  # EXACT_NATIVE_SLOT (codegen_exact_native_slot.rb): the shared body and one slot per method id the table's calls use.
  def native_slot_source(table)
    slots = table.native_slots.sort.map { |i| "static bc2cpp_xslot bc2cpp_xslot_#{i};\n" }.join
    "#{NATIVE_SLOT}#{slots}"
  end

  # EXACT_NATIVE_SLOT: a call whose receiver the compiler proved one class, whose method the closed world proved a C
  # function (codegen_exact_native_slot.rb). The slot of the method id keeps the method found for one receiver class,
  # valid while mruby's method cache still answers the same (the epoch where MRB_MT_ROWS clears it), so a definition
  # or removal anywhere forces the lookup again. The call runs in the frame mruby's dispatch pushes (bc2cpp_call_found)
  # after OP_SEND's argument-count check. A method that is no C function, or is not public, is not kept: the call is
  # then the checked by-name send, so a wrong proof costs speed, never the answer or the error.
  NATIVE_SLOT = <<~CPP
    #include <string.h>
    #ifndef BC2CPP_SHARD_ONE_BODY
    #define BC2CPP_SHARD_ONE_BODY
    #endif
    struct bc2cpp_xslot {
      unsigned epoch;
      mrb_state* state;
      struct RClass* klass;
      struct RClass* c;
      mrb_method_t m;
    #ifdef MRB_MT_ROWS
      uint32_t mt_epoch;
    #endif
    };
    static inline bool bc2cpp_xslot_hit(mrb_state* M, const bc2cpp_xslot& s, struct RClass* klass, mrb_sym mid) {
      if (s.klass != klass || s.epoch != bc2cpp_nsc_epoch || s.state != M) return false;
    #if defined(MRB_MT_ROWS)
      (void)mid;
      return s.mt_epoch == M->mt_epoch;
    #elif !defined(MRB_NO_METHOD_CACHE)
      int h = mrb_int_hash_func(M, ((intptr_t)klass) ^ mid) & (MRB_METHOD_CACHE_SIZE - 1);
      const struct mrb_cache_entry* mc = &M->cache[h];
      uintptr_t x, y;
      memcpy(&x, &mc->m.as, sizeof x);
      memcpy(&y, &s.m.as, sizeof y);
      return mc->c == klass && mc->mid == mid && mc->c0 == s.c && mc->m.flags == s.m.flags && x == y;
    #else
      (void)mid;
      return false;
    #endif
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_native_slot_argv(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s, mrb_int argc, const mrb_value* argv) {
      mrb_sym mid = bc2cpp_sym(M, i);
      struct RClass* klass = mrb_class(M, recv);
      if (!bc2cpp_xslot_hit(M, s, klass, mid)) {
        struct RClass* c = klass;
        mrb_method_t m = bc2cpp_find_proven(M, &c, mid);
        if (MRB_METHOD_UNDEF_P(m) || MRB_METHOD_PROC_P(m) || (m.flags & (MRB_METHOD_PRIVATE_FL | MRB_METHOD_PROTECTED_FL))) {
          bc2cpp_check_send(M, recv, mid, argc, argv, true, mrb_nil_value());
          return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
        }
        s.epoch = bc2cpp_nsc_epoch;
        s.state = M;
        s.klass = klass;
        s.c = c;
        s.m = m;
    #ifdef MRB_MT_ROWS
        s.mt_epoch = M->mt_epoch;
    #endif
      }
      // vm.c check_argument_count: the registered aspec, before the call.
      mrb_aspec aspec = MRB_MT_ASPEC(s.m.flags);
      int min = MRB_ASPEC_REQ(aspec) + MRB_ASPEC_POST(aspec);
      int max = MRB_ASPEC_REST(aspec) ? -1 : min + MRB_ASPEC_OPT(aspec);
      if (argc < min || (max >= 0 && argc > max)) mrb_argnum_error(M, argc, min, max);
      return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s.m, s.c, argc, argv, mrb_nil_value()); });
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_native_slot0(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s) {
      return bc2cpp_native_slot_argv(M, recv, i, s, 0, nullptr);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_native_slot1(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s, mrb_value a) {
      return bc2cpp_native_slot_argv(M, recv, i, s, 1, &a);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_native_slot2(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s, mrb_value a, mrb_value b) {
      const mrb_value argv[2] = {a, b};
      return bc2cpp_native_slot_argv(M, recv, i, s, 2, argv);
    }
    // The site spells the count after the slot; these fold it away.
    [[maybe_unused]] static inline mrb_value bc2cpp_native_slot(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s, mrb_int) {
      return bc2cpp_native_slot0(M, recv, i, s);
    }
    [[maybe_unused]] static inline mrb_value bc2cpp_native_slot(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s, mrb_int, mrb_value a) {
      return bc2cpp_native_slot1(M, recv, i, s, a);
    }
    [[maybe_unused]] static inline mrb_value bc2cpp_native_slot(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s, mrb_int, mrb_value a, mrb_value b) {
      return bc2cpp_native_slot2(M, recv, i, s, a, b);
    }
    template <class... A> [[maybe_unused]] static inline mrb_value bc2cpp_native_slot(mrb_state* M, mrb_value recv, int i, bc2cpp_xslot& s, mrb_int argc, mrb_value a, mrb_value b, mrb_value c, A... rest) {
      const mrb_value argv[] = {a, b, c, rest...};
      return bc2cpp_native_slot_argv(M, recv, i, s, argc, argv);
    }
  CPP
  private_constant :NATIVE_SLOT

  # LITERAL_TABLES (codegen_literal_tables.rb): the builder every table calls, in each unit's prelude.
  LITERAL_TABLES_PRELUDE = <<~CPP
    // LITERAL_TABLES (codegen_literal_tables.rb): a constant literal's word table, built as its instructions would build
    // it. A word with bit 15 clear is a presym id. A finished pair or element drops its arena slots: its container holds
    // it, and the container sits in the arena below them.
    struct Bc2cppLitStr { const char* p; mrb_int n; };
    #define BC2CPP_LIT_STR(s) { s, (mrb_int)sizeof(s) - 1 }
    #ifdef MRB_PRESYM_MAX
    static_assert(MRB_PRESYM_MAX < 0x8000, "LITERAL_TABLES: a presym id needs bit 15 clear");
    #endif
    [[maybe_unused]] static mrb_value bc2cpp_lit_node(mrb_state* M, const uint16_t*& pc, const Bc2cppLitStr* s, const mrb_value* d) {
      const unsigned w = *pc++;
      if (!(w & 0x8000u)) return mrb_symbol_value((mrb_sym)w);
      const unsigned p = w & 0x0fffu;
      switch (w >> 12) {
      case 0x8: return mrb_fixnum_value((mrb_int)p);
      case 0x9: {
        const uint32_t v = (uint32_t)pc[0] | ((uint32_t)pc[1] << 16);
        pc += 2;
        return mrb_fixnum_value((mrb_int)(int32_t)v);
      }
      case 0xa: {
        mrb_value h = mrb_hash_new_capa(M, (mrb_int)p);
        const int ai = mrb_gc_arena_save(M);
        for (unsigned i = 0; i < p; ++i) {
          mrb_value k = bc2cpp_lit_node(M, pc, s, d);
          mrb_value v = bc2cpp_lit_node(M, pc, s, d);
          mrb_hash_set(M, h, k, v);
          mrb_gc_arena_restore(M, ai);
        }
        return h;
      }
      case 0xb: {
        mrb_value a = mrb_ary_new_capa(M, (mrb_int)p);
        const int ai = mrb_gc_arena_save(M);
        for (unsigned i = 0; i < p; ++i) {
          mrb_ary_push(M, a, bc2cpp_lit_node(M, pc, s, d));
          mrb_gc_arena_restore(M, ai);
        }
        return a;
      }
      case 0xc: return mrb_str_new(M, s[p].p, s[p].n);
      case 0xd: return d[p];
      default: return p == 1 ? mrb_true_value() : p == 2 ? mrb_false_value() : mrb_nil_value();
      }
    }
    [[maybe_unused]] static mrb_value bc2cpp_lit_build(mrb_state* M, const uint16_t* code, const Bc2cppLitStr* s, const mrb_value* d) {
      return bc2cpp_lit_node(M, code, s, d);
    }
  CPP

  # OWNER_CALL, with OWNER_CALL_ICACHE compiled out when BC2CPP_OWNER_ICACHE=0.
  def owner_call_source
    text = ENV['BC2CPP_OWNER_CALL_CORE'] == '0' ? OWNER_CALL : owner_call_core(OWNER_CALL)
    text = program_owner_sites(text) if program_sites?
    ENV['BC2CPP_OWNER_ICACHE'] == '0' ? "#define BC2CPP_NO_OWNER_ICACHE 1\n#{text}" : text
  end

  # OWNER_CALL_CORE: the argv form's miss path (lookup, definer and argument checks, the kept-call store) becomes
  # bc2cpp_owner_call_core, which reads the gem's owner epoch and fiber definer test through a bc2cpp_owner_gem and
  # names no other per-gem item, so CROSS_GEM_SHARE keeps one body for every gem. The argv form keeps the symbol
  # lookup, the Proc#call test and the kept-call hit, in the same order as before. BC2CPP_OWNER_CALL_CORE=0 keeps one
  # argv body per gem.
  OWNER_CORE_EDITS = [
    ['static void bc2cpp_owner_direct_pick(mrb_state* M, const bc2cpp_owner_directs& t, struct RClass* klass, mrb_method_t* m, struct RClass** c) {
  if (*t.epoch != bc2cpp_owner_epoch) {
    for (int d = 0; d < t.count; ++d) t.cls[d] = bc2cpp_owner_direct_class(M, t.rows[d].owner);
    *t.epoch = bc2cpp_owner_epoch;
  }',
     'static void bc2cpp_owner_direct_pick(mrb_state* M, const bc2cpp_owner_directs& t, struct RClass* klass, mrb_method_t* m, struct RClass** c, unsigned epoch) {
  if (*t.epoch != epoch) {
    for (int d = 0; d < t.count; ++d) t.cls[d] = bc2cpp_owner_direct_class(M, t.rows[d].owner);
    *t.epoch = epoch;
  }'],
    ['BC2CPP_SHARD_ONE_BODY static mrb_value bc2cpp_owner_call_argv(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk, mrb_int argc, const mrb_value* argv,
                                        mrb_value caller_self = mrb_nil_value()) {
  bc2cpp_owner_set scratch;
  bc2cpp_owner_set& s = bc2cpp_owner_set_of(d, scratch);
  int level = d->level;
  mrb_sym mid = bc2cpp_sym(M, d->mid);
',
     '// The gem\'s own state the core reads: its owner epoch, and its fiber runtime\'s definer test (or none).
struct bc2cpp_owner_gem {
  unsigned* epoch;
  bool (*definer)(const mrb_method_t&);
};
BC2CPP_SHARD_ONE_BODY static mrb_value bc2cpp_owner_call_core(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_sym mid,
                                        const bc2cpp_owner_gem* g, mrb_value blk, mrb_int argc, const mrb_value* argv,
                                        mrb_value caller_self) {
  bc2cpp_owner_set scratch;
  bc2cpp_owner_set& s = bc2cpp_owner_set_of(d, scratch);
  int level = d->level;
  struct RClass* klass = mrb_class(M, recv);
'],
    ['  // As bc2cpp_funcall_argv: Proc#call and its aliases on a compiled block are a yield, not an OP_CALL in a C frame.
  if (mrb_nil_p(blk) && mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
  struct RClass* klass = mrb_class(M, recv);
#ifdef BC2CPP_OWNER_ICACHE
  if (bc2cpp_owner_icache_hit(M, s, klass, mid, argc)) return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s.hit_m, s.hit_c, argc, argv, blk); });
#endif
#ifdef BC2CPP_OWNER_ICACHE_STATS
  ++bc2cpp_owner_icache_misses;
#endif
', ''],
    ['  if (d->direct) bc2cpp_owner_direct_pick(M, *d->direct, klass, &m, &c);', '  if (d->direct) bc2cpp_owner_direct_pick(M, *d->direct, klass, &m, &c, *g->epoch);'],
    ['  if (s.epoch != bc2cpp_owner_epoch) {
    s.epoch = bc2cpp_owner_epoch;', '  if (s.epoch != *g->epoch) {
    s.epoch = *g->epoch;'],
    ['#ifdef BC2CPP_FIBER_RUNTIME
        && !bc2cpp_fiber_definer_p(m)
#endif
', "        && !(g->definer && g->definer(m))\n"],
    ['  return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &m, c, argc, argv, blk); });
}
[[maybe_unused]] static mrb_value bc2cpp_owner_call(',
     '  return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &m, c, argc, argv, blk); });
}
static const bc2cpp_owner_gem bc2cpp_owner_gem_state = {
  &bc2cpp_owner_epoch,
#ifdef BC2CPP_FIBER_RUNTIME
  bc2cpp_fiber_definer_p,
#else
  nullptr,
#endif
};
BC2CPP_SHARD_ONE_BODY static mrb_value bc2cpp_owner_call_argv(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk, mrb_int argc, const mrb_value* argv,
                                        mrb_value caller_self = mrb_nil_value()) {
  mrb_sym mid = bc2cpp_sym(M, d->mid);
  // As bc2cpp_funcall_argv: Proc#call and its aliases on a compiled block are a yield, not an OP_CALL in a C frame.
  if (mrb_nil_p(blk) && mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
#ifdef BC2CPP_OWNER_ICACHE
  bc2cpp_owner_set* s = *d->set;
  if (s && bc2cpp_owner_icache_hit(M, *s, mrb_class(M, recv), mid, argc)) return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s->hit_m, s->hit_c, argc, argv, blk); });
#endif
#ifdef BC2CPP_OWNER_ICACHE_STATS
  ++bc2cpp_owner_icache_misses;
#endif
  return bc2cpp_owner_call_core(M, recv, d, mid, &bc2cpp_owner_gem_state, blk, argc, argv, caller_self);
}
[[maybe_unused]] static mrb_value bc2cpp_owner_call(']
  ].freeze

  def owner_call_core(text)
    OWNER_CORE_EDITS.reduce(text) do |out, (from, to)|
      raise "OWNER_CALL_CORE: the owner-call source no longer has #{from.lines.first.strip}" unless out.include?(from)

      out.sub(from) { to }
    end
  end

  # PROGRAM_OWNER_SITES: a shared helper's owner call and proven nomethod (HELPER_OWNER_CALL,
  # codegen_outside_owner_call.rb) name their method by presym id, not by a slot of the gem's symbol table, and the
  # owner site (BC2CPP_OWNERS_PW) is dated by the program's owner epoch, not the gem's, so the helper's text is the
  # same in every gem and CROSS_GEM_SHARE keeps one copy. BC2CPP_HELPER_PROGRAM_SITES=0 (or OWNER_CALL_CORE off) keeps
  # the per-gem forms.
  PROGRAM_STATE_HEADER = File.expand_path('runtime/bc2cpp_program_state.hxx', __dir__)
  # A gem's owner site asks its fiber runtime's definer test (bc2cpp_fiber_definer_p, one per program under
  # FIBER_SHARE), so a site of a name it defines stays per gem; a program-wide site runs the core with no definer.
  FIBER_RUNTIME_NAMES = %w[raise new yield resume transfer alive? current].freeze

  def program_sites?(env = ENV)
    env['BC2CPP_HELPER_PROGRAM_SITES'] != '0' && env['BC2CPP_OWNER_CALL_CORE'] != '0'
  end

  # The presym macro a program-wide site names `name` by, or nil (the site keeps the gem's slot).
  def program_mid(name, owner_site: false)
    return nil unless program_sites?
    return nil if owner_site && FIBER_RUNTIME_NAMES.include?(name)

    presym_macro(%("#{name}"))
  end

  # OWNER_SET_EPOCH holds for a program-wide site with the program's epoch in place of the gem's: the entry checks
  # the calling VM itself and bumps the epoch when it changes, and every gem's symbol reset (a VM change it sees,
  # gem_final) bumps it too, so a current epoch names the calling VM and no set outlives it. The kept call (ICACHE)
  # is dated the same way. Its hits and lookups are not counted (the counters are each gem's).
  OWNER_CALL_PROGRAM = <<~CPP
    // PROGRAM_OWNER_SITES (symbol_cache.rb): MID is a presym id; the set is dated by bc2cpp_program_owner_epoch.
    #define BC2CPP_OWNERS_PW(MID, ...) ([]() -> const bc2cpp_owner_desc* { static const char* const names[] = { __VA_ARGS__, nullptr }; static bc2cpp_owner_set* s; static const bc2cpp_owner_desc d = { names, nullptr, &s, MID, 0 }; return &d; }())
    static const bc2cpp_owner_gem bc2cpp_owner_program_state = {
      &bc2cpp_program_owner_epoch,
      nullptr,
    };
    BC2CPP_SHARD_ONE_BODY static mrb_value bc2cpp_owner_call_pw_argv(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_int argc, const mrb_value* argv) {
      if (bc2cpp_program_owner_vm != M) {
        bc2cpp_program_owner_vm = M;
        ++bc2cpp_program_owner_epoch;
      }
      mrb_sym mid = (mrb_sym)d->mid;
      if (mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
    #ifdef BC2CPP_OWNER_ICACHE
      bc2cpp_owner_set* s = *d->set;
      if (s && bc2cpp_owner_icache_hit_at(M, *s, mrb_class(M, recv), mid, argc, bc2cpp_program_owner_epoch)) return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s->hit_m, s->hit_c, argc, argv, mrb_nil_value()); });
    #endif
      return bc2cpp_owner_call_core(M, recv, d, mid, &bc2cpp_owner_program_state, mrb_nil_value(), argc, argv, mrb_nil_value());
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call_pw0(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d) {
      return bc2cpp_owner_call_pw_argv(M, recv, d, 0, nullptr);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call_pw1(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value a) {
      return bc2cpp_owner_call_pw_argv(M, recv, d, 1, &a);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call_pw2(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value a, mrb_value b) {
      const mrb_value argv[2] = {a, b};
      return bc2cpp_owner_call_pw_argv(M, recv, d, 2, argv);
    }
  CPP

  # The kept-call test with the epoch as a parameter, so the program-wide entry shares it with the gem's.
  ICACHE_HIT_EDIT = [
    'static inline bool bc2cpp_owner_icache_hit(mrb_state* M, const bc2cpp_owner_set& s, struct RClass* klass, mrb_sym mid, mrb_int argc) {
  if (s.hit_klass != klass || (mrb_int)s.hit_argc != argc || s.epoch != bc2cpp_owner_epoch) return false;',
    'static inline bool bc2cpp_owner_icache_hit_at(mrb_state* M, const bc2cpp_owner_set& s, struct RClass* klass, mrb_sym mid, mrb_int argc, unsigned epoch) {
  if (s.hit_klass != klass || (mrb_int)s.hit_argc != argc || s.epoch != epoch) return false;'
  ].freeze
  ICACHE_HIT_TAIL = [
    '#ifdef BC2CPP_OWNER_ICACHE_STATS
  ++bc2cpp_owner_icache_hits;
#endif
  return true;
}
#endif
',
    '  return true;
}
#endif
// Its own region, so the stateless test above is a segment of its own (CROSS_GEM_SHARE).
#ifdef BC2CPP_OWNER_ICACHE
static inline bool bc2cpp_owner_icache_hit(mrb_state* M, const bc2cpp_owner_set& s, struct RClass* klass, mrb_sym mid, mrb_int argc) {
  if (!bc2cpp_owner_icache_hit_at(M, s, klass, mid, argc, bc2cpp_owner_epoch)) return false;
#ifdef BC2CPP_OWNER_ICACHE_STATS
  ++bc2cpp_owner_icache_hits;
#endif
  return true;
}
#endif
'
  ].freeze

  def program_owner_sites(text)
    [ICACHE_HIT_EDIT, ICACHE_HIT_TAIL].each do |from, to|
      raise "PROGRAM_OWNER_SITES: the owner-call source no longer has #{from.lines.first.strip}" unless text.include?(from)

      text = text.sub(from) { to }
    end
    "#{text}#{OWNER_CALL_PROGRAM}"
  end

  # The file-scope cache. Keyed on the mrb_state so a second live VM cannot read
  # the first one's ids, and reset from each gem's gem_final so a VM opened
  # later at a reused address cannot either. Symbols are never collected, so a
  # cached id stays valid for the whole life of its VM.
  def emit(table)
    names = table.literals.map { |literal| "  #{literal}," }.join("\n")
    # PRESYM_ALL: a slot's entry is its presym id, or the high bit and the index of its RAM slot; only the names presym
    # cannot spell keep a RAM slot (bc2cpp_syms) and an intern.
    dynamic = []
    entries = table.literals.each_with_index.map do |literal, slot|
      macro = presym_macro(literal)
      macro ? "(uint32_t)#{macro}" : "0x80000000u | #{(dynamic << slot).size - 1}u"
    end
    # SYM_DYN_NAMES: bc2cpp_sym_names is constexpr and read only at compile time, by the RAM slots' own name list, so a
    # presym name keeps no string in the image. BC2CPP_SYM_DYN_NAMES=0 interns from bc2cpp_sym_names again.
    dyn_names = ENV['BC2CPP_SYM_DYN_NAMES'] != '0'
    checked = table.checks.any? { |check| check.to_i.positive? }
    checks = (0...[table.size, 1].max).map { |slot| table.checks[slot].to_i }.join(', ')
    program = table.owner_call_used && program_sites?
    <<~CPP
      #{program ? "#include \"#{PROGRAM_STATE_HEADER}\"" : ''}
      // BC2CPP_NOIPA: GCC's noipa keeps a slow-path call in place (see bc2cpp_guard_violation). Clang has no such
      // attribute and warns on it. maybe_unused: a translation unit may call only some of these helpers.
      #ifndef BC2CPP_NOIPA
      #if defined(__clang__)
      #define BC2CPP_NOIPA [[maybe_unused]]
      #else
      #define BC2CPP_NOIPA [[gnu::noipa, maybe_unused]]
      #endif
      #endif#{"\n#{BranchHints.prelude.chomp}" if BranchHints.on?}
      // A bytecode pool string's value. Its own helper, so the static dispatch proof can tell it from a folded
      // constant's value (static_dispatch_registrations.rb, POOL_STRING_VALUE).
      template<size_t N> static inline mrb_value bc2cpp_pool_str(mrb_state* M, const char (&s)[N]) {
        return mrb_str_new(M, s, N - 1);
      }
      // STRCAT_LITERAL (codegen_strcat_literal.rb): a pool string's bytes appended in place, as mrb_str_concat of it.
      template<size_t N> static inline void bc2cpp_str_cat_lit(mrb_state* M, mrb_value str, const char (&s)[N]) {
        mrb_str_cat(M, str, s, N - 1);
      }
      #{LITERAL_TABLES_PRELUDE.chomp}
      // SYMBOL_CACHE -- see tools/bc2cpp/symbol_cache.rb.
      static mrb_state* bc2cpp_sym_state = nullptr;
      static mrb_sym bc2cpp_syms[#{[dynamic.size, 1].max}] = {};
      static const uint32_t bc2cpp_sym_entry[#{[table.size, 1].max}] = { #{entries.empty? ? '0x80000000u' : entries.join(', ')} };
      static #{dyn_names ? 'constexpr const char*' : 'const char* const'} bc2cpp_sym_names[#{[table.size, 1].max}] = {
      #{names.empty? ? '  "",' : names}
      };#{dyn_names ? "\nstatic const char* const bc2cpp_sym_dyn_names[#{[dynamic.size, 1].max}] = { #{dynamic.empty? ? 'nullptr' : dynamic.map { |slot| "bc2cpp_sym_names[#{slot}]" }.join(', ')} };" : ''}
      #{table.native_singleton_used ? "// NATIVE_SINGLETON_CALL: bumped with the symbol table, so no slot outlives its VM.\nstatic unsigned bc2cpp_nsc_epoch = 1;" : ''}#{table.owner_call_used ? "\n// OUTSIDE_OWNER_CALL: bumped with the symbol table, so no owner set outlives its VM.\nstatic unsigned bc2cpp_owner_epoch = 1;" : ''}
      static void bc2cpp_reset_symbol_cache() {
        bc2cpp_sym_state = nullptr;
        for (mrb_sym& s : bc2cpp_syms) s = 0;
      #{table.native_singleton_used ? '  ++bc2cpp_nsc_epoch;' : ''}#{table.owner_call_used ? "\n  ++bc2cpp_owner_epoch;" : ''}#{program ? "\n  ++bc2cpp_program_owner_epoch;" : ''}
      }
      static inline mrb_sym bc2cpp_sym(mrb_state* M, int i) {
        if (bc2cpp_sym_state != M) {
          bc2cpp_reset_symbol_cache();
          bc2cpp_sym_state = M;
        }
        // The VM check comes first: it also bumps the epochs of the caches keyed on this table.
        uint32_t e = bc2cpp_sym_entry[i];
        if (!(e & 0x80000000u)) return (mrb_sym)e;
        mrb_sym& s = bc2cpp_syms[e & 0x7fffffffu];
        if (!s) s = mrb_intern_cstr(M, #{dyn_names ? 'bc2cpp_sym_dyn_names[e & 0x7fffffffu]' : 'bc2cpp_sym_names[i]'});
        return s;
      }
      #{checked ? "static const unsigned char bc2cpp_sym_check[#{[table.size, 1].max}] = { #{checks} };\n#{checked_send_source}" : ''}
      // mrb_funcall_id with the symbol lookup folded in, so a dynamic call site is one
      // call. Same argc limit and error as mruby's (MRB_FUNCALL_ARGC_MAX, src/vm.c).
      static mrb_value bc2cpp_send(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
        mrb_value argv[16];
        if (argc > 16) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "Too long arguments. (limit=16)");
        va_list ap;
        va_start(ap, argc);
        for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
      #{checked ? "  // CALLER_SELF: an explicit-receiver slot's call passes the caller's self after its arguments.\n  mrb_value caller_self = bc2cpp_sym_check[i] == 2 ? va_arg(ap, mrb_value) : mrb_nil_value();" : ''}
        va_end(ap);
      #{checked ? "  if (bc2cpp_sym_check[i]) bc2cpp_check_send(M, recv, bc2cpp_sym(M, i), argc, argv, bc2cpp_sym_check[i] == 2, caller_self);" : ''}
        #ifdef BC2CPP_SEND_COUNT
        BC2CPP_SEND_HIT(M, "send", bc2cpp_sym(M, i));
        struct SendInner { SendInner() { bc2cpp_send_counting_inner() = true; } ~SendInner() { bc2cpp_send_counting_inner() = false; } } send_inner;
        #endif
        return bc2cpp_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
      }
      #{table.native_singleton_used ? NATIVE_SINGLETON : ''}#{table.native_slots.empty? ? '' : native_slot_source(table)}#{table.owner_call_used ? owner_call_source : ''}
      #{table.nomethod_used ? nomethod_source : ''}
      #{GUARD_VIOLATION}#{table.hint_violation_used ? HINT_VIOLATION : ''}
      #{table.nil_receiver_used ? NIL_RECEIVER : ''}
    CPP
  end

  # CHECKED_SEND: what OP_SEND / OP_SSEND check before calling and mrb_funcall does not.
  # Level 2 is an explicit-receiver OP_SEND: a private method raises NoMethodError (vm.c vis_error), and so does a
  # protected one unless the caller's self is a kind_of the class or module it was found on. Level 1 and 2 both raise ArgumentError for
  # a cfunc proc flagged MRB_PROC_NOARG (an attr_reader) called with arguments. An undefined
  # method is left to mrb_funcall, which reaches method_missing.
  CHECKED_SEND = <<~CPP
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_visibility_error(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv, bool priv) {
      mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", priv ? "private" : "protected", mid, recv);
    }
    static bool bc2cpp_is_public_send(mrb_state* M, mrb_sym mid) {
      static mrb_state* st; static mrb_sym ps;
      if (st != M) { ps = mrb_intern_lit(M, "public_send"); st = M; }
      return mid == ps;
    }
    [[gnu::noinline]] static void bc2cpp_check_send(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv, bool explicit_receiver,
                                                     mrb_value caller_self) {
      struct RClass* c = mrb_class(M, recv);
      mrb_method_t m = bc2cpp_find_method(M, &c, mid);
      if (MRB_METHOD_UNDEF_P(m)) return;
      // mrb_funcall reaches public_send's funcall branch, which skips its own visibility check; do it here.
      if (argc > 0 && MRB_METHOD_FUNC_P(m) && bc2cpp_is_public_send(M, mid)) {
        mrb_sym name = mrb_obj_to_sym(M, argv[0]);
        struct RClass* tc = mrb_class(M, recv);
        mrb_method_t tm = bc2cpp_find_method(M, &tc, name);
        if (!MRB_METHOD_UNDEF_P(tm) && (tm.flags & (MRB_METHOD_PRIVATE_FL | MRB_METHOD_PROTECTED_FL)))
          bc2cpp_visibility_error(M, recv, name, argc - 1, argv + 1, (tm.flags & MRB_METHOD_PRIVATE_FL) != 0);
      }
      if (explicit_receiver) {
        if (m.flags & MRB_METHOD_PRIVATE_FL) bc2cpp_visibility_error(M, recv, mid, argc, argv, true);
        if ((m.flags & MRB_METHOD_PROTECTED_FL) && !mrb_obj_is_kind_of(M, caller_self, c)) bc2cpp_visibility_error(M, recv, mid, argc, argv, false);
      }
      if (argc > 0 && MRB_METHOD_PROC_P(m)) {
        const struct RProc* p = MRB_METHOD_PROC(m);
        if (MRB_PROC_ALIAS_P(p)) p = p->upper;
        if (MRB_PROC_CFUNC_P(p) && MRB_PROC_NOARG_P(p)) mrb_argnum_error(M, argc, 0, 0);
      }
      // vm.c check_argument_count: OP_SEND checks a raw C function's registered aspec; mrb_funcall does not.
      if (MRB_METHOD_FUNC_P(m)) {
        mrb_aspec aspec = MRB_MT_ASPEC(m.flags);
        int min = MRB_ASPEC_REQ(aspec) + MRB_ASPEC_POST(aspec);
        int max = MRB_ASPEC_REST(aspec) ? -1 : min + MRB_ASPEC_OPT(aspec);
        if (argc < min || (max >= 0 && argc > max)) mrb_argnum_error(M, argc, min, max);
      }
    }
  CPP
  private_constant :CHECKED_SEND

  # NATIVE_SINGLETON_CALL: `Const.name(args)` where the compiler proved `name` is one C function
  # registered on the constant's singleton class (tools/bc2cpp/native_singletons.rb). The function reads its
  # arguments through mrb_get_args from the call frame, so it cannot be called bare; this runs the frame
  # mrb_funcall would push (mrb_funcall_with_method is funcall_with_block_m with the lookup done), once per site
  # instead of the two lookups a checked bc2cpp_send makes. The slot is filled by a call and is valid for one VM
  # (epoch), one receiver and one argument count. Anything the proof assumed but the VM does not show -- the method is
  # not a public C function, or an attr_reader-style NOARG function is given arguments -- is not cached and takes
  # the ordinary checked send, so a wrong proof costs speed, never the error or the answer.
  #
  # NSC_SLOT_SHARE: everything a slot keeps is a function of what it is keyed on, so every site of one kind (0
  # singleton, 1 owner) and method id in a unit shares one slot (static: the epoch is the unit's). Sites of the same
  # name on other receivers or counts only refill it. OWNER_SET_EPOCH holds as for the owner sets: both calls take
  # bc2cpp_sym(M, i) before reading the slot, so a current epoch names the calling VM and the slot keeps no state.
  NATIVE_SINGLETON = <<~CPP
    struct bc2cpp_nsc_slot {
      unsigned epoch;
      struct RObject* recv;
      mrb_method_t m;
      struct RClass* owner;
      mrb_int argc;
    };
    template <int K, int I> static bc2cpp_nsc_slot bc2cpp_nsc_slot_at;
    #define BC2CPP_NSC_SLOT_OF(K, I) (bc2cpp_nsc_slot_at<K, I>)
    // Keeps `m` (found on `c`) in the slot for `key`, or refuses: not a C function, or an argument count the
    // function cannot take.
    static bool bc2cpp_nsc_accept(mrb_state* M, bc2cpp_nsc_slot& s, struct RObject* key, mrb_method_t m, struct RClass* c, mrb_int argc) {
      if (MRB_METHOD_UNDEF_P(m) || !MRB_METHOD_CFUNC_P(m)) return false;
      if (!MRB_METHOD_PROC_P(m)) {
        // A raw C function: OP_SEND checks the aspec it was registered with (vm.c check_argument_count) before the call.
        mrb_aspec aspec = MRB_MT_ASPEC(m.flags);
        int min = MRB_ASPEC_REQ(aspec) + MRB_ASPEC_POST(aspec);
        int max = MRB_ASPEC_REST(aspec) ? -1 : min + MRB_ASPEC_OPT(aspec);
        if (argc < min || (max >= 0 && argc > max)) mrb_argnum_error(M, argc, min, max);
      }
      if (argc > 0 && MRB_METHOD_PROC_P(m)) {
        const struct RProc* p = MRB_METHOD_PROC(m);
        if (MRB_PROC_ALIAS_P(p)) p = p->upper;
        if (MRB_PROC_CFUNC_P(p) && MRB_PROC_NOARG_P(p)) return false;
      }
      s.epoch = bc2cpp_nsc_epoch;
      s.argc = argc;
      s.recv = key;
      s.m = m;
      s.owner = c;
      return true;
    }
    [[gnu::noinline]] static bool bc2cpp_nsc_fill(mrb_state* M, bc2cpp_nsc_slot& s, mrb_value recv, mrb_sym mid, mrb_int argc) {
      if (mrb_type(recv) != MRB_TT_CLASS && mrb_type(recv) != MRB_TT_MODULE) return false;
      struct RClass* c = mrb_class(M, recv);
      mrb_method_t m = bc2cpp_find_proven(M, &c, mid);
      if (!MRB_METHOD_UNDEF_P(m) && (m.flags & (MRB_METHOD_PRIVATE_FL | MRB_METHOD_PROTECTED_FL))) return false;
      return bc2cpp_nsc_accept(M, s, mrb_obj_ptr(recv), m, c, argc);
    }
    static mrb_value bc2cpp_native_singleton(mrb_state* M, mrb_value recv, int i, bc2cpp_nsc_slot& s, mrb_int argc, ...) {
      mrb_value argv[16];
      if (argc > 16) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "Too long arguments. (limit=16)");
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
      mrb_value caller_self = va_arg(ap, mrb_value);  // CALLER_SELF, as bc2cpp_send's level 2
      va_end(ap);
      mrb_sym mid = bc2cpp_sym(M, i);
      bool cached = s.epoch == bc2cpp_nsc_epoch && s.argc == argc && (mrb_type(recv) == MRB_TT_CLASS || mrb_type(recv) == MRB_TT_MODULE) &&
                    s.recv == mrb_obj_ptr(recv);
      if (cached || bc2cpp_nsc_fill(M, s, recv, mid, argc)) {
        return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s.m, s.owner, argc, argv, mrb_nil_value()); });
      }
      if (bc2cpp_sym_check[i]) bc2cpp_check_send(M, recv, mid, argc, argv, bc2cpp_sym_check[i] == 2, caller_self);
      return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
    }
    // CORE_SELF_NATIVE: a self call whose method the compiler proved to be the C function registered on `owner`
    // (codegen_core_self_native.rb). Every receiver's lookup ends at that registration, so the method is looked up
    // on `owner` itself, once per site and VM; the slot is keyed by the owner, not the receiver.
    static mrb_value bc2cpp_native_owner(mrb_state* M, mrb_value recv, int i, bc2cpp_nsc_slot& s, struct RClass* owner, mrb_int argc, ...) {
      mrb_value argv[16];
      if (argc > 16) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "Too long arguments. (limit=16)");
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      mrb_sym mid = bc2cpp_sym(M, i);
      bool cached = owner && s.epoch == bc2cpp_nsc_epoch && s.argc == argc && s.recv == (struct RObject*)owner;
      if (!cached && owner) {
        struct RClass* c = owner;
        mrb_method_t m = bc2cpp_find_proven(M, &c, mid);
        cached = bc2cpp_nsc_accept(M, s, (struct RObject*)owner, m, c, argc);
      }
      if (cached) return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s.m, s.owner, argc, argv, mrb_nil_value()); });
      if (bc2cpp_sym_check[i]) bc2cpp_check_send(M, recv, mid, argc, argv, false, mrb_nil_value());
      return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
    }
  CPP
  private_constant :NATIVE_SINGLETON

  # OUTSIDE_OWNER_CALL: the else of a closed-world chain whose remaining receivers answer the name only
  # through outside (core, native or outside Ruby) definitions, every one of which the compiler named
  # (BC2CPP_OWNERS: class paths as mrb_class_name spells them, `.singleton` for a class object's own method).
  # The method is looked up once and checked against that list: a listed owner's method runs in the frame mruby's
  # dispatch pushes (mrb_funcall_with_method: a C function reads its arguments from that frame) after the checks
  # OP_SEND makes at `level` (2 explicit receiver: visibility; 1 and 2: argument count, aspec); no method raises what
  # dispatch raises (the receiver is proven method_missing-free, so a dispatch that returns is a violated proof); any
  # other owner is a definer the closed world did not see, and raises. Owners already matched are kept per site and
  # VM (up to 32), so the name test runs once per owner.
  #
  # OWNER_CALL_ICACHE: each site also keeps its last (receiver class, argument count) -> (method, owner) that
  # passed every check. A repeat call with the same class and count skips the lookup, the owner test and the
  # checks, but only while mruby's own method cache (mrb->cache, which the lookup fills) still holds
  # that same entry: mruby clears an entry whenever a definition, removal, undef, include, prepend or the freeing
  # of either class could change it (class.c mc_clear_by_id, mrb_method_cache_clear, mrb_mc_clear_by_class), so
  # a present, equal entry is exactly what the full lookup would return, and the checks depend only on it and the
  # count. Protected methods are not kept (their check reads the caller's self). The slot is per VM like the owner set.
  # Builds with MRB_NO_METHOD_CACHE, -DBC2CPP_NO_OWNER_ICACHE or BC2CPP_OWNER_ICACHE=0 at generation take the full
  # path every time.
  OWNER_CALL = <<~CPP
    #include <string.h>
    #include <stdlib.h>
    #if defined(BC2CPP_NOMETHOD_VERIFY) || defined(BC2CPP_CLASS_REACH_VERIFY)
    #include <stdio.h>
    #include <stdlib.h>
    #endif
    #if !defined(MRB_NO_METHOD_CACHE) && !defined(BC2CPP_NO_OWNER_ICACHE)
    #define BC2CPP_OWNER_ICACHE 1
    #endif
    // OWNER_CALL_DIRECT (owner_call_direct.rb): a listed owner's compiled entry, called without a method-table lookup
    // (owner path, the entry wrapper, the flags its registration gives it: aspec and visibility), and a call's rows
    // with each owner's class in `state` (null: not defined there).
    struct bc2cpp_owner_direct {
      const char* owner;
      mrb_func_t func;
      uint32_t flags;
    };
    // OWNER_CALL_DESC: what never changes is const (rodata); `cls` and `epoch` point at the zeroed run-time state.
    // The epoch alone dates `cls`: bc2cpp_sym bumps it for another VM, and gem_final for a reused one.
    struct bc2cpp_owner_directs {
      const bc2cpp_owner_direct* rows;
      struct RClass** cls;
      unsigned* epoch;
      int count;
    };
    // The run-time state of an owner set. OWNER_SET_LAZY: a site keeps only a pointer (.bss), and the set is allocated
    // zeroed by the site's first call, so a site that never runs costs no state (bc2cpp_owner_set_of).
    // OWNER_SET_EPOCH: the set is valid while `epoch` is bc2cpp_owner_epoch. It keeps no mrb_state: every use follows
    // a bc2cpp_sym(M, ...) of the same call, which bumps the epoch whenever the gem's VM changes (or the gem is
    // finalised), so a current epoch names the calling VM. Narrow fields sit last, for padding.
    struct bc2cpp_owner_set {
      // Owners already matched, up to 32: the first two inline (most sites see one), the rest in `more`, allocated
      // when a third is matched.
      struct RClass* seen[2];
      struct RClass** more;
      // OWNER_CALL_ICACHE: the last call that passed every check (hit_klass null: none).
      struct RClass* hit_klass;
      struct RClass* hit_c;
      mrb_method_t hit_m;
      unsigned epoch;
    #ifdef MRB_MT_ROWS
      uint32_t hit_mt_epoch;
    #endif
      uint8_t seen_count;
      // A call of more arguments is not kept (see bc2cpp_owner_call_argv).
      uint8_t hit_argc;
    };
    // OWNER_CALL_DESC: a site's constant descriptor: its owner list, direct rows, state and the call's symbol slot and
    // level, so the call passes one pointer. The narrowing of a brace initialiser keeps a slot past 16 bits from
    // compiling.
    struct bc2cpp_owner_desc {
      const char* const* names;
      const bc2cpp_owner_directs* direct;
      bc2cpp_owner_set** set;
      uint16_t mid;
      uint8_t level;
    };
    // OWNER_SET_LAZY: the site's set, allocated on its first call. When the allocation fails the call runs on
    // `scratch`, zeroed: it keeps nothing, so every check runs as on a first call.
    [[gnu::noinline]] static bc2cpp_owner_set& bc2cpp_owner_set_make(const bc2cpp_owner_desc* d, bc2cpp_owner_set& scratch) {
      bc2cpp_owner_set* p = (bc2cpp_owner_set*)calloc(1, sizeof(bc2cpp_owner_set));
      if (!p) {
        memset(&scratch, 0, sizeof scratch);
        return scratch;
      }
      *d->set = p;
      return *p;
    }
    static inline bc2cpp_owner_set& bc2cpp_owner_set_of(const bc2cpp_owner_desc* d, bc2cpp_owner_set& scratch) {
      bc2cpp_owner_set* p = *d->set;
      return p ? *p : bc2cpp_owner_set_make(d, scratch);
    }
    #ifdef BC2CPP_OWNER_ICACHE_STATS
    // Hits and full lookups, for scripts/bc2cpp/owner_call_icache_check.rb; printed at exit.
    #include <stdio.h>
    static unsigned long bc2cpp_owner_icache_hits = 0;
    static unsigned long bc2cpp_owner_icache_misses = 0;
    static struct bc2cpp_owner_icache_report {
      ~bc2cpp_owner_icache_report() { fprintf(stderr, "bc2cpp: OWNER_ICACHE hits=%lu lookups=%lu\\n", bc2cpp_owner_icache_hits, bc2cpp_owner_icache_misses); }
    } bc2cpp_owner_icache_report_at_exit;
    #endif
    #ifdef BC2CPP_OWNER_ICACHE
    static inline bool bc2cpp_method_eq(const mrb_method_t& a, const mrb_method_t& b) {
      uintptr_t x, y;
      memcpy(&x, &a.as, sizeof x);
      memcpy(&y, &b.as, sizeof y);
      return a.flags == b.flags && x == y;
    }
    // The site's kept call, while mruby's method cache still holds the same entry for (klass, mid). A fork with rows
    // (MRB_MT_ROWS) bumps mt_epoch wherever it clears that cache, and a row is never cached: the epoch decides there.
    static inline bool bc2cpp_owner_icache_hit(mrb_state* M, const bc2cpp_owner_set& s, struct RClass* klass, mrb_sym mid, mrb_int argc) {
      if (s.hit_klass != klass || (mrb_int)s.hit_argc != argc || s.epoch != bc2cpp_owner_epoch) return false;
    #ifdef MRB_MT_ROWS
      (void)mid;
      if (s.hit_mt_epoch != M->mt_epoch) return false;
    #else
      int h = mrb_int_hash_func(M, ((intptr_t)klass) ^ mid) & (MRB_METHOD_CACHE_SIZE - 1);
      const struct mrb_cache_entry* mc = &M->cache[h];
      if (mc->c != klass || mc->mid != mid || mc->c0 != s.hit_c || !bc2cpp_method_eq(mc->m, s.hit_m)) return false;
    #endif
    #ifdef BC2CPP_OWNER_ICACHE_STATS
      ++bc2cpp_owner_icache_hits;
    #endif
      return true;
    }
    #endif
    // I is the call's symbol slot, L its level, then the owner list.
    #define BC2CPP_OWNERS(I, L, ...) ([]() -> const bc2cpp_owner_desc* { static const char* const names[] = { __VA_ARGS__, nullptr }; static bc2cpp_owner_set* s; static const bc2cpp_owner_desc d = { names, nullptr, &s, I, L }; return &d; }())
    // OWNER_CALL_DIRECT: DIRECTS is a run of BC2CPP_OWNER_DIRECT(owner, entry, aspec, visibility), no commas between.
    #define BC2CPP_OWNER_DIRECT(owner, fn, aspec, vis) { owner, fn, (uint32_t)(aspec) | (uint32_t)(vis) },
    #define BC2CPP_OWNERS_D(I, L, DIRECTS, ...) ([]() -> const bc2cpp_owner_desc* { static const char* const names[] = { __VA_ARGS__, nullptr }; static const bc2cpp_owner_direct rows[] = { DIRECTS }; static struct RClass* cls[sizeof rows / sizeof rows[0]]; static unsigned ep; static const bc2cpp_owner_directs dr = { rows, cls, &ep, (int)(sizeof rows / sizeof rows[0]) }; static bc2cpp_owner_set* s; static const bc2cpp_owner_desc d = { names, &dr, &s, I, L }; return &d; }())
    // OWNER_SET_SHARE (owner_set_share.rb): the descriptor every site with key K shares, defined once below; the
    // site's slot, level and owner list stay spelled for the reader.
    #define BC2CPP_SHARED(K, ...) (&bc2cpp_owner_sd_##K)
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_owner_violation(mrb_state* M, mrb_value recv, mrb_sym mid, const char* what) {
    #ifdef BC2CPP_CLASS_REACH_VERIFY
      // CLASS_REACH (class_reach.rb): the build left out the definitions of owners a site does not list.
      fprintf(stderr, "bc2cpp: CLASS_REACH_VERIFY: owner-call violation: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
      fprintf(stderr, "#%s: %s\\n", mrb_sym_name(M, mid), what);
      fflush(stderr);
      abort();
    #endif
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: owner-call violation: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
      fprintf(stderr, "#%s: %s\\n", mrb_sym_name(M, mid), what);
      fflush(stderr);
      abort();
    #endif
      mrb_value msg = mrb_format(M, "closed-world owner violation: %T#%n %s", recv, mid, what);
      struct RClass* klass = mrb_define_class(M, "BC2cppGuardViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
    }
    // The singleton class of an object that is no class or module: the registry names it `Const.singleton` after the
    // constant its `def Const.x` was written on (resolve_singleton_receiver), so it is listed when that constant holds
    // the very object. The path is walked with mrb_const_defined_at first, so no const_missing runs.
    static bool bc2cpp_owner_listed_object(mrb_state* M, mrb_value attached, const char* const* names) {
      for (int k = 0; names[k]; ++k) {
        size_t n = strlen(names[k]);
        if (n <= 10 || strcmp(names[k] + n - 10, ".singleton") != 0) continue;
        size_t end = n - 10;
        mrb_value cur = mrb_obj_value(M->object_class);
        bool found = true;
        for (size_t pos = 0; pos < end;) {
          size_t stop = pos;
          while (stop < end && names[k][stop] != ':') ++stop;
          mrb_sym id = mrb_intern(M, names[k] + pos, stop - pos);
          if ((mrb_type(cur) != MRB_TT_CLASS && mrb_type(cur) != MRB_TT_MODULE) || !mrb_const_defined_at(M, cur, id)) {
            found = false;
            break;
          }
          cur = mrb_const_get(M, cur, id);
          pos = stop + 2;
        }
        if (found && mrb_obj_eq(M, cur, attached)) return true;
      }
      return false;
    }
    // Is `c` (a method's owner, an iclass already resolved to its module) one of `names`?
    static bool bc2cpp_owner_listed(mrb_state* M, struct RClass* c, const char* const* names) {
      bool singleton = false;
      if (c->tt == MRB_TT_SCLASS) {
        mrb_value attached = mrb_iv_get(M, mrb_obj_value(c), mrb_intern_lit(M, "__attached__"));
        if (mrb_type(attached) != MRB_TT_CLASS && mrb_type(attached) != MRB_TT_MODULE) {
          return bc2cpp_owner_listed_object(M, attached, names);
        }
        c = mrb_class_ptr(attached);
        singleton = true;
      }
      if (c->tt != MRB_TT_CLASS && c->tt != MRB_TT_MODULE) return false;
      const char* path = mrb_class_name(M, c);
      if (!path) return false;
      size_t len = strlen(path);
      for (int k = 0; names[k]; ++k) {
        size_t n = strlen(names[k]);
        bool listed_singleton = n > 10 && strcmp(names[k] + n - 10, ".singleton") == 0;
        if (listed_singleton != singleton) continue;
        if ((listed_singleton ? n - 10 : n) == len && memcmp(names[k], path, len) == 0) return true;
      }
      return false;
    }
    // OWNER_CALL_DIRECT: the class or module at "A::B" (".singleton": its singleton class), or null when a segment is
    // not defined; walked with mrb_const_defined_at first, so no const_missing runs.
    static struct RClass* bc2cpp_owner_direct_class(mrb_state* M, const char* path) {
      size_t end = strlen(path);
      bool singleton = end > 10 && strcmp(path + end - 10, ".singleton") == 0;
      if (singleton) end -= 10;
      mrb_value cur = mrb_obj_value(M->object_class);
      for (size_t pos = 0; pos < end;) {
        size_t stop = pos;
        while (stop < end && path[stop] != ':') ++stop;
        mrb_sym id = mrb_intern(M, path + pos, stop - pos);
        if ((mrb_type(cur) != MRB_TT_CLASS && mrb_type(cur) != MRB_TT_MODULE) || !mrb_const_defined_at(M, cur, id)) return nullptr;
        cur = mrb_const_get(M, cur, id);
        pos = stop + 2;
      }
      if (mrb_type(cur) != MRB_TT_CLASS && mrb_type(cur) != MRB_TT_MODULE) return nullptr;
      return singleton ? mrb_class_ptr(mrb_singleton_class(M, cur)) : mrb_class_ptr(cur);
    }
    // OWNER_CALL_DIRECT: what mruby's lookup would find if every direct owner's entry were registered. The receiver's
    // ancestors are walked in lookup order up to where the table lookup found the name (`*c`; the whole chain when it
    // found none): the first direct owner met there answers with its entry, as its registration would have. A
    // prepended class keeps the table lookup (its origin reorders the chain; the closed world prepends into none).
    static void bc2cpp_owner_direct_pick(mrb_state* M, const bc2cpp_owner_directs& t, struct RClass* klass, mrb_method_t* m, struct RClass** c) {
      if (*t.epoch != bc2cpp_owner_epoch) {
        for (int d = 0; d < t.count; ++d) t.cls[d] = bc2cpp_owner_direct_class(M, t.rows[d].owner);
        *t.epoch = bc2cpp_owner_epoch;
      }
      struct RClass* found = MRB_METHOD_UNDEF_P(*m) ? nullptr : *c;
      for (struct RClass* k = klass; k; k = k->super) {
        if (MRB_FLAG_TEST(k, MRB_FL_CLASS_IS_PREPENDED)) return;
        struct RClass* o = k->tt == MRB_TT_ICLASS ? k->c : k;
        for (int d = 0; d < t.count; ++d) {
          if (t.cls[d] != o) continue;
          MRB_METHOD_FROM_FUNC(*m, t.rows[d].func);
          m->flags |= t.rows[d].flags;
          *c = k;
          return;
        }
        if (k == found) return;
      }
    }
    // The argv form: a splat site passes the Array's own items, as mrb_funcall_with_block would (both reach vm.c's
    // funcall_with_block_m, whose funcall_args_capture copies them and packs a long list as OP_SEND does).
    // CALLER_SELF: a level 2 call passes the caller's self (the generated code's `self`) for the protected check.
    // BC2CPP_SHARD_ONE_BODY (shard_output.rb): one body per sharded gem, which every shard's entries call.
    #ifndef BC2CPP_SHARD_ONE_BODY
    #define BC2CPP_SHARD_ONE_BODY
    #endif
    BC2CPP_SHARD_ONE_BODY static mrb_value bc2cpp_owner_call_argv(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk, mrb_int argc, const mrb_value* argv,
                                            mrb_value caller_self = mrb_nil_value()) {
      bc2cpp_owner_set scratch;
      bc2cpp_owner_set& s = bc2cpp_owner_set_of(d, scratch);
      int level = d->level;
      mrb_sym mid = bc2cpp_sym(M, d->mid);
      // As bc2cpp_funcall_argv: Proc#call and its aliases on a compiled block are a yield, not an OP_CALL in a C frame.
      if (mrb_nil_p(blk) && mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
      struct RClass* klass = mrb_class(M, recv);
    #ifdef BC2CPP_OWNER_ICACHE
      if (bc2cpp_owner_icache_hit(M, s, klass, mid, argc)) return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &s.hit_m, s.hit_c, argc, argv, blk); });
    #endif
    #ifdef BC2CPP_OWNER_ICACHE_STATS
      ++bc2cpp_owner_icache_misses;
    #endif
      struct RClass* c = klass;
      mrb_method_t m = bc2cpp_find_proven(M, &c, mid);
      if (d->direct) bc2cpp_owner_direct_pick(M, *d->direct, klass, &m, &c);
      if (MRB_METHOD_UNDEF_P(m)) {
        if (mrb_nil_p(blk)) bc2cpp_funcall_argv(M, recv, mid, argc, argv);
        else mrb_funcall_with_block(M, recv, mid, argc, argv, blk);
        bc2cpp_owner_violation(M, recv, mid, "was proven to raise NoMethodError but dispatched");
      }
      struct RClass* owner = c->tt == MRB_TT_ICLASS ? c->c : c;
      if (s.epoch != bc2cpp_owner_epoch) {
        s.epoch = bc2cpp_owner_epoch;
        s.seen_count = 0;
        s.hit_klass = nullptr;
      }
      bool seen = false;
      for (int k = 0; k < s.seen_count; ++k) seen = seen || (k < 2 ? s.seen[k] : s.more[k - 2]) == owner;
      if (!seen) {
        if (!bc2cpp_owner_listed(M, owner, d->names)
    #ifdef BC2CPP_FIBER_RUNTIME
            && !bc2cpp_fiber_definer_p(m)
    #endif
        ) bc2cpp_owner_violation(M, recv, mid, "resolves to a definer the closed world does not list");
        if (s.seen_count < 2) s.seen[s.seen_count++] = owner;
        else if (s.seen_count < 32) {
          if (!s.more) s.more = (struct RClass**)malloc(30 * sizeof(struct RClass*));
          if (s.more) s.more[s.seen_count++ - 2] = owner;
        }
      }
      if (level >= 2) {
        // vm.c OP_SEND: an explicit receiver may not call a private method, nor a protected one unless the caller's
        // self is a kind_of the class or module the method was found on.
        if (m.flags & MRB_METHOD_PRIVATE_FL) {
          mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "private", mid, recv);
        }
        if ((m.flags & MRB_METHOD_PROTECTED_FL) && !mrb_obj_is_kind_of(M, caller_self, c)) {
          mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "protected", mid, recv);
        }
      }
      if (level >= 1) {
        if (MRB_METHOD_PROC_P(m)) {
          const struct RProc* p = MRB_METHOD_PROC(m);
          if (MRB_PROC_ALIAS_P(p)) p = p->upper;
          if (MRB_PROC_CFUNC_P(p) && MRB_PROC_NOARG_P(p) && argc > 0) mrb_argnum_error(M, argc, 0, 0);
        } else {
          // vm.c check_argument_count: a raw C function's registered aspec, before the call.
          mrb_aspec aspec = MRB_MT_ASPEC(m.flags);
          int min = MRB_ASPEC_REQ(aspec) + MRB_ASPEC_POST(aspec);
          int max = MRB_ASPEC_REST(aspec) ? -1 : min + MRB_ASPEC_OPT(aspec);
          if (argc < min || (max >= 0 && argc > max)) mrb_argnum_error(M, argc, min, max);
        }
      }
    #ifdef BC2CPP_OWNER_ICACHE
      if (!(m.flags & MRB_METHOD_PROTECTED_FL) && argc <= UINT8_MAX) {
        s.hit_klass = klass;
        s.hit_c = c;
        s.hit_m = m;
        s.hit_argc = (uint8_t)argc;
    #ifdef MRB_MT_ROWS
        s.hit_mt_epoch = M->mt_epoch;
    #endif
      }
    #endif
      return bc2cpp_keep_call(M, [&] { return bc2cpp_call_found(M, recv, mid, &m, c, argc, argv, blk); });
    }
    [[maybe_unused]] static mrb_value bc2cpp_owner_call(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      for (mrb_int k = 16; k < argc; k++) (void)va_arg(ap, mrb_value);
      mrb_value caller_self = d->level >= 2 ? va_arg(ap, mrb_value) : mrb_nil_value();
      va_end(ap);
      return bc2cpp_owner_call_argv(M, recv, d, blk, argc, argv, caller_self);
    }
    // OWNER_CALL_ARITY (owner_call_arity.rb): the fixed-arity entries. Out of line, so each site passes only its own
    // arguments; the trailing caller_self overload is a level 2 site's. One body per sharded gem, as the argv form.
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call0(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d) {
      return bc2cpp_owner_call_argv(M, recv, d, mrb_nil_value(), 0, nullptr);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call0(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value caller_self) {
      return bc2cpp_owner_call_argv(M, recv, d, mrb_nil_value(), 0, nullptr, caller_self);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call1(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value a) {
      return bc2cpp_owner_call_argv(M, recv, d, mrb_nil_value(), 1, &a);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call1(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value a, mrb_value caller_self) {
      return bc2cpp_owner_call_argv(M, recv, d, mrb_nil_value(), 1, &a, caller_self);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call2(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value a, mrb_value b) {
      const mrb_value argv[2] = {a, b};
      return bc2cpp_owner_call_argv(M, recv, d, mrb_nil_value(), 2, argv);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call2(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value a, mrb_value b,
                                                                        mrb_value caller_self) {
      const mrb_value argv[2] = {a, b};
      return bc2cpp_owner_call_argv(M, recv, d, mrb_nil_value(), 2, argv, caller_self);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call_b0(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk) {
      return bc2cpp_owner_call_argv(M, recv, d, blk, 0, nullptr);
    }
    BC2CPP_SHARD_ONE_BODY [[gnu::noinline, maybe_unused]] static mrb_value bc2cpp_owner_call_b0(mrb_state* M, mrb_value recv, const bc2cpp_owner_desc* d, mrb_value blk, mrb_value caller_self) {
      return bc2cpp_owner_call_argv(M, recv, d, blk, 0, nullptr, caller_self);
    }
  CPP
  private_constant :OWNER_CALL

  # CLOSED_WORLD: the else arm of a guard chain proven to list
  # every class that answers the name, on a receiver with no method_missing.
  # mruby's own dispatch can only raise NoMethodError there; running it keeps
  # the error (message, args, call-depth and memory limits) exactly the same.
  # COLD_RAISE: the call heads of the helpers that only raise. noreturn lets GCC drop the code after each call (the
  # join back and any use of its result), which is most of a site's cost. BC2CPP_COLD_NORETURN=0 types them as
  # returning (BC2CPP_NOIPA), as before.
  COLD_RAISE = ENV['BC2CPP_COLD_NORETURN'] == '0' ? 'BC2CPP_NOIPA' : '[[noreturn, gnu::cold, gnu::noinline, maybe_unused]]'
  private_constant :COLD_RAISE

  NOMETHOD = <<~CPP
    #ifdef BC2CPP_NOMETHOD_VERIFY
    #include <stdio.h>
    #include <stdlib.h>
    #endif
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nomethod_argv(mrb_state* M, mrb_value recv, int i, mrb_int argc, const mrb_value* argv) {
      mrb_sym mid = bc2cpp_sym(M, i);
    #ifdef BC2CPP_NOMETHOD_VERIFY
      // ADR 0275: reaching a site the closed world proved dead is the finding. Dispatching
      // first would let a wrong proof run a method, and a rescue hide the raise, so abort.
      // Two calls: mrb_class_name and mrb_sym_name may share one scratch buffer.
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: dead site reached: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
      fprintf(stderr, "#%s (%d arg(s))\\n", mrb_sym_name(M, mid), (int)argc);
      fflush(stderr);
      abort();
    #endif
    #ifdef BC2CPP_FAIL_FAST_TYPE
      // FAIL_FAST_TYPE (compile-time, see BC2CPP_FAIL_FAST_TYPE in compiled_gems.rb): the receiver is not one the closed
      // world proved answers the name, so the fallback is a type error. Raised here instead of dispatching.
      mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError")), "bc2cpp: fail-fast: %T does not answer %n", recv, mid);
    #endif
      bc2cpp_funcall_argv(M, recv, mid, argc, argv);
      // The dispatch above found a method: the proof was wrong (ADR 0262). A
      // NoMethodError here would look like an ordinary user error.
      mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")),
                 "bc2cpp: closed-world proof violated: %T#%n was proven undefined but dispatched", recv, mid);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nomethod(mrb_state* M, mrb_value recv, int i) {
      bc2cpp_nomethod_argv(M, recv, i, 0, nullptr);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nomethod(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      bc2cpp_nomethod_argv(M, recv, i, argc, argv);
    }
    // DIRECT_RAISE (ADR 0226): a reviewed dead site, which the closed world proves answers the name
    // neither by a method nor by method_missing. Dispatch would find nothing and reach mruby's basic
    // method_missing (mrb_method_missing), which raises this NoMethodError; the format is that function's.
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nomethod_raise_argv(mrb_state* M, mrb_value recv, int i, mrb_int argc, const mrb_value* argv) {
      mrb_sym mid = bc2cpp_sym(M, i);
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: dead site reached: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
      fprintf(stderr, "#%s (%d arg(s))\\n", mrb_sym_name(M, mid), (int)argc);
      fflush(stderr);
      abort();
    #endif
      mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "undefined method '%n' for %T", mid, recv);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nomethod_raise(mrb_state* M, mrb_value recv, int i) {
      bc2cpp_nomethod_raise_argv(M, recv, i, 0, nullptr);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nomethod_raise(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      bc2cpp_nomethod_raise_argv(M, recv, i, argc, argv);
    }
  CPP
  private_constant :NOMETHOD

  # PROGRAM_OWNER_SITES: the nomethod body takes the method id, so a shared helper's proven nomethod
  # (bc2cpp_nomethod_pw, a presym id) and the gem's slot form (bc2cpp_nomethod) run the same one.
  NOMETHOD_MID_EDIT = [
    "[[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nomethod_argv(mrb_state* M, mrb_value recv, int i, mrb_int argc, const mrb_value* argv) {\n  mrb_sym mid = bc2cpp_sym(M, i);\n",
    "[[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nomethod_mid_argv(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv) {\n"
  ].freeze
  NOMETHOD_PROGRAM = <<~CPP
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nomethod_argv(mrb_state* M, mrb_value recv, int i, mrb_int argc, const mrb_value* argv) {
      bc2cpp_nomethod_mid_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nomethod_pw(mrb_state* M, mrb_value recv, mrb_sym mid) {
      bc2cpp_nomethod_mid_argv(M, recv, mid, 0, nullptr);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nomethod_pw(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_value a) {
      bc2cpp_nomethod_mid_argv(M, recv, mid, 1, &a);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nomethod_pw(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_value a, mrb_value b) {
      const mrb_value argv[2] = {a, b};
      bc2cpp_nomethod_mid_argv(M, recv, mid, 2, argv);
    }
  CPP
  private_constant :NOMETHOD_MID_EDIT, :NOMETHOD_PROGRAM

  def nomethod_source
    return NOMETHOD unless program_sites?

    from, to = NOMETHOD_MID_EDIT
    raise 'PROGRAM_OWNER_SITES: the nomethod source no longer has bc2cpp_nomethod_argv' unless NOMETHOD.include?(from)

    text = NOMETHOD.sub(from) { to }
    at = text.index("#{COLD_RAISE} static mrb_value bc2cpp_nomethod(")
    text[0...at] + NOMETHOD_PROGRAM + text[at..]
  end

  # CHECKED_SEND with `public_send` as its presym id when the build has one: the function-local cache of its interned
  # id is a state of the gem's, so bc2cpp_check_send stayed one copy per gem.
  CHECKED_SEND_PUBLIC_SEND = [
    "static bool bc2cpp_is_public_send(mrb_state* M, mrb_sym mid) {\n  static mrb_state* st; static mrb_sym ps;\n  if (st != M) { ps = mrb_intern_lit(M, \"public_send\"); st = M; }\n  return mid == ps;\n}\n",
    "static bool bc2cpp_is_public_send(mrb_state*, mrb_sym mid) {\n  return mid == %s;\n}\n"
  ].freeze
  private_constant :CHECKED_SEND_PUBLIC_SEND

  def checked_send_source
    macro = program_mid('public_send')
    return CHECKED_SEND unless macro

    from, to = CHECKED_SEND_PUBLIC_SEND
    raise 'PROGRAM_OWNER_SITES: the checked-send source no longer has bc2cpp_is_public_send' unless CHECKED_SEND.include?(from)

    CHECKED_SEND.sub(from) { format(to, macro) }
  end

  # GUARD_VIOLATION: the else arm of a guard whose register the
  # closed world proves holds a stable class constant. Unlike bc2cpp_nomethod it
  # never dispatches: reaching it means the proof is wrong, so it logs to $stderr
  # and raises a NoMethodError subclass (a rescue written for the old dispatch's
  # NoMethodError still sees it, after the log line). -DBC2CPP_NOMETHOD_VERIFY
  # aborts as the nomethod helper does; -DBC2CPP_GUARD_VIOLATION_DISPATCH restores
  # the plain send for debugging a suspected wrong proof.
  GUARD_VIOLATION = <<~CPP
    #ifdef BC2CPP_NOMETHOD_VERIFY
    #include <stdio.h>
    #include <stdlib.h>
    #endif
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_guard_violation_raise(mrb_state* M, mrb_value recv, mrb_sym mid, const char* site) {
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: guard violation reached: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
      fprintf(stderr, "#%s at %s\\n", mrb_sym_name(M, mid), site);
      fflush(stderr);
      abort();
    #endif
      mrb_value msg = mrb_format(M, "closed-world guard violation: %T#%n at %s", recv, mid, site);
      bc2cpp_stderr_report(M, "[RPG2k] ", msg);
      struct RClass* klass = mrb_define_class(M, "BC2cppGuardViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
    }
    // COLD_RAISE unless the debugging dispatch, which returns the send's result, is compiled in.
    #ifdef BC2CPP_GUARD_VIOLATION_DISPATCH
    #define BC2CPP_GUARD_VIOLATION_HEAD BC2CPP_NOIPA
    #else
    #define BC2CPP_GUARD_VIOLATION_HEAD #{COLD_RAISE}
    #endif
    BC2CPP_GUARD_VIOLATION_HEAD static mrb_value bc2cpp_guard_violation(mrb_state* M, mrb_value recv, int i, const char* site, mrb_int argc, ...) {
    #ifdef BC2CPP_GUARD_VIOLATION_DISPATCH
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      return bc2cpp_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
    #else
      (void)argc;
      bc2cpp_guard_violation_raise(M, recv, bc2cpp_sym(M, i), site);
    #endif
    }
  CPP
  private_constant :GUARD_VIOLATION

  # STRICT_HINTS: the else arm of a guard on a whole-program class HINT, forced by
  # BC2CPP_STRICT_HINTS. A wrong hint is reached here with a correct program: log, then raise
  # BC2cppHintViolation < NoMethodError (a `rescue NoMethodError` sees it after the log line). Never
  # dispatches, never undefined behavior. -DBC2CPP_NOMETHOD_VERIFY aborts, naming class, name and site,
  # so CI can run real workloads and prove zero violations; -DBC2CPP_HINT_VIOLATION_DISPATCH restores
  # the by-name send (silently) to bisect a suspected wrong hint without regenerating.
  # -DBC2CPP_HINT_VIOLATION_LOG is the survey mode of the verify build: every distinct
  # (site, class, name) is printed once on stderr as `bc2cpp: HINT_VIOLATION_LOG: Class#name at site`
  # and the by-name send runs, so one workload run lists every wrong hint instead of stopping at the first.
  HINT_VIOLATION = <<~CPP
    #if defined(BC2CPP_NOMETHOD_VERIFY) || defined(BC2CPP_HINT_VIOLATION_LOG)
    #include <stdio.h>
    #include <stdlib.h>
    #endif
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_hint_violation_raise(mrb_state* M, mrb_value recv, mrb_sym mid, const char* site) {
    #ifdef BC2CPP_NOMETHOD_VERIFY
      fprintf(stderr, "bc2cpp: NOMETHOD_VERIFY: hint violation reached: %s", mrb_class_name(M, mrb_obj_class(M, recv)));
      fprintf(stderr, "#%s at %s\\n", mrb_sym_name(M, mid), site);
      fflush(stderr);
      abort();
    #endif
      mrb_value msg = mrb_format(M, "%T#%n at %s", recv, mid, site);
      bc2cpp_stderr_report(M, "[RPG2k] hint violation: ", msg);
      struct RClass* klass = mrb_define_class(M, "BC2cppHintViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, mrb_str_plus(M, mrb_str_new_lit(M, "hint violation: "), msg)));
    }
    // COLD_RAISE unless a dispatch or log mode, which returns the send's result, is compiled in.
    #if defined(BC2CPP_HINT_VIOLATION_DISPATCH) || defined(BC2CPP_HINT_VIOLATION_LOG)
    #define BC2CPP_HINT_VIOLATION_HEAD BC2CPP_NOIPA
    #else
    #define BC2CPP_HINT_VIOLATION_HEAD #{COLD_RAISE}
    #endif
    BC2CPP_HINT_VIOLATION_HEAD static mrb_value bc2cpp_hint_violation(mrb_state* M, mrb_value recv, int i, const char* site, mrb_int argc, ...) {
    #ifdef BC2CPP_HINT_VIOLATION_LOG
      {
        static struct { const char* site; struct RClass* klass; mrb_sym mid; } seen[1024];
        static int nseen;
        struct RClass* klass = mrb_obj_class(M, recv);
        mrb_sym mid = bc2cpp_sym(M, i);
        bool known = false;
        for (int k = 0; k < nseen && !known; k++) known = seen[k].site == site && seen[k].klass == klass && seen[k].mid == mid;
        if (!known) {
          if (nseen < 1024) { seen[nseen].site = site; seen[nseen].klass = klass; seen[nseen].mid = mid; nseen++; }
          fprintf(stderr, "bc2cpp: HINT_VIOLATION_LOG: %s#%s at %s\\n", mrb_class_name(M, klass), mrb_sym_name(M, mid), site);
          fflush(stderr);
        }
      }
    #endif
    #if defined(BC2CPP_HINT_VIOLATION_DISPATCH) || defined(BC2CPP_HINT_VIOLATION_LOG)
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      return bc2cpp_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
    #else
      (void)argc;
      bc2cpp_hint_violation_raise(M, recv, bc2cpp_sym(M, i), site);
    #endif
    }
  CPP
  private_constant :HINT_VIOLATION

  # NIL_RECEIVER: the nil arm of a receiver the class pools prove is nil or one
  # class, for a name nil does not answer. It is a real program path (a nil dereference), so it
  # dispatches and lets mruby raise its own NoMethodError; only a dispatch that finds a method,
  # which means nil_unanswerable? was wrong, is an error of its own.
  NIL_RECEIVER = <<~CPP
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_nil_receiver_argv(mrb_state* M, mrb_value recv, int i, mrb_int argc, const mrb_value* argv) {
      mrb_sym mid = bc2cpp_sym(M, i);
      bc2cpp_funcall_argv(M, recv, mid, argc, argv);
      mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")),
                 "bc2cpp: closed-world proof violated: nil#%n was proven undefined but dispatched", mid);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nil_receiver(mrb_state* M, mrb_value recv, int i) {
      bc2cpp_nil_receiver_argv(M, recv, i, 0, nullptr);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nil_receiver(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      bc2cpp_nil_receiver_argv(M, recv, i, argc, argv);
    }
    // NIL_RECEIVER_ID: the same, at a site whose nil test proves the receiver nil (SymbolCache.nil_tested?).
    #{COLD_RAISE} static mrb_value bc2cpp_nil_receiver_id(mrb_state* M, int i) {
      bc2cpp_nil_receiver_argv(M, mrb_nil_value(), i, 0, nullptr);
    }
    #{COLD_RAISE} static mrb_value bc2cpp_nil_receiver_id(mrb_state* M, int i, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      bc2cpp_nil_receiver_argv(M, mrb_nil_value(), i, argc, argv);
    }
  CPP
  private_constant :NIL_RECEIVER
end
