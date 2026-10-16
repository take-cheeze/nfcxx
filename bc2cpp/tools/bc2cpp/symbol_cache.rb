# frozen_string_literal: true

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
  # CHECKED_SEND (ADR 0299): codegen_checked_send.rb marks a by-name call that must do what
  # OP_SEND / OP_SSEND check and mrb_funcall does not; the slot carries the check's level.
  # NATIVE_SINGLETON_CALL (ADR 0416): `bc2cpp_native_singleton_named` is an explicit-receiver by-name call whose
  # method the compiler proved to be one native singleton function; it keeps level 2 as its fallback is a
  # checked send, and gets a per-site method cache slot (BC2CPP_NSC_SLOT).
  CHECKED_FUNCALLS = { 'bc2cpp_funcall_noarg' => 1, 'bc2cpp_funcall_explicit' => 2,
                       'bc2cpp_native_singleton_named' => 2 }.freeze
  FUNCALLS = (%w[mrb_funcall] + CHECKED_FUNCALLS.keys).freeze
  FUNCALL_START = /\b(#{FUNCALLS.join('|')}|bc2cpp_owner_call_named|bc2cpp_nomethod_named|bc2cpp_nomethod_raise_named|bc2cpp_guard_violation_named|bc2cpp_hint_violation_named|bc2cpp_nil_receiver_named)\(M,\s*/
  FUNCALL_NAME = /\G,\s*(#{STRING})\s*,/
  NAMED_NAME = /\G,\s*(#{STRING})(?=\s*[,)])/
  SEND_INDEX = /\G,\s*(\d+)\s*[,)]/
  private_constant :STRING, :INTERN, :CHECKED_FUNCALLS, :FUNCALLS,
                   :FUNCALL_START, :FUNCALL_NAME, :NAMED_NAME, :SEND_INDEX

  # Symbols found so far, in first-seen order: C string literal => index.
  class Table
    # CLOSED_WORLD: set once a bc2cpp_nomethod call is rewritten, so emit adds it.
    attr_accessor :nomethod_used
    # GUARD_VIOLATION (ADR 0290): the same for bc2cpp_guard_violation.
    attr_accessor :violation_used
    # STRICT_HINTS (ADR 0419): the same for bc2cpp_hint_violation.
    attr_accessor :hint_violation_used
    # NIL_RECEIVER (ADR 0296): the same for bc2cpp_nil_receiver.
    attr_accessor :nil_receiver_used
    # NATIVE_SINGLETON_CALL (ADR 0416): the same for bc2cpp_native_singleton.
    attr_accessor :native_singleton_used
    # OUTSIDE_OWNER_CALL (ADR 0468): the same for bc2cpp_owner_call.
    attr_accessor :owner_call_used

    # CHECKED_SEND (ADR 0299): per slot, 0 plain, 1 argument count of an attr_reader, 2 that and
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
    rewrite_interns(rewrite_funcalls(code, table), table)
  end

  def rewrite_interns(code, table)
    code.gsub(INTERN) { "bc2cpp_sym(M, #{table.index_for(Regexp.last_match(1))})" }
  end

  # `mrb_funcall(M, RECV, "name", N, ...)` -> `bc2cpp_send(M, RECV, i, N, ...)`. RECV is an arbitrary C++ expression, so the
  # receiver is delimited with a bracket/quote-aware scan; a call whose name is
  # not a plain string literal is left alone.
  # CLOSED_WORLD's `bc2cpp_nomethod_named(M, RECV, "name"...)` becomes
  # `bc2cpp_nomethod(M, RECV, i...)` the same way, and GUARD_VIOLATION's
  # `bc2cpp_guard_violation_named(M, RECV, "name", "site", ...)` becomes
  # `bc2cpp_guard_violation(M, RECV, i, "site", ...)`; NIL_RECEIVER's
  # `bc2cpp_nil_receiver_named(M, RECV, "name", ...)` becomes `bc2cpp_nil_receiver(M, RECV, i, ...)`.
  def rewrite_funcalls(code, table, encoding: code.encoding)
    # The grammar is ASCII; byte offsets avoid rescanning UTF-8 prefixes at each match.
    code = code.b
    out = +''.b
    pos = 0
    while (start = code.index(FUNCALL_START, pos))
      kind = Regexp.last_match(1)
      head_end = Regexp.last_match.end(0)
      recv_end = expression_end(code, head_end)
      name = recv_end && (FUNCALLS.include?(kind) ? FUNCALL_NAME : NAMED_NAME).match(code, recv_end)
      if name
        # The receiver may itself contain a funcall; rewrite it first so its
        # names take their slots before this call's own.
        receiver = rewrite_funcalls(code[head_end...recv_end], table, encoding: encoding)
        index = table.index_for(name[1].force_encoding(encoding), CHECKED_FUNCALLS.fetch(kind, 0))
        table.nomethod_used = true if kind == 'bc2cpp_nomethod_named' || kind == 'bc2cpp_nomethod_raise_named'
        table.violation_used = true if kind == 'bc2cpp_guard_violation_named'
        table.hint_violation_used = true if kind == 'bc2cpp_hint_violation_named'
        table.nil_receiver_used = true if kind == 'bc2cpp_nil_receiver_named'
        table.native_singleton_used = true if kind == 'bc2cpp_native_singleton_named'
        table.owner_call_used = true if kind == 'bc2cpp_owner_call_named'
        replacement = case kind
                      when 'bc2cpp_nomethod_named' then "bc2cpp_nomethod(M, #{receiver}, #{index}"
                      when 'bc2cpp_nomethod_raise_named' then "bc2cpp_nomethod_raise(M, #{receiver}, #{index}"
                      when 'bc2cpp_guard_violation_named' then "bc2cpp_guard_violation(M, #{receiver}, #{index}"
                      when 'bc2cpp_hint_violation_named' then "bc2cpp_hint_violation(M, #{receiver}, #{index}"
                      when 'bc2cpp_nil_receiver_named' then "bc2cpp_nil_receiver(M, #{receiver}, #{index}"
                      when 'bc2cpp_owner_call_named' then "bc2cpp_owner_call(M, #{receiver}, #{index}"
                      when 'bc2cpp_native_singleton_named' then "bc2cpp_native_singleton(M, #{receiver}, #{index}, BC2CPP_NSC_SLOT,"
                      else "bc2cpp_send(M, #{receiver}, #{index},"
                      end
        out << code[pos...start] << replacement.b
        pos = recv_end + name[0].length
      else
        out << code[pos...head_end]
        pos = head_end
      end
    end
    out << code[pos..]
    out.force_encoding(encoding)
  end

  # The symbol index of every `bc2cpp_send(M, RECV, i, ...)` (and
  # `bc2cpp_nomethod(M, RECV, i...)`) in `code`, found with the same receiver
  # scan the rewrite uses (RECV may nest sends).
  def send_indices(code)
    code = code.b
    found = []
    pos = 0
    while (start = code.index(/\bbc2cpp_(?:send|nomethod|nomethod_raise|guard_violation|hint_violation|nil_receiver|native_singleton|owner_call)\(M,\s*/, pos))
      head_end = Regexp.last_match.end(0)
      recv_end = expression_end(code, head_end)
      match = recv_end && SEND_INDEX.match(code, recv_end)
      idx = match && match[1]
      found << idx.to_i if idx
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

  # The file-scope cache. Keyed on the mrb_state so a second live VM cannot read
  # the first one's ids, and reset from each gem's gem_final so a VM opened
  # later at a reused address cannot either. Symbols are never collected, so a
  # cached id stays valid for the whole life of its VM.
  def emit(table)
    names = table.literals.map { |literal| "  #{literal}," }.join("\n")
    checked = table.checks.any? { |check| check.to_i.positive? }
    checks = (0...[table.size, 1].max).map { |slot| table.checks[slot].to_i }.join(', ')
    <<~CPP
      // SYMBOL_CACHE -- see tools/bc2cpp/symbol_cache.rb.
      static mrb_state* bc2cpp_sym_state = nullptr;
      static mrb_sym bc2cpp_syms[#{[table.size, 1].max}] = {};
      static const char* const bc2cpp_sym_names[#{[table.size, 1].max}] = {
      #{names.empty? ? '  "",' : names}
      };
      #{table.native_singleton_used ? "// NATIVE_SINGLETON_CALL: bumped with the symbol table, so no slot outlives its VM.\nstatic unsigned bc2cpp_nsc_epoch = 1;" : ''}#{table.owner_call_used ? "\n// OUTSIDE_OWNER_CALL: bumped with the symbol table, so no owner set outlives its VM.\nstatic unsigned bc2cpp_owner_epoch = 1;" : ''}
      static void bc2cpp_reset_symbol_cache() {
        bc2cpp_sym_state = nullptr;
        for (mrb_sym& s : bc2cpp_syms) s = 0;
      #{table.native_singleton_used ? '  ++bc2cpp_nsc_epoch;' : ''}#{table.owner_call_used ? "\n  ++bc2cpp_owner_epoch;" : ''}
      }
      static inline mrb_sym bc2cpp_sym(mrb_state* M, int i) {
        if (bc2cpp_sym_state != M) {
          bc2cpp_reset_symbol_cache();
          bc2cpp_sym_state = M;
        }
        mrb_sym s = bc2cpp_syms[i];
        if (!s) s = bc2cpp_syms[i] = mrb_intern_cstr(M, bc2cpp_sym_names[i]);
        return s;
      }
      #{checked ? "static const unsigned char bc2cpp_sym_check[#{[table.size, 1].max}] = { #{checks} };\n#{CHECKED_SEND}" : ''}
      // mrb_funcall_id with the symbol lookup folded in, so a dynamic call site is one
      // call. Same argc limit and error as mruby's (MRB_FUNCALL_ARGC_MAX, src/vm.c).
      static mrb_value bc2cpp_send(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
        mrb_value argv[16];
        if (argc > 16) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "Too long arguments. (limit=16)");
        va_list ap;
        va_start(ap, argc);
        for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
        va_end(ap);
      #{checked ? "  if (bc2cpp_sym_check[i]) bc2cpp_check_send(M, recv, bc2cpp_sym(M, i), argc, argv, bc2cpp_sym_check[i] == 2);" : ''}
        return bc2cpp_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
      }
      #{table.native_singleton_used ? NATIVE_SINGLETON : ''}#{table.owner_call_used ? OWNER_CALL : ''}
      #{table.nomethod_used ? NOMETHOD : ''}
      #{table.violation_used ? GUARD_VIOLATION : ''}#{table.hint_violation_used ? HINT_VIOLATION : ''}
      #{table.nil_receiver_used ? NIL_RECEIVER : ''}
    CPP
  end

  # CHECKED_SEND (ADR 0299): what OP_SEND / OP_SSEND check before calling and mrb_funcall does not.
  # Level 2 is an explicit-receiver OP_SEND: a private or protected method raises NoMethodError
  # (vm.c vis_error, protected by the same kind_of test). Level 1 and 2 both raise ArgumentError for
  # a cfunc proc flagged MRB_PROC_NOARG (an attr_reader) called with arguments. An undefined
  # method is left to mrb_funcall, which reaches method_missing.
  CHECKED_SEND = <<~CPP
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_visibility_error(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv, bool priv) {
      mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", priv ? "private" : "protected", mid, recv);
    }
    [[gnu::noinline]] static void bc2cpp_check_send(mrb_state* M, mrb_value recv, mrb_sym mid, mrb_int argc, const mrb_value* argv, bool explicit_receiver) {
      struct RClass* c = mrb_class(M, recv);
      mrb_method_t m = mrb_method_search_vm(M, &c, mid);
      if (MRB_METHOD_UNDEF_P(m)) return;
      if (explicit_receiver) {
        if (m.flags & MRB_METHOD_PRIVATE_FL) bc2cpp_visibility_error(M, recv, mid, argc, argv, true);
        if ((m.flags & MRB_METHOD_PROTECTED_FL) && mrb_obj_is_kind_of(M, recv, c)) bc2cpp_visibility_error(M, recv, mid, argc, argv, false);
      }
      if (argc > 0 && MRB_METHOD_PROC_P(m)) {
        const struct RProc* p = MRB_METHOD_PROC(m);
        if (MRB_PROC_ALIAS_P(p)) p = p->upper;
        if (MRB_PROC_CFUNC_P(p) && MRB_PROC_NOARG_P(p)) mrb_argnum_error(M, argc, 0, 0);
      }
    }
  CPP
  private_constant :CHECKED_SEND

  # NATIVE_SINGLETON_CALL (ADR 0416): `Const.name(args)` where the compiler proved `name` is one C function
  # registered on the constant's singleton class (tools/bc2cpp/native_singletons.rb). The function reads its
  # arguments through mrb_get_args from the call frame, so it cannot be called bare; this runs the frame
  # mrb_funcall would push (mrb_funcall_with_method is funcall_with_block_m with the lookup done), once per site
  # instead of the two lookups a checked bc2cpp_send makes. The slot is filled by the first call and is valid for
  # one VM (epoch, state) and one receiver. Anything the proof assumed but the VM does not show -- the method is
  # not a public C function, or an attr_reader-style NOARG function is given arguments -- is not cached and takes
  # the ordinary checked send, so a wrong proof costs speed, never the error or the answer.
  NATIVE_SINGLETON = <<~CPP
    extern "C" mrb_value mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value);
    struct bc2cpp_nsc_slot {
      unsigned epoch;
      mrb_state* state;
      struct RObject* recv;
      mrb_method_t m;
      struct RClass* owner;
    };
    #define BC2CPP_NSC_SLOT ([]() -> bc2cpp_nsc_slot& { static bc2cpp_nsc_slot s; return s; }())
    [[gnu::noinline]] static bool bc2cpp_nsc_fill(mrb_state* M, bc2cpp_nsc_slot& s, mrb_value recv, mrb_sym mid, mrb_int argc) {
      if (mrb_type(recv) != MRB_TT_CLASS && mrb_type(recv) != MRB_TT_MODULE) return false;
      struct RClass* c = mrb_class(M, recv);
      mrb_method_t m = mrb_method_search_vm(M, &c, mid);
      if (MRB_METHOD_UNDEF_P(m) || !MRB_METHOD_CFUNC_P(m)) return false;
      if (m.flags & (MRB_METHOD_PRIVATE_FL | MRB_METHOD_PROTECTED_FL)) return false;
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
      s.state = M;
      s.recv = mrb_obj_ptr(recv);
      s.m = m;
      s.owner = c;
      return true;
    }
    static mrb_value bc2cpp_native_singleton(mrb_state* M, mrb_value recv, int i, bc2cpp_nsc_slot& s, mrb_int argc, ...) {
      mrb_value argv[16];
      if (argc > 16) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "Too long arguments. (limit=16)");
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      mrb_sym mid = bc2cpp_sym(M, i);
      bool cached = s.epoch == bc2cpp_nsc_epoch && s.state == M && (mrb_type(recv) == MRB_TT_CLASS || mrb_type(recv) == MRB_TT_MODULE) &&
                    s.recv == mrb_obj_ptr(recv);
      if (cached || bc2cpp_nsc_fill(M, s, recv, mid, argc)) {
        return mrb_funcall_with_method(M, recv, mid, &s.m, s.owner, argc, argv, mrb_nil_value());
      }
      if (bc2cpp_sym_check[i]) bc2cpp_check_send(M, recv, mid, argc, argv, bc2cpp_sym_check[i] == 2);
      return bc2cpp_funcall_argv(M, recv, mid, argc, argv);
    }
  CPP
  private_constant :NATIVE_SINGLETON

  # OUTSIDE_OWNER_CALL (ADR 0468): the else of a closed-world chain whose remaining receivers answer the name only
  # through outside (core, native or outside Ruby) definitions, every one of which the compiler named
  # (BC2CPP_OWNERS: class paths as mrb_class_name spells them, `.singleton` for a class object's own method).
  # The method is looked up once and checked against that list: a listed owner's method runs in the frame mruby's
  # dispatch pushes (mrb_funcall_with_method: a C function reads its arguments from that frame) after the checks
  # OP_SEND makes at `level` (2 explicit receiver: visibility; 1 and 2: argument count, aspec); no method raises what
  # dispatch raises (the receiver is proven method_missing-free, so a dispatch that returns is a violated proof); any
  # other owner is a definer the closed world did not see, and raises. Owners already matched are kept per site and
  # VM (up to 16), so the name test runs once per owner.
  OWNER_CALL = <<~CPP
    #include <string.h>
    #ifdef BC2CPP_NOMETHOD_VERIFY
    #include <stdio.h>
    #include <stdlib.h>
    #endif
    extern "C" mrb_value mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value);
    struct bc2cpp_owner_set {
      const char* const* names;
      unsigned epoch;
      mrb_state* state;
      int seen_count;
      struct RClass* seen[16];
    };
    #define BC2CPP_OWNERS(...) ([]() -> bc2cpp_owner_set& { static const char* const names[] = { __VA_ARGS__, nullptr }; static bc2cpp_owner_set s = { names, 0, nullptr, 0, {} }; return s; }())
    [[noreturn, gnu::cold, gnu::noinline]] static void bc2cpp_owner_violation(mrb_state* M, mrb_value recv, mrb_sym mid, const char* what) {
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
    // Is `c` (a method's owner, an iclass already resolved to its module) one of `names`?
    static bool bc2cpp_owner_listed(mrb_state* M, struct RClass* c, const char* const* names) {
      bool singleton = false;
      if (c->tt == MRB_TT_SCLASS) {
        mrb_value attached = mrb_iv_get(M, mrb_obj_value(c), mrb_intern_lit(M, "__attached__"));
        if (mrb_type(attached) != MRB_TT_CLASS && mrb_type(attached) != MRB_TT_MODULE) return false;
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
    static mrb_value bc2cpp_owner_call(mrb_state* M, mrb_value recv, int i, int level, bc2cpp_owner_set& s, mrb_value blk, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      mrb_sym mid = bc2cpp_sym(M, i);
      // As bc2cpp_funcall_argv: Proc#call and its aliases on a compiled block are a yield, not an OP_CALL in a C frame.
      if (mrb_nil_p(blk) && mrb_type(recv) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, recv, mid)) return bc2cpp_yield_argv(M, recv, argc, argv);
      struct RClass* c = mrb_class(M, recv);
      mrb_method_t m = mrb_method_search_vm(M, &c, mid);
      if (MRB_METHOD_UNDEF_P(m)) {
        if (mrb_nil_p(blk)) bc2cpp_funcall_argv(M, recv, mid, argc, argv);
        else mrb_funcall_with_block(M, recv, mid, argc, argv, blk);
        bc2cpp_owner_violation(M, recv, mid, "was proven to raise NoMethodError but dispatched");
      }
      struct RClass* owner = c->tt == MRB_TT_ICLASS ? c->c : c;
      if (s.epoch != bc2cpp_owner_epoch || s.state != M) {
        s.epoch = bc2cpp_owner_epoch;
        s.state = M;
        s.seen_count = 0;
      }
      bool seen = false;
      for (int k = 0; k < s.seen_count; ++k) seen = seen || s.seen[k] == owner;
      if (!seen) {
        if (!bc2cpp_owner_listed(M, owner, s.names)) bc2cpp_owner_violation(M, recv, mid, "resolves to a definer the closed world does not list");
        if (s.seen_count < 16) s.seen[s.seen_count++] = owner;
      }
      if (level >= 2) {
        // vm.c OP_SEND: an explicit receiver may not call a private method, nor a protected one from outside.
        if (m.flags & MRB_METHOD_PRIVATE_FL) {
          mrb_no_method_error(M, mid, mrb_ary_new_from_values(M, argc, argv), "%s method '%n' called for %T", "private", mid, recv);
        }
        if ((m.flags & MRB_METHOD_PROTECTED_FL) && mrb_obj_is_kind_of(M, recv, c)) {
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
      return mrb_funcall_with_method(M, recv, mid, &m, c, argc, argv, blk);
    }
  CPP
  private_constant :OWNER_CALL

  # CLOSED_WORLD (docs/adr/0210): the else arm of a guard chain proven to list
  # every class that answers the name, on a receiver with no method_missing.
  # mruby's own dispatch can only raise NoMethodError there; running it keeps
  # the error (message, args, call-depth and memory limits) exactly the same.
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
      mrb_funcall_argv(M, recv, mid, argc, argv);
      // The dispatch above found a method: the proof was wrong (ADR 0262). A
      // NoMethodError here would look like an ordinary user error.
      mrb_raisef(M, mrb_exc_get_id(M, mrb_intern_lit(M, "RuntimeError")),
                 "bc2cpp: closed-world proof violated: %T#%n was proven undefined but dispatched", recv, mid);
    }
    // Typed as returning so GCC keeps the call site in place: a known-noreturn
    // call is moved to the end of its function, which costs more than it saves.
    [[gnu::noipa]] static mrb_value bc2cpp_nomethod(mrb_state* M, mrb_value recv, int i) {
      bc2cpp_nomethod_argv(M, recv, i, 0, nullptr);
    }
    [[gnu::noipa]] static mrb_value bc2cpp_nomethod(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
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
    [[gnu::noipa]] static mrb_value bc2cpp_nomethod_raise(mrb_state* M, mrb_value recv, int i) {
      bc2cpp_nomethod_raise_argv(M, recv, i, 0, nullptr);
    }
    [[gnu::noipa]] static mrb_value bc2cpp_nomethod_raise(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      bc2cpp_nomethod_raise_argv(M, recv, i, argc, argv);
    }
  CPP
  private_constant :NOMETHOD

  # GUARD_VIOLATION (docs/adr/0290): the else arm of a guard whose register the
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
      mrb_value err = mrb_gv_get(M, mrb_intern_lit(M, "$stderr"));
      mrb_sym puts_id = mrb_intern_lit(M, "puts");
      if (mrb_respond_to(M, err, puts_id)) mrb_funcall_id(M, err, puts_id, 1, mrb_str_plus(M, mrb_str_new_lit(M, "[RPG2k] "), msg));
      struct RClass* klass = mrb_define_class(M, "BC2cppGuardViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, msg));
    }
    // Typed as returning, like bc2cpp_nomethod, so GCC keeps the call in place.
    [[gnu::noipa]] static mrb_value bc2cpp_guard_violation(mrb_state* M, mrb_value recv, int i, const char* site, mrb_int argc, ...) {
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

  # STRICT_HINTS (docs/adr/0419): the else arm of a guard on a whole-program class HINT, forced by
  # BC2CPP_STRICT_HINTS. A wrong hint is reached here with a correct program: log, then raise
  # BC2cppHintViolation < NoMethodError (a `rescue NoMethodError` sees it after the log line). Never
  # dispatches, never undefined behavior. -DBC2CPP_NOMETHOD_VERIFY aborts, naming class, name and site,
  # so CI can run real workloads and prove zero violations; -DBC2CPP_HINT_VIOLATION_DISPATCH restores
  # the by-name send (silently) to bisect a suspected wrong hint without regenerating.
  # -DBC2CPP_HINT_VIOLATION_LOG (ADR 0428) is the survey mode of the verify build: every distinct
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
      mrb_value err = mrb_gv_get(M, mrb_intern_lit(M, "$stderr"));
      mrb_sym puts_id = mrb_intern_lit(M, "puts");
      if (mrb_respond_to(M, err, puts_id)) mrb_funcall_id(M, err, puts_id, 1, mrb_str_plus(M, mrb_str_new_lit(M, "[RPG2k] hint violation: "), msg));
      struct RClass* klass = mrb_define_class(M, "BC2cppHintViolation", mrb_exc_get_id(M, mrb_intern_lit(M, "NoMethodError")));
      mrb_exc_raise(M, mrb_exc_new_str(M, klass, mrb_str_plus(M, mrb_str_new_lit(M, "hint violation: "), msg)));
    }
    [[gnu::noipa]] static mrb_value bc2cpp_hint_violation(mrb_state* M, mrb_value recv, int i, const char* site, mrb_int argc, ...) {
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

  # NIL_RECEIVER (docs/adr/0296): the nil arm of a receiver the class pools prove is nil or one
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
    [[gnu::noipa]] static mrb_value bc2cpp_nil_receiver(mrb_state* M, mrb_value recv, int i) {
      bc2cpp_nil_receiver_argv(M, recv, i, 0, nullptr);
    }
    [[gnu::noipa]] static mrb_value bc2cpp_nil_receiver(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
      mrb_value argv[16];
      va_list ap;
      va_start(ap, argc);
      for (mrb_int k = 0; k < argc && k < 16; k++) argv[k] = va_arg(ap, mrb_value);
      va_end(ap);
      bc2cpp_nil_receiver_argv(M, recv, i, argc, argv);
    }
  CPP
  private_constant :NIL_RECEIVER
end
