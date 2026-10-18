# frozen_string_literal: true

# BaseSection: the base-stub part of sig/bc2cpp/declarations.rbs, from the generators' output. The part runs from the top
# of the file to `# ---- block_types.rbs`. Its native blocks (a `# Native base RBS` header) are regenerated per tag by
# scripts/bc2cpp/base_rbs_native.rb's output; its Ruby blocks (a `# Base RBS` header) are compared as declarations.
#
# The check compares what is committed with what the generators write now. A native block must match byte for byte,
# so a changed generator or a hand edit shows up as the first differing lines. A Ruby declaration is compared as text
# with its marker removed, as a set, because the committed order is not one the generator writes.
module BaseSection
  END_MARKER = '# ---- block_types.rbs'
  HEADER = /^# (Base RBS|Native base RBS|----)/
  MARKER = /^# bc2cpp-native: (\S+)$/
  NATIVE_HEADER = /\A# Native base RBS/
  DECL = /^(?:class|module) .*?\n^end\n/m

  # Gem directory name to the table tag the section uses (base_<tag>). Listed rather than derived: a gem whose name does
  # not give its tag (mruby-numeric-ext is base_numeric) would otherwise share one with another gem (mruby-math-wio is
  # base_math-wio, not base_math). A gem missing from the table raises, so a new gem cannot silently join a block.
  TAGS = {
    'mruby-core' => 'base_mruby-core', 'mruby-dir' => 'base_dir', 'mruby-exit' => 'base_exit', 'mruby-fiber' => 'base_fiber', 'mruby-io' => 'base_io',
    'mruby-lcf' => 'base_lcf', 'mruby-marshal' => 'base_marshal', 'mruby-math' => 'base_math',
    'mruby-math-wio' => 'base_math-wio', 'mruby-mvjs' => 'base_mvjs', 'mruby-numeric-ext' => 'base_numeric',
    'mruby-random' => 'base_random', 'mruby-rgss' => 'base_rgss', 'mruby-rpg2k' => 'base_rpg',
    'mruby-sprintf' => 'base_sprintf', 'mruby-stringio' => 'base_stringio', 'mruby-time' => 'base_time',
    'mruby-wolf' => 'base_wolf'
  }.freeze

  def self.tag_of(gem)
    TAGS.fetch(gem) { raise "bc2cpp: #{gem} has no base section tag (add it to BaseSection::TAGS)" }
  end

  # The part of the committed file this check owns.
  def self.section_of(text)
    cut = text.index(END_MARKER)
    raise 'bc2cpp: sig/bc2cpp/declarations.rbs has no `# ---- block_types.rbs` line' unless cut

    text[0...cut]
  end

  # Native bodies from the generator's output directory, grouped by tag, header lines dropped.
  def self.native_bodies(gen_dir)
    bodies = Hash.new { |h, k| h[k] = +'' }
    Dir[File.join(gen_dir, '*', 'native.rbs')].sort.each do |path|
      gem = File.basename(File.dirname(path))
      body = File.readlines(path).drop_while { |l| l.match?(NATIVE_HEADER) || l.strip.empty? }.join
      bodies[tag_of(gem)] << body unless body.strip.empty?
    end
    bodies
  end

  # The committed section with each native block replaced by the generator's body for its tag. A tag with no body
  # is left as it is.
  def self.regenerate_native(section, gen_dir)
    lines = section.lines
    bodies = native_bodies(gen_dir)
    starts = lines.each_index.select { |i| lines[i].match?(HEADER) }
    blocks = starts.each_with_index.map { |s, k| [s, starts[k + 1] || lines.size] }
    out = lines[0...starts.first].join
    emitted = {}
    blocks.each do |s, e|
      block = lines[s...e]
      tag = block.filter_map { |l| l[MARKER, 1] }.first
      unless block.first.match?(NATIVE_HEADER) && tag && bodies.key?(tag)
        out << block.join
        next
      end
      next if emitted[tag]

      emitted[tag] = true
      out << block.first
      bodies[tag].each_line { |l| out << (l.match?(/^(module |class )/) ? "# bc2cpp-native: #{tag}\n#{l}" : l) }
      out << "\n" if block.last.strip.empty?
    end
    out
  end

  # The native blocks of a section, one string per tag, for a byte comparison.
  def self.native_text(section)
    lines = section.lines
    starts = lines.each_index.select { |i| lines[i].match?(HEADER) }
    blocks = starts.each_with_index.map { |s, k| [s, starts[k + 1] || lines.size] }
    blocks.filter_map do |s, e|
      block = lines[s...e]
      next unless block.first.match?(NATIVE_HEADER)

      block.join
    end.join
  end

  # Ruby declarations of a section (its `# Base RBS` blocks only), as normalised text with the marker lines removed.
  def self.ruby_decls(section)
    lines = section.lines
    starts = lines.each_index.select { |i| lines[i].match?(HEADER) }
    blocks = starts.each_with_index.map { |s, k| [s, starts[k + 1] || lines.size] }
    text = blocks.filter_map do |s, e|
      block = lines[s...e]
      next if block.first.match?(NATIVE_HEADER) || !block.first.match?(/\A# Base RBS/)

      block.reject { |l| l.match?(MARKER) }.join
    end.join
    text.scan(DECL).map { |d| d.strip + "\n" }.sort
  end

  # The Ruby declarations the generator writes, one per top-level class or module.
  def self.generated_ruby_decls(gen_dir)
    Dir[File.join(gen_dir, '*', 'ruby', '*.rbs')].sort.flat_map do |path|
      File.read(path).scan(DECL).map { |d| d.strip + "\n" }
    end.sort
  end

  # The first lines where two texts differ, for the failure message.
  def self.first_differences(committed, regenerated, limit: 12)
    a = committed.lines
    b = regenerated.lines
    index = (0...[a.size, b.size].max).find { |i| a[i] != b[i] }
    return [] unless index

    (index...[index + limit, a.size, b.size].max).filter_map do |i|
      next if a[i] == b[i]

      "  line #{i + 1}\n    committed:   #{a[i].to_s.chomp}\n    regenerated: #{b[i].to_s.chomp}"
    end.first(limit)
  end
end
