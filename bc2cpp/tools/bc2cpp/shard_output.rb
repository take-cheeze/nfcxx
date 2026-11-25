# frozen_string_literal: true

require 'set'
require 'stringio'
require_relative 'shard_colocate'

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
# `bc2cpp_shard_<symbol>`, and its stateful `static` items (shared_prelude_items) become `inline`, the stateless ones
# too in a size-optimized build (SHARED_HELPERS): an inline function or variable has one definition, and one copy of
# each function-local static, in the whole program, where `static` would give every shard its own. The namespace keeps
# two gems' same-named helpers apart. A methods-section `static` the prelude or another shard names loses `static`
# (its name is unique per owner and method); every other one stays file-local.
module ShardOutput
  UNIT_MARK = '/* BC2CPP_SHARD_UNIT '
  HOOKS_MARK = "/* BC2CPP_SHARD_HOOKS */\n"
  PRELUDE_ONLY = 'BC2CPP_SHARD_PRELUDE_ONLY'
  # Below this much method code per shard, compiling the prelude once more costs about what the split saves; a
  # gem under it stays one translation unit, its main file byte-identical to BC2CPP_SHARDS=1. A check's small
  # fixture lowers it with BC2CPP_SHARD_MIN_BYTES.
  MIN_SHARD_BYTES = 400_000
  IDENT = /[A-Za-z_$][\w$]*/.freeze
  ASCII_CHARS = Array.new(128) { |byte| byte.chr.freeze }.freeze

  class Error < StandardError; end

  module_function

  # Yields each identifier [name, offset] in a line of generated C++. ASCII
  # lines scan bytes directly (byte and character offsets coincide); any other
  # line uses the IDENT expression. Byte and regex paths agree identifier for
  # identifier on ASCII text, including `$` handling.
  def each_identifier(line)
    return enum_for(:each_identifier, line) unless block_given?

    unless line.ascii_only?
      line.scan(IDENT) { yield Regexp.last_match(0), Regexp.last_match.begin(0) }
      return
    end
    i = 0
    n = line.bytesize
    while i < n
      b = line.getbyte(i)
      if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 36
        j = i + 1
        while j < n
          c = line.getbyte(j)
          break unless (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36

          j += 1
        end
        yield line.byteslice(i, j - i), i
        i = j
      else
        i += 1
      end
    end
  end

  # Yields each identifier [name, offset] with ShardColocate::IDENT's edge
  # rules: `$` continues an identifier but never starts one, and a match must
  # not touch another word character or `$` on either side. Same ASCII fast
  # path as each_identifier; anything else uses the expression.
  def each_delimited_identifier(line)
    return enum_for(:each_delimited_identifier, line) unless block_given?

    unless line.ascii_only?
      line.scan(ShardColocate::IDENT) { yield Regexp.last_match(1), Regexp.last_match.begin(1) }
      return
    end
    i = 0
    n = line.bytesize
    while i < n
      b = line.getbyte(i)
      if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
        j = i + 1
        while j < n
          c = line.getbyte(j)
          break unless (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36

          j += 1
        end
        if i.zero?
          yield line.byteslice(i, j - i), i
        else
          p = line.getbyte(i - 1)
          yield line.byteslice(i, j - i), i unless (p >= 65 && p <= 90) || (p >= 97 && p <= 122) ||
                                                   (p >= 48 && p <= 57) || p == 95 || p == 36
        end
        i = j
      else
        i += 1
      end
    end
  end

  # How many files a run writes: BC2CPP_SHARDS, default 1 (no shard files).
  def count(env = ENV)
    raw = env.fetch('BC2CPP_SHARDS', '1')
    # Not Integer(raw, exception: false): mruby's Integer() takes a base as its second argument and reads the keyword
    # Hash as one (bc2cpp runs as an mruby executable, docs/bc2cpp-self-compile.md).
    n = begin
      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end
    raise Error, "BC2CPP_SHARDS must be a positive integer, got #{raw.inspect}" unless n&.positive?

    n
  end

  # The shard tier (docs/notes/bc2cpp-shard-tiers.md), set by flags on the bc2cpp command line:
  #   --shard-cold-opt=LEVEL  the shards other than the main file are compiled at this optimization level (a GCC
  #                           `#pragma GCC optimize` at the top of each; GCC only, other compilers ignore it);
  #   --shard-hot-owners=FILE owners (one per line, `#` comments) whose methods stay in the main file, which keeps the
  #                           build's own flags. Needs --shard-cold-opt. The list is the profile's, supplied by the caller.
  COLD_OPT_FLAG = '--shard-cold-opt='
  HOT_OWNERS_FLAG = '--shard-hot-owners='
  COLD_OPT = /\AO[0-3sz]\z/
  # The tier a unit reports when it is compiled with the build's own flags: the main file, or no tier at all.
  DEFAULT_TIER = 'default'

  # Takes the tier flags out of argv (in place) and returns { tier: level or nil, hot: Set of owners }.
  def take_argv!(argv)
    tier = nil
    hot_path = nil
    argv.dup.each do |arg|
      if arg.start_with?(COLD_OPT_FLAG)
        tier = arg.delete_prefix(COLD_OPT_FLAG)
        argv.delete(arg)
      elsif arg.start_with?(HOT_OWNERS_FLAG)
        hot_path = arg.delete_prefix(HOT_OWNERS_FLAG)
        argv.delete(arg)
      end
    end
    tier = valid_tier(tier) if tier
    raise Error, "#{HOT_OWNERS_FLAG.chomp('=')} needs #{COLD_OPT_FLAG.chomp('=')}" if hot_path && tier.nil?

    { tier: tier, hot: hot_path ? owners_file(hot_path) : Set.new }
  end

  def valid_tier(level)
    raise Error, "#{COLD_OPT_FLAG.chomp('=')} must be O0, O1, O2, O3, Os or Oz, got #{level.inspect}" unless level =~ COLD_OPT

    level
  end

  def owners_file(path)
    names = File.read(path).split("\n").map(&:strip)
    names.reject { |name| name.empty? || name[0] == '#' }.to_set
  end

  def unit_mark(owner)
    "#{UNIT_MARK}#{owner} */\n"
  end

  def shard_path(out_dir, symbol, index)
    File.join(out_dir, "#{symbol}_gen_shard#{index}.cpp")
  end

  # Register before every other stdout rewriter: at_exit runs last-in first-out, so this splits their final text.
  # on_tiers (optional) gets the shard tier of each unit in print order, after the files are written.
  def capture_stdout(symbol, out_dir, shards, tier = nil, hot = nil, on_tiers = nil)
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      next if $!

      main, files, tiers = split_with_tiers(buffer.string, symbol, shards, tier, hot)
      files.each_with_index { |text, i| File.write(shard_path(out_dir, symbol, i + 1), text) }
      original.write(main)
      on_tiers&.call(tiers)
    end
  end

  # [main text, the texts of shards 1...shards-1].
  def split(text, symbol, shards, tier = nil, hot = nil)
    main, files, _tiers = split_with_tiers(text, symbol, shards, tier, hot)
    [main, files]
  end

  # split, and the tier of each unit (in print order): DEFAULT_TIER for a unit in the main file or with no tier, else
  # the tier level for a unit in a shard other than the main file.
  def split_with_tiers(text, symbol, shards, tier = nil, hot = nil)
    tier = valid_tier(tier) if tier
    # Owners are kept in the main file only under a tier; without one the split is the default.
    hot = tier ? (hot || Set.new) : Set.new
    prelude, units, hooks = sections(text)
    colocate(symbol, prelude, units, hooks)
    # Each unit remembers its print position, so the placement can be reported after assign has regrouped them.
    indexed = units.each_with_index.map { |u, i| u.merge(index: i) }
    groups = assign(indexed, shards, hot)
    tiers = Array.new(units.size, DEFAULT_TIER)
    if groups.count { |g| !g.empty? } <= 1
      plain = prelude + units.map { |u| u[:code] }.join + units.map { |u| u[:tail].to_s }.join + hooks
      return [plain, Array.new(shards - 1) { |i| empty_shard(symbol, i + 1, shards) }, tiers]
    end

    if tier
      groups.each_with_index { |group, shard| group.each { |u| tiers[u[:index]] = tier } if shard.positive? }
    end
    main, files = rewrite(symbol, shards, prelude, groups, hooks, tier)
    [main, files, tiers]
  end

  # SHARD_COLOCATE (shard_colocate.rb), before the units are placed, so a copy is weighed with its root's unit.
  # BC2CPP_SHARD_COLOCATE_REPORT=FILE appends one `symbol callee root placement` row per copy.
  def colocate(symbol, prelude, units, hooks)
    return unless ShardColocate.enabled?

    rows = ShardColocate.apply!(prelude, units, hooks)
    return if rows.empty?

    warn "== shard colocate (SHARD_COLOCATE): #{rows.size} single-site callees copied beside " \
         "#{rows.map { |r| r[1] }.uniq.size} callers, #{rows.sum { |r| r[3] }} site-proven parameter guards left out =="
    return unless (path = ENV['BC2CPP_SHARD_COLOCATE_REPORT']) && !path.empty?

    File.open(path, 'a') { |f| rows.each { |r| f.puts([symbol, *r].join("\t")) } }
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

  # By default an owner's methods stay together for cross-method inlining. BC2CPP_SHARD_SPLIT_OWNERS=1 lets
  # oversized owners split into method units: a large compiler class otherwise leaves one translation unit on
  # the critical path after every other worker has finished. Owners fitting a fair share of method bytes stay
  # together, and explicitly hot owners remain together in the main file even with the opt-in.
  # The existing cross-shard declaration rewrite also covers calls between units of the same owner.
  # `shards` lists of units, each in print order.
  def assign(units, shards, hot = Set.new)
    by_owner = units.each_with_index.group_by { |u, _| u[:owner] }
    size = ->(list) { list.sum { |u, _| u[:code].bytesize + u[:tail].to_s.bytesize } }
    total = units.sum { |u| u[:code].bytesize + u[:tail].to_s.bytesize }
    min_bytes = Integer(ENV.fetch('BC2CPP_SHARD_MIN_BYTES', MIN_SHARD_BYTES.to_s))
    split_owners = ENV['BC2CPP_SHARD_SPLIT_OWNERS'] == '1'
    count = split_owners ? units.size : by_owner.size
    wanted = [[shards, count, (total / min_bytes.to_f).ceil].min, 1].max
    target = (total + wanted - 1) / wanted
    loads = Array.new(wanted, 0)
    placed = Array.new(wanted) { [] }
    # Hot owners all go to the main file (shard 0), before the cold ones are spread over the lightest shards.
    hot_part, cold_part = by_owner.partition { |owner, _| hot.include?(owner) }
    hot_part.each do |_, list|
      loads[0] += size.call(list)
      placed[0].concat(list)
    end
    cold_part = colocate_affinity(cold_part, size, target) unless split_owners
    chunks = cold_part.flat_map do |owner, list|
      split_owners && size.call(list) > target ? list.map { |unit| [owner, [unit]] } : [[owner, list]]
    end
    chunks.sort_by { |owner, list| [-size.call(list), owner, list.first.last] }.each do |_, list|
      i = loads.index(loads.min)
      loads[i] += size.call(list)
      placed[i].concat(list)
    end
    placed.map { |list| list.sort_by(&:last).map(&:first) } + Array.new(shards - wanted) { [] }
  end

  # SHARD_COLOCATE's affinity: an owner whose units hold copies of another owner's methods joins that owner's chunk,
  # heaviest copies first, while the joined chunk stays within one shard's share. A copy in another shard than its
  # original still works, but its shard then compiles its own copy of every stateless prelude helper the copy calls
  # (outside a size-optimized build, SHARED_HELPERS).
  def colocate_affinity(owners, size, target)
    index = owners.each_with_index.to_h { |(owner, _), i| [owner, i] }
    parent = (0...owners.size).to_a
    find = ->(i) { parent[i] == i ? i : (parent[i] = find.call(parent[i])) }
    weight = owners.map { |_, list| size.call(list) }
    edges = Hash.new(0)
    owners.each do |owner, list|
      list.each do |u, _|
        (u[:colo_owners] || {}).each { |other, bytes| edges[[owner, other].sort] += bytes if index.key?(other) && other != owner }
      end
    end
    edges.sort_by { |pair, bytes| [-bytes, pair] }.each do |(a, b), _|
      ra = find.call(index[a])
      rb = find.call(index[b])
      next if ra == rb || weight[ra] + weight[rb] > target

      ra, rb = rb, ra if rb < ra
      parent[rb] = ra
      weight[ra] += weight[rb]
    end
    owners.each_index.group_by { |i| find.call(i) }.sort.map do |_, members|
      [owners[members.first].first, members.flat_map { |i| owners[i].last }]
    end
  end

  def rewrite(symbol, shards, prelude, groups, hooks, tier)
    # A unit's :tail (SHARD_COLOCATE's copies) follows every unit of its shard.
    texts = groups.each_with_index.map do |g, i|
      g.map { |u| u[:code] }.join + g.map { |u| u[:tail].to_s }.join + (i.zero? ? hooks : '')
    end
    line_arrays = texts.map(&:lines)
    scans = line_arrays.map { |lines| scan_lines(lines) }
    items = line_arrays.zip(scans).map { |lines, scan| top_level_items(lines, scan: scan) }
    defined = {}
    items.each_with_index do |list, shard|
      list.each do |item|
        next unless item[:name] && item[:body]
        raise Error, "#{item[:name]} is defined in shards #{defined[item[:name]]} and #{shard}" if defined.key?(item[:name])

        defined[item[:name]] = shard
      end
    end
    prelude_ids = Set.new
    ShardOutput.each_identifier(prelude) { |name, _| prelude_ids << name }
    shard_ids = texts.map do |t|
      ids = Set.new
      ShardOutput.each_identifier(t) { |name, _| ids << name }
      ids
    end
    shared = defined.select do |name, shard|
      prelude_ids.include?(name) || shard_ids.each_with_index.any? { |ids, i| i != shard && ids.include?(name) }
    end.keys.to_set
    prelude_out, declared = rewrite_prelude(symbol, prelude, defined.keys.to_set, line_arrays.zip(scans).map { |lines, scan| code_text(lines, scan: scan) }.join)
    decls = String.new
    bodies = line_arrays.zip(items).map do |lines, list|
      list.each do |item|
        next unless item[:body] && shared.include?(item[:name])

        line = lines[item[:first]]
        # A const variable needs explicit external linkage; a mutable definition already has it without static.
        # `extern int state = 0` is valid C++ but GCC warns about it, unlike `extern const int table[] = ...`.
        constant = item[:var] && constant_static?(line.sub(/\A\s*\[\[[^\]]*\]\]\s*/, '').strip)
        lines[item[:first]] = constant ? line.sub(/\bstatic\b/, 'extern') : drop_static(line)
        decls << "#{item[:var] ? 'extern ' : ''}#{drop_static(item[:head])};\n" unless declared.include?(item[:name])
      end
      lines.join
    end
    main = String.new(prelude_out)
    main << "// SHARD_DECLS: methods-section definitions another shard names (docs/bc2cpp-shards.md).\n" << decls
    main << "#ifndef #{PRELUDE_ONLY}\n" << bodies[0] << "#endif // #{PRELUDE_ONLY}\n"
    files = bodies.drop(1).each_with_index.map do |body, i|
      next empty_shard(symbol, i + 1, shards) if groups[i + 1].empty?

      # A pragma before the include covers the prelude and the methods of this translation unit (docs/notes/bc2cpp-shard-tiers.md).
      # GCC only: clang has no such pragma, and -Wunknown-pragmas under -Werror would fail its build.
      head = tier ? "#if defined(__GNUC__) && !defined(__clang__)\n#pragma GCC optimize (\"#{tier}\")\n#endif\n" : ''
      "#{head}// #{symbol}_gen_shard#{i + 1}.cpp: shard #{i + 1} of #{shards} (docs/bc2cpp-shards.md).\n" \
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
    prelude_lines = prelude.lines
    prelude_scan = scan_lines(prelude_lines)
    segs = segments(prelude_lines, scan: prelude_scan)
    shared = shared_prelude_items(segs, code_text(prelude_lines, scan: prelude_scan) + methods_code)
    helpers = shared_helpers? ? stateless_helpers(segs, method_names) : Set.new
    out = String.new(helpers.empty? ? '' : SHARED_HELPER_MACROS)
    out << "namespace #{ns} {}\nusing namespace #{ns};\n"
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
            else
              if item[:function] && item[:body] && line[/\A[^(]*/].match?(/\bstatic\b/) &&
                 !line[/\A[^(]*/].match?(/\binline\b|maybe_unused/)
                # A shard need not call every helper the whole program does.
                line = lines[item[:first]] = "[[maybe_unused]] #{line}"
              end
              if helpers.include?(item[:name])
                # An attribute may stand on its own line, before the one with `static`.
                at = (item[:first]..item[:last]).find { |k| lines[k][/\A[^(]*/].match?(/\bstatic\b/) }
                lines[at] = to_shared_helper(lines[at]) if at
              end
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

  # SHARED_HELPERS (BC2CPP_SHARED_HELPERS=0 turns it off): every other `static` function of the prelude is
  # `inline` in a size-optimized build, so its link keeps one out-of-line body per gem instead of one per shard. Sound
  # because every shard compiles the same prelude text (one definition), and what such a function names is one entity
  # already (shared_prelude_items) or a stateless `static`; a unit whose macro says `static` gets its own copy, as
  # before. Other builds keep `static`: there `inline` moved GCC's inlining enough to cost speed (docs/bc2cpp-shards.md).
  SHARED_HELPER_MACROS = <<~CPP
    #ifndef BC2CPP_SHARED_FN
    #ifdef __OPTIMIZE_SIZE__
    #define BC2CPP_SHARED_FN inline
    #define BC2CPP_SHARED_STATIC
    #else
    #define BC2CPP_SHARED_FN static
    #define BC2CPP_SHARED_STATIC static
    #endif
    #endif
  CPP

  def shared_helpers?(env = ENV)
    env['BC2CPP_SHARED_HELPERS'] != '0'
  end

  # `static inline` keeps its `inline` and `static` alone becomes BC2CPP_SHARED_FN, so a build whose macros say
  # `static` compiles the text it did before.
  def to_shared_helper(line)
    return line.sub(/\bstatic\s+inline\b/, 'BC2CPP_SHARED_STATIC inline') if line.match?(/\bstatic\s+inline\b/)

    line.sub(/\bstatic\b/, 'BC2CPP_SHARED_FN')
  end

  # The names of the prelude's `static` functions with a body, less every name an item of an #if region holding a
  # global names: that region stays at global scope with its `static`s, and one name cannot be both. A function
  # template (top_level_items names none) stays `static`: its `inline` instantiations measured 2.4 KB larger on Wio.
  def stateless_helpers(segs, method_names)
    names = Set.new
    kept = Set.new
    segs.each do |seg|
      next unless seg[:kind] == :code

      lines = seg[:lines]
      items = top_level_items(lines)
      if items.any? { |item| (!item[:body] && method_names.include?(item[:name])) || external?(lines[item[:first]], item) }
        kept.merge(items.filter_map { |item| item[:name] })
        next
      end
      items.each do |item|
        names << item[:name] if item[:function] && item[:body] && item[:name] && item[:head][/\A[^(]*/].match?(/\bstatic\b/)
      end
    end
    names - kept
  end

  # SHARD_SINGLE_DEFINITION's prelude names: every file-scope variable, every function holding a mutable
  # function-local static or whose address is taken (a shard's own copy would compare unequal), and every static
  # function such an inline function calls (an inline function has one definition, so what it names must be one
  # entity too). Every other `static` function is SHARED_HELPERS': `static` outside a size-optimized build, where each
  # shard compiles its own copy, as an `inline` one shifts GCC's inlining (docs/bc2cpp-shards.md, "Measurements"). A
  # per-call-site cache that a macro such as BC2CPP_OWNERS declares belongs to that site, so a second copy of the
  # function is a second site, not a second state. A function whose head carries BC2CPP_SHARD_ONE_BODY is shared too:
  # an out-of-line entry every shard calls, whose own copy per shard would only cost code size.
  def shared_prelude_items(segs, code)
    items = segs.flat_map do |seg|
      next [] unless seg[:kind] == :code

      lines = seg[:lines]
      seg_scan = scan_lines(lines)
      code_lines = code_text(lines, scan: seg_scan).lines
      top_level_items(lines, scan: seg_scan).select { |item| item[:name] && item[:body] && lines[item[:first]].match?(/\bstatic\b/) }
                            .map { |item| item.merge(text: code_lines[item[:first]..item[:last]].join) }
    end
    by_name = items.group_by { |item| item[:name] }
    functions = by_name.select { |_, list| list.all? { |item| item[:function] } }.keys.to_set
    shared = by_name.keys.to_set - functions
    shared |= items.select { |item| item[:head].include?('BC2CPP_SHARD_ONE_BODY') }.to_set { |item| item[:name] } & functions
    code_idents = Set.new
    code.scan(/\b([A-Za-z_][\w$]*)\b(?!\s*\()/) { |cap| code_idents.merge(cap) }
    shared |= code_idents & functions
    items.each do |item|
      locals = item[:text].sub(/\A[^{]*\{/, '').scan(/\bstatic\b[^=;{(]*/)
      shared << item[:name] if locals.any? { |decl| !constant_static?(decl) }
    end
    # Each body is scanned at most once across all iterations: the fixpoint only
    # re-reads memoized identifier sets. Lazy, so a fast-converging loop never
    # pays for bodies it does not revisit.
    idents_by_item = Array.new(items.size)
    loop do
      grown = Set.new
      items.each_with_index do |item, i|
        next unless shared.include?(item[:name])

        idents = idents_by_item[i] ||= begin
          set = Set.new
          item[:text].scan(/\b[A-Za-z_][\w$]*\b/) { |name| set << name }
          set
        end
        grown.merge(idents)
      end
      grown &= functions
      break if grown.subset?(shared)

      shared |= grown
    end
    shared
  end

  # The text with comments and literals blanked, line for line (callers index its lines as the input's); a directive
  # line keeps its text (a macro can name a function).
  # A precomputed scan_lines(lines) avoids rescanning the same lines for every reader.
  def code_text(lines, scan: scan_lines(lines))
    scan.each_with_index.map do |info, i|
      info[:pp] ? lines[i].sub(%r{//.*}, '') : "#{info[:code].chomp}\n"
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
  def segments(lines, scan: scan_lines(lines))
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
  # A precomputed scan_lines(lines) avoids rescanning the same lines for every reader.
  def top_level_items(lines, scan: scan_lines(lines))
    scan.each_index.select { |k| scan[k][:item_start] }.map do |k|
      head = String.new
      cut = nil
      depth = 0
      j = k
      loop do
        code = scan[j][:code]
        # A parameter list wrapped over lines carries its parenthesis depth to the line holding the body's `{`.
        cut, depth = head_cut(code, depth)
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
  # [index or nil, the depth after the line]; `depth` is the depth the line starts at.
  # ASCII heads compare bytes directly: byte and character indices coincide, so no
  # one-character String is allocated per step. Non-ASCII heads keep the character path.
  def head_cut(code, depth = 0)
    if code.ascii_only?
      i = 0
      while i < code.bytesize
        case code.getbyte(i)
        when 40, 91 then depth += 1
        when 41, 93 then depth -= 1
        when 123, 59 then return [i, depth] if depth.zero?
        when 61
          if depth.zero? && code.getbyte(i + 1) != 61 && ![61, 33, 60, 62].include?(code.getbyte(i - 1))
            return [i, depth]
          end
        end
        i += 1
      end
      return [nil, depth]
    end
    code.each_char.with_index do |c, i|
      case c
      when '(', '[' then depth += 1
      when ')', ']' then depth -= 1
      when '{', ';' then return [i, depth] if depth.zero?
      when '=' then return [i, depth] if depth.zero? && code[i + 1] != '=' && !'=!<>'.include?(code[i - 1].to_s)
      end
    end
    [nil, depth]
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
      # Most emitted lines contain neither comments nor literals. They need only
      # brace accounting; avoid allocating a one-character String at every step.
      if !in_comment && !raw_end && !line.match?(/[\/"']/)
        code = line
        depth += line.count('{') - line.count('}')
      else
        code = String.new
        i = 0
        in_str = nil
        chars = line.ascii_only? && ASCII_CHARS
        while i < line.size
          # Byte and character indices coincide on ASCII lines; reuse their character strings.
          c = chars ? chars[line.getbyte(i)] : line[i]
          if in_comment
            if c == '*' && line[i, 2] == '*/'
              in_comment = false
              i += 1
            end
            code << ' '
          elsif raw_end
            if c == ')' && line[i, raw_end.size] == raw_end
              i += raw_end.size - 1
              raw_end = nil
            end
            code << ' '
          elsif in_str
            i += 1 if c == '\\'
            in_str = nil if c == in_str
            code << ' '
          elsif c == '/' && line[i, 2] == '//'
            break
          elsif c == '/' && line[i, 2] == '/*'
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
