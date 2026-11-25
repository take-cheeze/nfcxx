#!/usr/bin/env ruby
# frozen_string_literal: true

# Diff test for the base section writer (tools/bc2cpp/base_section.rb, `base_section_check.rb --write`). Host only, no
# clang and no closed build: the generators' output is replaced by fixture directories in the shape base_rbs_all.rb writes.
#
#   ruby scripts/bc2cpp/base_section_regen_check.rb
#
# Checks: the written section matches the generator (a stale declaration goes, a missing one and a missing native block
# come back under their marker); the rest of the file is kept byte for byte; writing again changes nothing; the output
# does not depend on the order or the markers the committed section had; and the committed files are canonical.

require_relative '../../tools/bc2cpp/world_root'
require 'set'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/bc2cpp/base_section'

ROOT = BC2CPP_WORLD_ROOT
DECLARATIONS = File.join(ROOT, 'sig/bc2cpp/declarations.rbs')
failures = []
checks = 0
check = lambda do |what, condition|
  checks += 1
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~RBS
  # ---- base stubs (fixture)
  # Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.
  # bc2cpp-native: base_math
  class Stale
    def x: () -> untyped
  end

  # bc2cpp-native: base_math
  class Kept
    def y: () -> untyped
  end

  # Native base RBS (scripts/bc2cpp/base_rbs_native.rb): mrb_define_* registrations, arity untyped.
  # bc2cpp-native: base_math
  module Math
    def sqrt: (untyped) -> untyped
  end

  # Native base RBS (scripts/bc2cpp/base_rbs_native.rb): mrb_define_* registrations, arity untyped.
  # bc2cpp-native: base_fiber
  class Fiber
    def resume: () -> untyped
  end

  # ---- block_types.rbs
  class Program
    def run: () -> Integer
  end
RBS

# Writes the generator's output shape for each gem: <gem>/native.rbs (header, then the body) and <gem>/ruby/*.rbs.
def write_gen(dir, natives: {}, ruby: {})
  natives.each do |gem, body|
    FileUtils.mkdir_p(File.join(dir, gem))
    File.write(File.join(dir, gem, 'native.rbs'), "# Native base RBS (scripts/bc2cpp/base_rbs_native.rb): fixture\n#{body}")
  end
  ruby.each do |gem, decls|
    FileUtils.mkdir_p(File.join(dir, gem, 'ruby'))
    File.write(File.join(dir, gem, 'ruby', 'decls.rbs'), decls)
  end
end

