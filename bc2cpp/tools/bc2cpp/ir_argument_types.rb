# frozen_string_literal: true

require 'set'

# Reporting-only joins. Excluding a caller requires a complete receiver set and
# stable dispatch for every member; an unknown receiver can reach any definition.
module IrArgumentTypes
  module_function

  # +arity+ is the accepted argument count: an Integer, or a Range for optional positionals. A reaching site
  # must pass +position+ itself; one that stops short binds the default there, which no call-site value describes.
  def classes(definition, position, sites, receiver:, target:, argument:, arity:)
    accepted = arity.is_a?(Range) ? arity : arity..arity
    reached = reaching_sites(definition, sites, receiver: receiver, target: target)
    return nil unless reached && !reached.empty?

    joined = Set.new
    reached.each do |irep, index, register, argc|
      return nil unless accepted.cover?(argc) && argc >= position

      values = argument.call(irep, index, register + position)
      return nil unless values && !values.empty?

      joined.merge(values)
    end
    joined.freeze
  end

  # Rest parameter (`*rest` after +fixed+ = mandatory + optional positionals): the join of every extra argument over
  # the reaching sites. The site list is complete (a dynamic or unknown caller poisons the name before this runs),
  # so the sites that pass any extra argument are known exactly; with none there is no element to type. +admit+
  # refuses a site whose argument layout is not plain positional (keyword pairs, see the caller).
  def rest_classes(definition, sites, receiver:, target:, argument:, fixed:, minimum:, admit:)
    reached = reaching_sites(definition, sites, receiver: receiver, target: target)
    return nil unless reached && !reached.empty?

    joined = Set.new
    passing = 0
    reached.each do |irep, index, register, argc|
      return nil unless admit.call(irep, index) && argc >= minimum
      next unless argc > fixed

      (fixed + 1..argc).each do |position|
        values = argument.call(irep, index, register + position)
        return nil unless values && !values.empty?

        joined.merge(values)
      end
      passing += 1
    end
    passing.positive? ? joined.freeze : nil
  end

  # Block parameter: Proc when every reaching site passes a block that +proc_value+ proves is a Proc (a literal
  # block or lambda). A site that passes no block binds nil, so one such site refuses the whole join.
  def block_proc(definition, sites, receiver:, target:, proc_value:)
    reached = reaching_sites(definition, sites, receiver: receiver, target: target)
    return nil unless reached && !reached.empty?
    return nil unless reached.all? { |irep, index, register, argc| proc_value.call(irep, index, register, argc) }

    Set[:Proc].freeze
  end

  # Keyword: the join of the value passed for it at every reaching site. +value+ returns the classes of that site's
  # keyword value, or nil when that site refuses the join. Required (+default+ nil): every site must pass the key as a
  # literal pair, so +value+ never returns empty classes. Optional: +default+ is the default's classes, joined in
  # because an omitting site binds it; +value+ returns empty classes for such a site.
  def keyword_classes(definition, sites, receiver:, target:, value:, default: nil)
    reached = reaching_sites(definition, sites, receiver: receiver, target: target)
    return nil unless reached && !reached.empty?

    joined = Set.new
    reached.each do |irep, index, register, argc|
      values = value.call(irep, index, register, argc)
      return nil unless values && (default || !values.empty?)

      joined.merge(values)
    end
    default ? joined.merge(default).freeze : joined.freeze
  end

  # The sites that can reach +definition+, as [irep, index, register, argc]. Nil when any site's receiver set or
  # dispatch target is unknown: such a site may or may not be a caller, so no join over the rest is complete.
  def reaching_sites(definition, sites, receiver:, target:)
    reached = []
    sites.each do |irep, index, register, argc, _owner|
      receivers = receiver.call(irep, index, register)
      return nil unless receivers && !receivers.empty?

      targets = receivers.map { |klass| target.call(definition.name, klass.to_s) }
      return nil if targets.any?(&:nil?)
      next unless targets.any? { |body| body.irep == definition.irep }

      reached << [irep, index, register, argc]
    end
    reached
  end
end
