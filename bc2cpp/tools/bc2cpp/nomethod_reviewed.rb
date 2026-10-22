# frozen_string_literal: true

# NOMETHOD (docs/adr/0226): every guard-chain fallback the closed world proves dead (a `bc2cpp_nomethod` site,
# ADR 0210) is listed on stderr as "file:line -> called name", the source line the send is written on. No review
# gate judges the listing any more (ADR 0522).
require 'set'
require_relative 'review_scope'

module NomethodReviewed
  # The marker names the send's source line ("file:line").
  MARKER = %r{/\* CLOSED_WORLD nomethod: (self|recv)\.(\S+) @ (\S+) \*/}
  # GUARD_VIOLATION (ADR 0290): a guard whose else arm the closed world proves dead because
  # its register holds a stable class constant. Listed, not gated: which of these exist
  # depends on which callees compile, so no
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

  # The GUARD_VIOLATION keys of `compiled`, for the stderr listing.
  def violation_sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(VIOLATION_MARKER).map { |(called)| key(m[:owner], m[:name], called) }
    end
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
