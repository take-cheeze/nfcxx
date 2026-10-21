#!/usr/bin/env ruby
# frozen_string_literal: true

# Diff test for the base section writer (tools/bc2cpp/base_section.rb, `base_section_check.rb --write`). Host only, no
# clang and no closed build: the generators' output is replaced by fixture directories in the shape base_rbs_all.rb writes.
#
#   ruby scripts/bc2cpp/base_section_regen_check.rb
#
# Checks: a regenerated section passes the comparisons the base section check makes; the rest of the file is kept byte for
# byte; a stale declaration goes and a missing one comes back under its marker; running it again changes nothing; and
# the committed file regenerates from its own content with no diff.

require 'set'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/bc2cpp/base_section'

ROOT = File.expand_path('../..', __dir__)
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

def ruby_text(section)
  BaseSection.ruby_decls(section).join
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

def native_bodies_of(section)
  lines = section.lines
  starts = lines.each_index.select { |i| lines[i].match?(BaseSection::HEADER) }
  starts.each_with_index.filter_map do |s, k|
    block = lines[s...(starts[k + 1] || lines.size)]
    next unless block.first.match?(BaseSection::NATIVE_HEADER)

    tag = block.filter_map { |l| l[BaseSection::MARKER, 1] }.first
    body = block.drop(1).reject { |l| l.match?(BaseSection::MARKER) }.join.rstrip + "\n"
    [tag, body]
  end
end

puts 'fixture: a stale declaration, a changed native body, a missing declaration, an unknown table'
Dir.mktmpdir('base-section-regen') do |gen|
  write_gen(gen,
            natives: { 'mruby-math' => "module Math\n  def sqrt: (untyped) -> untyped\n  def cbrt: (untyped) -> untyped\nend\n" },
            ruby: { 'mruby-math' => "class Kept\n  def y: () -> untyped\nend\n\nclass Added\n  def z: () -> untyped\nend\n" })
  once = BaseSection.regenerate(FIXTURE, gen)
  twice = BaseSection.regenerate(once, gen)
  section = BaseSection.section_of(once)

  check.call('the rest of the file after the base section is byte for byte the same',
             once[section.length..] == FIXTURE[BaseSection.section_of(FIXTURE).length..])
  check.call('the changed native body is written (cbrt present)', BaseSection.native_text(section).include?('def cbrt'))
  check.call('a table with no generator body keeps its block', BaseSection.native_text(section).include?('class Fiber'))
  check.call('the stale declaration is removed', !section.include?('class Stale'))
  check.call('the missing declaration is appended under its tag',
             section.include?("# bc2cpp-native: base_math\nclass Added\n"))
  check.call('the kept declaration is not duplicated', section.scan('class Kept').size == 1)
  check.call('the Ruby declarations now match the generator',
             BaseSection.ruby_decls(section) == BaseSection.generated_ruby_decls(gen))
  check.call('the native blocks now match the regenerated bodies',
             BaseSection.native_text(section) == BaseSection.native_text(BaseSection.regenerate_native(section, gen)))
  check.call('running it again changes nothing', twice == once)
  check.call('a section that already matches is returned unchanged',
             BaseSection.regenerate(once, gen) == once)
end

puts 'fixture: a section whose Ruby declarations are all current, with an unknown gem'
Dir.mktmpdir('base-section-regen') do |gen|
  write_gen(gen, ruby: { 'mruby-math' => "class Kept\n  def y: () -> untyped\nend\n" })
  section = BaseSection.section_of(FIXTURE)
  check.call('a Ruby declaration in the generator but not in the section is never dropped as stale',
             BaseSection.ruby_decls(BaseSection.regenerate_ruby(section, gen)).include?("class Kept\n  def y: () -> untyped\nend\n"))
end

puts 'committed file: regenerating from its own content is a no-op'
committed = File.read(DECLARATIONS)
bodies = native_bodies_of(BaseSection.section_of(committed)).group_by(&:first).transform_values { |rows| rows.map(&:last).join }
by_tag = Hash.new { |h, k| h[k] = [] }
tagged_decls(BaseSection.section_of(committed)).each { |tag, decl| by_tag[tag] << decl }
check.call('every Ruby declaration of the committed base section is an input to the round trip',
             by_tag.values.flatten.size == BaseSection.ruby_decls(BaseSection.section_of(committed)).size)
regenerated = BaseSection.regenerate_with(committed, bodies, by_tag)
check.call('the regenerated file is identical to the committed one', regenerated == committed)
BaseSection.first_differences(committed, regenerated).each { |line| warn line } unless regenerated == committed

puts 'the comparison needs no tag; every gem with Ruby sources has one'
Dir.mktmpdir('base-section-regen') do |gen|
  write_gen(gen, ruby: { 'mruby-not-in-table' => "class Unlisted\n  def y: () -> untyped\nend\n" })
  check.call('a gem outside the tag table is compared, not refused',
             BaseSection.generated_ruby_decls(gen) == ["class Unlisted\n  def y: () -> untyped\nend\n"])
end
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
