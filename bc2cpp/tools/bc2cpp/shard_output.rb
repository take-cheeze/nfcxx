# frozen_string_literal: true

require 'set'
require 'stringio'

# BC2CPP_SHARDS (docs/bc2cpp-shards.md): the generated translation unit split into files that compile in parallel.
#
# bc2cpp.rb prints a unit marker before each compiled method's code and a hooks marker before the gem hooks. This
# rewrites that one text into
#   * the main file (stdout, `<symbol>_gen.cpp`): the prelude, the cross-shard declarations, then shard 0's methods
#     and the gem hooks inside `#ifndef BC2CPP_SHARD_PRELUDE_ONLY`;
#   * `<symbol>_gen_shard<k>.cpp`, k = 1...N-1: `#define BC2CPP_SHARD_PRELUDE_ONLY`, `#include` of the main file, then
#     shard k's methods. A shard with no methods is a comment only, so a build can always list N objects.
#
# SHARD_SINGLE_DEFINITION: every shard compiles the prelude, which moves into the per-gem namespace
# `bc2cpp_shard_<symbol>`, and its stateful `static` items (shared_prelude_items) become `inline`: an inline function
# or variable has one definition, and one copy of each function-local static, in the whole program, where `static`
# would give every shard its own. The namespace keeps two gems' same-named helpers apart. A methods-section `static`
# the prelude or another shard names loses `static` (its name is unique per owner and method); every other one stays
# file-local.
module ShardOutput
  UNIT_MARK = '/* BC2CPP_SHARD_UNIT '
  HOOKS_MARK = "/* BC2CPP_SHARD_HOOKS */\n"
  PRELUDE_ONLY = 'BC2CPP_SHARD_PRELUDE_ONLY'
  # Below this much method code per shard, compiling the prelude once more costs about what the split saves; a
  # gem under it stays one translation unit, its main file byte-identical to BC2CPP_SHARDS=1. A check's small
  # fixture lowers it with BC2CPP_SHARD_MIN_BYTES.
  MIN_SHARD_BYTES = 400_000
  IDENT = /[A-Za-z_$][\w$]*/.freeze

  class Error < StandardError; end

  module_function

  # How many files a run writes: BC2CPP_SHARDS, default 1 (no shard files).
  def count(env = ENV)
    raw = env.fetch('BC2CPP_SHARDS', '1')
    n = Integer(raw, exception: false)
    raise Error, "BC2CPP_SHARDS must be a positive integer, got #{raw.inspect}" unless n&.positive?

    n
  end

  def unit_mark(owner)
    "#{UNIT_MARK}#{owner} */\n"
  end

  def shard_path(out_dir, symbol, index)
    File.join(out_dir, "#{symbol}_gen_shard#{index}.cpp")
  end

  # Register before every other stdout rewriter: at_exit runs last-in first-out, so this splits their final text.
  def capture_stdout(symbol, out_dir, shards)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      next if $!

      main, files = split(buffer.string, symbol, shards)
      files.each_with_index { |text, i| File.write(shard_path(out_dir, symbol, i + 1), text) }
      original.write(main)
    end
  end

  # [main text, the texts of shards 1...shards-1].
  def split(text, symbol, shards)
    prelude, units, hooks = sections(text)
    groups = assign(units, shards)
    if groups.count { |g| !g.empty? } <= 1
      plain = prelude + units.map { |u| u[:code] }.join + hooks
      return [plain, Array.new(shards - 1) { |i| empty_shard(symbol, i + 1, shards) }]
    end

    rewrite(symbol, shards, prelude, groups, hooks)
  end

  def empty_shard(symbol, index, shards)
    "// #{symbol}_gen_shard#{index}.cpp: shard #{index} of #{shards}, no methods (docs/bc2cpp-shards.md).\n"
  end

  # The prelude text, the units ({owner:, code:}, in print order) and the hooks text.
  def sections(text)
    hooks_at = text.index(HOOKS_MARK)
    raise Error, 'the generated text has no shard hooks marker' unless hooks_at

    first = text.index(UNIT_MARK) || hooks_at
    units = text[first...hooks_at].split(/^(?=#{Regexp.escape(UNIT_MARK)})/).reject(&:empty?).map do |chunk|
      head, code = chunk.split("\n", 2)
      { owner: head.delete_prefix(UNIT_MARK).delete_suffix(' */'), code: code.to_s }
    end
    [text[0...first], units, text[(hooks_at + HOOKS_MARK.size)..]]
  end

  # An owner's methods stay together (they call each other most); owners go largest first onto the lightest shard.
  # `shards` lists of units, each in print order.
  def assign(units, shards)
    by_owner = units.each_with_index.group_by { |u, _| u[:owner] }
    size = ->(list) { list.sum { |u, _| u[:code].bytesize } }
    total = units.sum { |u| u[:code].bytesize }
    min_bytes = Integer(ENV.fetch('BC2CPP_SHARD_MIN_BYTES', MIN_SHARD_BYTES.to_s))
    wanted = [[shards, by_owner.size, (total / min_bytes.to_f).ceil].min, 1].max
    loads = Array.new(wanted, 0)
    placed = Array.new(wanted) { [] }
    by_owner.sort_by { |owner, list| [-size.call(list), owner] }.each do |_, list|
      i = loads.index(loads.min)
      loads[i] += size.call(list)
      placed[i].concat(list)
    end
    placed.map { |list| list.sort_by(&:last).map(&:first) } + Array.new(shards - wanted) { [] }
  end

  def rewrite(symbol, shards, prelude, groups, hooks)
    texts = groups.each_with_index.map { |g, i| g.map { |u| u[:code] }.join + (i.zero? ? hooks : '') }
    items = texts.map { |t| top_level_items(t.lines) }
    defined = {}
    items.each_with_index do |list, shard|
      list.each do |item|
        next unless item[:name] && item[:body]
        raise Error, "#{item[:name]} is defined in shards #{defined[item[:name]]} and #{shard}" if defined.key?(item[:name])

        defined[item[:name]] = shard
      end
    end
    prelude_ids = prelude.scan(IDENT).to_set
    shard_ids = texts.map { |t| t.scan(IDENT).to_set }
    shared = defined.select do |name, shard|
      prelude_ids.include?(name) || shard_ids.each_with_index.any? { |ids, i| i != shard && ids.include?(name) }
    end.keys.to_set
    prelude_out, declared = rewrite_prelude(symbol, prelude, defined.keys.to_set, texts.map { |t| code_text(t.lines) }.join)
    decls = String.new
    bodies = texts.zip(items).map do |text, list|
      lines = text.lines
      list.each do |item|
        next unless item[:body] && shared.include?(item[:name])

        lines[item[:first]] = item[:var] ? lines[item[:first]].sub(/\bstatic\b/, 'extern') : drop_static(lines[item[:first]])
        decls << "#{item[:var] ? 'extern ' : ''}#{drop_static(item[:head])};\n" unless declared.include?(item[:name])
      end
      lines.join
    end
    main = String.new(prelude_out)
    main << "// SHARD_DECLS: methods-section definitions another shard names (docs/bc2cpp-shards.md).\n" << decls
    main << "#ifndef #{PRELUDE_ONLY}\n" << bodies[0] << "#endif // #{PRELUDE_ONLY}\n"
    files = bodies.drop(1).each_with_index.map do |body, i|
      next empty_shard(symbol, i + 1, shards) if groups[i + 1].empty?

      "// #{symbol}_gen_shard#{i + 1}.cpp: shard #{i + 1} of #{shards} (docs/bc2cpp-shards.md).\n" \
        "#define #{PRELUDE_ONLY}\n#include \"#{symbol}_gen.cpp\"\n#{body}"
    end
    [main, files]
  end

  # The prelude in the per-gem namespace with its stateful `static` items `inline`, and the methods-section names it
  # declares. Global stay: every `#include`, each declaration of a methods-section function (defined at global scope)
  # and each external item, a non-static function or variable another gem links to (DIRECT_CONSTRUCT_ACCESSORS'
  # `<Owner>_compiled_class`). An external definition is the main file's alone; a shard sees its declaration.
  def rewrite_prelude(symbol, prelude, method_names, methods_code)
    ns = "bc2cpp_shard_#{symbol}"
    segs = segments(prelude.lines)
    shared = shared_prelude_items(segs, code_text(prelude.lines) + methods_code)
    out = String.new("namespace #{ns} {}\nusing namespace #{ns};\n")
    inside = false
    declared = Set.new
    toggle = lambda do |want|
      next if inside == want

      out << (want ? "namespace #{ns} {\n" : "} // namespace #{ns}\n")
      inside = want
    end
    segs.each do |seg|
      lines = seg[:lines]
      case seg[:kind]
      when :other
        out << lines.join
      when :include
        toggle.call(false)
        out << lines.join
      else
        if seg[:include]
          # An #include inside an #if region: the region's directives with only its includes go first, at global
          # scope, then the region without them.
          toggle.call(false)
          out << lines.grep(/\A\s*#/).join
          lines = lines.grep_v(/\A\s*#\s*include\b/)
        end
        items = top_level_items(lines)
        globals = items.select do |item|
          (!item[:body] && method_names.include?(item[:name])) || external?(lines[item[:first]], item)
        end
        if globals.empty?
          toggle.call(true)
          items.each do |item|
            line = lines[item[:first]]
            if shared.include?(item[:name])
              lines[item[:first]] = to_inline(line)
            elsif item[:function] && item[:body] && line[/\A[^(]*/].match?(/\bstatic\b/) &&
                  !line[/\A[^(]*/].match?(/\binline\b|maybe_unused/)
              # A shard need not call every helper the whole program does.
              lines[item[:first]] = "[[maybe_unused]] #{line}"
            end
          end
        else
          toggle.call(false)
          (items - globals).each do |item|
            next unless shared.include?(item[:name]) && lines[item[:first]].match?(/\bstatic\b/)

            raise Error, "prelude item #{item[:name]} shares an #if region with a method declaration; " \
                         'a shard would get its own copy of it'
          end
          globals.reverse_each do |item|
            if external?(lines[item[:first]], item)
              next unless item[:body]

              decl = "#{item[:var] ? 'extern ' : ''}#{item[:head]};\n"
              lines[item[:last]] += "#else\n#{decl}#endif\n"
              lines[item[:first]] = "#ifndef #{PRELUDE_ONLY}\n#{lines[item[:first]]}"
            else
              declared << item[:name]
              lines[item[:first]] = drop_static(lines[item[:first]])
            end
          end
        end
        out << lines.join
      end
    end
    toggle.call(false)
    [out, declared]
  end

  # SHARD_SINGLE_DEFINITION's prelude names: every file-scope variable, every function holding a mutable
  # function-local static or whose address is taken (a shard's own copy would compare unequal), and every static
  # function such an inline function calls (an inline function has one definition, so what it names must be one
  # entity too). Every other `static` function stays `static` and each shard compiles its own copy: an `inline` one
  # keeps an out-of-line body GCC cannot drop, which shifts its inlining (docs/bc2cpp-shards.md, "Measurements"). A
  # per-call-site cache that a macro such as BC2CPP_OWNERS declares belongs to that site, so a second copy of the
  # function is a second site, not a second state.
  def shared_prelude_items(segs, code)
    items = segs.flat_map do |seg|
      next [] unless seg[:kind] == :code

      lines = seg[:lines]
      code_lines = code_text(lines).lines
      top_level_items(lines).select { |item| item[:name] && item[:body] && lines[item[:first]].match?(/\bstatic\b/) }
                            .map { |item| item.merge(text: code_lines[item[:first]..item[:last]].join) }
    end
    by_name = items.group_by { |item| item[:name] }
    functions = by_name.select { |_, list| list.all? { |item| item[:function] } }.keys.to_set
    shared = by_name.keys.to_set - functions
    shared |= code.scan(/\b([A-Za-z_][\w$]*)\b(?!\s*\()/).flatten.to_set & functions
    items.each do |item|
      locals = item[:text].sub(/\A[^{]*\{/, '').scan(/\bstatic\b[^=;{(]*/)
      shared << item[:name] if locals.any? { |decl| !constant_static?(decl) }
    end
    loop do
      grown = items.select { |item| shared.include?(item[:name]) }
                   .flat_map { |item| item[:text].scan(/\b[A-Za-z_][\w$]*\b/) }.to_set & functions
      break if grown.subset?(shared)

      shared |= grown
    end
    shared
  end

  # The text with comments and literals blanked; a directive line keeps its text (a macro can name a function).
  def code_text(lines)
    scan_lines(lines).each_with_index.map do |info, i|
      info[:pp] ? lines[i].sub(%r{//.*}, '') : "#{info[:code]}\n"
    end.join
  end

  # `static const char* const path[]`, `static constexpr int n`: a local that never changes, so a copy is the same.
  def constant_static?(decl)
    return true if decl.match?(/\Astatic\s+constexpr\b/)
    return false unless decl.match?(/\Astatic\s+const\b/)

    stars = decl.split('*')
    stars.size == 1 || stars.last.match?(/\A\s*const\b/)
  end

  # The prelude cut into: `#include` lines, top-level `#if` regions and items (:code, with :include when the region
  # holds an include), and everything else (:other: blank lines, comments, other directives).
  def segments(lines)
    scan = scan_lines(lines)
    segs = []
    i = 0
    while i < lines.size
      s = scan[i]
      if s[:top] && s[:directive] == 'include'
        segs << { kind: :include, lines: [lines[i]] }
        i += 1
      elsif s[:top] && s[:directive]&.start_with?('if')
        j = i + 1
        j += 1 until scan[j][:top] && scan[j][:directive] == 'endif' && scan[j][:cond] == s[:cond]
        segs << { kind: :code, lines: lines[i..j], include: scan[i..j].any? { |t| t[:directive] == 'include' } }
        i = j + 1
      elsif s[:item_start]
        j = i
        j += 1 until scan[j][:item_end]
        segs << { kind: :code, lines: lines[i..j] }
        i = j + 1
      else
        segs << { kind: :other, lines: [lines[i]] }
        i += 1
      end
    end
    segs
  end

  # A function or variable with external linkage of its own: not static, inline, extern "C", a type or a template.
  def external?(line, item)
    return false unless item[:name] && (item[:function] || item[:var])

    !line[/\A[^(=]*/].match?(/\b(?:static|inline|extern|typedef|template|using|constexpr|struct|class|union|enum)\b/)
  end

  def to_inline(line)
    line.sub(/\bstatic\s+inline\b/, 'inline').sub(/\bstatic\b/, 'inline')
  end

  def drop_static(line)
    line.sub(/\bstatic\s+/, '')
  end

  # Top-level items: {name:, body:, var:, first:, head:}; `head` is the text before the body or initializer.
  def top_level_items(lines)
    scan = scan_lines(lines)
    scan.each_index.select { |k| scan[k][:item_start] }.map do |k|
      head = String.new
      cut = nil
      j = k
      loop do
        code = scan[j][:code]
        cut = head_cut(code)
        head << (cut ? code[0...cut] : code) << ' '
        break if cut || scan[j][:item_end] || j + 1 >= lines.size

        j += 1
      end
      head = head.gsub(/\s+/, ' ').strip
      cut_char = cut && scan[j][:code][cut]
      function = head.match?(/[\w$]\s*\(/)
      name = function ? head[/([A-Za-z_$][\w$]*)\s*\((?!.*[\w$]\s*\()/, 1] : head[/([A-Za-z_$][\w$]*)\s*(?:\[[^\]]*\])*\z/, 1]
      name = nil if head.match?(/\A(?:typedef|template|using|namespace|extern "C")\b/) ||
                    (!function && cut_char == '{' && head.match?(/\A(?:struct|class|union|enum)\b/))
      last = j
      last += 1 until scan[last][:item_end] || last + 1 >= lines.size
      { name: name, body: cut_char == '{' || cut_char == '=' || (!function && cut_char == ';' && !head.start_with?('extern')),
        var: !function && !head.match?(/\A(?:struct|class|union|enum)\b/), function: function, first: k, last: last,
        head: head }
    end
  end

  # The index where a head meets its body `{`, initializer `=` or end `;` (outside parentheses), or nil.
  def head_cut(code)
    depth = 0
    code.each_char.with_index do |c, i|
      case c
      when '(', '[' then depth += 1
      when ')', ']' then depth -= 1
      when '{', ';' then return i if depth.zero?
      when '=' then return i if depth.zero? && code[i + 1] != '=' && !'=!<>'.include?(code[i - 1].to_s)
      end
    end
    nil
  end

  # Per line: the brace depth it starts at, its code with comments and literals blanked (:code), whether it is a
  # directive (:directive, its name) at depth 0 outside any conditional (:top), the conditional nesting (:cond), and
  # whether it starts or ends a top-level item. Both arms of an #if/#else are read from the same starting depth.
  def scan_lines(lines)
    depth = 0
    conds = []
    in_comment = false
    raw_end = nil
    continued = false
    open_item = false
    lines.map do |line|
      info = { depth: depth, cond: conds.size }
      if continued || (!in_comment && !raw_end && line.match?(/\A\s*#/))
        directive = line[/\A\s*#\s*(\w+)/, 1] unless continued
        continued = line.rstrip.end_with?('\\')
        info[:directive] = directive
        info[:top] = depth.zero? && !open_item && (directive&.start_with?('if') ? conds.size.zero? : conds.size <= 1) &&
                     !%w[else elif].include?(directive) || (depth.zero? && conds.empty? && directive == 'include')
        case directive
        when 'if', 'ifdef', 'ifndef' then conds << { saved: depth, first: nil }
        when 'elif', 'else' then conds.last[:first] ||= depth; depth = conds.last[:saved]
        when 'endif'
          frame = conds.pop
          depth = frame[:first] if frame && frame[:first]
          info[:cond] = conds.size
          info[:top] = depth.zero? && !open_item && conds.empty?
        end
        info[:top] = false if directive.nil?
        info[:pp] = true
        info[:code] = ''
        next info
      end
      code = String.new
      i = 0
      in_str = nil
      while i < line.size
        c = line[i]
        if in_comment
          if line[i, 2] == '*/'
            in_comment = false
            i += 1
          end
          code << ' '
        elsif raw_end
          if line[i, raw_end.size] == raw_end
            i += raw_end.size - 1
            raw_end = nil
          end
          code << ' '
        elsif in_str
          i += 1 if c == '\\'
          in_str = nil if c == in_str
          code << ' '
        elsif line[i, 2] == '//'
          break
        elsif line[i, 2] == '/*'
          in_comment = true
          i += 1
          code << ' '
        elsif c == 'R' && line[i + 1] == '"' && (m = line[i..].match(/\AR"([^ ()\\\t\r\n]{0,16})\(/))
          raw_end = ")#{m[1]}\""
          i += m[0].size - 1
          code << ' '
        elsif c == '"' || (c == "'" && !line[i - 1].to_s.match?(/[0-9A-Fa-f]/))
          in_str = c
          code << ' '
        else
          depth += 1 if c == '{'
          depth -= 1 if c == '}'
          code << c
        end
        i += 1
      end
      info[:code] = code
      stripped = code.strip
      if info[:depth].zero? && !open_item && !stripped.empty?
        info[:item_start] = true
        open_item = true
      end
      if open_item && depth.zero? && stripped.end_with?(';', '}')
        info[:item_end] = true
        open_item = false
      end
      info
    end
  end
end
