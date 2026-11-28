# frozen_string_literal: true

require 'strscan'

# CALLEE_ARENA: a compiled method called directly (`X_impl`) gives back the GC arena entries its body made, keeping its
# result rooted, as the VM's own call does. Without it every object allocated under a direct call tree stays rooted
# until the outermost VM or host entry returns (a map load roots tens of thousands of dead objects).
#
# Sound because a caller's register holds, after the call, only values the caller already rooted or reached, the
# result, or a value a store of the callee unlinked (GC_KEEP_OVERWRITTEN / GC_KEEP_REMOVED). Those stores record the
# arena slot of their root (bc2cpp_root_kept), and bc2cpp_arena_exit moves each record still in place below the restore
# point down with it. A block's stores into an enclosing compiled frame are rooted per slot (bc2cpp_upvar_root), and a
# raise leaves past the exit, as it does today. MULTI_RETURN's `X_mr` writes fresh values into its caller's buffer, so
# it keeps its arena (only the `X_impl` definition is wrapped, as printed); a resumable body may park, so it keeps its
# own too. BC2CPP_CALLEE_ARENA=0 restores nothing.
module CalleeArena
  module_function

  def on?
    ENV['BC2CPP_CALLEE_ARENA'] != '0'
  end

  # BC2CPP_CALLEE_ARENA_KEPT=0 (gc_root_check's mutation only): the exit with no records, which loses a kept value.
  def kept?
    ENV['BC2CPP_CALLEE_ARENA_KEPT'] != '0'
  end

  # Printed after bc2cpp_root: the record of kept roots and the exit both callers and stores share for the whole link
  # (C linkage, one copy whichever unit defines it).
  def runtime
    same = <<~'CPP'
      // A store that writes the object already in its slot unlinks nothing, so the old value needs no root.
      static inline bool bc2cpp_stores_itself(mrb_value old, mrb_value v) {
        return !mrb_immediate_p(old) && !mrb_immediate_p(v) && mrb_basic_ptr(old) == mrb_basic_ptr(v);
      }
    CPP
    plain = <<~'CPP'
      [[gnu::noinline]] inline void bc2cpp_root_kept(mrb_value v, mrb_state* M) { bc2cpp_root(M, v); }
    CPP
    return same + plain unless on?

    text = <<~'CPP'
      // KEPT_HINT_BITS: the by_obj hint has 2^BITS entries. It is only a hint (a miss records the root again), so a
      // target short of RAM may shrink it; every unit of one link must agree, since they share one record.
      #ifndef BC2CPP_KEPT_HINT_BITS
      #define BC2CPP_KEPT_HINT_BITS 10
      #endif
      // CALLEE_ARENA (callee_arena.rb): the arena slots of the roots stores took for values they unlinked, in order.
      struct Bc2cppKeptRoots {
        mrb_state* M;
        int n, capa;
        int* at;
        struct RBasic** obj;
        int at0[64];
        struct RBasic* obj0[64];
        // Record index + 1 by object address, a hint: a hit is used only when its record still holds that object.
        uint16_t by_obj[1u << BC2CPP_KEPT_HINT_BITS];
      };
      static inline unsigned bc2cpp_kept_hash(struct RBasic* p) { return ((uintptr_t)p >> 3) & ((1u << BC2CPP_KEPT_HINT_BITS) - 1); }
      // One record for the link: the C-linkage storage names no type, since each gem's namespace has its own struct.
      extern "C" inline void* bc2cpp_kept_roots_storage() {
        alignas(void*) static unsigned char s[sizeof(Bc2cppKeptRoots)];
        return s;
      }
      static inline Bc2cppKeptRoots* bc2cpp_kept_roots(mrb_state* M) {
        Bc2cppKeptRoots* k = (Bc2cppKeptRoots*)bc2cpp_kept_roots_storage();
        // Another state's record is dropped; a state at a closed one's address starts from that empty record too.
        if (k->M != M) {
          if (k->at && k->at != k->at0) {
            mrb_basic_alloc_func(k->at, 0);
            mrb_basic_alloc_func(k->obj, 0);
          }
          k->M = M;
          k->n = 0;
          k->capa = 64;
          k->at = k->at0;
          k->obj = k->obj0;
          memset(k->by_obj, 0, sizeof(k->by_obj));
        }
        return k;
      }
      // A root that must outlive the arena restore of the compiled call that took it: a caller's register may hold it.
      [[gnu::noinline]] inline void bc2cpp_root_kept(mrb_value v, mrb_state* M) {
        if (mrb_immediate_p(v)) return;
        struct RBasic* p = mrb_basic_ptr(v);
        Bc2cppKeptRoots* k = bc2cpp_kept_roots(M);
        // Already kept by a record still in place: its slot outlives this one would (a restore that drops it drops
        // every later slot too, and an exit moves both down), so one root is enough. A loop that shifts values along
        // an Array (an insertion sort) otherwise records the same few objects once per store.
        unsigned h = bc2cpp_kept_hash(p);
        int hit = (int)k->by_obj[h] - 1;
        if (hit >= 0 && hit < k->n && k->obj[hit] == p && k->at[hit] < M->gc.arena_idx && M->gc.arena[k->at[hit]] == p)
          return;
        bc2cpp_root(M, v);
        int at = M->gc.arena_idx - 1;
        // Not in the arena (a persistent ROM object): nothing to keep.
        if (at < 0 || M->gc.arena[at] != p) return;
        if (k->capa < 0) return;
        // A record at or above the new slot was dropped by a restore since; the same slot and object is this root.
        while (k->n > 0 && k->at[k->n - 1] >= at) {
          if (k->at[k->n - 1] == at && k->obj[k->n - 1] == p) return;
          k->n--;
        }
        if (k->n == k->capa) {
          // mruby's base allocator, not the state's: a record outlives the state it was made in (mrb_close).
          int capa = k->capa * 2;
          int* nat = (int*)mrb_basic_alloc_func(NULL, sizeof(int) * capa);
          struct RBasic** nobj = (struct RBasic**)mrb_basic_alloc_func(NULL, sizeof(struct RBasic*) * capa);
          if (!nat || !nobj) {
            if (nat) mrb_basic_alloc_func(nat, 0);
            if (nobj) mrb_basic_alloc_func(nobj, 0);
            // Unrecorded: no exit drops anything again until this state is gone (bc2cpp_arena_exit).
            k->capa = -1;
            return;
          }
          memcpy(nat, k->at, sizeof(int) * k->n);
          memcpy(nobj, k->obj, sizeof(struct RBasic*) * k->n);
          if (k->at != k->at0) {
            mrb_basic_alloc_func(k->at, 0);
            mrb_basic_alloc_func(k->obj, 0);
          }
          k->at = nat;
          k->obj = nobj;
          k->capa = capa;
        }
        k->at[k->n] = at;
        k->obj[k->n] = p;
        k->n++;
        if (k->n <= 0xffff) k->by_obj[h] = (uint16_t)k->n;
      }
      // LOOP_ARENA (loop_arena.rb): a backward jump drops the arena to its loop's entry index, as an exit does.
      [[gnu::noinline]] inline void bc2cpp_arena_back(mrb_state* M, int ai) {
        mrb_gc* gc = &M->gc;
        int top = gc->arena_idx;
        if (top <= ai) return;
        Bc2cppKeptRoots* k = bc2cpp_kept_roots(M);
        if (mrb_unlikely(k->capa < 0)) return;
        int first = k->n;
        while (first > 0 && k->at[first - 1] >= ai) first--;
        gc->arena_idx = ai;
        int w = first;
        for (int i = first; i < k->n; i++) {
          int at = k->at[i];
          struct RBasic* p = k->obj[i];
          if (at >= top || gc->arena[at] != p) continue;
          // Moved down already by this pass (the same object kept twice): one slot is enough.
          unsigned h = bc2cpp_kept_hash(p);
          int seen = (int)k->by_obj[h] - 1;
          if (seen >= first && seen < w && k->obj[seen] == p) continue;
          // The slot written is at or below `at`, and every later record's slot is above it.
          int to = gc->arena_idx;
          gc->arena[to] = p;
          gc->arena_idx = to + 1;
          k->at[w] = to;
          k->obj[w] = p;
          w++;
          if (w <= 0xffff) k->by_obj[h] = (uint16_t)w;
        }
        k->n = w;
        // A record grown by one long run gives its memory back once mostly empty, as the arena trim does.
        if (k->at != k->at0 && k->n < k->capa / 8) {
          int capa = k->capa / 4 < 64 ? 64 : k->capa / 4;
          int* nat = capa == 64 ? k->at0 : (int*)mrb_basic_alloc_func(NULL, sizeof(int) * capa);
          struct RBasic** nobj =
              capa == 64 ? k->obj0 : (struct RBasic**)mrb_basic_alloc_func(NULL, sizeof(struct RBasic*) * capa);
          if (nat && nobj) {
            memcpy(nat, k->at, sizeof(int) * k->n);
            memcpy(nobj, k->obj, sizeof(struct RBasic*) * k->n);
            mrb_basic_alloc_func(k->at, 0);
            mrb_basic_alloc_func(k->obj, 0);
            k->at = nat;
            k->obj = nobj;
            k->capa = capa;
          } else {
            if (nat && nat != k->at0) mrb_basic_alloc_func(nat, 0);
            if (nobj && nobj != k->obj0) mrb_basic_alloc_func(nobj, 0);
          }
        }
      }
      [[gnu::noinline]] inline void bc2cpp_loop_root(mrb_value v, mrb_state* M) { bc2cpp_root(M, v); }
      // The exit of a direct `X_impl`: drop the arena to the entry index `ai`, keep the recorded roots above it (moved
      // down, in order), then root the result.
      [[gnu::noinline]] inline mrb_value bc2cpp_arena_exit(mrb_state* M, int ai, mrb_value v) {
        mrb_gc* gc = &M->gc;
        int top = gc->arena_idx;
        if (top <= ai) return v;
        if (top == ai + 1 && (mrb_immediate_p(v) || gc->arena[ai] == mrb_basic_ptr(v))) return v;
        bc2cpp_arena_back(M, ai);
        bc2cpp_root(M, v);
        return v;
      }
    CPP
    same + (kept? ? text : text.sub(/^\/\/ A root that must outlive.*?^\}\n/m, plain))
  end

  # The lines wrap_code adds around a body. KeepSummary blanks LAMBDA before reading the body (its brace-init rule).
  # The lambda is always inlined: an out-of-line body is a new symbol, which the device's QSPI placement does not list.
  LAMBDA = '[&]() __attribute__((always_inline)) -> mrb_value {'
  OPEN = "  int bc2cpp_ai = M->gc.arena_idx;\n  return bc2cpp_arena_exit(M, bc2cpp_ai, #{LAMBDA}\n"
  CLOSE = "  }());\n"
  # What makes a body's arena growth unbounded: a loop, or a call that may run compiled or Ruby code.
  # A declared-return guard's `X_impl` only calls its body, `X_impl_unguarded` (DECLARED_RETURN_GUARD).
  RUNS_CODE = /\bgoto[ ]L\w+;|\bwhile\b|\bfor[ ]\(|_impl\(|_impl_unguarded\(|_direct\(|owner_call|funcall|bc2cpp_send|yield|
               _block|ccall|_proc|bc2cpp_call/x

  # Each `X_impl` definition of the compiled methods, as printed (a split `X_impl` builds the Array from
  # `X_mr`'s buffer; `X_mr` itself is not wrapped).
  def wrap!(compiled)
    return compiled unless on?

    compiled.each do |m|
      next unless m.is_a?(Hash) && m[:impl] && !m[:resumable] && !m[:unsupported]

      code = m[:code]
      next unless code.is_a?(String) && !code.include?('#error')

      wrapped = wrap_code(code, m[:impl])
      m[:code] = wrapped if wrapped
    end
    compiled
  end

  # The body runs as a lambda called in place, so each of its `return`s reaches the exit, and the definition keeps its
  # name, head and closing line for the passes and checks that read it.
  def wrap_code(code, impl)
    head = /^mrb_value #{Regexp.escape(impl)}\([^()]*\) \{\n/
    from = code.index(head) or return nil
    return nil if code.index(head, from + 1)

    start = code.index("\n", from) + 1
    stop = matching_close(code, start - 2) or return nil
    body = code[start...stop]
    # A resumable entry keeps its frame across a park: not a plain body.
    return nil if body.include?('bc2cpp_resumable_init(M)')
    # A straight-line body that runs no compiled or by-name code makes a bounded few entries, which its caller's own
    # exit drops; the exit would only cost code.
    return nil unless body.match?(RUNS_CODE)

    "#{code[0...start]}#{OPEN}#{code[start...stop]}#{CLOSE}#{code[stop..]}"
  end

  # The index of the `}` that closes the `{` at +open+ (a generated body has unindented braces of its own), past
  # string and character literals and comments; nil when it does not close.
  def matching_close(code, open)
    sc = StringScanner.new(code)
    sc.pos = open
    depth = 0
    while sc.skip_until(%r{[{}"'/]})
      case sc.matched
      when '{' then depth += 1
      when '}'
        depth -= 1
        return sc.pos - 1 if depth.zero?
      when '"' then sc.skip(/(?:[^"\\\n]|\\.)*"/)
      when "'" then sc.skip(/(?:[^'\\\n]|\\.)*'/)
      else
        sc.skip(%r{/[^\n]*}) || sc.skip(%r{\*.*?\*/}m)
      end
    end
    nil
  end
end
