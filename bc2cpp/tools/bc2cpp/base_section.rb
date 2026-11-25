# frozen_string_literal: true

require 'set'
require_relative 'native_sigs'

# BaseSection: the base-stub part of sig/bc2cpp/declarations.rbs (and bc2cpp/sig/base_core.rbs), from the generators'
# output. The part runs from the top of the file to `# ---- block_types.rbs`.
#
# The section is a function of the generator output alone (canonical_section): one block pair per table tag, in byte
# order of the tag, never the order an earlier write or a merge left. So one source tree writes one text, and the check
# compares it byte for byte.
module BaseSection
  END_MARKER = '# ---- block_types.rbs'
  HEADER = /^# (Base RBS|Native base RBS|----)/
  MARKER = /^# bc2cpp-native: (\S+)$/
  NATIVE_HEADER = /\A# Native base RBS/
  DECL = /^(?:class|module) .*?\n^end\n/m

  # Gem directory name to the table tag the section uses(base_<tag>). Listed rather than derived: a gem whose name does
  # not give its tag (mruby-numeric-ext is base_numeric) would otherwise share one with another gem. A gem missing from
  # the table raises, so a new gem cannot silently join a block.
  TAGS = {
    'mruby-core' => 'base_mruby-core', 'mruby-dir' => 'base_dir', 'mruby-enumerator' => 'base_enumerator',
    'mruby-exit' => 'base_exit', 'mruby-fiber' => 'base_fiber', 'mruby-io' => 'base_io',
    'mruby-lcf' => 'base_lcf', 'mruby-marshal' => 'base_marshal', 'mruby-math' => 'base_math',
    'mruby-array-ext' => 'base_array', 'mruby-enum-ext' => 'base_enum', 'mruby-hash-ext' => 'base_hash',
    'mruby-range-ext' => 'base_range', 'mruby-rpgvx' => 'base_rpgvx', 'mruby-rpgxp' => 'base_rpgxp',
    'mruby-onig-regexp' => 'base_onig-regexp',
    'mruby-math-wio' => 'base_math-wio', 'mruby-mvjs' => 'base_mvjs', 'mruby-numeric-ext' => 'base_numeric',
    'mruby-kernel-ext' => 'base_kernel-ext', 'mruby-string-ext' => 'base_string-ext',
    'mruby-compar-ext' => 'base_compar', 'mruby-random' => 'base_random', 'mruby-rgss' => 'base_rgss', 'mruby-rpg2k' => 'base_rpg',
    'mruby-sprintf' => 'base_sprintf', 'mruby-stringio' => 'base_stringio', 'mruby-symbol-ext' => 'base_symbol',
    'mruby-time' => 'base_time',
    'mruby-wolf' => 'base_wolf', 'mruby-require' => 'base_require'
  }.freeze

  # The tags of mruby's own core gems (a gem directory under 3rd/mruby/mrbgems). Their base stubs live in
  # bc2cpp/sig/base_core.rbs; the rest stay in sig/bc2cpp/declarations.rbs.
  CORE_TAGS = %w[
    base_mruby-core base_dir base_enumerator base_exit base_fiber base_io base_math base_array base_enum base_hash
    base_range base_numeric base_kernel-ext base_string-ext base_compar base_random base_sprintf base_symbol base_time
  ].freeze

  # The core base stubs, in the nfcxx repository (bc2cpp/sig/base_core.rbs). The world's declarations.rbs keeps the rest.
  CORE_FILE = File.expand_path('../../sig/base_core.rbs', __dir__).freeze

  def self.core_file_text
    File.file?(CORE_FILE) ? File.read(CORE_FILE, encoding: 'UTF-8') : +''
  end

  RUBY_HEADER = "# Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.\n"
  NATIVE_HEADER_LINE = "# Native base RBS (scripts/bc2cpp/base_rbs_native.rb): mrb_define_* registrations, arity untyped.\n"

  # `base_section_check.rb --write` (and the check, which compares with it): [core file text, world file text]. Both are
  # canonical_section of the generator output, split by CORE_TAGS; the world keeps its preamble (above its first header)
  # and everything after the base section.
  def self.write_texts(text, bodies, by_tag, core: core_file_text)
    declared_section = section_of(text)
    preamble = declared_section.lines.take_while { |l| !l.match?(HEADER) }.join
    committed = committed_native_bodies(core + declared_section)
    (committed.keys - bodies.keys).sort.each do |tag|
      warn "base_section: the generators wrote no native body for #{tag}; its committed block is kept"
    end
    natives = committed.merge(bodies)
    core_tag = ->(tag, _) { CORE_TAGS.include?(tag) }
    core_text = canonical_section(natives.select(&core_tag), by_tag.select(&core_tag))
    rest_text = canonical_section(natives.reject(&core_tag), by_tag.reject(&core_tag))
    [core_text, preamble + rest_text + text[declared_section.length..]]
  end

  # Per tag in byte order: its native block, then its Ruby declarations (uniq, in generator order), each under its marker.
  def self.canonical_section(bodies, by_tag)
    (bodies.keys | by_tag.keys).sort.map do |tag|
      out = +''
      body = bodies[tag].to_s
      unless body.strip.empty?
        out << NATIVE_HEADER_LINE
        body.sub(/\n*\z/, "\n").each_line { |l| out << (l.match?(/^(module |class )/) ? "# bc2cpp-native: #{tag}\n#{l}" : l) }
        out << "\n"
      end
      decls = Array(by_tag[tag]).uniq
      out << RUBY_HEADER << decls.map { |d| "# bc2cpp-native: #{tag}\n#{d}" }.join << "\n" unless decls.empty?
      out
    end.join
  end

  # The native bodies a section holds, by tag, markers and headers dropped: what a tag keeps when the generators wrote it
  # none (its gem failed to preprocess here). Two blocks of one tag are joined.
  def self.committed_native_bodies(section)
    lines = section.lines
    starts = lines.each_index.select { |i| lines[i].match?(HEADER) }
    bodies = Hash.new { |h, k| h[k] = +'' }
    starts.each_with_index do |s, k|
      block = lines[s...(starts[k + 1] || lines.size)]
      next unless block.first.match?(NATIVE_HEADER)

      tag = block.filter_map { |l| l[MARKER, 1] }.first
      next unless tag

      body = block.drop(1).reject { |l| l.match?(MARKER) }.join.strip
      bodies[tag] << (bodies[tag].empty? ? '' : "\n\n") << body unless body.empty?
    end
    bodies.reject { |_, body| body.empty? }.transform_values { |body| "#{body}\n" }
  end

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
      body = File.readlines(path, encoding: 'UTF-8').drop_while { |l| l.match?(NATIVE_HEADER) || l.strip.empty? }.join
      bodies[tag_of(gem)] << body unless body.strip.empty?
    end
    bodies
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

  # The Ruby declarations the generator writes, one per top-level class or module. No tag is needed to compare them, so a
  # gem outside TAGS cannot fail the check; only the writer needs a tag (generated_ruby_by_tag).
  # With +hand+ (method_keys of the hand-written declarations), a stub whose method the hand sections already declare is
  # left out: the loader folds the two the same way, so the stub only repeats the declaration.
  def self.generated_ruby_decls(gen_dir, hand = nil)
    Dir[File.join(gen_dir, '*', 'ruby', '*.rbs')].sort.flat_map do |path|
      File.read(path, encoding: 'UTF-8').scan(DECL).map { |d| without_hand_methods(d.strip + "\n", hand) }
    end.sort
  end

  # Method keys [owner, name, singleton] declared by the given signature texts (a class or module's methods, by owner).
  # A native declaration (a `# bc2cpp-native:` table member) is not one: the loader folds it into the stub's entry, and
  # without the stub the method would be lost, so the stub stays.
  def self.method_keys(texts)
    require 'rbs'
    texts.each_with_object(Set.new) do |text, keys|
      _buffer, _directives, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: 'hand', content: text))
      decls.each do |decl|
        next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

        owner = decl.name.to_s.delete_prefix('::')
        decl.members.each do |m|
          next unless m.is_a?(RBS::AST::Members::MethodDefinition) && !NativeSigs.native?(m, [decl])

          keys << [owner, m.name.to_s, m.kind == :singleton]
        end
      end
    end
  end

  # A generated declaration without the methods in +hand+ (method_keys). Its class line stays, so the superclass does too.
  def self.without_hand_methods(decl, hand)
    return decl unless hand

    owner = decl[/\A(?:class|module) (\S+)/, 1].to_s.delete_prefix('::')
    decl.lines.reject do |line|
      m = line.match(/\A  def (self\.)?(\S+?):/)
      m && hand.include?([owner, m[2], !m[1].nil?])
    end.join
  end

  # The same declarations grouped by their table tag. The tag is what a committed declaration carries as its marker, so
  # a regenerated one is written under the marker it would have had: unmarked, it would count as a program declaration.
  def self.generated_ruby_by_tag(gen_dir, hand = nil)
    by_tag = Hash.new { |h, k| h[k] = [] }
    Dir[File.join(gen_dir, '*', 'ruby', '*.rbs')].sort.each do |path|
      tag = tag_of(File.basename(File.dirname(File.dirname(path))))
      File.read(path, encoding: 'UTF-8').scan(DECL).each { |d| by_tag[tag] << without_hand_methods(d.strip + "\n", hand) }
    end
    by_tag
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
