# frozen_string_literal: true

require 'set'
require_relative 'class_layout'

# SUBTREE_DISPATCH: "an instance of C or of any descendant of C", a receiver fact distinct from the
# exact-class facts ClassLayout, ClassAnnotations and the RBS class types give. Only the send devirtualization reads
# it (codegen_subtree_dispatch.rb); embedding, constructor pools and element facts stay on exact facts.
#
# Sources:
#   join  an ivar ClassLayout poisoned because its stores disagree, when every store resolved to a declared class and
#         those classes meet at a nearest common declared ancestor A below Object whose subtree the closed world
#         enumerates (closed_root?). NIL_TOLERANT_JOIN is kept: `@x = nil` stores are not in the store log.
#   rbs   an ivar, parameter or return type naming a class with descendants (RbsSignatures.apply routes those here
#         instead of to the exact tables).
# Kill switch BC2CPP_SUBTREE_DISPATCH=0: no fact, no table, output byte-identical to the build without this file.
module SubtreeFacts
  ENV_NAME = 'BC2CPP_SUBTREE_DISPATCH'

  # ivars: owner -> {ivar => root}; args: irep label -> [root or nil] per required parameter; returns: irep label ->
  # root; sources: printable `kind owner#slot (root)` lines.
  Facts = Struct.new(:ivars, :args, :returns, :sources, keyword_init: true) do
    def roots
      @roots ||= (ivars.values.flat_map(&:values) + args.values.flatten.compact + returns.values).to_set
    end

    def empty?
      ivars.empty? && args.empty? && returns.empty?
    end
  end

  module_function

  def enabled?(env = ENV[ENV_NAME])
    env != '0'
  end

  # Is `root`'s subtree one the closed world enumerates completely: a declared class below Object, its hierarchy
  # known (no opaque class, no Class.new or rebinding of it), no descendant of unresolved ancestry, no Module/Class
  # ancestry, and at least one descendant (without one the exact fact says the same).
  def closed_root?(root, world)
    return false unless root.is_a?(String) && world && world.global_refusal.nil?
    return false if %w[Object BasicObject].include?(root) || !world.class_declared?(root)

    hierarchy = world.class_hierarchy(root)
    return false unless hierarchy && hierarchy[:wild].empty? && !hierarchy[:descendants].empty?

    world.instance_class?(root) && hierarchy[:descendants].all? { |klass| world.class_declared?(klass) }
  end

  # `klass` and its declared ancestors, nearest first, as far as ClosedWorld#declared_parent names them.
  def ancestry(klass, world)
    chain = []
    current = klass
    while current.is_a?(String) && world.class_declared?(current) && !chain.include?(current)
      chain << current
      current = world.declared_parent(current)
    end
    chain
  end

  # The nearest declared class every one of `classes` is or descends from; nil when the chains do not meet (their
  # only common ancestor would be Object) or one stops at an ancestor it cannot name.
  def common_ancestor(classes, world)
    chains = classes.map { |klass| ancestry(klass, world) }
    chains.first.find { |klass| chains.all? { |chain| chain.include?(klass) } }
  end

  # The join source. `raw` is ClassLayout.analyze's result, `store_log` the one it filled (IVAR_POISON_CAUSES: one
  # entry per SETIV, the last pass's resolution).
  def from_layout(raw, store_log, world)
    found_by_ivar = Hash.new { |h, k| h[k] = [] }
    store_log.each { |(owner, _label, _idx), (ivar, found, *)| found_by_ivar[[owner, ivar]] << found }
    out = {}
    found_by_ivar.sort_by { |key, _| key }.each do |(owner, ivar), found|
      next unless raw.key?(owner) && raw[owner][ivar] == ClassLayout::UNKNOWN

      classes = found.uniq
      next if classes.size < 2 || !classes.all? { |klass| klass.is_a?(String) && world.class_declared?(klass) }

      root = common_ancestor(classes, world)
      (out[owner] ||= {})[ivar] = root if root && closed_root?(root, world)
    end
    out
  end

  # Joins the sources. `exact_layout` is ClassLayout.known after the RBS seeds: an exact fact keeps priority, so an
  # RBS subtree ivar only fills an ivar the inference left without one. `labels` names an irep label for the listing.
  def build(raw:, store_log:, world:, exact_layout:, applied: nil, labels: {})
    sources = []
    ivars = from_layout(raw, store_log, world)
    ivars.each do |owner, slots|
      slots.each { |ivar, root| sources << "join #{owner}#@#{ivar} (#{root})" }
    end
    args = {}
    returns = {}
    if applied
      applied.subtree_ivars.each do |owner, slots|
        slots.each do |ivar, root|
          next if exact_layout.dig(owner, ivar) || ivars.dig(owner, ivar) || !closed_root?(root, world)

          (ivars[owner] ||= {})[ivar] = root
          sources << "rbs-ivar #{owner}#@#{ivar} (#{root})"
        end
      end
      applied.subtree_args.each do |label, roots|
        kept = roots.map { |root| root if closed_root?(root, world) }
        next if kept.compact.empty?

        args[label] = kept
        kept.each_with_index { |root, i| sources << "rbs-param #{labels[label] || label} ##{i + 1} (#{root})" if root }
      end
      applied.subtree_returns.each do |label, root|
        next unless closed_root?(root, world)

        returns[label] = root
        sources << "rbs-return #{labels[label] || label} (#{root})"
      end
    end
    Facts.new(ivars: ivars, args: args, returns: returns, sources: sources)
  end
end
