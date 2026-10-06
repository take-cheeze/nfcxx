# frozen_string_literal: true

require 'set'
require_relative 'core_mixins'

# CORE_COMPARE (ADR 0362): mruby's Comparable#<, #<=, #> and #>= as a known body. bc2cpp_slow_lt & co. mirror it
# for String and Symbol receivers, so a build whose core sources differ from the model keeps the by-name helper.
# Same verification as CoreMixins (owner, file, normalized body, every other definer, the native registrations);
# scripts/bc2cpp_numeric_slow_check.rb fails when the real 3rd/mruby stops matching.
module CoreCompare
  OPS = %w[< <= > >=].freeze
  FILE = 'mrblib/compar.rb'
  # The only other Ruby definer of these names in the build's core: the Hash subset tests.
  OTHERS = [['Hash', 'mruby-hash-ext/mrblib/hash.rb']].freeze
  # Integer#< and Float#< share num_lt; no other native source registers the names.
  NATIVES = ['src/numeric.c'].freeze

  def self.body(op)
    CoreMixins.normalize([
      "def #{op} other\n", "cmp = self <=> other\n", "if cmp.nil?\n",
      "raise ArgumentError, \"comparison of \#{self.class} with \#{other.class} failed\"\n", "end\n", "cmp #{op} 0\n", "end\n"
    ])
  end

  # The operators the sources still match. +ruby_paths+: FOREIGN_RUBY_SRCS; +native_sources+: name -> files.
  def self.verified(ruby_paths, native_sources)
    return Set.new if ruby_paths.nil? || native_sources.nil?

    texts = ruby_paths.to_h { |path| [path, File.read(path, encoding: 'UTF-8')] }
    expected = OTHERS.map { |owner, file| [owner, file] }.sort
    OPS.each_with_object(Set.new) do |op, ok|
      found = texts.flat_map { |path, text| CoreMixins.definers_in(path, text, op) }
      primary = found.select { |d| d.owner == 'Comparable' && CoreMixins.suffix?(d.path, FILE) && !d.alias_only }
      rest = found - primary
      next unless primary.one? && primary.first.body == body(op)
      next unless rest.map { |d| [d.owner, OTHERS.find { |_, f| CoreMixins.suffix?(d.path, f) }&.last] }.sort == expected
      next unless native_sources.fetch(op, []).all? { |path| NATIVES.any? { |f| CoreMixins.suffix?(path, f) } }

      ok << op
    end
  end
end
