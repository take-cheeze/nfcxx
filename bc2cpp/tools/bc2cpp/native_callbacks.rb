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
            va_start va_arg va_end malloc_trim _finite _isnan getsegmentdata _NSGetMachExecuteHeader].freeze
  # Compiler intrinsics (`__builtin_*`) and C++ keywords that look like calls (`throw (x)`) in the C++ sources.
  INTRINSIC = /\A(__|throw\z|catch\z|try\z)/

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
    while (m = /^[^;{}#]*?\b(\w+)\s*\([^;{}]*\)\s*\{/m.match(skel, pos))
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
      bodies + macros.map do |name, body|
        body = body.gsub("\\\n", '  ')
        Body.new(name, path, body, blank_strings(body), true)
      end
    end
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
    regs.each do |ruby_name, fn|
      closure = closure_of(functions.fetch(fn, []), functions, macros, fn)
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

  # The callbacks and unresolved calls of the C function +start+ (its bodies, by name +fn+) and everything it reaches.
  def closure_of(start, functions, macros, fn)
    seen = Set.new
    queue = start.dup
    callbacks = Set.new
    unresolved = Set.new
    unresolved << fn if start.empty? && !LIBC.include?(fn)
    until queue.empty?
      body = queue.shift
      next unless seen.add?(body.object_id)

      body.code.scan(/"(?:[^"\\\n]|\\.)*"/) { |s| callbacks << s[1...-1] }
      body.code.scan(MRB_SYM_TOKEN_RE) { |m, n| callbacks << resolve_mrb_sym_token(m, n) }
      body.skel.scan(/(->|\.)?\s*\b([A-Za-z_]\w*)\b(\s*\()?/) do |member, id, call|
        next if KEYWORDS.include?(id)

        if member
          unresolved << id if call
        elsif call
          targets = functions.fetch(id, []) + macros.fetch(id, [])
          if targets.empty?
            unresolved << id unless LIBC.include?(id) || id.match?(/\A[A-Z0-9_]+\z/) || id.match?(INTRINSIC)
          else
            queue.concat(targets)
          end
        else
          queue.concat(functions.fetch(id, []))
        end
      end
    end
    { callbacks: callbacks, unresolved: unresolved, complete: unresolved.empty? }
  end
end
