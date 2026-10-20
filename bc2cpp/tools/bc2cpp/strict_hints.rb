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
# is a wrong or incomplete hint, fixed at its source.
#
# Every forced site carries `/* STRICT_HINT FAMILY: name @ file:line */`, is listed on stderr
# (`STRICT_HINT_SITE file:line -> name (FAMILY)`) and must carry a review annotation on its source line
# (`# bc2cpp-reviewed: strict_hint FAMILY name -- reason`, tools/bc2cpp/source_review.rb), the way NOMETHOD holds dead fallbacks.
require 'set'
require_relative 'review_scope'
require_relative 'source_review'

module StrictHints
  ENV_NAME = 'BC2CPP_STRICT_HINTS'
  FAMILIES = %w[typed element ivar_accessor mono_embed poly_small_n poly_table interface_table subtree].freeze
  # `1` forces the families that read a receiver hint (layout, annotation, element); `all` adds the
  # candidate-set chains and tables, whose receivers are not traced (docs/adr/0419).
  DEFAULT_FAMILIES = %w[typed element ivar_accessor mono_embed].freeze
  MARKER = %r{/\* STRICT_HINT (\w+): (\S+) @ (\S+) \*/}
  LISTING = /^  STRICT_HINT_SITE (.+) -> (\S+) \((\w+)\)$/
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

  def enabled?(family)
    families.include?(family)
  end

  # `site`: the "file:line" the send is written on (CodeGen#insn_source_site).
  def marker(family, name, site:)
    "/* STRICT_HINT #{family}: #{name} @ #{site} */"
  end

  def key(site, called, family)
    "#{site} -> #{called} (#{family.upcase})"
  end

  # Every marked site in `compiled` (bc2cpp.rb's compiled-method hashes).
  def sites(compiled)
    compiled.flat_map do |m|
      m[:code].scan(MARKER).map do |family, called, site|
        file, line = NomethodReviewed.split_site(site)
        { key: key(site, called, family), owner: m[:owner], method: m[:name], called: called, family: family,
          site: site, file: file, line: line }
      end
    end
  end

  # bc2cpp.rb's "  STRICT_HINT_SITE <key>" stderr lines, back into sites.
  def parse_listing(stderr)
    stderr.scan(LISTING).map do |site, called, family|
      file, line = NomethodReviewed.split_site(site)
      { key: key(site, called, family.downcase), site: site, file: file, line: line, called: called,
        family: family.downcase }
    end
  end

  # Why this run's sites are unreviewed: a forced site whose source line carries no `strict_hint <family> <name>`
  # annotation. `scope`: ReviewScope.for_build of the run. Stale annotations are checked by source_review_check.rb.
  def violations(sites, scope:)
    ReviewScope.select(scope, sites).reject { |s| reviewed?(s) }.map do |s|
      "unreviewed forced hint: #{s[:key]} (annotate it: # bc2cpp-reviewed: strict_hint #{s[:family]} #{s[:called]} -- reason)"
    end.uniq.sort
  end

  def reviewed?(site)
    SourceReview.annotated?(site[:file], site[:line], SourceReview.key('strict_hint', "#{site[:family]} #{site[:called]}"))
  end

  def family_counts(compiled)
    sites(compiled).group_by { |s| s[:family].upcase }.transform_values(&:size)
  end
end
