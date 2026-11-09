# frozen_string_literal: true

require 'prism'

# One Prism parse per file text per generator process. Class-body, class-graph, owner, iterator-driver,
# lint and foreign-Ruby scans share unchanged syntax. Only parsing is shared; each consumer still
# derives its own facts and must not mutate the tree.
#
# An entry is kept per path, with the exact bytes it was parsed from. A lookup hits only when those
# bytes are equal to the requested ones, so different text never gets another text's tree, and a
# rewritten file (a check's fixture) replaces its entry instead of growing the cache. The bytes are
# compared, not the encoding: Prism parses the bytes and ignores the Ruby string's encoding
# (scripts/bc2cpp/ruby_parse_cache_check.rb).
#
# Trees are shared unfrozen. Prism 1.5 memoizes Node#location on first use, so a frozen node raises
# on that read; the consumers here only visit the tree and never write to it, which the check
# exercises. A consumer that did need to write must parse its own copy.
module RubyParseCache
  @trees = {}

  module_function

  # Prism.parse_file(path), read once per call and parsed once per text.
  def parse_file(path)
    parse(File.binread(path), path)
  end

  # Prism.parse(source, filepath: path). `source` is the exact text the caller would have parsed.
  def parse(source, path)
    bytes = source.b
    hit = @trees[path]
    return hit[1] if hit && hit[0] == bytes

    tree = Prism.parse(source, filepath: path)
    @trees[path] = [bytes.freeze, tree]
    tree
  end

  # Forgets every entry (used by the check; the generator never needs it).
  def clear
    @trees.clear
  end
end
