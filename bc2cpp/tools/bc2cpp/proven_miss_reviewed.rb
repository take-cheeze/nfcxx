# frozen_string_literal: true

# PROVEN_MISS (docs/adr/0275): a send whose receiver class is proven
# (a fresh `Klass.new`, an instance literal, a lexical instance `self`, a class
# constant) and whose chain answers the name by neither a definition nor
# method_missing can only raise NoMethodError. It is a build error on a
# closed-world run unless its source line carries a review annotation:
#   # bc2cpp-reviewed: proven_miss <kind> <Class>.<name> -- why the miss is defensive or dead
# so each one is read and judged: a real bug is fixed, defensive or dead code is annotated with a reason.
# Class hints (ClassLayout, annotations, element hints) are guarded facts and
# never make a site of this kind.
#
# Key: "<file>:<line> -> <name> (<proof kind> <class>)".
# bc2cpp.rb enforces it on every closed-world run;
# scripts/bc2cpp/proven_miss_check.rb re-proves it over a full wio run.
require 'set'
require_relative 'review_scope'
require_relative 'nomethod_reviewed'
require_relative 'source_review'

module ProvenMiss
  MARKER = %r{/\* CLOSED_WORLD proven_miss: (\w+) (\S+?)\.(\S+) @ (\S+) \*/}
  LISTING = /^  PROVEN_MISS (.+) -> (\S+) \((\w+) (\S+)\)$/

  module_function

  # `site`: the "file:line" the send is written on.
  def marker(name, kind, klass, site:)
    "/* CLOSED_WORLD proven_miss: #{kind} #{klass}.#{name} @ #{site} */"
  end

  def key(site, called, kind, klass)
    "#{site} -> #{called} (#{kind} #{klass})"
  end

  # The annotation key of a site: "proven_miss <kind> <Class>.<name>".
  def review_key(kind, klass, called)
    SourceReview.key('proven_miss', "#{kind} #{klass}.#{called}")
  end

  # Every marked site in `compiled` (bc2cpp.rb's compiled-method hashes).
  def sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(MARKER).map do |kind, klass, called, site|
        file, line = NomethodReviewed.split_site(site)
        { key: key(site, called, kind, klass), owner: m[:owner], method: m[:name], called: called,
          kind: kind, klass: klass, site: site, file: file, line: line }
      end
    end
  end

  # Why this run's sites are unreviewed: a site whose source line carries no `proven_miss` annotation for its kind
  # and class. `scope`: ReviewScope.for_build of the run. Stale annotations are checked by source_review_check.rb.
  def violations(sites, scope:)
    ReviewScope.select(scope, sites).reject { |s| reviewed?(s) }.map do |s|
      "unreviewed proven-class miss: #{s[:key]} (annotate it: # bc2cpp-reviewed: proven_miss " \
        "#{s[:kind]} #{s[:klass]}.#{s[:called]} -- reason)"
    end.uniq.sort
  end

  def reviewed?(site)
    SourceReview.annotated?(site[:file], site[:line], review_key(site[:kind], site[:klass], site[:called]))
  end

  # bc2cpp.rb's "  PROVEN_MISS <key>" stderr lines, back into sites.
  def parse_listing(stderr)
    stderr.scan(LISTING).map do |site, called, kind, klass|
      file, line = NomethodReviewed.split_site(site)
      { key: key(site, called, kind, klass), site: site, file: file, line: line, called: called, kind: kind,
        klass: klass }
    end
  end
end
