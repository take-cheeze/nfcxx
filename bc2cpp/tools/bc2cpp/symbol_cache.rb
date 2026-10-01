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
  CHECKED_FUNCALLS = { 'bc2cpp_funcall_noarg' => 1, 'bc2cpp_funcall_explicit' => 2 }.freeze
  FUNCALLS = (%w[mrb_funcall] + CHECKED_FUNCALLS.keys).freeze
  private_constant :STRING, :INTERN, :CHECKED_FUNCALLS, :FUNCALLS

  # Symbols found so far, in first-seen order: C string literal => index.
  class Table
    # CLOSED_WORLD: set once a bc2cpp_nomethod call is rewritten, so emit adds it.
    attr_accessor :nomethod_used
    # GUARD_VIOLATION (ADR 0290): the same for bc2cpp_guard_violation.
    attr_accessor :violation_used
    # NIL_RECEIVER (ADR 0296): the same for bc2cpp_nil_receiver.
    attr_accessor :nil_receiver_used

    # CHECKED_SEND (ADR 0299): per slot, 0 plain, 1 argument count of an attr_reader, 2 that and
    # the explicit-receiver visibility check.
    attr_reader :checks

    def initialize
      @index = {}
      @checks = []
      @nomethod_used = false
      @violation_used = false
      @nil_receiver_used = false
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
  def rewrite_funcalls(code, table)
    out = +''
    pos = 0
    while (start = code.index(/\b(#{FUNCALLS.join('|')}|bc2cpp_nomethod_named|bc2cpp_guard_violation_named|bc2cpp_nil_receiver_named)\(M,\s*/, pos))
      kind = Regexp.last_match(1)
      head_end = Regexp.last_match.end(0)
      recv_end = expression_end(code, head_end)
      name = recv_end && code[recv_end..].match(FUNCALLS.include?(kind) ? /\A,\s*(#{STRING})\s*,/ : /\A,\s*(#{STRING})(?=\s*[,)])/)
      if name
        # The receiver may itself contain a funcall; rewrite it first so its
        # names take their slots before this call's own.
        receiver = rewrite_funcalls(code[head_end...recv_end], table)
        index = table.index_for(name[1], CHECKED_FUNCALLS.fetch(kind, 0))
        table.nomethod_used = true if kind == 'bc2cpp_nomethod_named'
        table.violation_used = true if kind == 'bc2cpp_guard_violation_named'
        table.nil_receiver_used = true if kind == 'bc2cpp_nil_receiver_named'
        replacement = case kind
                      when 'bc2cpp_nomethod_named' then "bc2cpp_nomethod(M, #{receiver}, #{index}"
                      when 'bc2cpp_guard_violation_named' then "bc2cpp_guard_violation(M, #{receiver}, #{index}"
                      when 'bc2cpp_nil_receiver_named' then "bc2cpp_nil_receiver(M, #{receiver}, #{index}"
                      else "bc2cpp_send(M, #{receiver}, #{index},"
                      end
        out << code[pos...start] << replacement
        pos = recv_end + name[0].length
      else
        out << code[pos...head_end]
        pos = head_end
      end
    end
    out << code[pos..]
  end

  # The symbol index of every `bc2cpp_send(M, RECV, i, ...)` (and
  # `bc2cpp_nomethod(M, RECV, i...)`) in `code`, found with the same receiver
  # scan the rewrite uses (RECV may nest sends).
  def send_indices(code)
    found = []
    pos = 0
    while (start = code.index(/\bbc2cpp_(?:send|nomethod|guard_violation|nil_receiver)\(M,\s*/, pos))
      head_end = Regexp.last_match.end(0)
      recv_end = expression_end(code, head_end)
      idx = recv_end && code[recv_end..][/\A,\s*(\d+)\s*[,)]/, 1]
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
      static void bc2cpp_reset_symbol_cache() {
        bc2cpp_sym_state = nullptr;
        for (mrb_sym& s : bc2cpp_syms) s = 0;
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
      #{table.nomethod_used ? NOMETHOD : ''}
      #{table.violation_used ? GUARD_VIOLATION : ''}
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
