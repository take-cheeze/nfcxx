# frozen_string_literal: true

# PROVEN_MISS: a send whose receiver class is proven
# (a fresh `Klass.new`, an instance literal, a lexical instance `self`, a class
# constant) and whose chain answers the name by neither a definition nor
# method_missing can only raise NoMethodError. Each site is listed on stderr as
# "file:line -> name (kind Class)". No review gate judges the listing any more.
# Class hints (ClassLayout, annotations, element hints) are guarded facts and
# never make a site of this kind.
#
# Key: "<file>:<line> -> <name> (<proof kind> <class>)".
# bc2cpp.rb enforces it on every closed-world run;
# every entry must still hold over a full closed run.
require 'set'
require_relative 'review_scope'
require_relative 'nomethod_reviewed'

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

  # bc2cpp.rb's "  PROVEN_MISS <key>" stderr lines, back into sites.
  def parse_listing(stderr)
    stderr.scan(LISTING).map do |site, called, kind, klass|
      file, line = NomethodReviewed.split_site(site)
      { key: key(site, called, kind, klass), site: site, file: file, line: line, called: called, kind: kind,
        klass: klass }
    end
  end
end
