# frozen_string_literal: true

require 'digest'
require 'set'
require 'stringio'
require_relative 'shard_output'
require_relative 'runtime_header'
require_relative 'implicit_state'

# CROSS_GEM_SHARE: the prelude after the runtime region (owner- and use-dependent helpers) is printed by every gem,
# and its items sit in the gem's own namespace, so a link keeps one copy per gem of helpers whose text is the same.
# This moves each group of such items to a header named by the digest of its own text, in the namespace
# `bc2cpp_cs_<digest>`, included where the group stood and brought back into the gem's scope by using-declarations:
# gems that print the same group share one definition of each of its `inline` items.
#
# SOUND_SHARE: a group is the items of the segments that declare a name (a declaration and its definition stay
# together). It moves only when the meaning of its text is the same in every unit that prints it:
#   * no item keeps a state of its own: a mutable variable, a mutable function-local static (through a macro too);
#   * no function of it is named other than as a call (an address compared or installed is one per unit today);
#   * nothing it names is declared in the unit outside the moved groups: the runtime region's own items, a
#     declaration whose definition is not in the prelude tail (a compiled method), a template, an enum, an operator,
#     an external or extern "C" item, the entry header's names. The compiler cannot catch a miss: ShardOutput's
#     `using namespace bc2cpp_shard_<gem>` puts the gem's names in reach of every header. So every name a local head
#     might declare, however it is read (possible_names), counts, and a head read two ways that disagree stays;
#   * its digest covers its header text (after IMPLICIT_STATE), the namespaces of the groups it names, and every
#     `#define` of a macro it names, so a different text or a different meaning gets a different namespace.
# Compile flags are taken to be the same for every gem of a link, as RUNTIME_HEADER takes them.
# BC2CPP_CROSS_GEM_SHARE=0 turns it off.
module CrossGemShare
  ENV_KEY = 'BC2CPP_CROSS_GEM_SHARE'
  PART_MACRO = 'BC2CPP_CROSS_GEM_PART'
  NS_PLACEHOLDER = '@BC2CPP_CS_NS@'
  # Bumped when the header layout changes.
  FORMAT = 1
  FORBIDDEN = /\b(?:__FILE__|__LINE__|__COUNTER__|namespace|asm|__asm__|BC2CPP_SHARD_PRELUDE_ONLY)\b/.freeze
  # Generated names spell `$` (`Array_$5b$5d`), as ShardOutput::IDENT reads them.
  IDENT = /(?<![\w$])[A-Za-z_$][\w$]*(?![\w$])/.freeze
  KEYWORDS = %w[int bool char void long short unsigned signed float double auto const static inline struct class union
                enum decltype sizeof return operator __attribute__ alignas noexcept throw].to_set.freeze

  module_function

  def enabled?(env = ENV)
    env[ENV_KEY] != '0'
  end

  # Registered between ShardOutput and RuntimeHeader: at_exit runs last-in first-out, so this reads the text
  # RuntimeHeader leaves (its tail mark where the region ended) and ShardOutput splits what this leaves.
  def capture_stdout(dir, entry_path)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      next if $!

      keep = entry_path && File.file?(entry_path) ? File.read(entry_path).scan(IDENT).to_set : Set.new
      original.write(rewrite(buffer.string, dir, keep: keep))
    end
  end

  # The text with the tail mark gone and, with a directory, the shareable groups of the prelude tail moved to headers.
  def rewrite(text, dir, keep: Set.new)
    at = text.index(RuntimeHeader::TAIL_MARK)
    return text unless at

    head = text[0...at]
    rest = text[(at + RuntimeHeader::TAIL_MARK.size)..]
    stop = [rest.index(ShardOutput::UNIT_MARK), rest.index(ShardOutput::HOOKS_MARK)].compact.min
    return head + rest if dir.nil? || dir.empty? || stop.nil?

    head + share(head, rest[0...stop], rest, dir, keep) + rest[stop..]
  end

  # The tail with each shareable group replaced by its header parts.
  def share(head, tail, rest, dir, keep)
    lines = tail.lines
    segs = ShardOutput.segments(lines)
    macros = macro_defs(head + tail)
    stateful_macros = stateful(macros)
    rt_ns = head[/^using namespace (bc2cpp_rt_\h+);$/, 1]
    outside = declared_in(head.lines)
    entries = segs.each_with_index.filter_map do |seg, i|
      next unless seg[:kind] == :code

      facts(seg, i, macros, stateful_macros)
    end
    return tail if entries.empty?

    defined = Set.new
    entries.each { |e| defined.merge(e[:defines]) }
    roots = outside | (keep & defined)
    entries.each { |e| roots.merge(e[:declares] - defined - e[:c_prototypes]) }
    roots.merge(address_taken(entries, rest + head))
    groups = group(entries)
    local = local_groups(groups, roots)
    shared = groups.each_index.reject { |g| local.include?(g) }.map { |g| groups[g] }
    return tail if shared.empty?

    write_headers(shared, entries, segs, macros, rt_ns, dir)
  end

  # One entry per code segment: what it declares and defines, the identifiers its code names (macros expanded), and
  # whether it can move at all.
  def facts(seg, index, macros, stateful_macros)
    lines = seg[:lines]
    code = ShardOutput.code_text(lines)
    items = ShardOutput.top_level_items(lines)
    declares = Set.new
    defines = Set.new
    movable = !seg[:include] && !code.match?(FORBIDDEN)
    maybe = Set.new
    c_prototypes = Set.new
    items.each do |item|
      names, ok = declared_names(item, ShardOutput.code_text(lines[item[:first]..item[:last]]))
      declares.merge(names)
      c_prototypes << item[:name] if c_prototype?(item, lines)
      maybe.merge(possible_names(item))
      movable &&= ok && !state?(item, lines, code) && (!external?(item, lines) || c_prototype?(item, lines)) &&
                  !item[:head].match?(/\boperator\b/)
      defines.merge(names) if item[:body]
    end
    maybe.merge(declares)
    ids = expand(code.scan(IDENT).to_set, macros)
    # A head read two ways must agree: a name it might declare is never left to the global using-directive.
    movable &&= (ids & stateful_macros).empty? && (maybe - declares).empty?
    { index: index, items: items, declares: declares, maybe: maybe, defines: defines, ids: ids - declares, movable: movable,
      c_prototypes: c_prototypes }
  end

  # [names an item declares, whether it can move].
  def declared_names(item, code)
    head = item[:head]
    pointer = head[/\(\s*\*\s*(?:const\s+)?([A-Za-z_$][\w$]*)\s*\)\s*\(/, 1]
    if item[:name] && !head.match?(/\A(?:template|extern\s+"C"|typedef)\b/)
      # A function-pointer variable reads as a function named by its return type.
      return [[pointer], true] if pointer && head.index('(') == head.index(/\(\s*\*/)
      return [[item[:name]], true] unless item[:function]

      # top_level_items names a function by the last call in its head, which a default argument (`= mrb_nil_value()`)
      # fools: the declarator is the name before a parenthesis at the head's own depth.
      names = head_functions(head)
      return [names, names.size == 1]
    end

    case head
    when /\Atemplate\b/
      rest = head.sub(/\Atemplate\s*<[^>]*>\s*/, '')
      name = rest[/\A(?:struct|class|union)\s+([A-Za-z_$][\w$]*)/, 1] || rest[/\A[^(]*?([A-Za-z_$][\w$]*)\s*\(/, 1]
      [[name].compact, false]
    when /\Aextern\s+"C"/
      [[item[:name] || head[/([A-Za-z_$][\w$]*)\s*\(/, 1]].compact, false]
    when /\Atypedef\b/
      name = head[/\(\s*\*\s*([A-Za-z_$][\w$]*)\s*\)/, 1] || head[/([A-Za-z_$][\w$]*)\s*(?:\[[^\]]*\])*\s*\z/, 1]
      [[name].compact, !name.nil?]
    when /\Aenum\b/
      body = code[/\{(.*)\}/m, 1].to_s
      [[head[/\Aenum\s+(?:class\s+)?([A-Za-z_$][\w$]*)/, 1], *body.split(',').map { |e| e[/\A\s*([A-Za-z_$][\w$]*)/, 1] }].compact, false]
    when /\A(?:struct|class|union)\s+([A-Za-z_$][\w$]*)/
      [[Regexp.last_match(1)], true]
    when /\Ausing\s+([A-Za-z_$][\w$]*)\s*=/
      [[Regexp.last_match(1)], true]
    else
      [[], false]
    end
  end

  # Every name an item's head might declare, however it is read: what top_level_items names, and each name before a
  # parenthesis at the head's depth. A superset of what it declares, so a gem's own name always counts as local.
  # An operator is named by no call: every type its head spells counts, so a group using one stays with it.
  def possible_names(item)
    head = item[:head]
    return head.scan(IDENT).to_set - KEYWORDS if head.match?(/\boperator\b/)

    found = head_functions(head)
    found = [item[:name]].compact if found.empty?
    # A variable's declarator ends its head (`decltype(x) name`, `T name[N]`), whatever top_level_items made of it.
    last = head.sub(/(?:\s*\[[^\]]*\])+\s*\z/, '')[/([A-Za-z_$][\w$]*)\s*\z/, 1]
    found += [last] if last && !head.rstrip.end_with?(')')
    found.to_set - KEYWORDS
  end

  # The identifiers right before a `(` outside every parenthesis of `head`, less keywords and attributes.
  def head_functions(head)
    names = []
    depth = 0
    head.scan(/[A-Za-z_$][\w$]*\s*\(\s*\*?|\(|\)/) do |tok|
      if tok == ')'
        depth -= 1
      else
        # `T (*name)(...)`: T is a function pointer's return type, its name is the pointer's (declared_names).
        names << tok[/\A[A-Za-z_$][\w$]*/] if depth.zero? && tok != '(' && !tok.end_with?('*')
        depth += 1
      end
    end
    pointer = head[/\(\s*\*\s*(?:const\s+)?([A-Za-z_$][\w$]*)\s*\)\s*\(/, 1]
    names << pointer if pointer
    (names - KEYWORDS.to_a).uniq
  end

  # A mutable variable or a mutable function-local static: one per unit today.
  def state?(item, lines, code)
    text = ShardOutput.code_text(lines[item[:first]..item[:last]])
    if item[:function]
      return false unless item[:body]

      text.sub(/\A[^{]*\{/, '').scan(/\bstatic\b[^=;{(]*/).any? { |d| !ShardOutput.constant_static?(d) }
    elsif item[:var] && item[:body] && !item[:head].match?(/\A(?:typedef|using|struct|class|union|enum|template)\b/)
      !constant_var?(item[:head])
    else
      false
    end
  end

  def constant_var?(head)
    decl = head.sub(/\A(?:\s*\[\[[^\]]*\]\])*\s*/, '').sub(/\A(?:(?:static|inline)\s+)+/, '')
    ShardOutput.constant_static?("static #{decl}")
  end

  # An item with external linkage of its own: one definition in the gem that prints it, named by other gems.
  def external?(item, lines)
    line = lines[item[:first]].sub(/\A\s*\[\[[^\]]*\]\]\s*/, '')
    ShardOutput.external?(line, item) || item[:head].match?(/\bextern\b/)
  end

  # C_PROTOTYPE: an `extern "C"` function declaration with no body names the one C function of that name whatever
  # namespace it stands in, so it means the same in a header; a helper calling such a function can move with it.
  # BC2CPP_CROSS_GEM_C_PROTOTYPE=0 keeps them in the unit.
  def c_prototype?(item, lines)
    return false if ENV['BC2CPP_CROSS_GEM_C_PROTOTYPE'] == '0'
    return false unless item[:function] && !item[:body] && item[:name] && !item[:head].match?(/\(\s*\*/)

    text = lines[item[:first]..item[:last]].join.sub(/\A\s*(?:\[\[[^\]]*\]\]\s*)*/, '')
    text.match?(/\Aextern\s+"C"\s+[^{(]*(?<![\w$])#{Regexp.escape(item[:name])}\s*\(/) && head_functions(item[:head]) == [item[:name]]
  end

  # The names declared by the items of `lines` (the unit's text before the tail).
  def declared_in(lines)
    names = Set.new
    ShardOutput.top_level_items(lines).each do |item|
      code = ShardOutput.code_text(lines[item[:first]..item[:last]])
      found, = declared_names(item, code)
      names.merge(found).merge(possible_names(item))
    end
    names
  end

  # Function names of the tail that the unit names other than as a call.
  def address_taken(entries, text)
    functions = Set.new
    entries.each do |e|
      e[:items].each { |item| functions.merge(e[:declares] & [item[:name]]) if item[:function] }
    end
    return Set.new if functions.empty?

    found = Set.new
    pattern = /(?<![\w$])(#{functions.to_a.sort.map { |n| Regexp.escape(n) }.join('|')})(?![\w$])(?!\s*\()/
    text.scan(pattern) { found << Regexp.last_match(1) }
    found
  end

  # The segments that must move together: those declaring a common name.
  def group(entries)
    parent = (0...entries.size).to_a
    find = ->(i) { parent[i] == i ? i : (parent[i] = find.call(parent[i])) }
    owner = {}
    entries.each_with_index do |e, i|
      e[:declares].each do |name|
        if owner.key?(name)
          a = find.call(owner[name])
          b = find.call(i)
          parent[[a, b].max] = [a, b].min
        else
          owner[name] = i
        end
      end
    end
    entries.each_index.group_by { |i| find.call(i) }.values.map { |members| members.map { |i| entries[i] } }
  end

  # Indices of the groups that stay in the unit: a root name, an unmovable segment, or a name of such a group.
  def local_groups(groups, roots)
    local = Set.new
    names = roots.dup
    loop do
      grown = false
      groups.each_with_index do |g, gi|
        next if local.include?(gi)

        stays = g.any? { |e| !e[:movable] || e[:declares].any? { |n| roots.include?(n) } || e[:ids].any? { |n| names.include?(n) } }
        next unless stays

        local << gi
        g.each { |e| names.merge(e[:maybe]) }
        grown = true
      end
      break unless grown
    end
    local
  end

  # Macro name => its `#define` lines, in order.
  def macro_defs(text)
    defs = Hash.new { |h, k| h[k] = [] }
    open = nil
    text.each_line do |line|
      if open
        open << line
      elsif (m = line.match(/\A\s*#\s*define\s+([A-Za-z_$][\w$]*)/))
        open = String.new(line)
        defs[m[1]] << open
      end
      # A definition continues over lines ending in a backslash; its whole body counts.
      open = nil unless line.rstrip.end_with?('\\')
    end
    defs
  end

  # PROGRAM_OWNER_SITES (symbol_cache.rb): the site state of these macros is dated by the program's owner epoch, which
  # names the calling VM in every gem, so one copy for the program reads what one per gem would.
  PROGRAM_STATE_MACROS = %w[BC2CPP_OWNERS_PW].to_set.freeze

  # Macros whose expansion declares a mutable static (a per-site cache such as BC2CPP_OWNERS's), transitively.
  def stateful(macros)
    direct = macros.select { |name, defs| !PROGRAM_STATE_MACROS.include?(name) && defs.any? { |d| d.scan(/\bstatic\b[^=;{(]*/).any? { |s| !ShardOutput.constant_static?(s) } } }.keys.to_set
    loop do
      grown = macros.select { |name, defs| !direct.include?(name) && defs.any? { |d| d.scan(IDENT).any? { |id| direct.include?(id) } } }.keys
      break if grown.empty?

      direct.merge(grown)
    end
    direct
  end

  def expand(ids, macros)
    seen = ids.dup
    queue = ids.select { |id| macros.key?(id) }
    while (id = queue.pop)
      macros[id].each do |d|
        d.sub(/\A\s*#\s*define\s+[A-Za-z_$][\w$]*/, '').scan(IDENT).each { |x| queue << x if seen.add?(x) && macros.key?(x) }
      end
    end
    seen
  end

  # Writes one header per shared group (after the groups it names) and returns the tail with each moved segment
  # replaced by its part's include and using-declarations.
  def write_headers(shared, entries, segs, macros, rt_ns, dir)
    by_name = {}
    shared.each_with_index { |g, gi| g.each { |e| e[:declares].each { |n| by_name[n] = gi } } }
    # CONDITIONAL_USINGS: a name an #if region declares is reached through its namespace's using-directive, which
    # compiles whichever branch declared it.
    conditional = shared.flat_map { |g| g.select { |e| segs[e[:index]][:lines].first.match?(/\A\s*#\s*if/) } }
                        .flat_map { |e| e[:declares].to_a }.to_set
    conditional = Set.new if ENV['BC2CPP_CROSS_GEM_CONDITIONAL_USINGS'] == '0'
    deps = shared.map { |g| g.flat_map { |e| e[:ids].filter_map { |n| by_name[n] } }.to_set }
    comps = strongly_connected(deps)
    ns_of = {}
    replace = {}
    comps.each do |members|
      group = members.flat_map { |gi| shared[gi] }.sort_by { |e| e[:index] }
      names = group.flat_map { |e| e[:declares].to_a }.to_set
      text, macro_names = header_text(group, segs, names, by_name, ns_of, rt_ns, macros, conditional)
      text = ImplicitState.rewrite([text]).first if ImplicitState.enabled?
      macro_text = expand(macro_names, macros).select { |m| macros.key?(m) }.sort.flat_map { |m| macros[m] }.join
      digest = Digest::SHA256.hexdigest("#{FORMAT}\n#{macro_text}\n#{text}")[0, 16]
      ns = "bc2cpp_cs_#{digest}"
      path = File.join(File.expand_path(dir), "#{ns}.hxx")
      RuntimeHeader.write_once(path, text.gsub(NS_PLACEHOLDER, ns))
      members.each { |gi| ns_of[gi] = ns }
      group.each_with_index do |e, k|
        usings = usings_text(segs[e[:index]][:lines], e, ns)
        replace[e[:index]] = "#define #{PART_MACRO} #{k + 1}\n#include \"#{path}\"\n#undef #{PART_MACRO}\n#{usings}"
      end
    end
    warn "== cross-gem share (CROSS_GEM_SHARE): #{replace.size} of #{entries.size} prelude segments in #{comps.size} shared headers =="
    segs.each_with_index.map { |seg, i| replace.key?(i) ? replace[i] : seg[:lines].join }.join
  end

  # CONDITIONAL_USINGS: the using-declarations that bring a segment's names back. A segment that is one #if region
  # keeps its conditional directives around them, so a name is brought back only where its branch declared it (a
  # using-declaration of a name the header did not declare would not compile).
  CONDITIONAL = /\A\s*#\s*(?:if|ifdef|ifndef|elif|else|endif)\b/

  def usings_text(lines, entry, ns)
    if ENV['BC2CPP_CROSS_GEM_CONDITIONAL_USINGS'] == '0' || !lines.first.match?(/\A\s*#\s*if/)
      return entry[:declares].to_a.sort.map { |n| "using #{ns}::#{n};\n" }.join
    end

    starts = entry[:items].to_h { |item| [item[:first], item] }
    out = +''
    lines.each_with_index do |line, i|
      if line.match?(CONDITIONAL)
        out << line
      elsif (item = starts[i])
        names, = declared_names(item, ShardOutput.code_text(lines[item[:first]..item[:last]]))
        (names & entry[:declares].to_a).sort.each { |n| out << "using #{ns}::#{n};\n" }
      end
    end
    out
  end

  # The header text of one group: each segment in its own part, in the group's namespace, with the runtime namespace
  # and the names of earlier groups in reach. [text, the macro names its code names].
  def header_text(group, segs, names, by_name, ns_of, rt_ns, macros, conditional = Set.new)
    out = String.new("// bc2cpp cross-gem helpers (CROSS_GEM_SHARE, cross_gem_share.rb): generated, shared by the gems that print them.\n")
    out << ShardOutput::SHARED_HELPER_MACROS
    seen_deps = {}
    macro_names = Set.new
    group.each_with_index do |e, k|
      macro_names.merge(e[:ids].select { |n| macros.key?(n) })
      out << "#if #{PART_MACRO} == #{k + 1}\nnamespace #{NS_PLACEHOLDER} {\n"
      out << "using namespace #{rt_ns};\n" if rt_ns
      directives = Set.new
      e[:ids].select { |n| by_name.key?(n) && !names.include?(n) }.sort.each do |n|
        ns = ns_of.fetch(by_name[n])
        seen_deps[n] = true
        if conditional.include?(n)
          out << "using namespace #{ns};\n" if directives.add?(ns)
        else
          out << "using #{ns}::#{n};\n"
        end
      end
      out << convert(segs[e[:index]][:lines], e[:items])
      out << "} // namespace #{NS_PLACEHOLDER}\n#endif\n"
    end
    [out, macro_names]
  end

  # A segment's text as the header holds it: `static` functions as SHARED_HELPERS has them (an out-of-line entry every
  # shard calls `inline`), `static` constants `inline`.
  def convert(lines, items)
    lines = lines.dup
    items.each do |item|
      next unless item[:function] || item[:var]

      # The head's own line: an attribute may stand on the line before it, a member's `static` never counts.
      at = [item[:first], item[:first] + 1].find do |k|
        k <= item[:last] && lines[k][/\A[^(=]*/].match?(/\bstatic\b/) && (k == item[:first] || lines[item[:first]].strip.match?(/\A\[\[.*\]\]\z/))
      end
      next unless at

      line = lines[at]
      lines[at] =
        if item[:function] && item[:head].include?('BC2CPP_SHARD_ONE_BODY')
          ShardOutput.to_inline(line)
        elsif item[:function]
          fn = ShardOutput.to_shared_helper(line)
          fn.match?(/maybe_unused|\binline\b/) ? fn : "[[maybe_unused]] #{fn}"
        else
          ShardOutput.to_inline(line)
        end
    end
    lines.join
  end

  # Tarjan's components of `deps` (index => Set of indices): a component comes after every component it names.
  def strongly_connected(deps)
    index = {}
    low = {}
    on = Set.new
    stack = []
    out = []
    counter = 0
    visit = lambda do |v|
      index[v] = low[v] = counter
      counter += 1
      stack << v
      on << v
      deps[v].each do |w|
        if !index.key?(w)
          visit.call(w)
          low[v] = [low[v], low[w]].min
        elsif on.include?(w)
          low[v] = [low[v], index[w]].min
        end
      end
      next unless low[v] == index[v]

      comp = []
      loop do
        w = stack.pop
        on.delete(w)
        comp << w
        break if w == v
      end
      out << comp.sort
    end
    deps.each_index { |v| visit.call(v) unless index.key?(v) }
    out
  end
end
