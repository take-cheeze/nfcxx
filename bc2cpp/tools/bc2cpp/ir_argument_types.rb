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
    joined = Set.new
    reached = false
    sites.each do |irep, index, register, argc, _owner|
      receivers = receiver.call(irep, index, register)
      return nil unless receivers && !receivers.empty?

      targets = receivers.map { |klass| target.call(definition.name, klass.to_s) }
      return nil if targets.any?(&:nil?)
      next unless targets.any? { |body| body.irep == definition.irep }

      return nil unless accepted.cover?(argc) && argc >= position

      values = argument.call(irep, index, register + position)
      return nil unless values && !values.empty?

      reached = true
      joined.merge(values)
    end
    reached ? joined.freeze : nil
  end
end
