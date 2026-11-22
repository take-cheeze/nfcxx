# frozen_string_literal: true

require 'set'

# SHARD_COLOCATE (BC2CPP_SHARD_COLOCATE=0 turns it off): a generated function (a compiled `_impl`, a guard wrapper's
# body) with one direct call site gets a copy with internal linkage, defined in the caller's translation unit, and
# that site calls the copy. GCC inlines a static
# function called once (-finline-functions-called-once, on at -Os), which it does not do for the external original,
# and the original, then unreferenced, is dropped by --gc-sections.
#
# The copy is the callee's own text under a new name, so the site runs the same code. The original stays defined
# because another gem (OTHER_DECLS_HEADER) or a host (the entry header) may still call it; the linker drops it only
# when nothing does. Soundness rests on the copy sharing no state with the original that either could observe: a
# callee holding a mutable function-local `static` is refused (copy_safe?). The per-call-site caches the
# BC2CPP_OWNERS macros declare belong to their site, so the copy's are a second site's, as a second caller's are.
#
# A callee qualifies when, over the gem's whole text, exactly one function calls it and nothing else names it but its
# own wrapper, which nothing names (a registered wrapper keeps the original alive, and the copy would only add code).
# A qualifying callee whose site is inside another one is copied along with it, into the translation unit of the
# first caller up the chain that does not qualify (the root). A cycle of qualifying callees is left alone.
module ShardColocate
  PREFIX = 'bc2cpp_colo_'
  # GCC's identical code folding runs before its inliner and would merge a copy in its original's translation unit
  # back into the external original, which then stays out of line. no_icf keeps the copy its own function.
  ATTR = <<~CPP
    #ifndef BC2CPP_COLO_ATTR
    #if defined(__GNUC__) && !defined(__clang__)
    #define BC2CPP_COLO_ATTR [[gnu::no_icf]]
    #else
    #define BC2CPP_COLO_ATTR
    #endif
    #endif
  CPP
  IDENT = /(?<![\w$])([A-Za-z_][\w$]*)(?![\w$])/.freeze
  HEAD = /\A(?:\[\[maybe_unused\]\] )?(?:static )?(?:inline )?mrb_value ([A-Za-z_][\w$]*)\(/.freeze

  # `_impl` names called from outside the gem's text that the generator knows of (the entry header's); bc2cpp.rb
  # sets them before the split. Their originals stay referenced, so a copy would only add code.
  class << self
    attr_accessor :keep
  end

  module_function

  def enabled?(env = ENV)
    env['BC2CPP_SHARD_COLOCATE'] != '0'
  end

  # BC2CPP_SHARD_COLOCATE=all also copies a callee whose wrapper is registered. Still sound (the site runs the same
  # text), only larger; a check's fixture, whose methods are all registered, uses it to reach the copies.
  def live_wrappers?(env = ENV)
    env['BC2CPP_SHARD_COLOCATE'] == 'all'
  end

  # Rewrites `units` ({owner:, code:}) in place: each root's call points at its copy, the root's unit starts with
  # the copies' declarations, and its :tail holds their definitions, which the split prints after every unit of the
  # shard (where whatever a copy names from its original's unit is defined, or declared by SHARD_DECLS). Returns one
  # row [callee, root, same-unit|other-unit] per copy.
  def apply!(prelude, units, hooks, keep = self.keep)
    keep = (keep || []).to_set
    items = index(units)
    defs = items.select { |it| it[:impl] }.to_h { |it| [it[:name], it] }
    return [] if defs.empty?

    namers = Hash.new { |h, k| h[k] = Set.new }
    refs = Hash.new { |h, k| h[k] = [] }
    items.each { |it| scan(it, defs, refs, namers) }
    outside = outside_names(prelude, hooks)
    local = unit_local_names(units, items)
    eligible = {}
    defs.each do |name, d|
      next if keep.include?(name) || outside.include?(name) || !copy_safe?(d)

      site = sole_site(name, refs[name], namers, outside)
      next unless site && site[:item][:function]

      eligible[name] = site
    end
    drop_cycles!(eligible)
    settle!(eligible, defs, local)
    return [] if eligible.empty?

    hits = Hash.new { |h, k| h[k] = [] }
    eligible.each { |name, site| hits[site[:item][:key]] << site.merge(name: name) }
    roots = Hash.new { |h, k| h[k] = [] }
    eligible.each_key { |name| roots[root_of(name, eligible)] << name }
    rows = []
    roots.each do |root, names|
      unit = units[root[:unit]]
      unit[:prefix] = (unit[:prefix] || +ATTR) + names.map { |n| "#{copy_head(defs[n])};\n" }.join
      unit[:tail] = (unit[:tail] || +'') + names.map { |n| copy_text(defs[n], hits[defs[n][:key]]) }.join
      names.each do |n|
        rows << [n, root[:name], defs[n][:unit] == root[:unit] ? 'same-unit' : 'other-unit']
        # The split's affinity (ShardOutput.colocate_affinity): bytes of copies per original owner.
        (unit[:colo_owners] ||= Hash.new(0))[units[defs[n][:unit]][:owner]] += defs[n][:raw].sum(&:bytesize)
      end
    end
    roots.each_key { |root| rename!(units[root[:unit]][:lines], hits[root[:key]]) }
    touched = roots.keys.to_set { |root| root[:unit] }
    units.each_with_index do |u, i|
      lines = u.delete(:lines)
      u[:code] = "#{u.delete(:prefix)}#{lines.join}" if touched.include?(i)
    end
    rows
  end

  # Removes, until none is left to remove, each callee whose copy could not stand in its root's translation unit or
  # would buy nothing:
  #   * a static callee in its caller's own unit, unless that caller is copied too: GCC inlines it there already;
  #   * a callee whose text names a type or macro its unit defines (no other shard sees it);
  #   * a callee whose text names an `inline` helper of the methods section that is not copied along with it (a shard
  #     would see only a declaration of an inline function, with no definition to link).
  def settle!(eligible, defs, local)
    loop do
      drop = eligible.keys.select do |name|
        d = defs[name]
        site = eligible[name][:item]
        next true if d[:static] && site[:unit] == d[:unit] && !eligible.key?(site[:name])

        ids = d[:ids]
        next true if ids.intersect?(local[:types])

        ids.any? { |id| local[:inline].include?(id) && id != name && !(eligible.key?(id) && eligible[id][:item][:name] == name) }
      end
      break if drop.empty?

      drop.each { |name| eligible.delete(name) }
    end
  end

  # The names the methods section defines that a copy in another translation unit could not use: types and macros
  # (:types) and inline functions (:inline).
  def unit_local_names(units, items)
    types = Set.new
    inline = Set.new
    units.each do |unit|
      unit[:lines].each do |line|
        if (m = line.match(/\A\s*#\s*define\s+([A-Za-z_][\w$]*)/))
          types << m[1]
        elsif (m = line.match(/\A(?:typedef\s+)?(?:struct|class|union|enum(?:\s+class)?)\s+([A-Za-z_][\w$]*)\s*(?:\{|:|;|\z)/))
          types << m[1]
        elsif (m = line.match(/\Ausing\s+([A-Za-z_][\w$]*)\s*=/) || line.match(/\Atypedef\b.*?([A-Za-z_][\w$]*)\s*;\s*\z/))
          types << m[1]
        end
      end
    end
    items.each { |it| inline << it[:name] if it[:function] && it[:raw].first[/\A[^(]*/].match?(/\binline\b/) }
    { types: types, inline: inline }
  end

  # Every top-level item with a body: its unit, raw lines (:raw) and comment- and literal-blanked lines (:code).
  def index(units)
    units.each_with_index.flat_map do |unit, ui|
      lines = unit[:code].lines
      code = blanked(lines)
      unit[:lines] = lines
      ShardOutput.top_level_items(lines).filter_map do |it|
        next unless it[:name] && it[:body]

        first = lines[it[:first]]
        impl = it[:function] && first.match(HEAD)&.[](1) == it[:name] && !it[:head].include?('noinline')
        body = code[it[:first]..it[:last]]
        it.merge(unit: ui, key: [ui, it[:first]], raw: lines[it[:first]..it[:last]], code: body, impl: impl,
                 static: first.match?(/\A(?:\[\[maybe_unused\]\] )?static\b/),
                 ids: impl ? body.join.scan(IDENT).flatten.to_set : Set.new)
      end
    end
  end

  # One blanked line per line, columns kept (a directive line is empty): what scan_lines reads as code.
  def blanked(lines)
    ShardOutput.scan_lines(lines).map { |info| info[:pp] ? '' : info[:code].chomp }
  end

  # Records each reference to a compiled `_impl` (refs) and, for every identifier, the items naming it (namers).
  def scan(item, defs, refs, namers)
    item[:code].each_with_index do |line, k|
      line.scan(IDENT) do
        name = Regexp.last_match(1)
        namers[name] << item[:name] unless name == item[:name]
        next unless defs.key?(name)
        next if name == item[:name] && k.zero?

        at = Regexp.last_match.begin(1)
        refs[name] << { item: item, line: item[:first] + k, col: at, call: line[(at + name.size)..].match?(/\A\s*\(/) }
      end
    end
  end

  # Identifiers the prelude's or the hooks' code names outside a declaration.
  def outside_names(prelude, hooks)
    names = Set.new
    [prelude, hooks].each do |text|
      lines = text.lines
      code = blanked(lines)
      ShardOutput.top_level_items(lines).each do |it|
        next unless it[:body]

        code[it[:first]..it[:last]].each { |l| l.scan(IDENT) { names << Regexp.last_match(1) } }
      end
    end
    names
  end

  # The one call site of `name`, or nil. Every other reference must be the callee's own wrapper, and a wrapper
  # anything names but its CROSS_UNIT_ROW thunk (bc2cpp_xrow_<wrapper>, dropped with it when no gem calls it) is live.
  def sole_site(name, list, namers, outside)
    sites = []
    list.each do |ref|
      item = ref[:item]
      # A recursive callee's copy would still call the original.
      return nil if item[:name] == name

      if wrapper?(item, name)
        w = item[:name]
        return nil unless live_wrappers? || (!outside.include?(w) && (namers[w] - [w, "bc2cpp_xrow_#{w}"]).empty?)

        next
      end
      return nil unless ref[:call]

      sites << ref
    end
    sites.size == 1 ? sites.first : nil
  end

  def wrapper?(item, name)
    item[:static] && item[:function] && item[:code].join.include?("bc2cpp_cfunc_result({M, M->gc.arena_idx, #{name}(")
  end

  # No mutable function-local static: the copy would hold a second instance of it.
  def copy_safe?(d)
    body = d[:code].join.sub(/\A[^{]*\{/, '')
    body.scan(/\bstatic\b[^=;{(]*/).all? { |decl| ShardOutput.constant_static?(decl) }
  end

  def drop_cycles!(eligible)
    eligible.keys.each do |name|
      next unless eligible.key?(name)

      seen = [name]
      parent = eligible[name][:item][:name]
      while eligible.key?(parent)
        if seen.include?(parent)
          seen.each { |n| eligible.delete(n) }
          break
        end
        seen << parent
        parent = eligible[parent][:item][:name]
      end
    end
  end

  def root_of(name, eligible)
    item = eligible[name][:item]
    item = eligible[item[:name]][:item] while eligible.key?(item[:name])
    item
  end

  def copy_name(name) = "#{PREFIX}#{name}"

  def copy_head(d)
    head = d[:head].sub(/\A(?:\[\[maybe_unused\]\] )?(?:static )?(?:inline )?/, '')
    "BC2CPP_COLO_ATTR static #{head.sub(/(?<![\w$])#{Regexp.escape(d[:name])}(?=\()/, copy_name(d[:name]))}"
  end

  # The callee's text under the copy's name and with internal linkage, its own qualifying calls renamed too.
  def copy_text(d, hits)
    lines = d[:raw].dup
    rename!(lines, hits.map { |h| h.merge(line: h[:line] - d[:first]) })
    lines[0] = lines[0].sub(/\A(?:\[\[maybe_unused\]\] )?(?:static )?(?:inline )?/, 'BC2CPP_COLO_ATTR static ')
                       .sub(/(?<![\w$])#{Regexp.escape(d[:name])}(?=\()/, copy_name(d[:name]))
    "\n#{lines.join}"
  end

  # Renames each call site (line, col, name) in place, right to left within a line.
  def rename!(lines, hits)
    hits.sort_by { |h| [h[:line], -h[:col]] }.each do |h|
      line = lines[h[:line]]
      raise ShardOutput::Error, "SHARD_COLOCATE: #{h[:name]} is not at its recorded site" unless line[h[:col], h[:name].size] == h[:name]

      lines[h[:line]] = line[0...h[:col]] + copy_name(h[:name]) + line[(h[:col] + h[:name].size)..]
    end
  end
end
