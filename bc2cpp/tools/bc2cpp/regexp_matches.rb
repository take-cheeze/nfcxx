# frozen_string_literal: true

# The matches of +re+ in +text+, each a copy of its MatchData taken inside scan's block.
#
# Do not write `text.to_enum(:scan, re).map { Regexp.last_match }`: mruby's enumerator reads $~ after the scan has
# finished, so every element is the final match (the self-compiled bc2cpp then refused the closed world; see
# docs/notes/bc2cpp-self-aot.md). Inside the block, Regexp.last_match is the current match in both CRuby and mruby.
module RegexpMatches
  module_function

  def of(text, re)
    found = []
    text.scan(re) { found << Regexp.last_match.dup }
    found
  end
end
