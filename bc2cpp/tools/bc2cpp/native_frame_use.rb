# frozen_string_literal: true

require 'set'
require_relative 'native_expression_devirt'
require_relative 'owner_call_direct'

# FRAME_FREE: which registered native methods the fork can call without pushing a frame (mrb_call_direct, vm.c), decided
# for every native by one property of its C or C++ body instead of a list of names.
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
# The seeds are the named services below. Every other function of the corpus gets its effects from its own body:
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

  Def = Struct.new(:name, :path, :body, :signature, :owner, keyword_init: true)

  module_function

  # { name => [Def] } for every function defined at the left margin of the C sources (mruby's own style), and every
  # function, member function, constructor and destructor of the C++ sources and headers (cpp_definitions).
  def definitions(paths)
    defs = Hash.new { |h, k| h[k] = [] }
    paths.each do |path|
      next unless File.file?(path)
      next cpp_definitions(path, defs) if path.match?(CPP_SOURCE)
      next unless path.end_with?('.c')

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

  # CPP_SOURCE: the C++ sources and every header. Their functions are found by scope (namespaces, classes, templates,
  # qualified definitions) rather than by mruby's left-margin style, and their bodies are read by own_cpp.
  CPP_SOURCE = /\.(?:cc|cpp|cxx|h|hh|hpp|hxx|inc)\z/
  CPP_KEYWORDS = Set.new(%w[if while for switch return sizeof defined else do case catch throw new delete decltype alignof
                            alignas static_assert noexcept typeid static_cast dynamic_cast const_cast reinterpret_cast
                            __attribute__ __declspec template typename operator]).freeze

  # The source with comments, the contents of string and character literals and preprocessor lines (with their
  # continuations) turned into spaces, newlines kept: the same byte offsets, and no brace that is not code.
  def blank_code(source)
    out = source.b.dup
    i = 0
    n = out.bytesize
    line_start = true
    while i < n
      c = out.getbyte(i)
      if line_start && c == 0x23 # '#': a directive to the end of its last continued line
        j = i
        j += 1 while j < n && !(out.getbyte(j) == 0x0a && out.getbyte(j - 1) != 0x5c)
        (i...j).each { |k| out.setbyte(k, 0x20) unless out.getbyte(k) == 0x0a }
        i = j
        next
      end
      if c == 0x2f && out.getbyte(i + 1) == 0x2f
        j = out.index("\n", i) || n
        (i...j).each { |k| out.setbyte(k, 0x20) }
        i = j
        next
      elsif c == 0x2f && out.getbyte(i + 1) == 0x2a
        j = out.index('*/', i + 2)
        j = j ? j + 2 : n
        (i...j).each { |k| out.setbyte(k, 0x20) unless out.getbyte(k) == 0x0a }
        i = j
        next
      elsif c == 0x22 && i.positive? && out.getbyte(i - 1) == 0x52 && (m = out.byteslice(i, n - i).match(/\A"([^(\s]*)\(/n))
        close = out.index(")#{m[1]}\"", i)
        j = close ? close + m[1].bytesize + 2 : n
        (i + 1...j - 1).each { |k| out.setbyte(k, 0x20) unless out.getbyte(k) == 0x0a }
        i = j
        next
      elsif c == 0x22 || (c == 0x27 && !(i.positive? && out.byteslice(i - 1, 1).match?(/[0-9A-Fa-f]/n)))
        j = i + 1
        while j < n && out.getbyte(j) != c && out.getbyte(j) != 0x0a
          j += out.getbyte(j) == 0x5c ? 2 : 1
        end
        (i + 1...[j, n].min).each { |k| out.setbyte(k, 0x20) }
        i = j + 1
        line_start = false
        next
      end
      line_start = c == 0x0a || (line_start && (c == 0x20 || c == 0x09))
      i += 1
    end
    out
  end

  # { open brace offset => close brace offset } of blanked code.
  def brace_pairs(code)
    pairs = {}
    stack = []
    code.each_byte.with_index do |c, i|
      if c == 0x7b then stack << i
      elsif c == 0x7d && (open = stack.pop) then pairs[open] = i
      end
    end
    pairs
  end

  # The parenthesised groups at depth 0 of a head, as [open, close] offsets.
  def paren_groups(head)
    groups = []
    depth = 0
    start = nil
    head.each_byte.with_index do |c, i|
      if c == 0x28
        start = i if depth.zero?
        depth += 1
      elsif c == 0x29 && depth.positive?
        depth -= 1
        groups << [start, i] if depth.zero?
      end
    end
    groups
  end

  FUNCTION_TAIL = /\A\s*(?:(?:const|volatile|noexcept(?:\s*\([^()]*\))?|override|final|mutable|&&?|throw\s*\(\s*\))\s*)*
                   (?:->[^{};]*|:(?!:)[^{};]*)?\s*\z/x
  FUNCTION_NAME = /((?:[A-Za-z_]\w*\s*(?:<[^<>;{}()]*>)?\s*::\s*)*(?:~\s*[A-Za-z_]\w*|operator\b\s*(?:\(\s*\)|\[\s*\]|[^\w\s(]+|[A-Za-z_][\w\s]*?)|[A-Za-z_]\w*))
                   \s*(?:<[^<>;{}()]*>)?\s*\z/x

  # A C++ name as a key of the corpus: `operator==` and `~T` are no identifiers a body spells, so they become ones
  # the class's member list (cpp_definitions) can name.
  def cpp_key(name)
    name = name.gsub(/\s+/, '')
    return "dtor_#{name.delete_prefix('~')}" if name.start_with?('~')
    return "operator_#{name.delete_prefix('operator').unpack1('H*')}" if name.start_with?('operator') && name !~ /\Aoperator\w/

    name
  end

  # The head before a brace as [:function, class or nil, name] / [:class, name] / [:scope] / nil (an initializer, an
  # enum, a lambda at namespace scope: none defines a function by name).
  def classify_head(head)
    text = head.gsub(/\b__attribute__\s*\(\(.*?\)\)|\[\[.*?\]\]/m, ' ')
    text = text.sub(/\A.*\b(?:public|private|protected)\s*:(?!:)/m, '')
    return [:scope] if text.match?(/\bnamespace\b[\w\s:]*\z/) || text.match?(/\bextern\s*"\s*"\s*\z/)
    return nil if text.match?(/\benum\b/) && !text.include?('(')
    if (m = text.match(/\b(?:class|struct|union)\s+(?:alignas\s*\([^()]*\)\s*)?([A-Za-z_]\w*)(?:\s+final)?\s*(?::(?!:)[^(){};]*)?\z/))
      return [:class, m[1]]
    end
    return [:class, nil] if text.match?(/\b(?:struct|union|class)\s*\z/)

    paren_groups(text).each do |open, close|
      next unless text[close + 1..].match?(FUNCTION_TAIL)
      next unless (m = text[0...open].match(FUNCTION_NAME))
      next if text[0...open].match?(/(?:=|\]|\breturn)\s*\z/)

      parts = m[1].gsub(/<[^<>]*>/, '').split('::').map(&:strip)
      name = parts.last
      next if CPP_KEYWORDS.include?(name)

      return [:function, parts.size > 1 ? parts[-2] : nil, name]
    end
    nil
  end

  # C++ definitions into `defs`. A class's members are also listed under the class's name as a body that calls them
  # all, so a body that names the class (a local of that type, a construction, a cast) takes the effects of its
  # constructors, destructor, operators and methods: the calls C++ makes without spelling them.
  def cpp_definitions(path, defs)
    source = NativeExpressionDevirt.read_source(path).b
    code = blank_code(source)
    pairs = brace_pairs(code)
    members = Hash.new { |h, k| h[k] = Set.new }
    walk = lambda do |from, to, klass|
      head_start = from
      i = from
      while i < to
        c = code.getbyte(i)
        if c == 0x3b || c == 0x7d
          head_start = i + 1
        elsif c == 0x7b
          close = pairs[i] || to
          head = code.byteslice(head_start, i - head_start)
          kind = classify_head(head)
          case kind&.first
          when :scope then walk.call(i + 1, close, klass)
          when :class then walk.call(i + 1, close, kind[1] || klass)
          when :function
            owner = kind[1] || klass
            key = cpp_key(kind[2])
            body = source.byteslice(i, close - i + 1).force_encoding(Encoding::UTF_8)
            signature = source.byteslice(head_start, i - head_start).force_encoding(Encoding::UTF_8)
            defs[key] << Def.new(name: key, path: path, body: body, signature: signature, owner: owner)
            members[owner] << key if owner
            if owner.nil? && key.start_with?('operator_')
              signature.scan(/\b([A-Z]\w*)\b/).flatten.each { |type| members[type] << key }
            end
          end
          i = close
          head_start = close + 1
        end
        i += 1
      end
    end
    walk.call(0, code.bytesize, nil)
    members.each do |klass, names|
      body = "{ #{names.to_a.sort.map { |n| "#{n}();" }.join(' ')} }"
      defs[klass] << Def.new(name: klass, path: path, body: body, signature: '')
    end
  end

  # The code of a source outside its function bodies, as [namespace scope, { class name => its own scope }]: where
  # the globals and each class's members are declared.
  def scope_code(path)
    code = blank_code(NativeExpressionDevirt.read_source(path))
    pairs = brace_pairs(code)
    members = Hash.new { |h, k| h[k] = +'' }
    blank = ->(from, to) { (from...to).each { |k| code.setbyte(k, 0x20) unless code.getbyte(k) == 0x0a } }
    walk = lambda do |from, to|
      head_start = from
      i = from
      while i < to
        c = code.getbyte(i)
        if c == 0x3b || c == 0x7d
          head_start = i + 1
        elsif c == 0x7b
          close = pairs[i] || to
          kind = classify_head(code.byteslice(head_start, i - head_start))
          case kind&.first
          when :function then blank.call(i + 1, close)
          when :class
            walk.call(i + 1, close)
            members[kind[1]] << code.byteslice(i + 1, close - i - 1) << "\n"
            blank.call(i + 1, close)
          when :scope then walk.call(i + 1, close)
          end
          i = close
          head_start = close + 1
        end
        i += 1
      end
    end
    walk.call(0, code.bytesize)
    [code.force_encoding(Encoding::UTF_8), members.transform_values { |m| m.force_encoding(Encoding::UTF_8) }]
  end

  # The function-pointer types of the corpus: `typedef R (*T)(...)` and `using T = R (*)(...)`.
  def pointer_types(paths)
    types = Set.new
    paths.each do |p|
      next unless File.file?(p) && (p.end_with?('.c') || p.match?(CPP_SOURCE))

      t = strip_comments(NativeExpressionDevirt.read_source(p))
      t.scan(/\btypedef\b[^;{}]*?\(\s*\*\s*(\w+)\s*\)\s*\(/) { |(n)| types << n }
      t.scan(/\busing\s+(\w+)\s*=[^;{}]*\(\s*\*\s*\)\s*\(/) { |(n)| types << n }
    end
    types
  end

  # The names `code` declares as something called through a pointer: a function pointer (spelled, or of a pointer
  # type), a std::function.
  def callable_decls(code, types, scope: false)
    names = Set.new
    # `(*name)(...)`; at scope also `(*name)` alone, once callable_names took the parameter lists out (in a body that
    # is a dereference).
    code.scan(scope ? /\(\s*\*\s*(\w+)\s*\)\s*[(;,=\[]/ : /\(\s*\*\s*(\w+)\s*\)\s*\(/) { |(n)| names << n }
    code.scan(/\bstd::function\s*<[^;{}]*?>\s*(?:const\s*)?&{0,2}\s*([A-Za-z_]\w*)/) { |(n)| names << n }
    unless types.empty?
      code.scan(/\b(?:#{types.map { |t| Regexp.escape(t) }.join('|')})\b\s*(?:const\s*)?[&*]?\s*([A-Za-z_]\w*)\s*[;,=)\[]/) { |(n)| names << n }
    end
    names - types
  end

  # CALLABLE: what the corpus declares callable (callable_decls) at namespace scope (globals, named bare) and in a
  # class or struct (members, called after `->` or `.`, or named bare in a member function of that class), and the
  # pointer types for the locals and parameters a body declares. A body that names one is OPEN.
  Callables = Struct.new(:globals, :members, :by_class, :types)
  NO_CALLABLES = Callables.new(globals: Set.new.freeze, members: Set.new.freeze, by_class: {}.freeze, types: Set.new.freeze).freeze

  def callable_names(paths)
    types = pointer_types(paths)
    globals = Set.new
    members = Set.new
    by_class = Hash.new { |h, k| h[k] = Set.new }
    # A prototype's parameters declare nothing: every group but a declarator's `(*name)` goes.
    params = /\((?!\s*\*)(?:[^()]|\g<0>)*\)/
    paths.each do |p|
      next unless File.file?(p) && (p.end_with?('.c') || p.match?(CPP_SOURCE))

      ns, cls = scope_code(p)
      globals.merge(callable_decls(ns.gsub(params, ' '), types, scope: true))
      cls.each do |klass, text|
        names = callable_decls(text.gsub(params, ' '), types, scope: true)
        members.merge(names)
        by_class[klass].merge(names) if klass
      end
    end
    Callables.new(globals: globals.freeze, members: members.freeze, by_class: by_class.to_h.freeze, types: types.freeze)
  end

  # The effects of a C++ body: [kinds, callees]. Every identifier is a callee -- a call, a function named as a value
  # (a callback, a template argument), a type whose members run implicitly -- so a lambda or functor is read where its
  # body is written, and a call of a template's callable parameter adds nothing of its own. A member call of a name
  # the corpus does not define is the standard library's. A name the corpus declares callable (callable_names) is
  # OPEN, a `catch` or `throw` is CI (it unwinds or stops a raise outside the frame the raise path gives it).
  def own_cpp(body, callables, signature = '', owner: nil)
    text = strip_comments(body)
    code = blank_code(body).force_encoding(Encoding::UTF_8)
    kinds = Set.new
    kinds << :CI if code.match?(FRAME_TOKEN) || code.match?(/\b(?:catch|throw)\b/)
    kinds << :OPEN if code.match?(/\(\s*\*\s*\w+\s*\)\s*\(/)
    text.scan(/\bmrb_get_args\s*\(\s*\w+\s*,\s*("(?:[^"\\]|\\.)*"|[^,)]+)/) do |(format)|
      if format.start_with?('"') then kinds << :BLOCK if format.include?('&')
      else kinds << :CI
      end
    end
    idents = code.scan(/\b[A-Za-z_]\w*\b/).to_set
    local = callable_decls("#{blank_code(signature).force_encoding(Encoding::UTF_8)} #{code}", callables.types)
    # Storing into a callable (`g_hook = fn`) calls nothing; every other use of a global or local one may. A member is
    # called through its object (`p->f(...)`): the same member name is often a plain field of another struct, and a
    # member passed on is called where it arrives, through a parameter or variable of a pointer type.
    read = code.gsub(/(?:->|\.)?\s*\b[A-Za-z_]\w*\s*=(?!=)/, ' ')
    accessed = read.scan(/(?:->|\.)\s*([A-Za-z_]\w*)\s*\(/).flatten.to_set
    idents_read = read.scan(/\b[A-Za-z_]\w*\b/).to_set
    kinds << :OPEN if idents_read.intersect?(callables.globals) || idents_read.intersect?(local) ||
                      accessed.intersect?(callables.members) || (owner && idents_read.intersect?(callables.by_class.fetch(owner, Set.new)))
    [kinds, idents.reject { |n| CPP_KEYWORDS.include?(n) }.to_set]
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
  def effects(defs, callables = NO_CALLABLES)
    direct = {}
    calls = {}
    defs.each do |name, list|
      kinds = Set.new
      callees = Set.new
      list.each do |d|
        k, c = d.path.match?(CPP_SOURCE) ? own_cpp(d.body, callables, d.signature, owner: d.owner) : own(d.body, d.path, d.signature)
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
  # `corpus` is every native source the closed world links (the library's own included): the effects follow calls
  # across files. A function the corpus does not define is not frame-free. `owner_map` (NativeOwnerMap) adds the ROM
  # tables and the C++ registrations that name their function; a lambda registered in place names none, so it is framed.
  def rows(paths, corpus, owner_map: nil)
    table = effects(definitions(corpus), callable_names(corpus))
    out = []
    if owner_map
      (owner_map.rom + owner_map.registrations).each do |owner, name, function|
        out << [owner, name, function] if owner && function && table.key?(function) && frame_free?(table[function])
      end
    end
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
      next unless File.file?(path) && (path.end_with?('.c') || path.match?(CPP_SOURCE))

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
        static inline void bc2cpp_frame_free_install(mrb_state*) {}
        static inline bool bc2cpp_frame_free_wrappers(const mrb_func_t*, size_t) { return false; }
      CPP
    end

    capacity = 1 << ((rows.size + wrapper_names(keys).size + READER_HEADROOM) * 2).bit_length
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
      // FRAME_FREE_WRAPPERS: an owner call's direct-row wrappers (frame_free_wrappers_source), handed over by the unit.
      static const mrb_func_t* bc2cpp_ff_wrapper_fns = nullptr;
      static size_t bc2cpp_ff_wrapper_count = 0;
      static inline bool bc2cpp_frame_free_wrappers(const mrb_func_t* fns, size_t n) {
        bc2cpp_ff_wrapper_fns = fns;
        bc2cpp_ff_wrapper_count = n;
        bc2cpp_ff_state = nullptr;
        return true;
      }
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
          mrb_method_t m = bc2cpp_find_proven(M, &c, mrb_intern_cstr(M, r.name));
          if (MRB_METHOD_UNDEF_P(m) || !MRB_METHOD_FUNC_P(m)) continue;
          if (c != start && !(c->tt == MRB_TT_ICLASS && c->c == start) && c != bc2cpp_ff_origin(start)) continue;
          bc2cpp_ff_add(MRB_METHOD_FUNC(m));
        }
        for (size_t i = 0; i < bc2cpp_ff_wrapper_count; ++i) bc2cpp_ff_add(bc2cpp_ff_wrapper_fns[i]);
      }
      static inline bool bc2cpp_frame_free_p(mrb_state* M, mrb_func_t f) {
        if (bc2cpp_ff_state != M) bc2cpp_ff_build(M);
        for (unsigned i = bc2cpp_ff_slot(f); bc2cpp_ff_set[i]; i = (i + 1) & #{capacity - 1}) {
          if (bc2cpp_ff_set[i] == f) return true;
        }
        return false;
      }
      // Every compiled gem installs its own hook; each keeps the one installed before it, so a function any unit
      // handed over (its FRAME_FREE_READERS) is frame-free whichever gem installed last.
      static decltype(mrb_state::frame_free_p) bc2cpp_ff_prev = nullptr;
      static mrb_bool bc2cpp_frame_free_hook(mrb_state* M, mrb_func_t f) {
        return bc2cpp_frame_free_p(M, f) || (bc2cpp_ff_prev && bc2cpp_ff_prev(M, f));
      }
      // mrb_funcall_with_method makes the frame-free decision for every caller of a found method, C included
      // (mrb_obj_init's initialize): a native proven frame-free runs through mrb_call_direct, the rest keep their frame.
      // Installed at the end of each compiled gem's init, so the rows resolve against the classes defined so far.
      static inline void bc2cpp_frame_free_install(mrb_state* M) {
        bc2cpp_ff_state = nullptr;
        if (M->frame_free_p != bc2cpp_frame_free_hook) bc2cpp_ff_prev = M->frame_free_p;
        M->frame_free_p = bc2cpp_frame_free_hook;
      }
      static inline mrb_value bc2cpp_call_found(mrb_state* M, mrb_value recv, mrb_sym mid, const mrb_method_t* m, struct RClass* c,
                                                mrb_int argc, const mrb_value* argv, mrb_value blk) {
        return mrb_funcall_with_method(M, recv, mid, m, c, argc, argv, blk);
      }
    CPP
  end

  # FRAME_FREE_WRAPPERS: an owner call's direct row (OwnerCallDirect.native_entries) runs the entry's body through an
  # exported wrapper that only calls it, so the wrapper is frame-free when its row is; the table lookup never finds it.
  def wrapper_names(keys)
    OwnerCallDirect.native_entries.filter_map { |(owner, name), e| e[:entry] if keys.include?("#{owner}##{name}") }.uniq.sort
  end

  # FRAME_FREE_READERS: a synthesized attr_reader's entry (CodeGen#emit_ivar_accessor_pair) only returns its embedded
  # field, with no argument, frame or raise, so a C caller that found it (lib.cxx's attr_read over RGSS::Font) calls it
  # without a frame too. Each unit hands over its own; READER_HEADROOM keeps the shared table's capacity above them.
  READER_HEADROOM = 1024

  def reader_entries(compiled)
    compiled.filter_map { |m| m[:entry] if m[:label].to_s.start_with?('synth:') && m[:arity].to_i.zero? }.uniq.sort
  end

  # The unit's hand-over of those wrappers, printed after OwnerCallDirect.native_prototypes: there, at global scope,
  # each name has its one declaration (the runtime text may sit in a namespace of its own, where a declaration
  # would name another function).
  def wrappers_source(keys, readers = [])
    names = ENV['BC2CPP_FRAMEFREE'] == '0' ? [] : wrapper_names(keys) + readers.first(READER_HEADROOM)
    return '' if names.empty?

    <<~CPP
      static const mrb_func_t bc2cpp_ff_wrapper_list[] = { #{names.join(', ')} };
      [[maybe_unused]] static const bool bc2cpp_ff_wrappers_handed =
          bc2cpp_frame_free_wrappers(bc2cpp_ff_wrapper_list, sizeof bc2cpp_ff_wrapper_list / sizeof bc2cpp_ff_wrapper_list[0]);
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

