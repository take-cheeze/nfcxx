# frozen_string_literal: true

# SYMBOL_CACHE: every ivar/constant/method name and symbol literal in generated
# C++ used to be spelled `mrb_intern_cstr(M, "name")` (or `mrb_funcall(M, r,
# "name", ...)`, which interns the same way inside mruby), so each execution
# paid a presym binary search plus a symbol-table hash lookup. A stack sample of
# the desktop RPGMAKER_BC2CPP build on the RPG2k map scene put ~33% of busy time
# there, almost all of it in Game::Interpreter#execute's command switch (a symbol
# literal or constant chain per `when` arm).
#
# This rewrites the finished C++ of every compiled function so each distinct
# literal is interned once per VM and read from a file-scope table afterwards.
# It is a purely textual pass over calls this generator itself emits, so it
# cannot change which symbol a call site names.
module SymbolCache
  STRING = /"(?:[^"\\\n]|\\.)*"/
  INTERN = /\bmrb_intern_(?:cstr|lit)\(M,\s*(#{STRING})\)/
  private_constant :STRING, :INTERN

  # Symbols found so far, in first-seen order: C string literal => index.
  class Table
    def initialize
      @index = {}
    end

    def index_for(literal)
      @index[literal] ||= @index.size
    end

    def literals
      @index.keys
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
  def rewrite_funcalls(code, table)
    out = +''
    pos = 0
    while (start = code.index(/\bmrb_funcall\(M,\s*/, pos))
      head_end = Regexp.last_match.end(0)
      recv_end = expression_end(code, head_end)
      name = recv_end && code[recv_end..].match(/\A,\s*(#{STRING})\s*,/)
      if name
        # The receiver may itself contain a funcall; rewrite it first so its
        # names take their slots before this call's own.
        receiver = rewrite_funcalls(code[head_end...recv_end], table)
        out << code[pos...start] << "bc2cpp_send(M, #{receiver}, #{table.index_for(name[1])},"
        pos = recv_end + name[0].length
      else
        out << code[pos...head_end]
        pos = head_end
      end
    end
    out << code[pos..]
  end

  # The symbol index of every `bc2cpp_send(M, RECV, i, ...)` in `code`, found
  # with the same receiver scan the rewrite uses (RECV may nest sends).
  def send_indices(code)
    found = []
    pos = 0
    while (start = code.index(/\bbc2cpp_send\(M,\s*/, pos))
      head_end = Regexp.last_match.end(0)
      recv_end = expression_end(code, head_end)
      idx = recv_end && code[recv_end..][/\A,\s*(\d+)\s*,/, 1]
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
      // mrb_funcall_id with the symbol lookup folded in, so a dynamic call site is one
      // call. Same argc limit and error as mruby's (MRB_FUNCALL_ARGC_MAX, src/vm.c).
      static mrb_value bc2cpp_send(mrb_state* M, mrb_value recv, int i, mrb_int argc, ...) {
        mrb_value argv[16];
        if (argc > 16) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "ArgumentError")), "Too long arguments. (limit=16)");
        va_list ap;
        va_start(ap, argc);
        for (mrb_int k = 0; k < argc; k++) argv[k] = va_arg(ap, mrb_value);
        va_end(ap);
        return mrb_funcall_argv(M, recv, bc2cpp_sym(M, i), argc, argv);
      }

    CPP
  end
end
