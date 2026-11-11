# StringScanner: the methods bc2cpp uses (scan, check, skip, skip_until, match?, eos?, pos, matched, matched_size, []). Positions are byte offsets,
# as in CRuby. Each match is anchored at the position by a cached \A(?:...) form of the pattern.
class StringScanner
  attr_reader :string, :matched
  attr_accessor :pos

  def initialize(string)
    @string = string
    @pos = 0
    @matched = nil
    @match = nil
    @anchored = {}
  end

  def eos?
    @pos >= @string.bytesize
  end

  def rest
    @string.byteslice(@pos, @string.bytesize - @pos)
  end

  # Matches at the position and advances past the match; returns the matched text or nil.
  def scan(pattern)
    match = anchored(pattern).match(rest)
    return nil unless match

    @match = match
    @matched = match[0]
    @pos += @matched.bytesize
    @matched
  end

  # Like scan, without advancing.
  def check(pattern)
    match = anchored(pattern).match(rest)
    return nil unless match

    @match = match
    @matched = match[0]
  end

  # Advances past the next match anywhere after the position; returns the number of bytes skipped, or nil.
  def skip_until(pattern)
    match = pattern.match(rest)
    return nil unless match

    skipped = match.pre_match.bytesize + match[0].bytesize
    @match = match
    @matched = match[0]
    @pos += skipped
    skipped
  end

  # A group of the last match, by index or name.
  def [](group)
    @match && @match[group]
  end

  # The byte length of the last match, or nil if there is none.
  def matched_size
    @matched&.bytesize
  end

  # Matches at the position and advances past the match; returns its byte length or nil.
  def skip(pattern)
    scan(pattern)&.bytesize
  end

  # Like skip, without advancing: the byte length of the match at the position, or nil.
  def match?(pattern)
    check(pattern)&.bytesize
  end

  private

  def anchored(pattern)
    @anchored[pattern] ||= Regexp.new("\\A(?:#{pattern.source})", pattern.options)
  end
end

MRubyRequire.provide('strscan') { defined?(StringScanner) } if defined?(MRubyRequire)
