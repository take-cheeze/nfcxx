# frozen_string_literal: true

# PROVEN_MISS_REVIEWED (docs/adr/0275): a send whose receiver class is proven
# (a fresh `Klass.new`, an instance literal, a lexical instance `self`, a class
# constant) and whose chain answers the name by neither a definition nor
# method_missing can only raise NoMethodError. It is a build error on a
# closed-world run unless its key is listed here, so each one is read and
# judged: a real bug is fixed, defensive or dead code is listed with a reason.
# Class hints (ClassLayout, annotations, element hints) are guarded facts and
# never make a site of this kind.
#
# Key: "<compiled owner>#<compiled method> -> <name> (<proof kind> <class>)".
# bc2cpp.rb enforces it on every closed-world run;
# scripts/bc2cpp_proven_miss_check.rb re-proves it over a full wio run.
# Regenerate with `MRBC=... ruby scripts/bc2cpp_proven_miss_update.rb`.
require 'set'

module ProvenMiss
  MARKER = %r{/\* CLOSED_WORLD proven_miss: (\w+) (\S+?)\.(\S+) \*/}
  LISTING = /^  PROVEN_MISS (.+ -> \S+ \(\w+ \S+\))$/

  module_function

  def marker(name, kind, klass)
    "/* CLOSED_WORLD proven_miss: #{kind} #{klass}.#{name} */"
  end

  def key(owner, method, called, kind, klass)
    "#{owner}##{method} -> #{called} (#{kind} #{klass})"
  end

  # Every marked site in `compiled` (bc2cpp.rb's compiled-method hashes).
  def sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(MARKER).map do |kind, klass, called|
        { key: key(m[:owner], m[:name], called, kind, klass), owner: m[:owner], method: m[:name],
          called: called, kind: kind, klass: klass }
      end
    end
  end

  # Same contract as NomethodReviewed.violations.
  def violations(sites, compiled, reviewed: PROVEN_MISS_REVIEWED, stale: true)
    found = sites.map { |s| s[:key] }.to_set
    compiled_methods = compiled.reject { |m| m[:unsupported] }.map { |m| "#{m[:owner]}##{m[:name]}" }.to_set
    unreviewed = (found - reviewed).sort.map { |k| "unreviewed proven-class miss: #{k}" }
    return unreviewed unless stale

    stale = reviewed.select { |k| compiled_methods.include?(k.split(' -> ', 2).first) && !found.include?(k) }
    unreviewed + stale.sort.map { |k| "stale PROVEN_MISS_REVIEWED entry (no such site any more): #{k}" }
  end

  def parse_listing(stderr)
    stderr.scan(LISTING).flatten.map { |k| { key: k } }
  end
end

PROVEN_MISS_REVIEWED = Set[].freeze
