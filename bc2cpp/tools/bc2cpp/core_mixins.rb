# frozen_string_literal: true

require 'set'

# CORE_MIXINS (docs/adr/0261): mruby's own Enumerable/Comparable as known
# mixins, and the core Ruby methods bc2cpp inlines (Numeric#positive?/#negative?,
# Enumerable#min/#max). Each inlined method is named by owner, file, normalized
# body and every other core definer, and stays active only while the build's
# core sources still say exactly that; scripts/bc2cpp_core_mixins_check.rb
# fails when they stop, so the model gets reviewed instead of going stale.
module CoreMixins
  # Kernel is Object's own ancestor and is never re-included.
  NAMES = %w[Enumerable Comparable].freeze

  def self.core_mixin?(name)
    NAMES.include?(name.to_s.delete_prefix('::'))
  end

  # A def body without comments and blank lines, whitespace collapsed.
  def self.normalize(lines)
    lines.map { |line| line.chomp.sub(/\s#.*\z/, '').strip }.reject { |line| line.empty? || line.start_with?('#') }
         .join(' ').gsub(/\s+/, ' ')
  end

  # `others`: the remaining core Ruby definers ([owner, file suffix]); `natives`:
  # the native sources allowed to register the name.
  Method = Struct.new(:name, :owner, :file, :body, :others, :natives, keyword_init: true)

  MIN_BODY = <<~RUBY
    def min(&block)
      flag = true
      result = nil
      self.each {|*val|
        val = val.__svalue
        if flag
          result = val
          flag = false
        else
          if block
            result = val if block.call(val, result) < 0
          else
            result = val if (val <=> result) < 0
          end
        end
      }
      result
    end
  RUBY

  MAX_BODY = MIN_BODY.sub('def min', 'def max').sub('.call(val, result) < 0', '.call(val, result) > 0')
                     .sub('(val <=> result) < 0', '(val <=> result) > 0')

  RANGE_EXT = 'mruby-range-ext/mrblib/range.rb'

  METHODS = [
    Method.new(name: 'positive?', owner: 'Numeric', file: 'mruby-numeric-ext/mrblib/numeric_ext.rb',
               body: normalize(["def positive?\n", "self > 0\n", "end\n"]), others: [], natives: []),
    Method.new(name: 'negative?', owner: 'Numeric', file: 'mruby-numeric-ext/mrblib/numeric_ext.rb',
               body: normalize(["def negative?\n", "self < 0\n", "end\n"]), others: [], natives: []),
    Method.new(name: 'min', owner: 'Enumerable', file: 'mrblib/enum.rb', body: normalize(MIN_BODY.lines),
               others: [['Range', RANGE_EXT]], natives: ['mruby-time/src/time.c']),
    Method.new(name: 'max', owner: 'Enumerable', file: 'mrblib/enum.rb', body: normalize(MAX_BODY.lines),
               others: [['Range', RANGE_EXT]], natives: [])
  ].freeze

  Definer = Struct.new(:owner, :path, :body, :alias_only, keyword_init: true)

  # Every def and alias of `name` in one Ruby source, with its enclosing
  # class/module, by indentation (how mruby's core is formatted).
  def self.definers_in(path, text, name)
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
      if (m = line.match(/\A(\s*)def\s+(self\.)?#{Regexp.escape(name)}(?![\w?!=])/))
        stop = (index + 1...lines.size).find { |i| lines[i].match?(/\A#{m[1]}end\b/) } || lines.size - 1
        Definer.new(owner: m[2] ? "#{owner}.singleton" : owner, path: path,
                    body: normalize(lines[index..stop]), alias_only: false)
      elsif line.match?(/\A\s*alias(?:_method)?\b.*[\s:,(]#{Regexp.escape(name)}(?![\w?!=])/) ||
            line.match?(/define_method\s*\(?\s*:#{Regexp.escape(name)}(?![\w?!=])/)
        Definer.new(owner: owner, path: path, body: nil, alias_only: true)
      end
    end
  end

  def self.suffix?(path, suffix)
    path == suffix || path.end_with?("/#{suffix}")
  end

  # Names of METHODS the sources still match. +ruby_paths+: FOREIGN_RUBY_SRCS;
  # +native_sources+: name -> native files registering it.
  def self.verified(ruby_paths, native_sources)
    return Set.new if ruby_paths.nil? || native_sources.nil?

    texts = ruby_paths.to_h { |path| [path, File.read(path, encoding: 'UTF-8')] }
    METHODS.each_with_object(Set.new) do |model, ok|
      found = texts.flat_map { |path, text| definers_in(path, text, model.name) }
      primary = found.select { |d| d.owner == model.owner && suffix?(d.path, model.file) && !d.alias_only }
      rest = found - primary
      expected = model.others.map { |owner, file| [owner, file] }.sort
      next unless primary.one? && primary.first.body == model.body
      next unless rest.map { |d| [d.owner, model.others.find { |_, f| suffix?(d.path, f) }&.last] }.sort == expected
      next unless native_sources.fetch(model.name, []).all? { |path| model.natives.any? { |f| suffix?(path, f) } }

      ok << model.name
    end
  end
end