# Each declaration of the section's `# Base RBS` blocks with its marker's tag, for the round trip.
def tagged_decls(section)
  lines = section.lines
  starts = lines.each_index.select { |i| lines[i].match?(BaseSection::HEADER) }
  starts.each_with_index.flat_map do |s, k|
    block = lines[s...(starts[k + 1] || lines.size)]
    next [] unless block.first.match?(/\A# Base RBS/)

    block.join.scan(/^(?:# bc2cpp-native: (\S+)\n)?((?:class|module) .*?\n^end\n)/m)
  end
end

# write_texts with the generator output read from +gen+, as base_section_check.rb --write calls it.
def write_from(text, gen, core: '')
  BaseSection.write_texts(text, BaseSection.native_bodies(gen), BaseSection.generated_ruby_by_tag(gen), core: core)
end

puts 'fixture: a stale declaration, a changed native body, a missing declaration and native block, an unknown table'
Dir.mktmpdir('base-section-regen') do |gen|
  write_gen(gen,
            natives: { 'mruby-math' => "module Math\n  def sqrt: (untyped) -> untyped\n  def cbrt: (untyped) -> untyped\nend\n",
                       'mruby-lcf' => "module LCF\n  def rom_keys: (untyped) -> untyped\nend\n" },
            ruby: { 'mruby-math' => "class Kept\n  def y: () -> untyped\nend\n\nclass Added\n  def z: () -> untyped\nend\n" })
  once_core, once = write_from(FIXTURE, gen)
  twice = write_from(once, gen, core: once_core)
  # base_math and base_fiber are core tags, so their blocks are in the core text.
  section = once_core + BaseSection.section_of(once)

  check.call('the rest of the file after the base section is byte for byte the same',
             once[BaseSection.section_of(once).length..] == FIXTURE[BaseSection.section_of(FIXTURE).length..])
  check.call('the changed native body is written (cbrt present)', section.include?("  def cbrt: (untyped) -> untyped\n"))
  check.call('a native block the section lacks is written under its tag', section.include?("# bc2cpp-native: base_lcf\nmodule LCF\n"))
  check.call('a table with no generator body keeps its block', section.include?("# bc2cpp-native: base_fiber\nclass Fiber\n"))
  check.call('the stale declaration is removed', !section.include?('class Stale'))
  check.call('the missing declaration is written under its tag', section.include?("# bc2cpp-native: base_math\nclass Added\n"))
  check.call('the kept declaration is not duplicated', section.scan('class Kept').size == 1)
  check.call('the Ruby declarations now match the generator',
             BaseSection.ruby_decls(section) == BaseSection.generated_ruby_decls(gen))
  check.call('the tags are in byte order, each native block before its Ruby declarations',
             section.scan(/^# bc2cpp-native: (\S+)$/).flatten.chunk_while { |x, y| x == y }.map(&:first) ==
               %w[base_fiber base_math base_lcf])
  check.call('running it again changes nothing', twice == [once_core, once])
end

puts 'the output depends on the generator output only, not on the committed layout'
Dir.mktmpdir('base-section-regen') do |gen|
  write_gen(gen, natives: { 'mruby-math' => "module Math\n  def sqrt: (untyped) -> untyped\nend\n" },
                 ruby: { 'mruby-math' => "class Kept\n  def y: () -> untyped\nend\n",
                         'mruby-rpg2k' => "class Game\n  def run: () -> untyped\nend\n" })
  canonical = write_from(FIXTURE, gen)
  # The same declarations, reordered, split over several blocks, under a stale tag and with no marker.
  shuffled = +<<~RBS
    # ---- base stubs (fixture)
    # Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.
    # bc2cpp-native: base_rpg2k
    class Game
      def run: () -> untyped
    end
    # Native base RBS (scripts/bc2cpp/base_rbs_native.rb): mrb_define_* registrations, arity untyped.
    # bc2cpp-native: base_fiber
    class Fiber
      def resume: () -> untyped
    end

    # Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.
    class Kept
      def y: () -> untyped
    end

    # Native base RBS (scripts/bc2cpp/base_rbs_native.rb): mrb_define_* registrations, arity untyped.
    # bc2cpp-native: base_math
    module Math
      def old: () -> untyped
    end

  RBS
  shuffled += FIXTURE[BaseSection.section_of(FIXTURE).length..]
  check.call('a reordered, re-tagged section writes the same bytes', write_from(shuffled, gen) == canonical)
  check.call('so does the canonical output itself', write_from(canonical.last, gen, core: canonical.first) == canonical)
end

puts 'the --write split: core tags go to the core file, the world keeps its preamble and the rest of the file'
WORLD = <<~RBS
  # world preamble
  # Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.
  # Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.
  # bc2cpp-native: base_rpg2k
  class Kept
    def y: () -> untyped
  end

  # ---- block_types.rbs
  class Program
    def run: () -> Integer
  end
RBS
CORE = <<~RBS
  # Base RBS (scripts/bc2cpp/base_rbs.rb): shapes from the AST, no types.
  # bc2cpp-native: base_enum
  module Enumerable
    def each_slice: (untyped) -> untyped
  end

RBS
write_by_tag = { 'base_rpg' => ["class Kept\n  def y: () -> untyped\nend\n"],
                 'base_array' => ["class Array\n  def bsearch: () -> untyped\nend\n"],
                 'base_enum' => ["module Enumerable\n  def each_slice: (untyped) -> untyped\nend\n"] }
core1, world1 = BaseSection.write_texts(WORLD, {}, write_by_tag, core: CORE)
core2, world2 = BaseSection.write_texts(world1, {}, write_by_tag, core: core1)
check.call('the core declarations are in the core file, in tag order, and not in the world',
           core1.index('class Array') && core1.index('module Enumerable') && core1.index('class Array') < core1.index('module Enumerable') &&
             !world1.include?('class Array'))
check.call('the world keeps its preamble, its own declaration under its tag and the rest of the file',
           world1.start_with?("# world preamble\n# Base RBS") && world1.include?("# bc2cpp-native: base_rpg\nclass Kept\n") &&
           world1.end_with?(WORLD[BaseSection.section_of(WORLD).length..]))
check.call('a second write changes neither file', core2 == core1 && world2 == world1)

puts 'committed files: written again from their own content, they are byte for byte the same (canonical)'
committed = File.read(DECLARATIONS, encoding: 'UTF-8')
committed_core = BaseSection.core_file_text
combined = committed_core + BaseSection.section_of(committed)
bodies = BaseSection.committed_native_bodies(combined)
by_tag = Hash.new { |h, k| h[k] = [] }
tagged_decls(combined).each { |tag, decl| by_tag[tag] << decl }
check.call('every Ruby declaration of the committed base sections carries a tag',
           !by_tag.key?(nil) && by_tag.values.flatten.size == BaseSection.ruby_decls(combined).size)
core_again, world_again = by_tag.key?(nil) ? [nil, nil] : BaseSection.write_texts(committed, bodies, by_tag, core: committed_core)
check.call('the world file is canonical', world_again == committed)
check.call('the core file is canonical', core_again == committed_core)
BaseSection.first_differences(committed, world_again).each { |line| warn line } if world_again && world_again != committed
BaseSection.first_differences(committed_core, core_again).each { |line| warn line } if core_again && core_again != committed_core

puts 'the comparison needs no tag; every gem with Ruby sources has one'
Dir.mktmpdir('base-section-regen') do |gen|
  write_gen(gen, ruby: { 'mruby-not-in-table' => "class Unlisted\n  def y: () -> untyped\nend\n" })
  check.call('a gem outside the tag table is compared, not refused',
             BaseSection.generated_ruby_decls(gen) == ["class Unlisted\n  def y: () -> untyped\nend\n"])
end
puts 'a stub whose method the hand sections declare is left out; a native declaration does not count as one'
hand_text = "class Box\n  def fill: () -> String\n  def self.make: () -> Box\nend\n" \
            "# bc2cpp-native: core_results\nclass Native\n  def keep: () -> String\nend\n"
hand = BaseSection.method_keys([hand_text])
check.call('hand keys hold the instance and singleton methods of each class',
           hand == Set[['Box', 'fill', false], ['Box', 'make', true]])
check.call('the native declaration is not a hand key', !hand.include?(['Native', 'keep', false]))
stub = "class Box < Base\n  def fill: () -> untyped\n  def other: (untyped) -> untyped\n  def self.make: () -> untyped\nend\n"
check.call('a hand-declared stub is removed, the others and the class line stay',
           BaseSection.without_hand_methods(stub, hand) == "class Box < Base\n  def other: (untyped) -> untyped\nend\n")
check.call('no hand keys leaves a stub as it is', BaseSection.without_hand_methods(stub, nil) == stub)
require_relative '../../scripts/bc2cpp/base_rbs_all'
abort 'base section regen check: 3rd/mruby is missing; the gem list needs it' unless File.directory?(File.join(ROOT, '3rd/mruby'))
untagged = BaseRbsAll.gems.select { |gem| !BaseRbsAll.ruby_sources(gem).empty? }.map { |gem| File.basename(gem) }
                      .reject { |name| BaseSection::TAGS.key?(name) }
check.call("every repo gem with Ruby sources has a base section tag (#{untagged.join(', ')} missing)", untagged.empty?)

if failures.empty?
  puts "base section regen check: #{checks} checks passed"
else
  warn "base section regen check: #{failures.size} of #{checks} failed"
  exit 1
end
