# frozen_string_literal: true

require 'set'
require_relative 'native_expression_devirt'

# FRAME_FREE: which registered native methods the fork can call without pushing a frame (mrb_call_direct, vm.c), decided
# for every native by one property of its C body instead of a list of names.
#
# A native reads the frame it runs in only through a few services. The fork serves the argument readers from the
# call's own arguments and gives the native its frame on demand (mrb_direct_materialize) when it raises or pushes
# another frame, so those three stay correct. Everything else that reads the frame (the block, the method id, `super`,
# the proc's env, a raw `->ci`) does not, so a native that can reach one is framed:
#
#   ARGS   mrb_get_args and the argument readers          allowed, from the call
#   RAISE  anything that builds a backtrace                allowed, the frame is pushed first
#   CALLS  mrb_funcall and the other frame pushers         allowed, the frame is pushed first
#   BLOCK  the block, `&` in a mrb_get_args format, yield  framed
#   CI     any other read of the frame                     framed
#   OPEN   a call through a function pointer               framed
#
# The seeds are the named services below. Every other function of the C corpus gets its effects from its own body:
# a reference to the frame (`->ci`, `mrb_callinfo`, `mrb_ci_*`, `cipush`, ...) is CI, and a call adds the effects of
# the callee, so a new frame-reading API of the fork is framed until it is named here as one of the allowed kinds.
module NativeFrameUse
  ARGS = %w[mrb_get_args mrb_get_args_a mrb_get_argc mrb_get_argv mrb_get_arg1].freeze
  RAISE = %w[mrb_raise mrb_raisef mrb_exc_raise mrb_sys_fail mrb_bug mrb_name_error mrb_frozen_error mrb_argnum_error
             mrb_no_method_error mrb_notimplement mrb_exc_set mrb_keep_backtrace mrb_exc_new mrb_exc_new_str
             mrb_make_exception].freeze
  CALLS = %w[mrb_funcall mrb_funcall_id mrb_funcall_argv mrb_funcall_with_block mrb_funcall_send mrb_funcall_with_method
             mrb_funcall_send_with_method mrb_obj_new mrb_class_new_instance mrb_convert_type mrb_check_convert_type
             mrb_type_convert mrb_type_convert_check mrb_inspect mrb_obj_as_string mrb_any_to_s mrb_equal mrb_eql
             mrb_obj_equal mrb_cmp].freeze
  BLOCK = %w[mrb_block_given_p mrb_yield mrb_yield_argv mrb_yield_with_class mrb_yield_cont mrb_get_block].freeze
  ALLOWED = Set[:ARGS, :RAISE, :CALLS].freeze
  SEEDS = (ARGS.to_h { |n| [n, :ARGS] }.merge(RAISE.to_h { |n| [n, :RAISE] }, CALLS.to_h { |n| [n, :CALLS] },
                                               BLOCK.to_h { |n| [n, :BLOCK] })).freeze

  # A read of the executing frame, spelled in a body.
  FRAME_TOKEN = /(?:->|\.)\s*ci\b|\bcibase\b|\bmrb_callinfo\b|\bmrb_ci_\w+|\bmrb_vm_ci_\w+|\bCINFO_\w+|\bcipush\b|\bcipop\b|\bmrb_get_mid\b|
                 \bmrb_call_super\b|\bmrb_proc_cfunc_env\w*|\bmrb_protect_error\b|\bmrb_rescue\w*|\bmrb_ensure\b|\bmrb_throw\b/x
  # A call that no name resolves: `(*f)(...)`, `p->f(...)`, `s.f(...)`. A function-pointer variable declared in the body
  # (`ret (*f)(args) = ...;`) is read for the functions it can hold instead (see own).
  OPEN_CALL = /\(\s*\*\s*\w+\s*\)\s*\(|(?:->|\.)\s*\w+\s*\(/
  SIGNATURE_POINTER = /\(\s*\*\s*(\w+)\s*\)\s*\([^()]*\)/
  POINTER_DECL = /(?<!return)(?<!else)\b[A-Za-z_]\w*[ \t\*]+\(\s*\*\s*(\w+)\s*\)\s*\([^()]*\)(?=\s*[=;,])/
  NOT_CALLS = Set.new(%w[if while for switch return sizeof defined else do case]).freeze

  Def = Struct.new(:name, :path, :body, :signature, keyword_init: true)

  module_function

  # { name => [Def] } for every function defined at the left margin of the C sources (mruby's own style).
  def definitions(paths)
    defs = Hash.new { |h, k| h[k] = [] }
    paths.each do |path|
      next unless File.file?(path) && path.end_with?('.c')

      source = NativeExpressionDevirt.read_source(path)
      source.scan(/^(?:[A-Za-z_][\w \t\*]*[ \t\*])?([A-Za-z_]\w*)[ \t]*\([^;{}]*?\)[ \t]*\n?\{/m) do
        name = Regexp.last_match(1)
        next if NOT_CALLS.include?(name)

        open = Regexp.last_match.end(0) - 1
        body = NativeExpressionDevirt.brace_body(source, open)&.first
        defs[name] << Def.new(name: name, path: path, body: body, signature: Regexp.last_match(0)) if body
      end
    end
    defs
  end

  def strip_comments(text)
    text.gsub(%r{/\*.*?\*/|//[^\n]*}m, ' ')
  end

  # The collector walks every context's frames to mark them; that is not a read of the running frame.
  COLLECTOR = %r{/src/gc\.c\z}

  # The library's own sources: the fork's API calls its helpers through function pointers (variable iteration,
  # hooks) that are the library's own, so only the effects of its frame reads count there.
  LIBRARY = %r{/3rd/mruby/src/[^/]+\.c\z}

  # The effects of the body alone: [kinds, callee names].
  def own(body, path = nil, signature = '')
    text = strip_comments(body)
    kinds = Set.new
    library = path&.match?(LIBRARY)
    callees = Set.new
    # A pointer declared here holds only the functions assigned to it; one that is a parameter, or never assigned a
    # named function, holds anything.
    pointers = library ? [] : text.scan(POINTER_DECL).flatten
    stripped = library ? text : text.gsub(POINTER_DECL, ' ')
    pointers.each do |var|
      values = text.scan(/(?:\(\s*\*\s*#{var}\s*\)\s*\([^()]*\)|\b#{var})\s*=\s*([^;]+);/).flatten
      names = values.flat_map { |v| v.scan(/[A-Za-z_]\w*/) }
      callees.merge(names)
      kinds << :OPEN if names.empty?
    end
    strip_comments(signature).scan(SIGNATURE_POINTER).flatten.each { |var| kinds << :OPEN if stripped.match?(/\b#{var}\s*\(/) } unless library
    kinds << :OPEN if !library && stripped.match?(OPEN_CALL)
    kinds << :CI if text.match?(FRAME_TOKEN) && !path&.match?(COLLECTOR)
    # `&` in a mrb_get_args format reads the block; a format that is no literal cannot be read.
    text.scan(/\bmrb_get_args\s*\(\s*\w+\s*,\s*("(?:[^"\\]|\\.)*"|[^,)]+)/) do |(format)|
      if format.start_with?('"') then kinds << :BLOCK if format.include?('&')
      else kinds << :CI
      end
    end
    callees.merge(stripped.scan(/(?<![\w>.])([A-Za-z_]\w*)\s*\(/).flatten.reject { |n| NOT_CALLS.include?(n) })
    [kinds, callees]
  end

  # { name => Set of kinds } to a fixpoint. A function of the corpus with several definitions (a static helper of the
  # same name in two files) takes the union.
  def effects(defs)
    direct = {}
    calls = {}
    defs.each do |name, list|
      kinds = Set.new
      callees = Set.new
      list.each do |d|
        k, c = own(d.body, d.path, d.signature)
        kinds.merge(k)
        callees.merge(c)
      end
      direct[name] = kinds
      calls[name] = callees
    end
    SEEDS.each { |name, kind| direct[name] = Set[kind] }
    # The collector is a barrier: it marks every context's frames and runs the objects' free functions, it never reads
    # the frame of the native that happened to allocate.
    defs.each { |name, list| direct[name] = Set.new if list.all? { |d| d.path.match?(COLLECTOR) } }
    result = direct.transform_values(&:dup)
    loop do
      changed = false
      result.each do |name, kinds|
        next if SEEDS.key?(name) || defs.fetch(name, []).all? { |d| d.path.match?(COLLECTOR) } && defs.key?(name)

        calls.fetch(name, []).each do |callee|
          next unless result.key?(callee)

          before = kinds.size
          kinds.merge(result[callee])
          changed ||= kinds.size != before
        end
      end
      break unless changed
    end
    result
  end

  def frame_free?(kinds)
    kinds.subset?(ALLOWED)
  end

  # The plain defines of a gem's init, `mrb_define_method(mrb, klass, "name", fn, aspec)`, with the class named where it
  # is created (`klass = mrb_define_class(mrb, "Name", ...)`) or a core class field (`mrb->array_class`). The ROM scan
  # does not attribute them for a gem that is neither core nor the engine, so they are read here, from the same text.
  DEFINE = /\bmrb_define_(method|class_method|module_function|private_method|singleton_method)\s*\(\s*\w+\s*,\s*([\w>-]+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*(\w+)\s*,/
  CLASS_VAR = /\b(\w+)\s*=\s*mrb_define_(?:class|module)\s*\(\s*\w+\s*,\s*"([^"]+)"/

  def plain_defines(path)
    source = strip_comments(NativeExpressionDevirt.read_source(path))
    vars = source.scan(CLASS_VAR).to_h
    source.scan(DEFINE).filter_map do |kind, var, name, function|
      owner = vars[var] || (var.match(/\Amrb->(\w+)_class\z/) && Regexp.last_match(1).capitalize)
      next unless owner

      owner = "#{owner}.singleton" if kind == 'class_method' || kind == 'singleton_method'
      [owner, name, function]
    end
  end

  # [[owner class name, method name, function]] of the registrations in `paths` whose function takes no frame.
  # `corpus` is every C source the closed world links (the library's own included): the effects follow calls across
  # files. A function the corpus does not define is not frame-free.
  def rows(paths, corpus)
    table = effects(definitions(corpus))
    out = []
    by_name, = NativeExpressionDevirt.class_registrations(paths)
    by_name.each do |name, registrations|
      registrations.each do |r|
        owner = r[:owner] && r[:owner][:class_name]
        function = r[:function]
        next unless owner && function && table.key?(function) && frame_free?(table[function])

        out << [owner, name, function]
      end
    end
    paths.each do |path|
      next unless File.file?(path) && path.end_with?('.c')

      plain_defines(path).each { |row| out << row if table.key?(row[2]) && frame_free?(table[row[2]]) }
    end
    out.uniq.sort
  end

  # FRAME_FREE_SOURCE: the C++ that decides, at a call of a found method, whether it may be called without a frame.
  # `keys` are the "Owner#name" rows the closed-list proof computed (StaticDispatchLists#frame_free). Each VM resolves them
  # once to the functions they are registered as -- a row counts only while the owner's own table holds a plain C
  # function under the name -- and a call goes through mrb_call_direct when the function it found is one of them: a
  # subclass's override, a redefinition or a Ruby method under the same name is another function, so it is framed.
  # BC2CPP_FRAMEFREE=0 turns it off.
  def cpp_source(keys)
    rows = keys.to_a.sort.map { |key| key.split('#', 2) }
    if ENV['BC2CPP_FRAMEFREE'] == '0' || rows.empty?
      return <<~CPP
        extern "C" mrb_value mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value);
        static inline mrb_value bc2cpp_call_found(mrb_state* M, mrb_value recv, mrb_sym mid, const mrb_method_t* m, struct RClass* c,
                                                  mrb_int argc, const mrb_value* argv, mrb_value blk) {
          return mrb_funcall_with_method(M, recv, mid, m, c, argc, argv, blk);
        }
      CPP
    end

    capacity = 1 << (rows.size * 2).bit_length
    table = rows.map { |owner, name| "  { #{c_string(owner)}, #{c_string(name)} }," }.join("\n")
    <<~CPP
      // FRAME_FREE (native_frame_use.rb): #{rows.size} natives mrb_call_direct may call without their frame.
      #include <stdint.h>
      #include <string.h>
      extern "C" mrb_value mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value);
      struct bc2cpp_ff_row { const char* owner; const char* name; };
      static const bc2cpp_ff_row bc2cpp_ff_rows[] = {
      #{ROWS_BEGIN}
      #{table}
      #{ROWS_END}
      };
      static mrb_state* bc2cpp_ff_state = nullptr;
      static mrb_func_t bc2cpp_ff_set[#{capacity}];
      static inline unsigned bc2cpp_ff_slot(mrb_func_t f) { return (unsigned)(((uintptr_t)f >> 4) * 2654435761u) & #{capacity - 1}; }
      static void bc2cpp_ff_add(mrb_func_t f) {
        for (unsigned i = bc2cpp_ff_slot(f); ; i = (i + 1) & #{capacity - 1}) {
          if (bc2cpp_ff_set[i] == f) return;
          if (!bc2cpp_ff_set[i]) { bc2cpp_ff_set[i] = f; return; }
        }
      }
      // "A::B" or "A::B.singleton" to the class whose own table holds the name; null where there is none (no constant, or a
      // class object without a singleton class).
      static struct RClass* bc2cpp_ff_class(mrb_state* M, const char* path) {
        char buf[160];
        size_t n = strlen(path);
        bool singleton = n > 10 && strcmp(path + n - 10, ".singleton") == 0;
        if (singleton) n -= 10;
        if (n >= sizeof buf) return nullptr;
        memcpy(buf, path, n);
        buf[n] = 0;
        mrb_value scope = mrb_obj_value(M->object_class);
        for (char* part = buf; part; ) {
          char* sep = strstr(part, "::");
          if (sep) *sep = 0;
          mrb_sym id = mrb_intern_cstr(M, part);
          if (!mrb_const_defined_at(M, scope, id)) return nullptr;
          scope = mrb_const_get(M, scope, id);
          if (!mrb_class_p(scope) && !mrb_module_p(scope)) return nullptr;
          part = sep ? sep + 2 : nullptr;
        }
        struct RClass* c = mrb_class_ptr(scope);
        if (!singleton) return c;
        return c->c && c->c->tt == MRB_TT_SCLASS ? c->c : nullptr;
      }
      static inline struct RClass* bc2cpp_ff_origin(struct RClass* k) { MRB_CLASS_ORIGIN(k); return k; }
      static void bc2cpp_ff_build(mrb_state* M) {
        memset(bc2cpp_ff_set, 0, sizeof bc2cpp_ff_set);
        bc2cpp_ff_state = M;
        for (const bc2cpp_ff_row& r : bc2cpp_ff_rows) {
          struct RClass* start = bc2cpp_ff_class(M, r.owner);
          if (!start) continue;
          struct RClass* c = start;
          mrb_method_t m = bc2cpp_find_method(M, &c, mrb_intern_cstr(M, r.name));
          if (MRB_METHOD_UNDEF_P(m) || !MRB_METHOD_FUNC_P(m)) continue;
          if (c != start && !(c->tt == MRB_TT_ICLASS && c->c == start) && c != bc2cpp_ff_origin(start)) continue;
          bc2cpp_ff_add(MRB_METHOD_FUNC(m));
        }
      }
      static inline bool bc2cpp_frame_free_p(mrb_state* M, mrb_func_t f) {
        if (bc2cpp_ff_state != M) bc2cpp_ff_build(M);
        for (unsigned i = bc2cpp_ff_slot(f); bc2cpp_ff_set[i]; i = (i + 1) & #{capacity - 1}) {
          if (bc2cpp_ff_set[i] == f) return true;
        }
        return false;
      }
      // A found method's call: a native proven frame-free runs without a frame; the block, a Ruby method and every other
      // function keep mrb_funcall_with_method.
      static inline mrb_value bc2cpp_call_found(mrb_state* M, mrb_value recv, mrb_sym mid, const mrb_method_t* m, struct RClass* c,
                                                mrb_int argc, const mrb_value* argv, mrb_value blk) {
        if (mrb_nil_p(blk) && MRB_METHOD_FUNC_P(*m) && bc2cpp_frame_free_p(M, MRB_METHOD_FUNC(*m)))
          return mrb_call_direct(M, recv, mid, MRB_METHOD_FUNC(*m), c, argc, argv);
        return mrb_funcall_with_method(M, recv, mid, m, c, argc, argv, blk);
      }
    CPP
  end

  # The rows' names are looked up only to find the functions they are registered as: a name the method table leaves out
  # resolves to nothing and that native stays framed, so the generated-code name scan (static_dispatch_registrations.rb
  # c_literals) skips them.
  ROWS_BEGIN = '// FRAME_FREE_ROWS begin'
  ROWS_END = '// FRAME_FREE_ROWS end'
  ROWS_SPAN = /^[ \t]*#{Regexp.escape(ROWS_BEGIN)}\n.*?^[ \t]*#{Regexp.escape(ROWS_END)}$/m

  def strip_rows(gen)
    gen.include?(ROWS_BEGIN) ? gen.gsub(ROWS_SPAN, '') : gen
  end

  def c_string(text)
    "\"#{text.gsub(/["\\]/) { |c| "\\#{c}" }}\""
  end
end

