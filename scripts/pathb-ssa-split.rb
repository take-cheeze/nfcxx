# Splits one QBE module into chunks of functions, so QBE never holds the whole module (pathb-ssa-build's `assemble`).
#
# QBE takes a module at once, and its memory grows with the module: a ggml-vulkan unit (33 MB of IL) peaks at 42 GB in QBE
# alone. The functions are independent except for the symbols they share, so each chunk is a module of its own: the types,
# the module's data and its other lines (markers, which are comments) go with the first chunk, and the function definitions
# are grouped in order by size. A local symbol (no `export`) that a chunk uses but another chunk defines becomes global, and
# unique to this unit (NAME.sTAG), so two units cannot collide at the link. QBE numbers its labels (.Lbb12) per module, so
# the labels of each chunk are renamed before the assemblies are joined.
#
# split_module(il, target_bytes, tag) -> [chunk_il_array, renamed_il]. renamed_il is the whole module with the same renames
# (its markers name symbols too). A module within target_bytes is one chunk, unchanged.

module PathbSsaSplit
  SYM = /\$([^\s,()\[\]{}=]+)/
  DEF = /\A(?:export )?(?:function|data) (?:\w+ )?\$([^\s=(]+)/

  def self.def_name(line)
    line[DEF, 1]
  end

  def self.split_module(il, target_bytes, tag)
    lines = il.split("\n", -1)
    types = []; data = []; funcs = []; rest = []
    i = 0
    while i < lines.length
      l = lines[i]
      if l.start_with?("type ")
        types << l
      elsif l.start_with?("data ") || l.start_with?("export data ")
        data << l
      elsif l.start_with?("function ") || l.start_with?("export function ")
        start = i
        i += 1 while i < lines.length && lines[i] != "}"
        funcs << lines[start..i].join("\n")
      else
        rest << l
      end
      i += 1
    end
    return [[il], il] if funcs.sum(&:bytesize) <= target_bytes

    # the function definitions in order, grouped by size
    groups = [[]]
    size = 0
    funcs.each do |f|
      if size > 0 && size + f.bytesize > target_bytes
        groups << []
        size = 0
      end
      groups.last << f
      size += f.bytesize
    end

    # where each definition is: its chunk, and whether it is exported already
    defined = {}
    groups.each_with_index do |g, ci|
      g.each { |f| defined[def_name(f.lines.first)] = [ci, f.start_with?("export ")] }
    end
    data.each { |d| defined[def_name(d)] = [0, d.start_with?("export ")] }

    chunk_parts = lambda do |ci|
      parts = [types.join("\n")]
      parts << data.join("\n") << rest.join("\n") if ci == 0
      parts << groups[ci].join("\n\n")
      parts.reject(&:empty?).join("\n\n")
    end

    # the local symbols a chunk uses that another chunk defines: these become global and unique
    crossing = {}
    groups.each_index do |ci|
      uses = chunk_parts.call(ci).scan(SYM).flatten
      uses.each do |n|
        d = defined[n]
        crossing[n] = true if d && d[0] != ci && !d[1]
      end
    end
    rest.join("\n").scan(SYM).flatten.each do |n|
      d = defined[n]
      crossing[n] = true if d && d[0] != 0 && !d[1]
    end
    renames = {}
    crossing.each_key { |n| renames[n] = "#{n}.s#{tag}" }

    rename_text = lambda do |text|
      text.gsub(SYM) { renames.key?($1) ? "$#{renames[$1]}" : $& }
    end
    # a renamed definition is exported (the other chunks reference it)
    rename_def = lambda do |line|
      n = def_name(line)
      return line unless n && renames.key?(n)
      out = rename_text.call(line)
      out.start_with?("export ") ? out : "export " + out
    end
    rename_lines = lambda do |text|
      text.lines.map do |l|
        if l.start_with?("function ") || l.start_with?("data ")
          rename_def.call(l)
        else
          rename_text.call(l)
        end
      end.join
    end

    chunks = groups.each_index.map { |ci| rename_lines.call(chunk_parts.call(ci)) }
    full = rename_lines.call(il)
    [chunks, full]
  end

  # The assemblies of the chunks, joined: each chunk's local labels get the chunk's prefix.
  def self.join_asm(asms)
    asms.each_with_index.map { |a, ci| a.gsub(/\.L([A-Za-z0-9_]+)/) { ".Lc#{ci}_#{$1}" } }.join
  end
end
