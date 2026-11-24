# frozen_string_literal: true

require 'set'

# CLASS_REACH (closed only, the entries run of CoreNativeCandidates.reachable under ENGINE_SENDS_COMPILED): a generated
# owner call (OUTSIDE_OWNER_CALL, symbol_cache.rb) looks its name up on the receiver and runs the method only when the
# definer is one of the owners the compiler listed at the site; any other definer is a violated proof, which raises.
# So under that proof the site reaches the listed owners' definitions of the name and no other: a definition of the
# name on an unlisted owner is left out unless some other lookup names it. A nil-receiver site (NIL_SITES) dispatches
# on nil, which only nil's chain and the modules along it can answer. Every other spelling of the name -- a by-name
# send, a literal, a native's lookup, core Ruby's sends -- still reaches every owner's definition.
#
# BC2CPP_CLASS_REACH=0 reads those sites as reaching every owner again. The lists record the keys left out this way
# (StaticDispatchLists#class_reach); a build with BC2CPP_CLASS_REACH_VERIFY aborts on an owner-call violation, and the
# UNREGISTERED_VERIFY stubs it is built with abort on a by-name lookup of a left-out entry.
module ClassReach
  # A site's descriptor: the slot (the symbol table index of the name) and level, then the owners; BC2CPP_OWNERS_D puts
  # the direct rows between them, BC2CPP_SHARED its key in front.
  SITE = /(?<![\w#])BC2CPP_(OWNERS|OWNERS_D|SHARED)\(/
  INT = /\A\s*\d+\s*\z/
  OWNER = /\A\s*"([A-Z][\w:]*(?:\.singleton)?)"\s*\z/
  DIRECT = /\A\s*BC2CPP_OWNER_DIRECT\(/
  # A nil-receiver site's slot: bc2cpp_nil_receiver_id(M, I...) or bc2cpp_nil_receiver(M, recv, I...).
  NIL_SITE = /(?<![\w#])bc2cpp_nil_receiver(?:_id\(M, |\(M, [^,()]+, )(\d+)(?=[,)])/
  # What a nil site reaches: nil's lookup runs NilClass, Object and BasicObject, and any module included along them.
  NIL = :nil
  NIL_CLASSES = %w[NilClass Object BasicObject].to_set.freeze

  module_function

  def enabled?(env = ENV)
    env['BC2CPP_CLASS_REACH'] != '0'
  end

  # `text` (a generated unit without its symbol table) with each owner site's slot operand blanked; `typed` (name =>
  # Set of owners) gains the site's name and owners. A site whose operands do not read as above keeps its slot, which
  # the caller then counts as a lookup of the name on every owner.
  def blank_owner_slots(text, table, typed)
    out = nil
    text.to_enum(:scan, SITE).each do
      m = Regexp.last_match
      line_start = text.rindex("\n", m.begin(0)) || 0
      next if text[line_start, m.begin(0) - line_start].match?(/^\s*#/)

      spans = StaticDispatchRegistrations.call_arg_spans(text, m.end(0) - 1) or next
      args = spans.map { |from, to| text[from...to] }
      slot_at = m[1] == 'SHARED' ? 1 : 0
      next unless args.size > slot_at + 2 && args[slot_at].match?(INT) && args[slot_at + 1].match?(INT)

      rest = args[(slot_at + 2)..]
      owners = rest.drop_while { |a| m[1] == 'OWNERS_D' && a.match?(DIRECT) }
      next if owners.empty? || !owners.all? { |a| a.match?(OWNER) }
      next if m[1] != 'OWNERS_D' && owners.size != rest.size

      name = table[args[slot_at].to_i] or next
      (typed[name] ||= Set.new).merge(owners.map { |a| a[OWNER, 1] })
      from, to = spans[slot_at]
      (out ||= text.dup)[from...to] = ' ' * (to - from)
    end
    # NIL_SITES: the nil arm of a receiver (NIL_RECEIVER, symbol_cache.rb) dispatches the name on nil.
    text = out || text
    nil_sites = text.to_enum(:scan, NIL_SITE).map { Regexp.last_match }
    unless nil_sites.empty?
      out = text.dup
      nil_sites.each do |mm|
        name = table[mm[1].to_i] or next
        (typed[name] ||= Set.new) << NIL
        out[mm.begin(1)...mm.end(1)] = ' ' * (mm.end(1) - mm.begin(1))
      end
    end
    out || text
  end

  # The classes a nil site's reach rules out by being classes: every one declared or defined in the world but nil's
  # own chain. Anything else -- a module, a singleton, a name not known to be a class -- counts as reached.
  @classes = Set.new.freeze
  class << self
    attr_accessor :classes
  end

  # Whether a CLASS_REACH site reaches `owner`'s definition of `name`.
  def reaches?(typed, name, owner)
    return false unless typed && owner

    sites = typed[name] or return false
    sites.include?(owner) || (sites.include?(NIL) && !(ClassReach.classes.include?(owner) && !NIL_CLASSES.include?(owner)))
  end

  # The same for a ROM entry, whose table names its class by token (CoreNativeCandidates.engine_token).
  def reaches_token?(typed, name, token)
    return false unless typed

    sites = typed[name] or return false
    owner = CoreNativeCandidates.engine_owner(token) || token
    reaches?(typed, name, owner) || sites.any? { |o| o.is_a?(String) && CoreNativeCandidates.engine_token(o) == token }
  end
end
