# frozen_string_literal: true

# Source-level review annotations for the bc2cpp gates (NOMETHOD, STRICT_HINT, PROVEN_MISS, CONSTANT).
#
# A reviewed site is marked where it is written, not in a central list. A reviewer adds, on the line of the site or
# on the line directly above it:
#   # bc2cpp-reviewed: nomethod name -- why the fallback is dead
# The gate reads that comment from the source file the site came from. A site without one fails the build, and an
# annotation that no longer matches a site is stale (scripts/bc2cpp/source_review_check.rb reports it on a full run).
#
# The gate and spec are matched exactly: `gate` is the gate's name, `spec` what the gate keys on (for nomethod the
# called name; for strict_hint "<family> <name>"; for proven_miss "<kind> <Class>.<name>"; for constant nothing).
# The reason after ` -- ` is for the reader; it is not compared.
module SourceReview
  TAG = 'bc2cpp-reviewed:'
  # A comment that starts with `#`, then the tag: `# bc2cpp-reviewed:`.
  COMMENT_START = /#\s*\z/

  module_function

  # The `gate spec` string a site is matched against ("constant" when the gate keys on nothing else).
  def key(gate, spec = nil)
    [gate, spec].compact.reject { |s| s.to_s.empty? }.join(' ')
  end

  # Whether the source at `file`, line `line` carries an annotation for `key` on that line, the one above, or the
  # one above the statement it continues (a line ending in a backslash joins the next). A missing file, or a line 0 (no
  # source line behind the site), is not reviewed.
  def annotated?(file, line, key)
    return false unless line.to_i.positive? && File.file?(file.to_s)

    lines = source(file)
    annotation_lines(file, line).any? { |n| annotation_keys(lines[n - 1]).include?(key) }
  end

  # The 1-indexed lines that can carry the annotation for a site at `line`: the site's own line, the line above it,
  # and the line above the statement it belongs to.
  def annotation_lines(file, line)
    lines = source(file)
    [line, line - 1, statement_start(lines, line) - 1].select { |n| n >= 1 && n <= lines.size }.uniq
  end

  # The 1-indexed first line of the statement `line` belongs to: the start of a backslash-continued run.
  def statement_start(lines, line)
    start = line
    start -= 1 while start >= 2 && lines[start - 2].rstrip.end_with?('\\')
    start
  end

  # Every annotation in `file` as [line, key].
  def annotations(file)
    source(file).each_with_index.flat_map do |text, i|
      annotation_keys(text).map { |k| [i + 1, k] }
    end
  end

  # The keys the line's bc2cpp-reviewed comment names: the part before ` -- `, split on commas (one line can hold
  # several sends with different names).
  def annotation_keys(text)
    i = text.index(TAG)
    return [] unless i && text[0...i].match?(COMMENT_START)

    body = text[(i + TAG.size)..].split(' -- ', 2).first.to_s
    body.split(',').map { |k| k.strip.squeeze(' ') }.reject(&:empty?)
  end

  # Source lines of `file`, read once per run.
  def source(file)
    @sources ||= {}
    @sources[file] ||= File.readlines(file, encoding: 'UTF-8')
  end
end
