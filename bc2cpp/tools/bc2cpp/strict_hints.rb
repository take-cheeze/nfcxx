# frozen_string_literal: true

# STRICT_HINTS (docs/adr/0419): an opt-in tier that forces the whole-program class HINTS of a
# closed-world build. A guarded hint site is `if (class guard) direct-call else bc2cpp_send(...)`;
# with BC2CPP_STRICT_HINTS=1 the else arm of the families below is `bc2cpp_hint_violation`, which
# logs `[RPG2k] hint violation: <Class>#<name> at <Owner#method (FAMILY)>` to $stderr and raises
# BC2cppHintViolation < NoMethodError, so no by-name send is left at the site and a wrong hint
# fails loudly instead of costing speed. Default ON (ADR 0438): unset or empty selects `1`; `0` is the
# byte-identical baseline with the tier off.
#
# Families (BC2CPP_STRICT_HINTS=1 selects the first four, `all` every one; a comma list selects some):
#   typed             TYPED / CLOSED_WORLD_TYPED_INHERITED: receiver class traced from a ClassLayout ivar
#                     fact, a ClassAnnotations argument, a class pool or a capture hint
#   element           the same for the element hint of an inlined loop parameter (TYPED/ELEMENT)
#   ivar_accessor     IVAR_ACCESSOR_DEVIRT (attr_reader / attr_writer) behind the same hints
#   mono_embed        MONO_EMBED_GUARD whose receiver also has such a hint naming the owner
#   poly_small_n      the else arm of a POLY_SMALL_N / INHERITED_GUARD chain (the candidate set is the hint)
#   poly_table        the else arm of an outlined POLY_TABLE
#   interface_table   the else arm of an interface-table dispatch
#   subtree           the else arm of a SUBTREE_TABLE / SUBTREE_DIRECT site (docs/adr/0453); only when listed by
#                     name or by `all`, never by `1`
# Not forced: numeric arms (Float, Bignum and overflow promotion are legitimate flows on their
# slow-path helpers) and the families docs/adr/0419 lists with their evidence.
#
# Policy: a hint is not a proof, so no proof gates the forcing; every violation the verify build finds
# is a wrong or incomplete hint, fixed at its source. BC2CPP_STRICT_HINTS_PROVEN=1 restricts the tier to
# owners with no descendant and a name nil does not answer (the conservative setting).
#
# Every forced site carries `/* STRICT_HINT FAMILY: name */`, is listed on stderr
# (`STRICT_HINT_SITE Owner#method -> name (FAMILY)`) and must be in STRICT_HINTS_REVIEWED
# (tools/bc2cpp/strict_hints_reviewed.rb), the way NOMETHOD_REVIEWED holds dead fallbacks.
require 'set'
require_relative 'review_scope'

module StrictHints
  ENV_NAME = 'BC2CPP_STRICT_HINTS'
  FAMILIES = %w[typed element ivar_accessor mono_embed poly_small_n poly_table interface_table subtree].freeze
  # `1` forces the families that read a receiver hint (layout, annotation, element); `all` adds the
  # candidate-set chains and tables, whose receivers are not traced (docs/adr/0419).
  DEFAULT_FAMILIES = %w[typed element ivar_accessor mono_embed].freeze
  MARKER = %r{/\* STRICT_HINT (\w+): (\S+) \*/}
  LISTING = /^  STRICT_HINT_SITE (.+ -> \S+ \(\w+\))$/
  # Classes whose exact-class guards are exact-core-type guards (kept) or whose instances are the
  # numeric and nil values the tier never forces.
  CORE_OWNERS = %w[Object BasicObject Kernel Module Class Comparable Enumerable Array Hash String Symbol Range
                   Integer Float Numeric NilClass TrueClass FalseClass Proc Struct Exception StandardError
                   Regexp MatchData Time Fiber Enumerator Set Rational Complex].freeze

  module_function

  # The enabled families: "0" none, nil/""/"1" the receiver-hint families (the default), "all" every
  # family, else a comma list (unknown names abort).
  def families(env = ENV[ENV_NAME])
    return [] if env == '0'
    return DEFAULT_FAMILIES if env.nil? || env.empty? || env == '1'
    return FAMILIES if env == 'all'

    list = env.split(',').map(&:strip).reject(&:empty?)
    unknown = list - FAMILIES
    raise ArgumentError, "#{ENV_NAME}: unknown famil#{unknown.size > 1 ? 'ies' : 'y'} #{unknown.join(', ')} (known: #{FAMILIES.join(', ')})" unless unknown.empty?

    list
  end

  # BC2CPP_STRICT_HINTS_PROVEN=1: force only sites the closed world proves cannot see a legitimate
  # receiver of another class (no descendant of the hint class, a name nil does not answer).
  def proven_only?
    ENV['BC2CPP_STRICT_HINTS_PROVEN'] == '1'
  end

  def enabled?(family)
    families.include?(family)
  end

  def marker(family, name)
    "/* STRICT_HINT #{family}: #{name} */"
  end

  def key(owner, method, called, family)
    "#{owner}##{method} -> #{called} (#{family.upcase})"
  end

  # Every marked site in `compiled` (bc2cpp.rb's compiled-method hashes).
  def sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(MARKER).map do |family, called|
        { key: key(m[:owner], m[:name], called, family), owner: m[:owner], method: m[:name], called: called,
          family: family }
      end
    end
  end

  def parse_listing(stderr)
    stderr.scan(LISTING).flatten
  end

  # Why this run's sites break STRICT_HINTS_REVIEWED; empty when they do not. As NomethodReviewed:
  # stale entries only for methods this run compiled, and not at all for a hot-only run. `scope`:
  # ReviewScope.for_build of the run (tools/bc2cpp/review_scope.rb).
  def violations(sites, compiled, scope:, reviewed: reviewed_set, stale: true)
    found = ReviewScope.select(scope, sites).map { |s| s[:key] }.to_set
    compiled_methods = compiled.reject { |m| m[:unsupported] || !ReviewScope.cover?(scope, m[:owner]) }
                               .map { |m| "#{m[:owner]}##{m[:name]}" }.to_set
    unreviewed = (found - reviewed).sort.map { |k| "unreviewed forced hint: #{k}" }
    return unreviewed unless stale

    # An entry of a family this run did not force is not stale: it is simply not in play.
    on = families.map(&:upcase)
    gone = reviewed.select do |k|
      compiled_methods.include?(k.split(' -> ', 2).first) && on.include?(k[/\((\w+)\)\z/, 1]) && !found.include?(k)
    end
    unreviewed + gone.sort.map { |k| "stale STRICT_HINTS_REVIEWED entry (no such site any more): #{k}" }
  end

  def reviewed_set
    require_relative 'strict_hints_reviewed'
    STRICT_HINTS_REVIEWED
  end

  def family_counts(compiled)
    sites(compiled).group_by { |s| s[:family].upcase }.transform_values(&:size)
  end
end
