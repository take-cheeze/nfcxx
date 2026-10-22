# frozen_string_literal: true

require 'set'

# CORE_MIXINS: mruby's own Enumerable/Comparable as known mixins. The core Ruby methods bc2cpp once
# inlined from a verified model (Numeric#positive?/#negative?, Enumerable#min/#max) are no longer modelled: their
# receivers run the ordinary dispatch. The definer scan below is still what core_compare.rb and the source checks use.
module CoreMixins
  # Kernel is Object's own ancestor and is never re-included.
  NAMES = %w[Enumerable Comparable].freeze

  def self.core_mixin?(name)
    NAMES.include?(name.to_s.delete_prefix('::'))
  end

  # A def body without comments and blank lines, whitespace collapsed.
  def self.normalize(lines)
    lines.map { |line| line.chomp.sub(/\s#(?!\{).*\z/, '').strip }.reject { |line| line.empty? || line.start_with?('#') }
         .join(' ').gsub(/\s+/, ' ')
  end

  Definer = Struct.new(:owner, :path, :body, :alias_only, keyword_init: true)

  # Every def and alias of `name` in one Ruby source, with its enclosing
  # class/module, by indentation (how mruby's core is formatted).
  def self.definers_in(path, text, name)
    # Every match below needs the literal name, so a source without it has no definer (and the three
    # per-name regexes are built once, not once per line).
    return [] unless text.include?(name)

    quoted = Regexp.escape(name)
    def_re = /\A(\s*)def\s+(self\.)?#{quoted}(?![\w?!=<>])/
    alias_re = /\A\s*alias(?:_method)?\b.*[\s:,(]#{quoted}(?![\w?!=<>])/
    define_re = /define_method\s*\(?\s*:#{quoted}(?![\w?!=<>])/
    stack = []
    lines = text.lines
    lines.each_with_index.filter_map do |raw, index|
      line = raw.chomp
      if (m = line.match(/\A(\s*)(?:class|module)\s+([A-Z][\w:]*)/))
        stack << [m[1].size, m[2].split('::').last]
      elsif (m = line.match(/\A(\s*)end\b/)) && stack.last && stack.last[0] == m[1].size
        stack.pop
      end
      owner = stack.last ? stack.last[1] : '<top>'
      if (m = line.match(def_re))
        stop = (index + 1...lines.size).find { |i| lines[i].match?(/\A#{m[1]}end\b/) } || lines.size - 1
        Definer.new(owner: m[2] ? "#{owner}.singleton" : owner, path: path,
                    body: normalize(lines[index..stop]), alias_only: false)
      elsif line.match?(alias_re) || line.match?(define_re)
        Definer.new(owner: owner, path: path, body: nil, alias_only: true)
      end
    end
  end

  def self.suffix?(path, suffix)
    path == suffix || path.end_with?("/#{suffix}")
  end
end
