# frozen_string_literal: true

require_relative 'native_names'

# NativeCallbacks: which Ruby method names a native method's C body can call back into, computed per registered
# C function rather than over every native source. Phase 1 is report-only: the Fiber yield analysis still reads the
# global set (YieldReach's opaque_names), and this module only states what each name's closure reaches.
#
# A closure is the C function a registration names, plus every body it reaches. A call reaches a function or a
# function-like macro of that name; a bare reference (a function pointer passed on) reaches a function only, since a
# type name such as `mrb_int` is also a macro. A member call (`x->fn(...)`) is a call through a pointer the scan
# cannot resolve. The callbacks of a closure are the C string literals and MRB_SYM tokens of its bodies: a superset
# of the names they can call, since a string may be a format or a key. A closure with an unresolved call is
# incomplete, and an incomplete closure must not be trusted to exclude a name.
module NativeCallbacks
  KEYWORDS = %w[if while for switch return sizeof else do case defined].freeze
  # C library functions that cannot call back into Ruby.
  LIBC = %w[memcpy memmove memset memcmp memchr strlen strcmp strncmp strchr strrchr strstr strcpy strncpy strcat
            strncat strtol strtoll strtoul strtod malloc calloc realloc free snprintf sprintf printf fprintf vsnprintf
            fputs fwrite fflush putchar puts abs labs floor ceil fabs sqrt pow fmod exp log log10 sin cos isnan isinf
            isdigit isspace isalpha isalnum isupper islower tolower toupper assert abort exit qsort getenv
            va_start va_arg va_end malloc_trim _finite _isnan getsegmentdata _NSGetMachExecuteHeader
            fgetc feof fputc putc fstat gmtime localtime time clock_gettime close opendir readdir closedir
            waitpid strerror strftime offsetof timespec_get _copysign].freeze
  # Compiler intrinsics (`__builtin_*`, SSE `_mm_*`) and C++ keywords that look like calls (`throw (x)`).
  INTRINSIC = /\A(__|_mm_|throw\z|catch\z|try\z)/
  # The mruby entry points that call a method named at run time.
  DISPATCH = /\Amrb_(funcall|check_funcall|yield|send)\w*\z/

  Entry = Struct.new(:callbacks, :unresolved, :complete)
  # One C body: +code+ keeps string literals (their tokens are callbacks), +skel+ blanks them so that call and
  # reference detection sees only code. +macro+ is true for a function-like macro.
  Body = Struct.new(:name, :file, :code, :skel, :macro)

  module_function

  def read(path)
    File.binread(path).force_encoding(Encoding::UTF_8).scrub
  end

  # Comments blanked, string contents kept.
  def strip_comments(text)
    text.gsub(%r{/\*.*?\*/|//[^\n]*}m) { |c| c.gsub(/[^\n]/, ' ') }
  end

  def blank_strings(text)
    text.gsub(/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/) { |s| "#{s[0]}#{' ' * (s.size - 2)}#{s[-1]}" }
  end

  # Comments and preprocessor lines blanked (continuations included), string contents kept.
  def code_of(text)
    continued = false
    strip_comments(text).lines.map do |line|
      directive = continued || line.lstrip.start_with?('#')
      continued = directive && line.rstrip.end_with?('\\')
      directive ? line.gsub(/[^\n]/, ' ') : line
    end.join
  end

  # [name, body range] for every top-level C function definition of the blanked text +skel+.
  def functions(skel)
    found = []
    pos = 0
    # The parameter list allows one level of parentheses (a function-pointer parameter) and no more, so a match
    # cannot run from a preceding invocation such as `GEN(a, b)` through to the next definition's parameters.
    while (m = /^[^;{}#]*?\b(\w+)\s*\((?:[^;{}()]|\([^;{}()]*\))*\)\s*\{/m.match(skel, pos))
      open = m.end(0) - 1
      depth = 0
      close = open
      while close < skel.size
        depth += 1 if skel[close] == '{'
        depth -= 1 if skel[close] == '}'
        break if depth.zero?

        close += 1
      end
      found << [m[1], open...(close + 1)] unless KEYWORDS.include?(m[1])
      pos = close + 1
    end
    found
  end

  # Every function and function-like macro of +paths+ (C sources and headers), as Body structs.
  def index(paths)
    paths.flat_map do |path|
      raw = read(path)
      code = code_of(raw)
      skel = blank_strings(code)
      bodies = functions(skel).map do |name, range|
        Body.new(name, path, code[range], skel[range], false)
      end
      macros = strip_comments(raw).scan(/^[ \t]*#[ \t]*define[ \t]+(\w+)\([^)\n]*\)((?:[^\n]*\\\n)*[^\n]*)/)
      bodies + generated(path, raw, code) + macros.map do |name, body|
        body = body.gsub("\\\n", '  ')
        Body.new(name, path, body, blank_strings(body), true)
      end
    end
  end

  # The functions a file-local generator macro defines when invoked at top level, such as hash.c's DEFINE_ACCESSOR:
  # the invocation's arguments are substituted into the macro body and its `##` joins applied, and the result is
  # indexed as ordinary C. Nested generator invocations expand in turn. An invocation the scan cannot read (continued
  # lines, nested parentheses in its arguments, an argument count that differs) defines nothing, so the names it
  # would define stay unresolved and the closures reaching them incomplete.
  def generated(path, raw, code)
    generators = {}
    strip_comments(raw).scan(/^[ \t]*#[ \t]*define[ \t]+(\w+)\(([^)\n]*)\)((?:[^\n]*\\\n)*[^\n]*)/) do |name, params, body|
      generators[name] = [params.split(',').map(&:strip), body.gsub("\\\n", ' ')]
    end
    return [] if generators.empty?

    invocation = /^[ \t]*(\w+)\(([^\n()]*)\)[ \t]*$/
    generator_names = generators.keys.join('|')
    text = code.lines.select { |line| (m = invocation.match(line)) && generators.key?(m[1]) }.join
    expanded = +''
    4.times do
      break if text.empty?

      next_text = +''
      text.each_line do |line|
        m = invocation.match(line)
        params, body = m && generators[m[1]]
        args = m && m[2].split(',').map(&:strip)
        next unless params && args.size == params.size

        # Several functions in one expansion (DEFINE_SWITCHER) each start a line, which the function scan needs.
        piece = body.gsub(/\b\w+\b/) { |w| params.include?(w) ? args[params.index(w)] : w }.gsub(/\s*##\s*/, '').gsub(/\}\s*/, "}\n")
        next_text << piece.gsub(/\b(#{generator_names})\s*\(/) { "\n#{Regexp.last_match(1)}(" } << "\n"
      end
      # An invocation line is expanded next round, so it stays out of the text the function scan reads.
      invoking = next_text.lines.select { |line| (m = invocation.match(line)) && generators.key?(m[1]) }
      expanded << (next_text.lines - invoking).join
      text = invoking.join
    end

    skel = blank_strings(expanded)
    functions(skel).map { |name, range| Body.new(name, path, expanded[range], skel[range], false) }
  end

  # Native registrations of +paths+ as [[ruby name, C function name]], plus alias pairs [new name, old name].
  def registrations(paths)
    regs = []
    aliases = []
    paths.each do |path|
      code = code_of(read(path))
      code.scan(/\bmrb_define_(?:class_|module_|singleton_)?method(?:_id|_raw)?\s*\(\s*[^,]+,\s*[^,]+,\s*("(?:[^"\\]|\\.)*"|MRB_\w+\(\w+\))\s*,\s*(\w+)\s*,/m) do |name, fn|
        regs << [resolve_name(name), fn]
      end
      code.scan(/MRB_MT_ENTRY\s*\(\s*(\w+)\s*,\s*("(?:[^"\\]|\\.)*"|MRB_\w+\(\w+\))/m) do |fn, name|
        regs << [resolve_name(name), fn]
      end
      code.scan(/\bmrb_define_alias(?:_id)?\s*\(\s*[^,]+,\s*[^,]+,\s*("(?:[^"\\]|\\.)*"|MRB_\w+\(\w+\))\s*,\s*("(?:[^"\\]|\\.)*"|MRB_\w+\(\w+\))/m) do |new_name, old_name|
        aliases << [resolve_name(new_name), resolve_name(old_name)]
      end
    end
    [regs, aliases]
  end

  # The text between the parenthesis at +open+ and its match.
  def balanced_args(text, open)
    depth = 0
    close = open
    while close < text.size
      depth += 1 if text[close] == '('
      depth -= 1 if text[close] == ')'
      break if depth.zero?

      close += 1
    end
    text[(open + 1)...close]
  end

  def resolve_name(token)
    return token[1...-1].gsub('\\"', '"') if token.start_with?('"')

    token.match(MRB_SYM_TOKEN_RE) { |m| resolve_mrb_sym_token(m[1], m[2]) }
  end

  # Ruby name => Entry, over every native registration in +paths+ (sources and headers both index the C bodies).
  def analyze(paths)
    bodies = index(paths)
    functions = bodies.reject(&:macro).group_by(&:name)
    macros = bodies.select(&:macro).group_by(&:name)
    regs, aliases = registrations(paths)
    entries = {}
    memo = {}.compare_by_identity
    regs.each do |ruby_name, fn|
      closure = closure_of(functions.fetch(fn, []), functions, macros, fn, memo)
      entry = (entries[ruby_name] ||= Entry.new(Set.new, Set.new, true))
      entry.callbacks.merge(closure[:callbacks])
      entry.unresolved.merge(closure[:unresolved])
      entry.complete &&= closure[:complete]
    end
    # An alias runs the same C body as its target, so it carries the target's closure.
    loop do
      changed = false
      aliases.each do |new_name, old_name|
        old = entries[old_name] or next
        entry = (entries[new_name] ||= Entry.new(Set.new, Set.new, true))
        before = entry.callbacks.size
        entry.callbacks.merge(old.callbacks)
        entry.unresolved.merge(old.unresolved)
        entry.complete &&= old.complete
        changed ||= entry.callbacks.size != before
      end
      break unless changed
    end
    entries
  end

  # What one body adds to a closure, in scan order: its callbacks, its unresolved calls and the bodies it reaches. It
  # depends on the body alone, so it is computed once and shared by every registration that reaches the body.
  BodyFacts = Struct.new(:callbacks, :unresolved, :reached)

  def body_facts(body, functions, macros, memo)
    memo[body] ||= begin
      callbacks = []
      unresolved = []
      reached = []
      body.code.scan(/"(?:[^"\\\n]|\\.)*"/) { |s| callbacks << s[1...-1] }
      body.code.scan(MRB_SYM_TOKEN_RE) { |m, n| callbacks << resolve_mrb_sym_token(m, n) }
      # A dispatch call names its method at run time unless the argument list spells the name. Such a call can reach
      # any method, which the literal tokens cannot bound, so the closure is incomplete.
      body.code.to_enum(:scan, /\b(\w+)\s*\(/).map { Regexp.last_match }.each do |m|
        next unless DISPATCH.match?(m[1])

        args = balanced_args(body.code, m.end(0) - 1)
        # A yield runs a block, a dynamic callee with no name to spell, so it is always unbounded here.
        named = args.match?(/"|MRB_(SYM|OPSYM|SYM_[QBE])\(/)
        unresolved << "#{m[1]}(dynamic callee)" if m[1].include?('yield') || !named
      end
      body.skel.scan(/(->|\.)?\s*\b([A-Za-z_]\w*)\b(\s*\()?/) do |member, id, call|
        next if KEYWORDS.include?(id)

        if member
          unresolved << id if call
        elsif call
          targets = functions.fetch(id, []) + macros.fetch(id, [])
          if targets.empty?
            unresolved << id unless LIBC.include?(id) || id.match?(/\A[A-Z0-9_]+\z/) || id.match?(INTRINSIC)
          else
            reached.concat(targets)
          end
        else
          reached.concat(functions.fetch(id, []))
        end
      end
      BodyFacts.new(callbacks, unresolved, reached)
    end
  end

  # The callbacks and unresolved calls of the C function +start+ (its bodies, by name +fn+) and everything it reaches.
  # +memo+ is the body_facts cache for one analyze call.
  def closure_of(start, functions, macros, fn, memo)
    seen = Set.new
    queue = start.dup
    callbacks = Set.new
    unresolved = Set.new
    unresolved << fn if start.empty? && !LIBC.include?(fn)
    until queue.empty?
      body = queue.shift
      next unless seen.add?(body.object_id)

      facts = body_facts(body, functions, macros, memo)
      callbacks.merge(facts.callbacks)
      unresolved.merge(facts.unresolved)
      queue.concat(facts.reached)
    end
    { callbacks: callbacks, unresolved: unresolved, complete: unresolved.empty? }
  end
end
