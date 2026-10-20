# frozen_string_literal: true

# NOMETHOD (docs/adr/0226): every guard-chain fallback the closed world proves dead (a `bc2cpp_nomethod` site,
# ADR 0210) is a build error unless its source line carries a review annotation:
#   # bc2cpp-reviewed: nomethod <called name> -- why the fallback is dead
# on the site's line or the line above (SourceReview). Each annotated site was read and judged a defensive branch
# the runtime rescues (see the ADR); a real bug is fixed, not annotated.
#
# Key: "<file>:<line> -> <called name>", the source line the send is written on. scripts/bc2cpp/source_review_check.rb
# re-proves the annotations in both directions over a full (not hot-only) wio run of all three gems.
require 'set'
require_relative 'review_scope'
require_relative 'source_review'

module NomethodReviewed
  # The marker names the send's source line ("file:line"), which SourceReview reads.
  MARKER = %r{/\* CLOSED_WORLD nomethod: (self|recv)\.(\S+) @ (\S+) \*/}
  # A by-name nomethod fallback and its marker, as compiled (the args up to the call's `);`).
  DIRECT_RAISE_CALL = %r{bc2cpp_nomethod_named\((M, [^\n]*?)\); (/\* CLOSED_WORLD nomethod: (?:self|recv)\.\S+ @ \S+ \*/)}
  # GUARD_VIOLATION (ADR 0290): a guard whose else arm the closed world proves dead because
  # its register holds a stable class constant. Listed, not gated: which of these exist
  # depends on which callees compile (a hot-only build has sites a full one lacks), so no
  # two-way list can be exact; the proof is the gate.
  VIOLATION_MARKER = %r{/\* CLOSED_WORLD guard-violation: (\S+) \*/}
  # NIL_RECEIVER (ADR 0296): the nil arm of a receiver the class pools prove is nil or one class.
  # A real program path (a nil dereference), so listed, never gated.
  NIL_RECEIVER_MARKER = %r{/\* CLOSED_WORLD nil-receiver: (\S+) \*/}
  # Generator kill switch: =0 keeps every guard's dispatch fallback (ADR 0290).
  GUARD_VIOLATION_ENV = 'BC2CPP_GUARD_VIOLATION'

  module_function

  # `site`: the "file:line" the send is written on (CodeGen#insn_source_site); "?:0" when none is known.
  def marker(name, self_receiver:, site:)
    "/* CLOSED_WORLD nomethod: #{self_receiver ? 'self' : 'recv'}.#{name} @ #{site} */"
  end

  def violation_marker(name)
    "/* CLOSED_WORLD guard-violation: #{name} */"
  end

  def nil_receiver_marker(name)
    "/* CLOSED_WORLD nil-receiver: #{name} */"
  end

  # The NIL_RECEIVER keys of `compiled`, for the stderr listing.
  def nil_receiver_sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(NIL_RECEIVER_MARKER).map { |(called)| key(m[:owner], m[:name], called) }
    end
  end

  def guard_violation_enabled?
    ENV[GUARD_VIOLATION_ENV] != '0'
  end

  # The listing key of a site: where the send is written, and the name it sends.
  def key(owner, method, called)
    "#{owner}##{method} -> #{called}"
  end

  def site_key(site, called)
    "#{site} -> #{called}"
  end

  # Every marked site in `compiled` (bc2cpp.rb's compiled-method hashes).
  def sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(MARKER).map do |recv, called, site|
        file, line = split_site(site)
        { key: site_key(site, called), owner: m[:owner], method: m[:name], called: called, site: site,
          file: file, line: line, self_receiver: recv == 'self' }
      end
    end
  end

  # "file:line" -> [file, line]; the last colon separates them, so a path may contain colons.
  def split_site(site)
    file, _, line = site.rpartition(':')
    [file, line.to_i]
  end

  # DIRECT_RAISE (ADR 0226): a reviewed site's by-name fallback calls bc2cpp_nomethod_raise_named, which raises the
  # NoMethodError without dispatching, instead of bc2cpp_nomethod_named. Only the callee name changes, and the marker
  # stays, so the gate still counts the site. A site without an annotation keeps the dispatching fallback.
  def direct_raise(code)
    return code unless code.include?('CLOSED_WORLD nomethod:')

    code.gsub(DIRECT_RAISE_CALL) do
      whole, args, marker = Regexp.last_match(0), Regexp.last_match(1), Regexp.last_match(2)
      _recv, called, site = MARKER.match(marker).captures
      file, line = split_site(site)
      if SourceReview.annotated?(file, line, SourceReview.key('nomethod', called))
        "bc2cpp_nomethod_raise_named(#{args}); #{marker}"
      else
        whole
      end
    end
  end

  # The GUARD_VIOLATION keys of `compiled`, for the stderr listing.
  def violation_sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(VIOLATION_MARKER).map { |(called)| key(m[:owner], m[:name], called) }
    end
  end

  # Why this run's sites are unreviewed: a site whose source line carries no `nomethod <name>` annotation. `scope`:
  # ReviewScope.for_build of the run (tools/bc2cpp/review_scope.rb); sites outside it are not the program judged.
  def violations(sites, scope:)
    ReviewScope.select(scope, sites).reject { |s| reviewed?(s) }.map do |s|
      where = s[:file] == '?' ? 'no source line behind this send' : s[:site]
      "unreviewed dead fallback: #{s[:key]} (#{where}; annotate it: # bc2cpp-reviewed: nomethod #{s[:called]} -- reason)"
    end.uniq.sort
  end

  def reviewed?(site)
    SourceReview.annotated?(site[:file], site[:line], SourceReview.key('nomethod', site[:called]))
  end

  # bc2cpp.rb's "  NOMETHOD <key>[ [self]]" stderr lines, back into sites.
  def parse_listing(stderr)
    stderr.scan(/^  NOMETHOD (.+? -> \S+?)( \[self\])?$/).map do |k, s|
      site, called = k.split(' -> ', 2)
      file, line = split_site(site)
      { key: k, site: site, file: file, line: line, called: called, self_receiver: !s.nil? }
    end
  end
end
